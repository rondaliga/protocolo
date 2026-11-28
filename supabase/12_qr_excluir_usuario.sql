-- =====================================================================
-- MIGRAÇÃO 12 — Busca por QR Code, exclusão de usuário inativo e urgência automática
-- Rode DEPOIS da 11 (ou use instalacao_completa.sql). Pode ser executada mais de uma vez.
--   • protocolo_por_numero(): usada pelo QR Code da ficha impressa (abre o protocolo direto).
--   • painel_excluir_usuario(): só para usuário INATIVO e sem registros no livro.
--   • Toda demanda judicial é urgente (sem caixa de seleção): a regra fica no banco.
-- =====================================================================

-- ---------- 1. QR Code: localizar o protocolo pelo número (respeitando quem pode ver)
create or replace function public.protocolo_por_numero(p_numero text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_num text := btrim(coalesce(p_numero, ''));
begin
  perform public._uid();
  if v_num !~ '^[0-9A-Za-z-]{3,30}$' then return null; end if;
  select id into v_id from public.protocolos where numero = v_num;
  if v_id is null or not public.pode_ver_protocolo(v_id) then return null; end if;
  return v_id;
end $$;

-- ---------- 2. toda demanda judicial é urgente
create or replace function public._protocolos_guarda() returns trigger
language plpgsql as $$
begin
  if new.id is distinct from old.id or new.numero is distinct from old.numero
     or new.descricao is distinct from old.descricao or new.created_at is distinct from old.created_at
     or new.created_by is distinct from old.created_by
     or new.tipo is distinct from old.tipo
     or (new.urgente is distinct from old.urgente and coalesce(current_setting('app.alteracao_autorizada', true), '') <> 'URGENCIA') then
    raise exception 'Campos originais do protocolo são imutáveis. Use a correção com justificativa.'
      using errcode = '42501';
  end if;
  if old.setor_destino_id is not null and new.setor_destino_id is distinct from old.setor_destino_id
     and coalesce(current_setting('app.alteracao_autorizada', true), '') <> 'REDIRECIONAR' then
    raise exception 'O setor de destino só pode ser alterado por reencaminhamento ou devolução, com justificativa.' using errcode = '42501';
  end if;
  if new.status is distinct from old.status and not (
       (old.status = 'pendente_adm'   and new.status = 'pendente_setor') or
       (old.status = 'pendente_setor' and new.status = 'concluido')) then
    raise exception 'Transição de status inválida.' using errcode = '42501';
  end if;
  return new;
end $$;

create or replace function public._trg_protocolos_urgencia() returns trigger
language plpgsql as $$
begin
  new.urgente := (new.tipo = 'judicial');
  return new;
end $$;
drop trigger if exists trg_protocolos_urgencia on public.protocolos;
create trigger trg_protocolos_urgencia before insert on public.protocolos
  for each row execute function public._trg_protocolos_urgencia();

-- protocolos já existentes: judicial passa a constar como urgente (alteração autorizada, só deste campo)
do $$
begin
  perform set_config('app.alteracao_autorizada', 'URGENCIA', true);
  update public.protocolos set urgente = (tipo = 'judicial') where urgente is distinct from (tipo = 'judicial');
  perform set_config('app.alteracao_autorizada', '', true);
end $$;

create or replace function public.registrar_protocolo(
  p_descricao text, p_pin text, p_assinatura text default null,
  p_tipo text default 'correspondencia', p_urgente boolean default false, p_foto_caminho text default null,
  p_assinatura_modo text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_desc text; v_png text; v_msg text; v_modo text;
  v_agora timestamptz := now(); v_ano int; v_n int; v_num text; v_id bigint;
  v_tipo text := coalesce(p_tipo, 'correspondencia'); v_urg boolean;
  v_foto text := nullif(btrim(coalesce(p_foto_caminho, '')), ''); v_tam int;
  v_dias int; v_prazo date; v_sla timestamptz;
begin
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  if not found or v_perfil.papel not in ('portaria', 'gestor') then
    raise exception 'Seu perfil não tem permissão para registrar protocolos.' using errcode = '42501';
  end if;
  if v_tipo not in ('judicial', 'correspondencia') then raise exception 'Tipo de documento inválido.'; end if;
  v_urg := (v_tipo = 'judicial');          -- toda demanda judicial é urgente; o parâmetro p_urgente é ignorado
  v_desc := public._validar_descricao(p_descricao);
  v_png  := public._validar_assinatura(p_assinatura);
  v_modo := public._modo_assinatura(v_png, p_assinatura_modo);

  if v_foto is null then
    if v_tipo = 'judicial' and public._param_text('foto_obrigatoria_judicial', 'true') = 'true' then
      raise exception 'Demandas judiciais exigem a foto do envelope ou da capa do documento.';
    end if;
  else
    if v_foto !~ ('^' || v_uid::text || '/[0-9a-f-]{36}\.jpg$') then raise exception 'Caminho da foto inválido.'; end if;
    select (metadata ->> 'size')::int into v_tam from storage.objects
     where bucket_id = 'protocolo-fotos' and name = v_foto;
    if not found then raise exception 'A foto enviada não foi encontrada. Envie novamente.'; end if;
    if exists (select 1 from public.protocolo_fotos where caminho = v_foto) then
      raise exception 'Esta foto já foi usada em outro protocolo.';
    end if;
  end if;

  v_msg := public._checar_pin(v_uid, p_pin);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;

  v_ano := extract(year from v_agora at time zone public._fuso())::int;
  insert into public.sequencias (ano, ultimo) values (v_ano, 1)
    on conflict (ano) do update set ultimo = public.sequencias.ultimo + 1
    returning ultimo into v_n;
  v_num := v_ano::text || '-' || lpad(v_n::text, 4, '0');

  v_dias := case v_tipo when 'judicial' then public._param_int('prazo_judicial_dias', 5)
                        else public._param_int('prazo_correspondencia_dias', 0) end;
  v_prazo := case when v_dias > 0 then public._somar_dias_uteis((v_agora at time zone public._fuso())::date, v_dias) end;
  v_sla := public._somar_horas_uteis(v_agora, case when v_urg then (public._param_min('sla_adm_urgente_min', 120) / 60.0)
                                                   else (public._param_min('sla_adm_min', 240) / 60.0) end);

  insert into public.protocolos (numero, descricao, status, created_at, created_by, tipo, urgente, prazo_data, sla_limite)
  values (v_num, v_desc, 'pendente_adm', v_agora, v_uid, v_tipo, v_urg, v_prazo, v_sla) returning id into v_id;
  perform public._inserir_tramite(v_id, v_num, 1, v_uid, v_perfil.nome, null, null, v_png, v_agora, p_assinatura_modo);
  if v_foto is not null then
    insert into public.protocolo_fotos (protocolo_id, caminho, tamanho, enviado_por, enviado_em)
    values (v_id, v_foto, v_tam, v_uid, v_agora);
  end if;
  perform public._auditar(v_uid, v_perfil.nome, 'PROTOCOLO_CRIADO', v_id,
            jsonb_build_object('numero', v_num, 'descricao', v_desc, 'tipo', v_tipo, 'urgente', v_urg,
                               'prazo', v_prazo, 'foto', v_foto is not null, 'assinatura', v_modo));
  perform public._enfileirar_email('chegada:' || v_id, 'CHEGADA', v_id, public._emails(array['adm']),
            '[Protocolo' || case when v_urg then ' URGENTE' else '' end || '] ' || v_num || ' aguardando o ADM',
            public._texto_email(v_num, v_tipo, v_urg, v_prazo, v_sla, 'Chegou uma nova demanda na Portaria e aguarda o recebimento do ADM.'));
  return jsonb_build_object('ok', true, 'id', v_id, 'numero', v_num);
end $$;

-- ---------- 3. excluir usuário (somente inativo e sem histórico no livro)
create or replace function public.painel_excluir_usuario(p_user_id uuid, p_pin_gestor text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare g public.perfis%rowtype := public._exigir_gestor(); a public.perfis%rowtype; v_msg text;
begin
  select * into a from public.perfis where user_id = p_user_id;
  if not found then raise exception 'Usuário não encontrado.'; end if;
  if a.user_id = g.user_id then raise exception 'Você não pode excluir o seu próprio usuário.'; end if;
  if a.ativo then raise exception 'Só é possível excluir um usuário inativo. Desative-o primeiro.'; end if;
  v_msg := public._checar_pin(g.user_id, p_pin_gestor);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;
  begin
    delete from public.perfis where user_id = p_user_id;
    delete from auth.users where id = p_user_id;
  exception when foreign_key_violation then
    raise exception 'Este usuário já participou de protocolos (registro, recebimento, correção ou outra ação) e o livro precisa manter o responsável. Ele não pode ser excluído: mantenha-o desativado.';
  end;
  perform public._auditar(g.user_id, g.nome, 'USUARIO_EXCLUIDO', null,
            jsonb_build_object('email', a.email, 'nome', a.nome, 'papel', a.papel));
  return jsonb_build_object('ok', true);
end $$;

-- ---------- 4. impressão da folha de identificação (QR Code) entra na trilha de auditoria
create or replace function public.registrar_exportacao(
  p_tipo text, p_protocolo_id bigint default null, p_filtros text default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_num text; v_det jsonb := '{}'::jsonb;
begin
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  if not found then raise exception 'Perfil não encontrado.' using errcode = '42501'; end if;
  if p_tipo not in ('FICHA', 'FOLHA', 'LIVRO', 'TRILHA') then raise exception 'Tipo inválido.'; end if;
  if p_tipo = 'TRILHA' and v_perfil.papel <> 'gestor' then raise exception 'Apenas o gestor exporta a trilha.' using errcode = '42501'; end if;
  if p_protocolo_id is not null then
    select numero into v_num from public.protocolos where id = p_protocolo_id and public.pode_ver_protocolo(id);
    if v_num is null then raise exception 'Protocolo não encontrado.'; end if;
    v_det := v_det || jsonb_build_object('numero', v_num);
  end if;
  if nullif(btrim(coalesce(p_filtros, '')), '') is not null then
    v_det := v_det || jsonb_build_object('filtros', left(btrim(p_filtros), 300));
  end if;
  perform public._auditar(v_uid, v_perfil.nome, 'IMPRESSAO_' || p_tipo, p_protocolo_id, v_det);
end $$;

-- ---------- 5. nomes de usuário no padrão "Primeira Letra Maiúscula" (ex.: Maria José de Paiva Rodrigues)
create or replace function public._nome_proprio(p_nome text) returns text
language plpgsql immutable set search_path = public as $$
declare v text; v_pal text; v_out text[] := '{}'; v_i int := 0;
begin
  if p_nome is null then return null; end if;
  v := btrim(regexp_replace(p_nome, '\s+', ' ', 'g'));
  foreach v_pal in array string_to_array(v, ' ') loop
    v_i := v_i + 1;
    v_pal := initcap(lower(v_pal));
    if v_i > 1 and v_pal in ('De', 'Da', 'Do', 'Das', 'Dos', 'E', 'Di', 'Du') then v_pal := lower(v_pal); end if;
    v_out := v_out || v_pal;
  end loop;
  return array_to_string(v_out, ' ');
end $$;

create or replace function public._trg_perfis_nome() returns trigger
language plpgsql set search_path = public as $$
begin
  new.nome := public._nome_proprio(new.nome);
  return new;
end $$;

drop trigger if exists trg_perfis_nome on public.perfis;
create trigger trg_perfis_nome before insert or update of nome on public.perfis
  for each row execute function public._trg_perfis_nome();

-- ajusta os nomes já cadastrados (a condição WHERE é exigida pelo pg-safeupdate do Supabase)
update public.perfis set nome = public._nome_proprio(nome) where nome is distinct from public._nome_proprio(nome);

insert into public.schema_versao (versao, arquivo) values (12, '12_qr_excluir_usuario.sql') on conflict (versao) do nothing;

revoke all on function public._trg_perfis_nome() from public, anon, authenticated;
revoke all on function public.protocolo_por_numero(text), public.painel_excluir_usuario(uuid, text),
  public._trg_protocolos_urgencia() from public, anon, authenticated;
grant execute on function public.protocolo_por_numero(text), public.painel_excluir_usuario(uuid, text) to authenticated;
