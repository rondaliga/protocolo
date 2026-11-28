-- =====================================================================
-- MIGRAÇÃO 16 — Delegação temporária de recebimento + relatório de produtividade/tendência
-- Rode DEPOIS da 15 (ou use instalacao_completa.sql). Pode ser executada mais de uma vez.
--
-- O QUE ENTRA NESTA MIGRAÇÃO:
--  1) Delegação temporária de recebimento: o responsável por um setor (super_setor) pode, por um
--     período definido (ex.: férias), autorizar outra pessoa ativa do sistema a receber e tramitar
--     os documentos do seu setor — sem precisar compartilhar PIN nem trocar de perfil. A pessoa
--     delegada age sempre com o PIN e a assinatura DELA; a trilha de auditoria registra cada ato
--     normalmente, com uma marca "via_delegacao" para transparência total.
--  2) Relatório de produtividade por usuário: o relatório gerencial (painel_relatorio) passa a trazer
--     também quantas etapas cada pessoa realizou no período e o tempo médio de resposta dela —
--     além do que já existia por setor.
--  3) Gráfico de tendência: o gráfico "registros por dia" passa a trazer também os concluídos por
--     dia (não só os registrados), para o gestor ver se o volume represado está crescendo ou não.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tabela de delegações. Sem acesso direto do cliente — só pelas funções abaixo, que registram
--    tudo na trilha de auditoria. Não é uma tabela de "evidência" como a auditoria (não é encadeada
--    por hash): é configuração operacional, revogável a qualquer momento pelo próprio delegante,
--    pela pessoa delegada ou por qualquer gestor.
-- ---------------------------------------------------------------------
create table if not exists public.delegacoes (
  id                 bigint generated always as identity primary key,
  setor_id           bigint not null references public.setores(id),
  delegante_user_id  uuid not null references auth.users(id) on delete restrict,
  delegante_nome     text not null,
  delegado_user_id   uuid not null references auth.users(id) on delete restrict,
  delegado_nome      text not null,
  inicio             date not null,
  fim                date not null,
  justificativa      text not null,
  ativa              boolean not null default true,
  criado_em          timestamptz not null default now(),
  revogado_em        timestamptz,
  revogado_por_nome  text,
  check (fim >= inicio),
  check (delegado_user_id <> delegante_user_id)
);
create index if not exists ix_delegacoes_setor on public.delegacoes(setor_id);
create index if not exists ix_delegacoes_delegado on public.delegacoes(delegado_user_id);
create index if not exists ix_delegacoes_delegante on public.delegacoes(delegante_user_id);
alter table public.delegacoes enable row level security;
revoke all on public.delegacoes from public, anon, authenticated;   -- só pelas funções security definer abaixo

-- ---------------------------------------------------------------------
-- 2. Quem está coberto por uma delegação agora (comparação em UTC via current_date do servidor,
--    coerente com o restante do sistema que já trabalha por data corrida, não por fuso por delegação).
-- ---------------------------------------------------------------------
create or replace function public._setor_delegado_para_mim(p_setor_id bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.delegacoes d
     where d.setor_id = p_setor_id and d.delegado_user_id = public._uid() and d.ativa
       and current_date between d.inicio and d.fim)
$$;

create or replace function public._tenho_delegacao_ativa() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.delegacoes d
     where d.delegado_user_id = public._uid() and d.ativa
       and current_date between d.inicio and d.fim)
$$;

