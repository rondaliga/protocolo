-- =====================================================================
-- MIGRAÇÃO 03 — Painel de controle do gestor, gestor com acesso total,
--               trilha de auditoria organizada e assinatura digitada.
-- Rode no SQL Editor DEPOIS de schema.sql e 02_prazos_alertas.sql (pode rodar de novo).
--
--  1. GESTOR COM ACESSO TOTAL: registra (Portaria), recebe como ADM, recebe pelo setor de destino,
--     ajusta prazo, corrige descrição, vê tudo. (Parâmetro gestor_ignora_segregacao, ver README.)
--  2. PAINEL DE CONTROLE (somente gestor): usuários (criar, editar, ativar/desativar, redefinir
--     senha e PIN, desbloquear), setores, parâmetros e feriados. Ações sensíveis pedem o PIN do gestor
--     e ficam na trilha de auditoria.
--  3. TRILHA: listar_auditoria() com filtros, categorias, nº do protocolo e paginação.
--  4. ASSINATURA: modo "digitada" (nome em fonte de assinatura) além da "desenhada".
--  5. PRIMEIRO ACESSO: usuário criado pelo gestor é obrigado a trocar a senha e o PIN provisórios.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. ESTRUTURA
-- ---------------------------------------------------------------------
alter table public.perfis
  add column if not exists deve_trocar_senha boolean not null default false,
  add column if not exists deve_trocar_pin   boolean not null default false,
  add column if not exists senha_provisoria_hash text,         -- nunca exposto ao cliente
  add column if not exists criado_por uuid;

alter table public.tramites drop constraint if exists tramites_assinatura_tipo_check;
alter table public.tramites add constraint tramites_assinatura_tipo_check
  check (assinatura_tipo in ('pin', 'pin_canvas', 'pin_digitada'));

insert into public.parametros (chave, valor, descricao) values
  ('gestor_ignora_segregacao', 'true',
   'O gestor (acesso total) pode assinar mais de uma etapa do mesmo protocolo. Use false para exigir pessoas diferentes também do gestor.')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------
-- 2. UTILITÁRIOS
-- ---------------------------------------------------------------------
create or replace function public._validar_parametro(p_chave text, p_valor text) returns text
language plpgsql stable security definer set search_path = public as $$
declare v text := btrim(coalesce(p_valor, '')); n int;
begin
  if not exists (select 1 from public.parametros where chave = p_chave) then
    raise exception 'Parâmetro desconhecido: %.', p_chave;
  end if;
  if p_chave = 'url_sistema' then
    if v <> '' and v !~ '^https://[^\s]+$' then raise exception 'O endereço do sistema deve começar com https://'; end if;
  elsif p_chave in ('foto_obrigatoria_judicial', 'gestor_ignora_segregacao') then
    if v not in ('true', 'false') then raise exception 'Use true ou false.'; end if;
  else
    if v !~ '^\d{1,3}$' then raise exception 'Informe um número inteiro de 0 a 999.'; end if;
    n := v::int;
    if p_chave like 'sla\_%' and n < 1 then raise exception 'O tempo máximo deve ser de pelo menos 1 hora.'; end if;
    if p_chave = 'expediente_inicio' and (n > 23 or n >= public._param_int('expediente_fim', 17)) then
      raise exception 'Início do expediente inválido (0 a 23 e antes do fim).'; end if;
    if p_chave = 'expediente_fim' and (n < 1 or n > 24 or n <= public._param_int('expediente_inicio', 8)) then
      raise exception 'Fim do expediente inválido (1 a 24 e depois do início).'; end if;
    if p_chave in ('prazo_judicial_dias', 'prazo_correspondencia_dias', 'alerta_prazo_dias') and n > 365 then
      raise exception 'Valor máximo: 365 dias.'; end if;
    v := n::text;
  end if;
  return v;
end $$;

create or replace function public._tipo_parametro(p_chave text) returns text
language sql immutable as $$
  select case when p_chave = 'url_sistema' then 'texto'
              when p_chave in ('foto_obrigatoria_judicial', 'gestor_ignora_segregacao') then 'booleano'
              else 'numero' end
$$;

-- Troca a validação do admin_definir_parametro (SQL Editor) pela versão única
create or replace function public.admin_definir_parametro(p_chave text, p_valor text) returns text
language plpgsql security definer set search_path = public as $$
declare v text := public._validar_parametro(p_chave, p_valor);
begin
  update public.parametros set valor = v where chave = p_chave;
  perform public._auditar(null, 'admin (SQL Editor)', 'PARAMETRO_ALTERADO', null, jsonb_build_object('chave', p_chave, 'valor', v));
  return p_chave || ' = ' || v;
end $$;

create or replace function public._validar_senha(p text) returns void
language plpgsql immutable as $$
begin
  if p is null or length(p) < 10 or length(p) > 72 or p !~ '[A-Za-z]' or p !~ '[0-9]' then
    raise exception 'A senha deve ter de 10 a 72 caracteres, com letras e números.';
  end if;