-- ---------------------------------------------------------------------
-- 3. Quem pode ver o protocolo: o super_setor continua só enxergando o que é do seu setor — agora
--    "o seu setor" inclui também qualquer setor que lhe foi delegado enquanto a delegação durar.
--    Nenhuma outra regra de visibilidade muda (gestor/portaria/ADM continuam como sempre).
-- ---------------------------------------------------------------------
create or replace function public.pode_ver_protocolo(p_id bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select case public.meu_papel()
    when 'gestor'   then true
    when 'portaria' then true
    when 'adm'      then true
    when 'super_setor' then exists (
      select 1 from public.protocolos p
       where p.id = p_id
         and ((p.status = 'pendente_setor'
               and (p.setor_destino_id = public.meu_setor() or public._setor_delegado_para_mim(p.setor_destino_id)))
              or exists (select 1 from public.tramites t
                          where t.protocolo_id = p.id and t.etapa = 3
                            and (t.setor_id = public.meu_setor() or public._setor_delegado_para_mim(t.setor_id)))))
    else false
  end
$$;

-- ---------------------------------------------------------------------
-- 4. confirmar_etapa (3ª etapa) e devolver_protocolo: aceitam também quem tem delegação ativa
--    para o setor de destino do protocolo, além do responsável titular e do gestor. A auditoria
--    passa a marcar "via_delegacao" quando for o caso, para ficar claro quem agiu e por quê.
-- ---------------------------------------------------------------------
create or replace function public.confirmar_etapa(
  p_protocolo_id bigint, p_etapa int, p_pin text, p_assinatura text default null,
  p_setor_destino_id bigint default null, p_assinatura_modo text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_p public.protocolos%rowtype;
  v_png text; v_msg text; v_agora timestamptz := now(); v_setor_nome text; v_setor_id bigint;
  v_dest_nome text; v_sla timestamptz; v_modo text; v_gestor boolean; v_delegado boolean;
begin
  if p_etapa not in (2, 3) then raise exception 'Etapa inválida.'; end if;
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  v_gestor := found and v_perfil.papel = 'gestor';
  v_delegado := found and p_etapa = 3 and public._tenho_delegacao_ativa();
  if not found or not (v_gestor or v_delegado
                       or v_perfil.papel = case p_etapa when 2 then 'adm' else 'super_setor' end) then
    raise exception 'Seu perfil não tem permissão para esta etapa.' using errcode = '42501';
  end if;
  select * into v_p from public.protocolos where id = p_protocolo_id for update;
  if not found then raise exception 'Protocolo não encontrado.'; end if;

  if v_p.status = 'concluido' then
    if p_etapa = 3 and not v_gestor and v_p.setor_destino_id is distinct from v_perfil.setor_id
       and not public._setor_delegado_para_mim(v_p.setor_destino_id) then
      raise exception 'Protocolo não encontrado.';
    end if;
    raise exception 'Este protocolo já foi concluído.';
  end if;
  if p_etapa = 3 then
    if v_p.status = 'pendente_adm' then
      if v_gestor then raise exception 'Este protocolo ainda aguarda o recebimento do ADM (2ª etapa).'; end if;
      raise exception 'Protocolo não encontrado.';           -- não revela protocolos de outros setores
    end if;
    if not v_gestor and v_p.setor_destino_id is distinct from v_perfil.setor_id
       and not public._setor_delegado_para_mim(v_p.setor_destino_id) then
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
    v_setor_id := v_p.setor_destino_id;     -- setor de destino real do protocolo, sempre — vale também
                                             -- para quem age por delegação, cujo perfis.setor_id pode ser outro
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
                               'como_gestor', v_gestor,
                               'via_delegacao', (p_etapa = 3 and not v_gestor and v_setor_id is distinct from v_perfil.setor_id)));
  return jsonb_build_object('ok', true, 'id', v_p.id, 'numero', v_p.numero);
end $$;

create or replace function public.devolver_protocolo(p_protocolo_id bigint, p_justificativa text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_p public.protocolos%rowtype;
  v_just text; v_msg text; v_agora timestamptz := now(); v_de text; v_sla timestamptz; v_mid bigint; v_delegado boolean;
begin
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  v_delegado := found and public._tenho_delegacao_ativa();
  if not found or not (v_perfil.papel in ('super_setor', 'gestor') or v_delegado) then
    raise exception 'Seu perfil não tem permissão para devolver protocolos.' using errcode = '42501';
  end if;
  v_just := regexp_replace(btrim(coalesce(p_justificativa, '')), '\s+', ' ', 'g');
  if length(v_just) not between 10 and 500 then raise exception 'Informe a justificativa (de 10 a 500 caracteres).'; end if;
  select * into v_p from public.protocolos where id = p_protocolo_id for update;
  if not found then raise exception 'Protocolo não encontrado.'; end if;
  if v_perfil.papel <> 'gestor' then
    if v_p.status <> 'pendente_setor' or v_p.devolvido
       or (v_p.setor_destino_id is distinct from v_perfil.setor_id
           and not public._setor_delegado_para_mim(v_p.setor_destino_id)) then
      raise exception 'Protocolo não encontrado.';
    end if;
  end if;
  if v_p.status <> 'pendente_setor' then raise exception 'Só é possível devolver ao ADM um protocolo que aguarda o recebimento do setor.'; end if;
  if v_p.devolvido then raise exception 'Este protocolo já foi devolvido ao ADM.'; end if;
  v_msg := public._checar_pin(v_uid, p_pin);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;

  select nome into v_de from public.setores where id = v_p.setor_destino_id;
  v_sla := public._somar_horas_uteis(v_agora, case when v_p.urgente then (public._param_min('sla_adm_urgente_min', 120) / 60.0)
                                                   else (public._param_min('sla_adm_min', 240) / 60.0) end);
  insert into public.movimentacoes (protocolo_id, tipo, de_setor_id, de_setor_nome, para_setor_id, para_setor_nome,
                                    justificativa, usuario_id, usuario_nome, em)
  values (v_p.id, 'devolvido', v_p.setor_destino_id, v_de, null, null, v_just, v_uid, v_perfil.nome, v_agora)
  returning id into v_mid;
  perform set_config('app.alteracao_autorizada', 'REDIRECIONAR', true);
  update public.protocolos set setor_destino_id = null, devolvido = true, sla_limite = v_sla where id = v_p.id;
  perform set_config('app.alteracao_autorizada', '', true);
  perform public._enfileirar_email('devol:' || v_p.id || ':' || v_mid, 'DEVOLVIDO', v_p.id, public._emails(array['adm']),
            '[Protocolo' || case when v_p.urgente then ' URGENTE' else '' end || '] ' || v_p.numero || ' devolvido ao ADM',
            public._texto_email(v_p.numero, v_p.tipo, v_p.urgente, v_p.prazo_data, v_sla,
                                'O setor ' || coalesce(v_de, '—') || ' devolveu a demanda ao ADM. É preciso reencaminhá-la ao setor correto.'));
  perform public._auditar(v_uid, v_perfil.nome, 'PROTOCOLO_DEVOLVIDO', v_p.id,
            jsonb_build_object('numero', v_p.numero, 'de', v_de, 'justificativa', v_just,
                               'via_delegacao', (v_perfil.papel <> 'gestor' and v_p.setor_destino_id is distinct from v_perfil.setor_id)));
  return jsonb_build_object('ok', true, 'id', v_p.id, 'numero', v_p.numero);
end $$;

-- ---------------------------------------------------------------------
-- 5. Candidatos a receber uma delegação: qualquer pessoa ativa, exceto quem está pedindo.
--    Só nome/perfil/setor (o mesmo tipo de dado que já aparece em qualquer trâmite/auditoria).
-- ---------------------------------------------------------------------
create or replace function public.usuarios_para_delegar() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := public._uid(); v_papel text;
begin
  select papel into v_papel from public.perfis where user_id = v_uid and ativo;
  if v_papel not in ('super_setor', 'gestor') then
    raise exception 'Seu perfil não pode delegar recebimento.' using errcode = '42501';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'user_id', p.user_id, 'nome', p.nome, 'papel', p.papel, 'setor_nome', s.nome) order by p.nome)
    from public.perfis p left join public.setores s on s.id = p.setor_id
   where p.ativo and p.user_id <> v_uid), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- 6. Criar, revogar e listar delegações.