end $$;

-- Dados do gestor autenticado (confere papel e PIN). Retorna o perfil ou levanta exceção.
create or replace function public._exigir_gestor() returns public.perfis
language plpgsql security definer set search_path = public as $$
declare v public.perfis%rowtype;
begin
  select * into v from public.perfis where user_id = public._uid() and ativo and papel = 'gestor';
  if not found then raise exception 'Apenas o gestor pode usar o painel de controle.' using errcode = '42501'; end if;
  return v;
end $$;

create or replace function public._outros_gestores_ativos(p_excluir uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.perfis where ativo and papel = 'gestor' and user_id <> p_excluir
$$;

-- Cria o usuário no Supabase Auth (equivalente a "Add user → Auto Confirm"). Só uso interno.
create or replace function public._criar_usuario_auth(p_email text, p_senha text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid := gen_random_uuid(); c text;
begin
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', lower(p_email),
          crypt(p_senha, gen_salt('bf', 10)), now(),
          '{"provider":"email","providers":["email"]}', '{}', now(), now());
  -- colunas de token precisam ser '' (e não NULL) para o login funcionar em algumas versões do Auth
  for c in select column_name from information_schema.columns
            where table_schema = 'auth' and table_name = 'users'
              and column_name in ('confirmation_token', 'recovery_token', 'email_change', 'email_change_token_new',
                                  'email_change_token_current', 'phone_change', 'phone_change_token', 'reauthentication_token') loop
    execute format('update auth.users set %1$I = coalesce(%1$I, '''') where id = $1', c) using v_id;
  end loop;
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_id, v_id::text, jsonb_build_object('sub', v_id::text, 'email', lower(p_email), 'email_verified', true),
          'email', now(), now(), now());
  return v_id;
end $$;

create or replace function public._definir_senha_auth(p_uid uuid, p_senha text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_hash text := crypt(p_senha, gen_salt('bf', 10));
begin
  update auth.users set encrypted_password = v_hash, updated_at = now() where id = p_uid;
  if not found then raise exception 'Usuário não encontrado no Auth.'; end if;
  delete from auth.sessions where user_id = p_uid;       -- derruba sessões abertas
  return v_hash;
end $$;

-- ---------------------------------------------------------------------
-- 3. _inserir_tramite com o modo de assinatura
-- ---------------------------------------------------------------------
drop function if exists public._inserir_tramite(bigint, text, int, uuid, text, bigint, text, text, timestamptz);
create or replace function public._inserir_tramite(
  p_pid bigint, p_numero text, p_etapa int, p_uid uuid, p_nome text,
  p_setor_id bigint, p_setor_nome text, p_png text, p_quando timestamptz, p_modo text default 'desenhada')
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_selo text;
begin
  v_selo := encode(digest(concat_ws('|', p_numero, p_etapa::text, p_uid::text,
              to_char(p_quando at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
              coalesce(p_setor_id::text, ''),
              coalesce(encode(digest(p_png, 'sha256'), 'hex'), '')), 'sha256'), 'hex');
  insert into public.tramites (protocolo_id, etapa, recebido_em, usuario_id, usuario_nome,
                               setor_id, setor_nome, assinatura_tipo, assinatura_png, selo)
  values (p_pid, p_etapa, p_quando, p_uid, p_nome, p_setor_id, p_setor_nome,
          case when p_png is null then 'pin' when p_modo = 'digitada' then 'pin_digitada' else 'pin_canvas' end,
          p_png, v_selo);
end $$;

create or replace function public._modo_assinatura(p_png text, p_modo text) returns text
language plpgsql immutable as $$
begin
  if p_png is null then return 'pin'; end if;
  if coalesce(p_modo, 'desenhada') not in ('desenhada', 'digitada') then raise exception 'Modo de assinatura inválido.'; end if;
  return case coalesce(p_modo, 'desenhada') when 'digitada' then 'pin_digitada' else 'pin_canvas' end;
end $$;

-- ---------------------------------------------------------------------
-- 4. GESTOR COM ACESSO TOTAL — RPCs de escrita reescritas
-- ---------------------------------------------------------------------
drop function if exists public.registrar_protocolo(text, text, text, text, boolean, text);
drop function if exists public.confirmar_etapa(bigint, int, text, text, bigint);

create or replace function public.registrar_protocolo(
  p_descricao text, p_pin text, p_assinatura text default null,
  p_tipo text default 'correspondencia', p_urgente boolean default false, p_foto_caminho text default null,
  p_assinatura_modo text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_desc text; v_png text; v_msg text; v_modo text;
  v_agora timestamptz := now(); v_ano int; v_n int; v_num text; v_id bigint;
  v_tipo text := coalesce(p_tipo, 'correspondencia'); v_urg boolean := coalesce(p_urgente, false);
  v_foto text := nullif(btrim(coalesce(p_foto_caminho, '')), ''); v_tam int;
  v_dias int; v_prazo date; v_sla timestamptz;
begin
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  if not found or v_perfil.papel not in ('portaria', 'gestor') then
    raise exception 'Seu perfil não tem permissão para registrar protocolos.' using errcode = '42501';
  end if;
  if v_tipo not in ('judicial', 'correspondencia') then raise exception 'Tipo de documento inválido.'; end if;
  if v_urg and v_tipo <> 'judicial' then
    raise exception 'A marcação de urgência vale apenas para demandas judiciais.';
  end if;
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

-- 2ª etapa (ADM ou gestor, escolhendo o destino) e 3ª etapa (setor de destino ou gestor em nome dele)
create or replace function public.confirmar_etapa(
  p_protocolo_id bigint, p_etapa int, p_pin text, p_assinatura text default null,
  p_setor_destino_id bigint default null, p_assinatura_modo text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_p public.protocolos%rowtype;
  v_png text; v_msg text; v_agora timestamptz := now(); v_setor_nome text; v_setor_id bigint;
  v_dest_nome text; v_sla timestamptz; v_modo text; v_gestor boolean;
begin
  if p_etapa not in (2, 3) then raise exception 'Etapa inválida.'; end if;
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  v_gestor := found and v_perfil.papel = 'gestor';
  if not found or not (v_gestor or v_perfil.papel = case p_etapa when 2 then 'adm' else 'super_setor' end) then
    raise exception 'Seu perfil não tem permissão para esta etapa.' using errcode = '42501';
  end if;
  select * into v_p from public.protocolos where id = p_protocolo_id for update;
  if not found then raise exception 'Protocolo não encontrado.'; end if;

  if v_p.status = 'concluido' then
    if p_etapa = 3 and not v_gestor and v_p.setor_destino_id is distinct from v_perfil.setor_id then
      raise exception 'Protocolo não encontrado.';
    end if;
    raise exception 'Este protocolo já foi concluído.';
  end if;
  if p_etapa = 3 then
    if v_p.status = 'pendente_adm' then
      if v_gestor then raise exception 'Este protocolo ainda aguarda o recebimento do ADM (2ª etapa).'; end if;
      raise exception 'Protocolo não encontrado.';           -- não revela protocolos de outros setores
    end if;
    if not v_gestor and v_p.setor_destino_id is distinct from v_perfil.setor_id then
      raise exception 'Protocolo não encontrado.';
    end if;
  end if;
  if p_etapa = 2 and v_p.status <> 'pendente_adm' then
    raise exception 'O recebimento do ADM já foi registrado para este protocolo.';
  end if;
  if not (v_gestor and public._param_text('gestor_ignora_segregacao', 'true') = 'true')
     and exists (select 1 from public.tramites where protocolo_id = v_p.id and usuario_id = v_uid) then
    raise exception 'Segregação de funções: você já assinou outra etapa deste protocolo.' using errcode = '42501';
  end if;
  if p_etapa = 2 then
    select nome into v_dest_nome from public.setores where id = p_setor_destino_id and ativo;
    if v_dest_nome is null then raise exception 'Informe o setor de destino do documento.'; end if;
  end if;

  v_png := public._validar_assinatura(p_assinatura);
  v_modo := public._modo_assinatura(v_png, p_assinatura_modo);
  v_msg := public._checar_pin(v_uid, p_pin);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;

  if p_etapa = 3 then
    v_setor_id := case when v_gestor then v_p.setor_destino_id else v_perfil.setor_id end;
    select nome into v_setor_nome from public.setores where id = v_setor_id;
  end if;
  perform public._inserir_tramite(v_p.id, v_p.numero, p_etapa, v_uid, v_perfil.nome,
            v_setor_id, v_setor_nome, v_png, v_agora, p_assinatura_modo);

  if p_etapa = 2 then
    v_sla := public._somar_horas_uteis(v_agora, case when v_p.urgente then (public._param_min('sla_setor_urgente_min', 240) / 60.0)
                                                     else (public._param_min('sla_setor_min', 540) / 60.0) end);
    update public.protocolos set setor_destino_id = p_setor_destino_id, sla_limite = v_sla where id = v_p.id;
    perform public._enfileirar_email('encaminhado:' || v_p.id, 'ENCAMINHADO', v_p.id,
              public._emails(array['super_setor'], p_setor_destino_id),
              '[Protocolo' || case when v_p.urgente then ' URGENTE' else '' end || '] ' || v_p.numero || ' encaminhado ao seu setor',
              public._texto_email(v_p.numero, v_p.tipo, v_p.urgente, v_p.prazo_data, v_sla,
                                  'Uma demanda foi encaminhada pelo ADM ao setor ' || v_dest_nome || '.'));
  else
    update public.protocolos set sla_limite = null where id = v_p.id;
  end if;

  perform public._auditar(v_uid, v_perfil.nome,
            case p_etapa when 2 then 'RECEBIMENTO_ADM' else 'RECEBIMENTO_SETOR' end, v_p.id,
            jsonb_build_object('numero', v_p.numero, 'setor', coalesce(v_setor_nome, v_dest_nome), 'assinatura', v_modo,
                               'como_gestor', v_gestor));
  return jsonb_build_object('ok', true, 'id', v_p.id, 'numero', v_p.numero);
end $$;

-- O gestor também envia fotos; (o ADM/setor continuam sem enviar)
drop policy if exists fotos_insert on storage.objects;
create policy fotos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'protocolo-fotos' and public.meu_papel() in ('portaria', 'gestor')
              and (storage.foldername(name))[1] = public._uid()::text);

-- Pendências: o gestor acompanha TODOS os protocolos em aberto
create or replace function public.minhas_pendencias() returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare v_papel text := public.meu_papel(); v_itens jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_itens from (
    select v.id, v.numero, v.tipo, v.urgente, v.status, v.prazo_data, v.dias_restantes, v.semaforo,
           v.aguardando_desde, v.sla_limite, v.sla_estourado, v.setor_destino_nome
      from public.v_livro v
     where v.status <> 'concluido'
       and ((v_papel = 'adm' and v.status = 'pendente_adm')
         or (v_papel = 'super_setor' and v.status = 'pendente_setor')
         or (v_papel = 'gestor'))
     order by v.sla_estourado desc, (v.semaforo = 'vencido') desc, v.urgente desc, v.dias_restantes nulls last, v.id
     limit 100
  ) x;
  return jsonb_build_object('papel', v_papel, 'total', jsonb_array_length(v_itens), 'itens', v_itens,
    'urgentes', (select count(*) from jsonb_array_elements(v_itens) e
                  where (e ->> 'sla_estourado')::boolean or e ->> 'semaforo' = 'vencido'));
end $$;

-- O próprio usuário troca o PIN; isso encerra a pendência de "primeiro acesso" do PIN
create or replace function public.alterar_meu_pin(p_atual text, p_novo text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_uid uuid := public._uid(); v_nome text; v_msg text;
begin
  select nome into v_nome from public.perfis where user_id = v_uid and ativo;
  if v_nome is null then raise exception 'Perfil não encontrado.' using errcode = '42501'; end if;
  if p_novo is null or p_novo !~ '^\d{4,6}$' then raise exception 'O novo PIN deve ter de 4 a 6 dígitos numéricos.'; end if;
  v_msg := public._checar_pin(v_uid, p_atual);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;
  if p_novo = p_atual then raise exception 'O novo PIN deve ser diferente do atual.'; end if;
  if p_novo ~ '^(\d)\1+$' or p_novo in ('1234', '12345', '123456', '4321', '0123', '1212') then
    raise exception 'PIN muito fácil de adivinhar. Escolha outro.';
  end if;
  update public.perfis set pin_hash = crypt(p_novo, gen_salt('bf', 10)), deve_trocar_pin = false where user_id = v_uid;
  perform public._auditar(v_uid, v_nome, 'PIN_ALTERADO', null, '{}');
  return jsonb_build_object('ok', true);
end $$;

-- O usuário confirma que trocou a senha (o banco confere se a senha realmente mudou)
create or replace function public.confirmar_troca_senha() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public._uid(); v public.perfis%rowtype; v_hash text;
begin
  select * into v from public.perfis where user_id = v_uid and ativo;
  if not found then raise exception 'Perfil não encontrado.' using errcode = '42501'; end if;
  select encrypted_password into v_hash from auth.users where id = v_uid;
  if v.senha_provisoria_hash is not null and v_hash = v.senha_provisoria_hash then
    raise exception 'A senha ainda é a provisória. Defina uma nova senha.';
  end if;
  update public.perfis set deve_trocar_senha = false, senha_provisoria_hash = null where user_id = v_uid;
  perform public._auditar(v_uid, v.nome, 'SENHA_ALTERADA', null, '{}');
  return jsonb_build_object('ok', true);
end $$;

-- Impressão/exportação (ficha, livro e trilha) com detalhes legíveis
create or replace function public.registrar_exportacao(
  p_tipo text, p_protocolo_id bigint default null, p_filtros text default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_num text; v_det jsonb := '{}'::jsonb;
begin
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  if not found then raise exception 'Perfil não encontrado.' using errcode = '42501'; end if;
  if p_tipo not in ('FICHA', 'LIVRO', 'TRILHA') then raise exception 'Tipo inválido.'; end if;
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

-- ---------------------------------------------------------------------
-- 5. TRILHA DE AUDITORIA ORGANIZADA
-- ---------------------------------------------------------------------
create or replace function public._categoria_auditoria(p_acao text) returns text
language sql immutable as $$
  select case
    when p_acao in ('LOGIN', 'LOGOUT', 'LOGOUT_INATIVIDADE', 'FALHA_PIN', 'USUARIO_BLOQUEADO') then 'acesso'
    when p_acao = 'PROTOCOLO_CRIADO' then 'protocolo'
    when p_acao in ('RECEBIMENTO_ADM', 'RECEBIMENTO_SETOR') then 'tramitacao'
    when p_acao = 'DESCRICAO_CORRIGIDA' then 'correcao'
    when p_acao = 'PRAZO_AJUSTADO' or p_acao like 'ALERTA\_%' then 'prazo'
    when p_acao like 'IMPRESSAO\_%' then 'impressao'
    when p_acao in ('PIN_ALTERADO', 'SENHA_ALTERADA') then 'seguranca'
    else 'administracao' end
$$;

create or replace function public.listar_auditoria(
  p_q text default null, p_categoria text default null, p_usuario text default null,
  p_data_ini date default null, p_data_fim date default null,
  p_limite int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_like text; v_usr text; v_total bigint; v_itens jsonb;
begin
  perform public._exigir_gestor();
  p_limite := least(greatest(coalesce(p_limite, 50), 1), 1000);
  p_offset := greatest(coalesce(p_offset, 0), 0);
  v_like := case when nullif(btrim(p_q), '') is null then null
                 else '%' || replace(replace(replace(left(btrim(p_q), 100), '\', '\\'), '%', '\%'), '_', '\_') || '%' end;
  v_usr  := case when nullif(btrim(p_usuario), '') is null then null
                 else '%' || replace(replace(replace(left(btrim(p_usuario), 100), '\', '\\'), '%', '\%'), '_', '\_') || '%' end;
  with b as (
    select a.id, a.ocorrido_em, a.usuario_nome, a.acao, public._categoria_auditoria(a.acao) as categoria,
           a.protocolo_id, p.numero, a.detalhes
      from public.auditoria a left join public.protocolos p on p.id = a.protocolo_id
     where (v_like is null or a.acao ilike v_like or coalesce(p.numero, '') ilike v_like
            or coalesce(a.usuario_nome, '') ilike v_like or a.detalhes::text ilike v_like)
       and (v_usr is null or coalesce(a.usuario_nome, '') ilike v_usr)
       and (p_categoria is null or public._categoria_auditoria(a.acao) = p_categoria)
       and (p_data_ini is null or (a.ocorrido_em at time zone public._fuso())::date >= p_data_ini)
       and (p_data_fim is null or (a.ocorrido_em at time zone public._fuso())::date <= p_data_fim)
  )
  select (select count(*) from b),
         coalesce((select jsonb_agg(to_jsonb(x) order by x.id desc)
                     from (select * from b order by id desc limit p_limite offset p_offset) x), '[]'::jsonb)
    into v_total, v_itens;
  return jsonb_build_object('total', v_total, 'itens', v_itens);
end $$;

-- ---------------------------------------------------------------------
-- 6. PAINEL DE CONTROLE (somente gestor)
-- ---------------------------------------------------------------------
create or replace function public.painel_listar_usuarios() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._exigir_gestor();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'user_id', p.user_id, 'email', coalesce(p.email, u.email), 'nome', p.nome, 'papel', p.papel,
      'setor_id', p.setor_id, 'setor_nome', s.nome, 'ativo', p.ativo,
      'pin_bloqueado', (p.pin_bloqueado_ate is not null and p.pin_bloqueado_ate > now()),
      'sem_pin', p.pin_hash is null,
      'deve_trocar_senha', p.deve_trocar_senha, 'deve_trocar_pin', p.deve_trocar_pin,
      'ultimo_acesso', u.last_sign_in_at, 'criado_em', p.created_at) order by p.ativo desc, p.nome)
    from public.perfis p
    join auth.users u on u.id = p.user_id
    left join public.setores s on s.id = p.setor_id), '[]'::jsonb);
end $$;

create or replace function public.painel_criar_usuario(
  p_email text, p_nome text, p_papel text, p_setor_id bigint, p_senha text, p_pin text, p_pin_gestor text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  g public.perfis%rowtype := public._exigir_gestor(); v_msg text; v_email text := lower(btrim(coalesce(p_email, '')));
  v_nome text := regexp_replace(btrim(coalesce(p_nome, '')), '\s+', ' ', 'g'); v_uid uuid; v_novo boolean := false; v_setor text;
begin
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 200 then raise exception 'Informe um e-mail válido.'; end if;
  if length(v_nome) not between 2 and 120 then raise exception 'Informe o nome completo (2 a 120 caracteres).'; end if;
  if p_papel not in ('portaria', 'adm', 'super_setor', 'gestor') then raise exception 'Perfil inválido.'; end if;
  if p_papel = 'super_setor' then
    select nome into v_setor from public.setores where id = p_setor_id and ativo;
    if v_setor is null then raise exception 'Escolha o setor do usuário (setor de destino).'; end if;
  else p_setor_id := null; end if;
  if p_pin is null or p_pin !~ '^\d{4,6}$' then raise exception 'O PIN provisório deve ter de 4 a 6 dígitos numéricos.'; end if;
  select id into v_uid from auth.users where lower(email) = v_email;
  if v_uid is not null and exists (select 1 from public.perfis where user_id = v_uid) then
    raise exception 'Já existe um usuário com este e-mail.';
  end if;
  if v_uid is null then perform public._validar_senha(p_senha); end if;
  v_msg := public._checar_pin(g.user_id, p_pin_gestor);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;

  if v_uid is null then v_uid := public._criar_usuario_auth(v_email, p_senha); v_novo := true; end if;
  insert into public.perfis (user_id, nome, papel, setor_id, pin_hash, email, deve_trocar_pin, deve_trocar_senha, senha_provisoria_hash, criado_por)
  values (v_uid, v_nome, p_papel, p_setor_id, crypt(p_pin, gen_salt('bf', 10)), v_email, true, v_novo,
          case when v_novo then (select encrypted_password from auth.users where id = v_uid) end, g.user_id);
  perform public._auditar(g.user_id, g.nome, 'USUARIO_CRIADO', null,
            jsonb_build_object('email', v_email, 'nome', v_nome, 'papel', p_papel, 'setor', v_setor, 'conta_nova', v_novo));
  return jsonb_build_object('ok', true, 'user_id', v_uid, 'conta_nova', v_novo);
end $$;

create or replace function public.painel_atualizar_usuario(
  p_user_id uuid, p_nome text, p_papel text, p_setor_id bigint, p_pin_gestor text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  g public.perfis%rowtype := public._exigir_gestor(); a public.perfis%rowtype; v_msg text; v_setor text;
  v_nome text := regexp_replace(btrim(coalesce(p_nome, '')), '\s+', ' ', 'g');
begin
  select * into a from public.perfis where user_id = p_user_id;
  if not found then raise exception 'Usuário não encontrado.'; end if;
  if length(v_nome) not between 2 and 120 then raise exception 'Informe o nome completo (2 a 120 caracteres).'; end if;
  if p_papel not in ('portaria', 'adm', 'super_setor', 'gestor') then raise exception 'Perfil inválido.'; end if;
  if p_papel = 'super_setor' then
    select nome into v_setor from public.setores where id = p_setor_id and ativo;
    if v_setor is null then raise exception 'Escolha o setor do usuário (setor de destino).'; end if;
  else p_setor_id := null; end if;
  if a.user_id = g.user_id and p_papel <> 'gestor' then raise exception 'Você não pode retirar o seu próprio acesso de gestor.'; end if;
  if a.papel = 'gestor' and p_papel <> 'gestor' and a.ativo and public._outros_gestores_ativos(a.user_id) = 0 then
    raise exception 'Não é possível remover o perfil de gestor do último gestor ativo.';
  end if;
  v_msg := public._checar_pin(g.user_id, p_pin_gestor);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;
  update public.perfis set nome = v_nome, papel = p_papel, setor_id = p_setor_id where user_id = p_user_id;
  perform public._auditar(g.user_id, g.nome, 'USUARIO_ATUALIZADO', null,
            jsonb_build_object('email', a.email, 'nome_anterior', a.nome, 'nome', v_nome, 'papel_anterior', a.papel, 'papel', p_papel, 'setor', v_setor));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.painel_definir_ativo(p_user_id uuid, p_ativo boolean, p_pin_gestor text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare g public.perfis%rowtype := public._exigir_gestor(); a public.perfis%rowtype; v_msg text;
begin
  select * into a from public.perfis where user_id = p_user_id;
  if not found then raise exception 'Usuário não encontrado.'; end if;
  if not p_ativo then
    if a.user_id = g.user_id then raise exception 'Você não pode desativar o seu próprio acesso.'; end if;
    if a.papel = 'gestor' and a.ativo and public._outros_gestores_ativos(a.user_id) = 0 then
      raise exception 'Não é possível desativar o último gestor ativo.'; end if;
  end if;
  v_msg := public._checar_pin(g.user_id, p_pin_gestor);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;
  update public.perfis set ativo = p_ativo where user_id = p_user_id;
  update auth.users set banned_until = case when p_ativo then null else 'infinity'::timestamptz end where id = p_user_id;
  if not p_ativo then delete from auth.sessions where user_id = p_user_id; end if;
  perform public._auditar(g.user_id, g.nome, case when p_ativo then 'USUARIO_ATIVADO' else 'USUARIO_DESATIVADO' end, null,
            jsonb_build_object('email', a.email, 'nome', a.nome));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.painel_redefinir_senha(p_user_id uuid, p_senha text, p_pin_gestor text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare g public.perfis%rowtype := public._exigir_gestor(); a public.perfis%rowtype; v_msg text; v_hash text;
begin
  select * into a from public.perfis where user_id = p_user_id;
  if not found then raise exception 'Usuário não encontrado.'; end if;
  if a.user_id = g.user_id then raise exception 'Para trocar a sua própria senha use "Alterar senha".'; end if;
  perform public._validar_senha(p_senha);
  v_msg := public._checar_pin(g.user_id, p_pin_gestor);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;
  v_hash := public._definir_senha_auth(p_user_id, p_senha);
  update public.perfis set deve_trocar_senha = true, senha_provisoria_hash = v_hash where user_id = p_user_id;
  perform public._auditar(g.user_id, g.nome, 'SENHA_REDEFINIDA', null, jsonb_build_object('email', a.email, 'nome', a.nome));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.painel_redefinir_pin(p_user_id uuid, p_pin text, p_pin_gestor text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare g public.perfis%rowtype := public._exigir_gestor(); a public.perfis%rowtype; v_msg text;
begin
  select * into a from public.perfis where user_id = p_user_id;
  if not found then raise exception 'Usuário não encontrado.'; end if;
  if a.user_id = g.user_id then raise exception 'Para trocar o seu próprio PIN use "Alterar PIN".'; end if;
  if p_pin is null or p_pin !~ '^\d{4,6}$' then raise exception 'O PIN provisório deve ter de 4 a 6 dígitos numéricos.'; end if;
  v_msg := public._checar_pin(g.user_id, p_pin_gestor);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;
  update public.perfis set pin_hash = crypt(p_pin, gen_salt('bf', 10)), deve_trocar_pin = true, pin_falhas = 0, pin_bloqueado_ate = null
   where user_id = p_user_id;
  perform public._auditar(g.user_id, g.nome, 'PIN_REDEFINIDO', null, jsonb_build_object('email', a.email, 'nome', a.nome));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.painel_desbloquear_pin(p_user_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.perfis%rowtype := public._exigir_gestor(); a public.perfis%rowtype;
begin
  select * into a from public.perfis where user_id = p_user_id;
  if not found then raise exception 'Usuário não encontrado.'; end if;
  update public.perfis set pin_falhas = 0, pin_bloqueado_ate = null where user_id = p_user_id;
  perform public._auditar(g.user_id, g.nome, 'PIN_DESBLOQUEADO', null, jsonb_build_object('email', a.email, 'nome', a.nome));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.painel_listar_setores() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._exigir_gestor();
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'nome', s.nome, 'ativo', s.ativo,
      'usuarios', (select count(*) from public.perfis p where p.setor_id = s.id and p.ativo)) order by s.ativo desc, s.nome)
    from public.setores s), '[]'::jsonb);
end $$;

create or replace function public.painel_salvar_setor(p_id bigint, p_nome text, p_ativo boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.perfis%rowtype := public._exigir_gestor(); v_nome text := regexp_replace(btrim(coalesce(p_nome, '')), '\s+', ' ', 'g'); v_id bigint;
begin
  if length(v_nome) not between 2 and 80 then raise exception 'O nome do setor deve ter de 2 a 80 caracteres.'; end if;
  if exists (select 1 from public.setores where lower(nome) = lower(v_nome) and id is distinct from p_id) then
    raise exception 'Já existe um setor com este nome.';
  end if;
  if p_id is null then
    insert into public.setores (nome, ativo) values (v_nome, coalesce(p_ativo, true)) returning id into v_id;
  else
    if not coalesce(p_ativo, true) and exists (select 1 from public.perfis where setor_id = p_id and ativo) then
      raise exception 'Há usuários ativos neste setor. Mude o setor deles antes de desativá-lo.';
    end if;
    update public.setores set nome = v_nome, ativo = coalesce(p_ativo, true) where id = p_id returning id into v_id;
    if v_id is null then raise exception 'Setor não encontrado.'; end if;
  end if;
  perform public._auditar(g.user_id, g.nome, 'SETOR_SALVO', null,
            jsonb_build_object('setor', v_nome, 'ativo', coalesce(p_ativo, true), 'novo', p_id is null));
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.painel_listar_parametros() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._exigir_gestor();
  return coalesce((select jsonb_agg(jsonb_build_object('chave', chave, 'valor', valor, 'descricao', descricao,
                     'tipo', public._tipo_parametro(chave)) order by chave) from public.parametros), '[]'::jsonb);
end $$;

create or replace function public.painel_definir_parametro(p_chave text, p_valor text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.perfis%rowtype := public._exigir_gestor(); v text := public._validar_parametro(p_chave, p_valor); v_ant text;
begin
  select valor into v_ant from public.parametros where chave = p_chave;
  if v_ant = v then return jsonb_build_object('ok', true, 'alterado', false); end if;
  update public.parametros set valor = v where chave = p_chave;
  perform public._auditar(g.user_id, g.nome, 'PARAMETRO_ALTERADO', null,
            jsonb_build_object('chave', p_chave, 'anterior', v_ant, 'valor', v));
  return jsonb_build_object('ok', true, 'alterado', true);
end $$;

create or replace function public.painel_listar_feriados() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._exigir_gestor();
  return coalesce((select jsonb_agg(jsonb_build_object('data', data, 'descricao', descricao) order by data) from public.feriados), '[]'::jsonb);
end $$;

create or replace function public.painel_salvar_feriado(p_data date, p_descricao text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.perfis%rowtype := public._exigir_gestor(); v_desc text := regexp_replace(btrim(coalesce(p_descricao, '')), '\s+', ' ', 'g');
begin
  if p_data is null or p_data < date '2020-01-01' or p_data > date '2100-12-31' then raise exception 'Data inválida.'; end if;
  if length(v_desc) not between 2 and 80 then raise exception 'Informe a descrição do feriado (2 a 80 caracteres).'; end if;
  insert into public.feriados (data, descricao) values (p_data, v_desc)
  on conflict (data) do update set descricao = excluded.descricao;
  perform public._auditar(g.user_id, g.nome, 'FERIADO_SALVO', null, jsonb_build_object('data', p_data, 'descricao', v_desc));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.painel_remover_feriado(p_data date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.perfis%rowtype := public._exigir_gestor(); v_desc text;
begin
  delete from public.feriados where data = p_data returning descricao into v_desc;
  if v_desc is null then raise exception 'Feriado não encontrado.'; end if;
  perform public._auditar(g.user_id, g.nome, 'FERIADO_REMOVIDO', null, jsonb_build_object('data', p_data, 'descricao', v_desc));
  return jsonb_build_object('ok', true);
end $$;

-- Saúde do sistema: usuários e fila de e-mails
create or replace function public.painel_resumo() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._exigir_gestor();
  return jsonb_build_object(
    'usuarios_ativos',   (select count(*) from public.perfis where ativo),
    'usuarios_inativos', (select count(*) from public.perfis where not ativo),
    'sem_email',         (select count(*) from public.perfis where ativo and email is null),
    'pin_bloqueado',     (select count(*) from public.perfis where pin_bloqueado_ate > now()),
    'email_pendente',    (select count(*) from public.fila_email where status = 'pendente'),
    'email_erro',        (select count(*) from public.fila_email where status = 'erro'),
    'email_enviado',     (select count(*) from public.fila_email where status = 'enviado'),
    'ultimo_erro_email', (select erro from public.fila_email where status = 'erro' order by id desc limit 1),
    'integracao_configurada', exists (select 1 from public.integracao));
end $$;

-- ---------------------------------------------------------------------
-- 7. PRIVILÉGIOS
-- ---------------------------------------------------------------------
revoke all on function
  public._validar_parametro(text, text), public._tipo_parametro(text), public._validar_senha(text), public._exigir_gestor(),
  public._outros_gestores_ativos(uuid), public._criar_usuario_auth(text, text), public._definir_senha_auth(uuid, text),
  public._inserir_tramite(bigint, text, int, uuid, text, bigint, text, text, timestamptz, text), public._modo_assinatura(text, text),
  public._categoria_auditoria(text),
  public.registrar_protocolo(text, text, text, text, boolean, text, text), public.confirmar_etapa(bigint, int, text, text, bigint, text),
  public.confirmar_troca_senha(), public.listar_auditoria(text, text, text, date, date, int, int),
  public.painel_listar_usuarios(), public.painel_criar_usuario(text, text, text, bigint, text, text, text),
  public.painel_atualizar_usuario(uuid, text, text, bigint, text), public.painel_definir_ativo(uuid, boolean, text),
  public.painel_redefinir_senha(uuid, text, text), public.painel_redefinir_pin(uuid, text, text),
  public.painel_desbloquear_pin(uuid), public.painel_listar_setores(), public.painel_salvar_setor(bigint, text, boolean),
  public.painel_listar_parametros(), public.painel_definir_parametro(text, text), public.painel_listar_feriados(),
  public.painel_salvar_feriado(date, text), public.painel_remover_feriado(date), public.painel_resumo()
  from public, anon, authenticated;

grant execute on function
  public.registrar_protocolo(text, text, text, text, boolean, text, text), public.confirmar_etapa(bigint, int, text, text, bigint, text),
  public.confirmar_troca_senha(), public.listar_auditoria(text, text, text, date, date, int, int),
  public.painel_listar_usuarios(), public.painel_criar_usuario(text, text, text, bigint, text, text, text),
  public.painel_atualizar_usuario(uuid, text, text, bigint, text), public.painel_definir_ativo(uuid, boolean, text),
  public.painel_redefinir_senha(uuid, text, text), public.painel_redefinir_pin(uuid, text, text),
  public.painel_desbloquear_pin(uuid), public.painel_listar_setores(), public.painel_salvar_setor(bigint, text, boolean),
  public.painel_listar_parametros(), public.painel_definir_parametro(text, text), public.painel_listar_feriados(),
  public.painel_salvar_feriado(date, text), public.painel_remover_feriado(date), public.painel_resumo()
  to authenticated;

-- o cliente lê o próprio estado de "primeiro acesso" (nunca o hash da senha provisória)
grant select (user_id, nome, papel, setor_id, ativo, email, deve_trocar_senha, deve_trocar_pin) on public.perfis to authenticated;