-- ---------------------------------------------------------------------
create or replace function public.painel_delegar_recebimento(
  p_delegado_user_id uuid, p_inicio date, p_fim date, p_justificativa text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_delegado public.perfis%rowtype;
  v_just text; v_msg text; v_id bigint;
begin
  select * into v_perfil from public.perfis where user_id = v_uid and ativo and papel = 'super_setor';
  if not found then raise exception 'Apenas o responsável por um setor pode delegar o próprio recebimento.' using errcode = '42501'; end if;
  select * into v_delegado from public.perfis where user_id = p_delegado_user_id and ativo;
  if not found then raise exception 'A pessoa escolhida não está ativa no sistema.'; end if;
  if v_delegado.user_id = v_uid then raise exception 'Escolha outra pessoa para receber a delegação.'; end if;
  if p_inicio is null or p_fim is null then raise exception 'Informe o período da delegação.'; end if;
  if p_fim < p_inicio then raise exception 'A data final não pode ser anterior à inicial.'; end if;
  if p_fim < current_date then raise exception 'O período da delegação já passou; escolha datas atuais ou futuras.'; end if;
  if p_fim - p_inicio > 180 then raise exception 'O período máximo de uma delegação é de 180 dias.'; end if;
  v_just := regexp_replace(btrim(coalesce(p_justificativa, '')), '\s+', ' ', 'g');
  if length(v_just) not between 10 and 500 then raise exception 'Informe a justificativa (de 10 a 500 caracteres).'; end if;
  v_msg := public._checar_pin(v_uid, p_pin);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;

  -- uma nova delegação deste responsável para o próprio setor substitui qualquer anterior ainda ativa
  update public.delegacoes set ativa = false, revogado_em = now(), revogado_por_nome = v_perfil.nome
   where setor_id = v_perfil.setor_id and delegante_user_id = v_uid and ativa;

  insert into public.delegacoes (setor_id, delegante_user_id, delegante_nome, delegado_user_id, delegado_nome,
                                 inicio, fim, justificativa)
  values (v_perfil.setor_id, v_uid, v_perfil.nome, v_delegado.user_id, v_delegado.nome, p_inicio, p_fim, v_just)
  returning id into v_id;
  perform public._auditar(v_uid, v_perfil.nome, 'DELEGACAO_CRIADA', null,
            jsonb_build_object('setor_id', v_perfil.setor_id, 'delegado', v_delegado.nome,
                               'inicio', p_inicio, 'fim', p_fim, 'justificativa', v_just));
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.painel_revogar_delegacao(p_id bigint, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_d public.delegacoes%rowtype; v_msg text;
begin
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  if not found then raise exception 'Sessão inválida.' using errcode = '42501'; end if;
  select * into v_d from public.delegacoes where id = p_id;
  if not found then raise exception 'Delegação não encontrada.'; end if;
  if not (v_perfil.papel = 'gestor' or v_uid in (v_d.delegante_user_id, v_d.delegado_user_id)) then
    raise exception 'Você não pode revogar esta delegação.' using errcode = '42501';
  end if;
  if not v_d.ativa then raise exception 'Esta delegação já não está mais ativa.'; end if;
  v_msg := public._checar_pin(v_uid, p_pin);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;
  update public.delegacoes set ativa = false, revogado_em = now(), revogado_por_nome = v_perfil.nome where id = p_id;
  perform public._auditar(v_uid, v_perfil.nome, 'DELEGACAO_REVOGADA', null,
            jsonb_build_object('setor_id', v_d.setor_id, 'delegado', v_d.delegado_nome, 'delegante', v_d.delegante_nome));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.painel_listar_delegacoes() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := public._uid(); v_perfil public.perfis%rowtype;
begin
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  if not found then raise exception 'Sessão inválida.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', d.id, 'setor_nome', s.nome, 'delegante_nome', d.delegante_nome, 'delegado_nome', d.delegado_nome,
      'inicio', d.inicio, 'fim', d.fim, 'justificativa', d.justificativa, 'ativa', d.ativa,
      'vigente', d.ativa and current_date between d.inicio and d.fim,
      'pode_revogar', d.ativa and (v_perfil.papel = 'gestor' or v_uid in (d.delegante_user_id, d.delegado_user_id)),
      'criado_em', d.criado_em, 'revogado_em', d.revogado_em) order by d.ativa desc, d.criado_em desc)
    from public.delegacoes d join public.setores s on s.id = d.setor_id
   where v_perfil.papel = 'gestor' or v_uid in (d.delegante_user_id, d.delegado_user_id)
      or (v_perfil.papel = 'super_setor' and d.setor_id = v_perfil.setor_id)), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- 7. Relatório gerencial: acrescenta "por_usuario" (produtividade) e enriquece "por_dia" com os
--    concluídos (tendência de entrada x saída), sem mudar o restante do relatório já existente.
-- ---------------------------------------------------------------------
create or replace function public.painel_relatorio(
  p_inicio date default null, p_fim date default null, p_incluir_teste boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  g public.perfis%rowtype := public._exigir_gestor();
  v_fuso text := public._fuso();
  v_hoje date := (now() at time zone public._fuso())::date;
  v_ini date := coalesce(p_inicio, (now() at time zone public._fuso())::date - 29);
  v_fim date := coalesce(p_fim, (now() at time zone public._fuso())::date);
  v_incl_teste boolean := coalesce(p_incluir_teste, false) and public._pode_ver_teste(g);
  v_tot jsonb; v_tempo jsonb; v_setor jsonb; v_dia jsonb; v_atr jsonb; v_mov jsonb; v_usuario jsonb;
begin
  if v_fim < v_ini then raise exception 'A data final não pode ser anterior à data inicial.'; end if;
  if v_fim - v_ini > 366 then raise exception 'Escolha um período de até 12 meses.'; end if;

  create temporary table if not exists _rel_base (
    id bigint, numero text, tipo text, urgente boolean, status text, prazo date, devolvido boolean,
    dia date, t1 timestamptz, t2 timestamptz, t3 timestamptz, setor text) on commit drop;
  delete from _rel_base where true;
  insert into _rel_base
  select p.id, p.numero, p.tipo, p.urgente, p.status, p.prazo_data, coalesce(p.devolvido, false),
         (p.created_at at time zone v_fuso)::date, t1.recebido_em, t2.recebido_em, t3.recebido_em,
         coalesce(t3.setor_nome, s.nome, 'Sem setor definido')
    from public.protocolos p
    left join public.tramites t1 on t1.protocolo_id = p.id and t1.etapa = 1
    left join public.tramites t2 on t2.protocolo_id = p.id and t2.etapa = 2
    left join public.tramites t3 on t3.protocolo_id = p.id and t3.etapa = 3
    left join public.setores s on s.id = p.setor_destino_id
   where (p.created_at at time zone v_fuso)::date between v_ini and v_fim
     and (v_incl_teste or p.ambiente = 'producao');

  select jsonb_build_object(
    'registrados', count(*),
    'concluidos', count(*) filter (where status = 'concluido'),
    'em_andamento', count(*) filter (where status <> 'concluido'),
    'aguardando_adm', count(*) filter (where status = 'pendente_adm' and not devolvido),
    'aguardando_setor', count(*) filter (where status = 'pendente_setor'),
    'devolvidos_agora', count(*) filter (where devolvido and status <> 'concluido'),
    'vencidos', count(*) filter (where status <> 'concluido' and prazo < v_hoje),
    'concluidos_no_prazo', count(*) filter (where status = 'concluido' and (prazo is null or (t3 at time zone v_fuso)::date <= prazo)),
    'concluidos_fora_do_prazo', count(*) filter (where status = 'concluido' and prazo is not null and (t3 at time zone v_fuso)::date > prazo),
    'urgentes', count(*) filter (where urgente),
    'judiciais', count(*) filter (where tipo = 'judicial'),
    'correspondencias', count(*) filter (where tipo = 'correspondencia'))
    into v_tot from _rel_base;

  select jsonb_build_object(
    'portaria_adm',  jsonb_build_object('media', round(avg(extract(epoch from (t2 - t1)) / 3600)::numeric, 1),
                                        'maximo', round(max(extract(epoch from (t2 - t1)) / 3600)::numeric, 1), 'n', count(t2)),
    'adm_setor',     jsonb_build_object('media', round(avg(extract(epoch from (t3 - t2)) / 3600) filter (where t3 is not null and t2 is not null)::numeric, 1),
                                        'maximo', round(max(extract(epoch from (t3 - t2)) / 3600) filter (where t3 is not null and t2 is not null)::numeric, 1), 'n', count(t3)),
    'total',         jsonb_build_object('media', round(avg(extract(epoch from (t3 - t1)) / 3600) filter (where t3 is not null)::numeric, 1),
                                        'maximo', round(max(extract(epoch from (t3 - t1)) / 3600) filter (where t3 is not null)::numeric, 1), 'n', count(t3)))
    into v_tempo from _rel_base;

  select coalesce(jsonb_agg(x order by (x->>'total')::int desc, x->>'setor'), '[]'::jsonb) into v_setor from (
    select jsonb_build_object('setor', setor, 'total', count(*),
             'concluidos', count(*) filter (where status = 'concluido'),
             'aguardando', count(*) filter (where status <> 'concluido'),
             'vencidos', count(*) filter (where status <> 'concluido' and prazo < v_hoje),
             'horas_medias', round(avg(extract(epoch from (t3 - t2)) / 3600) filter (where t3 is not null and t2 is not null)::numeric, 1)) as x
      from _rel_base where status <> 'pendente_adm' or setor <> 'Sem setor definido' group by setor) q;

  select coalesce(jsonb_agg(jsonb_build_object('dia', d::date, 'registrados', coalesce(c.n, 0), 'concluidos', coalesce(cc.n, 0)) order by d), '[]'::jsonb) into v_dia
    from generate_series(v_ini, v_fim, interval '1 day') d
    left join (select dia, count(*)::int n from _rel_base group by dia) c on c.dia = d::date
    left join (select (t3 at time zone v_fuso)::date as dia, count(*)::int n from _rel_base
                where status = 'concluido' and t3 is not null group by (t3 at time zone v_fuso)::date) cc on cc.dia = d::date;

  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_atr from (
    select jsonb_build_object('numero', numero, 'setor', case when status = 'pendente_adm' then 'ADM' else setor end,
             'dias_atraso', v_hoje - prazo, 'urgente', urgente, 'tipo', tipo) as x
      from _rel_base where status <> 'concluido' and prazo < v_hoje order by prazo, numero limit 10) q;

  select jsonb_build_object('reencaminhados', count(*) filter (where m.tipo = 'reencaminhado'),
                            'devolvidos', count(*) filter (where m.tipo = 'devolvido')) into v_mov
    from public.movimentacoes m join public.protocolos p on p.id = m.protocolo_id
   where (m.em at time zone v_fuso)::date between v_ini and v_fim
     and (v_incl_teste or p.ambiente = 'producao');

  -- produtividade por pessoa: quantas etapas cada uma realizou e o tempo médio de resposta dela
  -- (etapa 1 é a própria Portaria registrando — não é "tempo de resposta a nada", só volume).
  select coalesce(jsonb_agg(x order by (x->>'etapas')::int desc, x->>'usuario'), '[]'::jsonb) into v_usuario from (
    select jsonb_build_object(
             'usuario', max(t.usuario_nome), 'papel', max(pf.papel), 'setor_nome', max(st.nome),
             'etapas', count(*),
             'etapa1', count(*) filter (where t.etapa = 1),
             'etapa2', count(*) filter (where t.etapa = 2),
             'etapa3', count(*) filter (where t.etapa = 3),
             'tempo_medio_horas', round(avg(
                 case when t.etapa = 2 then extract(epoch from (t.recebido_em - t1x.recebido_em)) / 3600
                      when t.etapa = 3 then extract(epoch from (t.recebido_em - t2x.recebido_em)) / 3600
                 end) filter (where t.etapa in (2, 3))::numeric, 1)) as x
      from public.tramites t
      join public.protocolos p on p.id = t.protocolo_id
      left join public.perfis pf on pf.user_id = t.usuario_id
      left join public.setores st on st.id = pf.setor_id
      left join public.tramites t1x on t1x.protocolo_id = t.protocolo_id and t1x.etapa = 1
      left join public.tramites t2x on t2x.protocolo_id = t.protocolo_id and t2x.etapa = 2
     where (t.recebido_em at time zone v_fuso)::date between v_ini and v_fim
       and (v_incl_teste or p.ambiente = 'producao')
     group by t.usuario_id) q;

  perform public._auditar(g.user_id, g.nome, 'RELATORIO_GERADO', null,
            jsonb_build_object('inicio', v_ini, 'fim', v_fim, 'incluiu_teste', v_incl_teste));
  return jsonb_build_object('periodo', jsonb_build_object('inicio', v_ini, 'fim', v_fim), 'totais', v_tot,
           'tempo_horas', v_tempo, 'por_setor', v_setor, 'por_dia', v_dia, 'atrasados', v_atr, 'movimentacoes', v_mov,
           'por_usuario', v_usuario, 'pode_ver_teste', public._pode_ver_teste(g), 'incluiu_teste', v_incl_teste);
end $$;

-- ---------------------------------------------------------------------
-- 8. Diagnóstico da instalação: só atualiza a contagem de arquivos (15 → 16).
-- ---------------------------------------------------------------------
create or replace function public.painel_diagnostico() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  g public.perfis%rowtype := public._exigir_gestor();
  v_itens jsonb := '[]'::jsonb; v_aux text; v_n int; v_t text; v_sem text := '';
  v_arquivos int := 16;
begin
  -- cada item tem nivel: ok | aviso | erro
  -- Versão do banco
  select max(versao) into v_n from public.schema_versao;
  v_itens := v_itens || jsonb_build_object('grupo', 'Banco de dados', 'item', 'Versão do banco',
     'nivel', case when v_n = v_arquivos then 'ok' else 'erro' end,
     'detalhe', case when v_n = v_arquivos then 'Atualizado (' || v_n || ' de ' || v_arquivos || ').'
                     else 'Versão ' || coalesce(v_n::text, '?') || ' de ' || v_arquivos || '. Rode o instalacao_completa.sql no SQL Editor.' end);

  -- RLS em todas as tabelas
  select string_agg(c.relname, ', ' order by c.relname) into v_aux
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  v_itens := v_itens || jsonb_build_object('grupo', 'Segurança', 'item', 'Proteção por linha (RLS) em todas as tabelas',
     'nivel', case when v_aux is null then 'ok' else 'erro' end,
     'detalhe', coalesce('Sem proteção: ' || v_aux, 'Todas as tabelas protegidas.'));

  -- acesso direto negado
  v_aux := null;
  foreach v_t in array array['protocolos', 'tramites', 'perfis', 'auditoria', 'parametros', 'fila_email', 'email_brevo', 'push_inscricoes', 'push_config', 'integracao', 'delegacoes'] loop
    if to_regclass('public.' || v_t) is not null then
      if has_table_privilege('anon', 'public.' || v_t, 'select') or has_table_privilege('anon', 'public.' || v_t, 'insert') then
        v_aux := coalesce(v_aux || ', ', '') || v_t || ' (visitante)';
      end if;
    end if;
  end loop;
  foreach v_t in array array['email_brevo', 'push_inscricoes', 'push_config', 'integracao', 'fila_email', 'delegacoes'] loop
    if to_regclass('public.' || v_t) is not null and has_table_privilege('authenticated', 'public.' || v_t, 'select') then
      v_aux := coalesce(v_aux || ', ', '') || v_t || ' (usuário logado)';
    end if;
  end loop;
  v_itens := v_itens || jsonb_build_object('grupo', 'Segurança', 'item', 'Acesso direto às tabelas sensíveis bloqueado',
     'nivel', case when v_aux is null then 'ok' else 'erro' end,
     'detalhe', coalesce('Acesso indevido: ' || v_aux, 'Visitantes e usuários só usam as funções do sistema.'));

  -- cadeia da trilha
  v_aux := (public.verificar_auditoria() ->> 'ok');
  v_itens := v_itens || jsonb_build_object('grupo', 'Segurança', 'item', 'Trilha de auditoria íntegra',
     'nivel', case when v_aux = 'true' then 'ok' else 'erro' end,
     'detalhe', case when v_aux = 'true' then 'Cadeia de hashes conferida.' else 'ADULTERAÇÃO DETECTADA. Use "Verificar trilha" na aba Auditoria.' end);

  -- quem opera o sistema
  select count(*) into v_n from public.perfis where ativo and papel = 'gestor';
  v_itens := v_itens || jsonb_build_object('grupo', 'Usuários e setores', 'item', 'Gestor ativo',
     'nivel', case when v_n >= 1 then 'ok' else 'erro' end, 'detalhe', v_n || ' gestor(es) ativo(s).');
  select count(*) into v_n from public.perfis where ativo and papel = 'adm';
  v_itens := v_itens || jsonb_build_object('grupo', 'Usuários e setores', 'item', 'ADM ativo (recebe os avisos de chegada)',
     'nivel', case when v_n >= 1 then 'ok' else 'erro' end, 'detalhe', v_n || ' ADM ativo(s).');
  select count(*) into v_n from public.perfis where ativo and papel = 'portaria';
  v_itens := v_itens || jsonb_build_object('grupo', 'Usuários e setores', 'item', 'Portaria ativa',
     'nivel', case when v_n >= 1 then 'ok' else 'aviso' end, 'detalhe', v_n || ' usuário(s) da Portaria.');
  select string_agg(s.nome, ', ' order by s.nome) into v_aux from public.setores s
   where s.ativo and not exists (select 1 from public.perfis p where p.ativo and p.papel = 'super_setor' and p.setor_id = s.id);
  v_itens := v_itens || jsonb_build_object('grupo', 'Usuários e setores', 'item', 'Todo setor ativo tem responsável',
     'nivel', case when v_aux is null then 'ok' else 'aviso' end, 'detalhe', coalesce('Sem responsável: ' || v_aux, 'Todos os setores ativos têm responsável.'));
  select count(*) into v_n from public.perfis where ativo and email is null;
  v_itens := v_itens || jsonb_build_object('grupo', 'Usuários e setores', 'item', 'Usuários com e-mail cadastrado',
     'nivel', case when v_n = 0 then 'ok' else 'aviso' end, 'detalhe', case when v_n = 0 then 'Todos podem receber avisos.' else v_n || ' usuário(s) sem e-mail não recebem avisos.' end);

  -- e-mail
  v_itens := v_itens || jsonb_build_object('grupo', 'Avisos por e-mail', 'item', 'Endereço do sistema nos e-mails',
     'nivel', case when public._param_text('url_sistema', '') <> '' then 'ok' else 'aviso' end,
     'detalhe', case when public._param_text('url_sistema', '') <> '' then public._param_text('url_sistema', '') else 'Preencha em Sistema > Prazos e regras, para o e-mail trazer o link.' end);
  v_itens := v_itens || jsonb_build_object('grupo', 'Avisos por e-mail', 'item', 'Extensão pg_net (envio imediato)',
     'nivel', case when exists (select 1 from pg_extension where extname = 'pg_net') then 'ok' else 'aviso' end,
     'detalhe', case when exists (select 1 from pg_extension where extname = 'pg_net') then 'Ativa.' else 'Ative em Database > Extensions > pg_net.' end);
  v_itens := v_itens || jsonb_build_object('grupo', 'Avisos por e-mail', 'item', 'Brevo configurado',
     'nivel', case when exists (select 1 from public.email_brevo where ativo) then 'ok' else 'aviso' end,
     'detalhe', case when exists (select 1 from public.email_brevo where ativo) then 'Remetente: ' || (select remetente_email from public.email_brevo where ativo)
                     else 'Sem envio imediato. Veja o GUIA_BREVO.md.' end);
  select count(*) into v_n from public.fila_email where status = 'erro';
  v_itens := v_itens || jsonb_build_object('grupo', 'Avisos por e-mail', 'item', 'E-mails com erro',
     'nivel', case when v_n = 0 then 'ok' else 'aviso' end,
     'detalhe', case when v_n = 0 then 'Nenhum.' else v_n || ' com erro. Último: ' || coalesce((select left(erro, 120) from public.fila_email where status = 'erro' order by id desc limit 1), '?') end);

  -- push
  v_itens := v_itens || jsonb_build_object('grupo', 'Avisos no aparelho', 'item', 'Notificações no celular (Web Push)',
     'nivel', case when exists (select 1 from public.push_config where ativo) then 'ok' else 'aviso' end,
     'detalhe', case when exists (select 1 from public.push_config where ativo)
                     then (select count(distinct user_id) from public.push_inscricoes) || ' usuário(s) com aparelho ativado.'
                     else 'Opcional. Veja o GUIA_AVISOS_NO_CELULAR.md.' end);

  return jsonb_build_object(
    'ok', not exists (select 1 from jsonb_array_elements(v_itens) i where i->>'nivel' = 'erro'),
    'erros', (select count(*) from jsonb_array_elements(v_itens) i where i->>'nivel' = 'erro'),
    'avisos', (select count(*) from jsonb_array_elements(v_itens) i where i->>'nivel' = 'aviso'),
    'itens', v_itens, 'gerado_em', now());
end $$;

insert into public.schema_versao (versao, arquivo) values (16, '16_delegacao_produtividade.sql') on conflict (versao) do nothing;

-- ---------------------------------------------------------------------
-- 9. Permissões de execução das novas funções.
-- ---------------------------------------------------------------------
revoke all on function public._setor_delegado_para_mim(bigint), public._tenho_delegacao_ativa(),
  public.usuarios_para_delegar(), public.painel_delegar_recebimento(uuid, date, date, text, text),
  public.painel_revogar_delegacao(bigint, text), public.painel_listar_delegacoes()
  from public, anon, authenticated;
grant execute on function public.usuarios_para_delegar(), public.painel_delegar_recebimento(uuid, date, date, text, text),
  public.painel_revogar_delegacao(bigint, text), public.painel_listar_delegacoes()
  to authenticated;
