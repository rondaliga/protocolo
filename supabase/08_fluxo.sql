-- =====================================================================
-- 08 · FLUXO: devolução e reencaminhamento, atalhos da lista e lembretes escalonados
-- Rode DEPOIS de schema.sql → 02 → … → 07. Idempotente.
--   • Reencaminhar: ADM ou gestor trocam o setor de destino de um protocolo que ainda não foi concluído.
--   • Devolver: o setor de destino devolve ao ADM (documento enviado ao setor errado). O ADM reencaminha.
--     Tudo com justificativa, PIN, histórico próprio (movimentacoes) e registro na trilha.
--   • Atalhos da lista: "meus pendentes", "vencem em 7 dias", "urgentes", "devolvidos".
--   • Lembretes em escada quando o tempo máximo estoura (responsável → novo lembrete → gestor).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. ESTRUTURA
-- ---------------------------------------------------------------------
alter table public.protocolos add column if not exists devolvido boolean not null default false;

create table if not exists public.movimentacoes (
  id              bigint generated always as identity primary key,
  protocolo_id    bigint not null references public.protocolos(id),
  tipo            text not null check (tipo in ('reencaminhado', 'devolvido')),
  de_setor_id     bigint references public.setores(id),
  de_setor_nome   text,
  para_setor_id   bigint references public.setores(id),
  para_setor_nome text,
  justificativa   text not null check (length(justificativa) between 10 and 500),
  usuario_id      uuid not null references auth.users(id),
  usuario_nome    text not null,
  em              timestamptz not null default now()
);
create index if not exists ix_movimentacoes_protocolo on public.movimentacoes(protocolo_id);

do $$
declare t text := 'movimentacoes';
begin
  execute format('drop trigger if exists trg_%1$s_imutavel on public.%1$s', t);
  execute format('create trigger trg_%1$s_imutavel before update or delete on public.%1$s
                  for each row execute function public._bloquear_alteracao()', t);
  execute format('drop trigger if exists trg_%1$s_sem_truncate on public.%1$s', t);
  execute format('create trigger trg_%1$s_sem_truncate before truncate on public.%1$s
                  for each statement execute function public._bloquear_alteracao()', t);
end $$;

alter table public.movimentacoes enable row level security;
drop policy if exists p_mov_select on public.movimentacoes;
create policy p_mov_select on public.movimentacoes for select to authenticated
  using (public.pode_ver_protocolo(protocolo_id));
revoke all on public.movimentacoes from public, anon, authenticated;
grant select on public.movimentacoes to authenticated;

-- o destino só muda pelas funções de reencaminhar/devolver (que sinalizam a alteração autorizada)
create or replace function public._protocolos_guarda() returns trigger
language plpgsql as $$
begin
  if new.id is distinct from old.id or new.numero is distinct from old.numero
     or new.descricao is distinct from old.descricao or new.created_at is distinct from old.created_at
     or new.created_by is distinct from old.created_by
     or new.tipo is distinct from old.tipo or new.urgente is distinct from old.urgente then
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

-- documento devolvido ao ADM não pode ser recebido pelo setor até ser reencaminhado
create or replace function public._tramite_bloqueia_devolvido() returns trigger
language plpgsql as $$
begin
  if new.etapa = 3 and exists (select 1 from public.protocolos where id = new.protocolo_id and devolvido) then
    raise exception 'Este protocolo foi devolvido ao ADM e aguarda novo encaminhamento.' using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists trg_tramites_devolvido on public.tramites;
create trigger trg_tramites_devolvido before insert on public.tramites
  for each row execute function public._tramite_bloqueia_devolvido();

create or replace function public._categoria_auditoria(p_acao text) returns text
language sql immutable as $$
  select case
    when p_acao in ('LOGIN', 'LOGOUT', 'LOGOUT_INATIVIDADE', 'FALHA_PIN', 'USUARIO_BLOQUEADO') then 'acesso'
    when p_acao = 'PROTOCOLO_CRIADO' then 'protocolo'
    when p_acao in ('RECEBIMENTO_ADM', 'RECEBIMENTO_SETOR', 'PROTOCOLO_REENCAMINHADO', 'PROTOCOLO_DEVOLVIDO') then 'tramitacao'
    when p_acao = 'DESCRICAO_CORRIGIDA' then 'correcao'
    when p_acao = 'PRAZO_AJUSTADO' or p_acao like 'ALERTA\_%' then 'prazo'
    when p_acao like 'IMPRESSAO\_%' then 'impressao'
    when p_acao in ('PIN_ALTERADO', 'SENHA_ALTERADA') then 'seguranca'
    else 'administracao' end
$$;

-- ---------------------------------------------------------------------
-- 2. LEITURA: visão, listagem com atalhos, resumo, pendências e detalhe
-- ---------------------------------------------------------------------
drop view if exists public.v_livro;
create view public.v_livro with (security_invoker = true) as
select p.id, p.numero, p.status, p.created_at,
       coalesce((select c.descricao_nova from public.correcoes_descricao c
                  where c.protocolo_id = p.id order by c.id desc limit 1), p.descricao) as descricao,
       (select count(*) from public.correcoes_descricao c where c.protocolo_id = p.id)::int as n_correcoes,
       t1.recebido_em as e1_em, t1.usuario_nome as e1_usuario, t1.assinatura_tipo as e1_tipo,
       (t1.assinatura_png is not null) as e1_png,
       t2.recebido_em as e2_em, t2.usuario_nome as e2_usuario, t2.assinatura_tipo as e2_tipo,
       (t2.assinatura_png is not null) as e2_png,
       t3.recebido_em as e3_em, t3.usuario_nome as e3_usuario, t3.assinatura_tipo as e3_tipo,
       (t3.assinatura_png is not null) as e3_png, t3.setor_nome as e3_setor,
       p.tipo, p.urgente, p.prazo_data,
       public._dias_restantes(p.prazo_data, p.status) as dias_restantes,
       public._semaforo(p.prazo_data, p.status) as semaforo,
       p.setor_destino_id, sd.nome as setor_destino_nome, p.sla_limite,
       (p.status <> 'concluido' and p.sla_limite is not null and now() > p.sla_limite) as sla_estourado,
       case p.status when 'pendente_adm' then t1.recebido_em
                     when 'pendente_setor' then coalesce((select max(m.em) from public.movimentacoes m where m.protocolo_id = p.id), t2.recebido_em)
       end as aguardando_desde,
       (select count(*) from public.protocolo_fotos f where f.protocolo_id = p.id)::int as n_fotos,
       p.devolvido,
       (select m.de_setor_nome from public.movimentacoes m where m.protocolo_id = p.id and p.devolvido order by m.id desc limit 1) as devolvido_por,
       (select count(*) from public.movimentacoes m where m.protocolo_id = p.id)::int as n_movimentacoes
  from public.protocolos p
  left join public.tramites t1 on t1.protocolo_id = p.id and t1.etapa = 1
  left join public.tramites t2 on t2.protocolo_id = p.id and t2.etapa = 2
  left join public.tramites t3 on t3.protocolo_id = p.id and t3.etapa = 3
  left join public.setores sd on sd.id = p.setor_destino_id;
grant select on public.v_livro to authenticated;

-- "meus pendentes" = o mesmo critério do sino (minhas_pendencias)
create or replace function public._sou_responsavel(p_status text, p_devolvido boolean, p_semaforo text, p_sla boolean) returns boolean
language sql stable security definer set search_path = public as $$
  select case public.meu_papel()
    when 'adm' then p_status = 'pendente_adm' or (p_status = 'pendente_setor' and p_devolvido)
    when 'super_setor' then p_status = 'pendente_setor' and not p_devolvido
    when 'gestor' then p_status <> 'concluido' and (p_semaforo in ('vencido', 'critico') or p_sla)
    else false end
$$;

create or replace function public.listar_livro(
  p_q text default null, p_status text default null,
  p_data_ini date default null, p_data_fim date default null,
  p_limite int default 25, p_offset int default 0,
  p_alerta text default null, p_ordem text default 'recentes')
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare v_like text; v_total bigint; v_itens jsonb; v_hoje date := (now() at time zone public._fuso())::date;
begin
  p_limite := least(greatest(coalesce(p_limite, 25), 1), 500);
  p_offset := greatest(coalesce(p_offset, 0), 0);
  v_like := case when nullif(btrim(p_q), '') is null then null
                 else '%' || replace(replace(replace(left(btrim(p_q), 100), '\', '\\'), '%', '\%'), '_', '\_') || '%' end;

  with f as (
    select v.* from public.v_livro v
     where (v_like is null or v.numero ilike v_like or v.descricao ilike v_like)
       and (p_status is null or v.status = p_status)
       and (p_data_ini is null or (v.created_at at time zone public._fuso())::date >= p_data_ini)
       and (p_data_fim is null or (v.created_at at time zone public._fuso())::date <= p_data_fim)
       and (p_alerta is null
            or (p_alerta = 'abertos'    and v.status <> 'concluido')
            or (p_alerta = 'vencidos'   and v.semaforo = 'vencido')
            or (p_alerta = 'criticos'   and v.semaforo = 'critico')
            or (p_alerta = 'sla'        and v.sla_estourado)
            or (p_alerta = 'urgentes'   and v.urgente and v.status <> 'concluido')
            or (p_alerta = 'semana'     and v.status <> 'concluido' and v.prazo_data between v_hoje and v_hoje + 7)
            or (p_alerta = 'devolvidos' and v.devolvido and v.status <> 'concluido')
            or (p_alerta = 'meus'       and public._sou_responsavel(v.status, v.devolvido, v.semaforo, v.sla_estourado)))
  ), o as (
    select f.*, row_number() over (
             order by case when p_ordem = 'prazo' then (f.status = 'concluido') end,
                      case when p_ordem = 'prazo' then f.prazo_data end nulls last,
                      case when p_ordem = 'prazo' then f.urgente end desc,
                      f.id desc) as rn
      from f
  )
  select (select count(*) from f),
         coalesce((select jsonb_agg(to_jsonb(o) - 'rn' order by o.rn) from o where o.rn > p_offset and o.rn <= p_offset + p_limite), '[]'::jsonb)
    into v_total, v_itens;
  return jsonb_build_object('total', v_total, 'itens', v_itens);
end $$;

create or replace function public.resumo_livro() returns jsonb
language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'total',          count(*),
    'hoje',           count(*) filter (where (created_at at time zone public._fuso())::date
                                            = (now() at time zone public._fuso())::date),
    'pendente_adm',   count(*) filter (where status = 'pendente_adm'),
    'pendente_setor', count(*) filter (where status = 'pendente_setor'),
    'concluido',      count(*) filter (where status = 'concluido'),
    'abertos',        count(*) filter (where status <> 'concluido'),
    'vencidos',       count(*) filter (where semaforo = 'vencido'),
    'criticos',       count(*) filter (where semaforo = 'critico'),
    'sla_estourado',  count(*) filter (where sla_estourado),
    'devolvidos',     count(*) filter (where devolvido and status <> 'concluido'),
    'alerta_dias',    public._alerta_dias())
  from public.v_livro
$$;

create or replace function public.minhas_pendencias() returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare v_papel text := public.meu_papel(); v_itens jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_itens from (
    select v.id, v.numero, v.tipo, v.urgente, v.status, v.prazo_data, v.dias_restantes, v.semaforo,
           v.aguardando_desde, v.sla_limite, v.sla_estourado, v.setor_destino_nome, v.devolvido
      from public.v_livro v
     where v.status <> 'concluido'
       and ((v_papel = 'adm' and (v.status = 'pendente_adm' or v.devolvido))
         or (v_papel = 'super_setor' and v.status = 'pendente_setor' and not v.devolvido)
         or (v_papel = 'gestor' and (v.semaforo in ('vencido', 'critico') or v.sla_estourado)))
     order by v.sla_estourado desc, (v.semaforo = 'vencido') desc, v.urgente desc, v.dias_restantes nulls last, v.id
  ) x;
  return jsonb_build_object('papel', v_papel, 'total', jsonb_array_length(v_itens), 'itens', v_itens,
    'urgentes', (select count(*) from jsonb_array_elements(v_itens) e
                  where (e ->> 'sla_estourado')::boolean or e ->> 'semaforo' = 'vencido'));
end $$;

create or replace function public.detalhe_protocolo(p_id bigint) returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare v jsonb;
begin
  select to_jsonb(x) into v from public.v_livro x where x.id = p_id;
  if v is null then return null; end if;
  return v || jsonb_build_object(
    'descricao_original', (select descricao from public.protocolos where id = p_id),
    'etapas', coalesce((select jsonb_agg(jsonb_build_object(
                'etapa', t.etapa, 'recebido_em', t.recebido_em, 'usuario', t.usuario_nome,
                'setor', t.setor_nome, 'assinatura_tipo', t.assinatura_tipo,
                'assinatura_png', t.assinatura_png, 'selo', t.selo) order by t.etapa)
                from public.tramites t where t.protocolo_id = p_id), '[]'::jsonb),
    'correcoes', coalesce((select jsonb_agg(jsonb_build_object(
                'corrigido_em', c.corrigido_em, 'usuario', c.usuario_nome, 'anterior', c.descricao_anterior,
                'nova', c.descricao_nova, 'justificativa', c.justificativa) order by c.id)
                from public.correcoes_descricao c where c.protocolo_id = p_id), '[]'::jsonb),
    'prazos', coalesce((select jsonb_agg(jsonb_build_object(
                'ajustado_em', h.ajustado_em, 'usuario', h.usuario_nome, 'anterior', h.prazo_anterior,
                'novo', h.prazo_novo, 'justificativa', h.justificativa) order by h.id)
                from public.prazo_historico h where h.protocolo_id = p_id), '[]'::jsonb),
    'movimentacoes', coalesce((select jsonb_agg(jsonb_build_object(
                'tipo', m.tipo, 'em', m.em, 'usuario', m.usuario_nome, 'de', m.de_setor_nome, 'para', m.para_setor_nome,
                'justificativa', m.justificativa) order by m.id)
                from public.movimentacoes m where m.protocolo_id = p_id), '[]'::jsonb),
    'fotos', coalesce((select jsonb_agg(jsonb_build_object('caminho', f.caminho, 'enviado_em', f.enviado_em) order by f.id)
                from public.protocolo_fotos f where f.protocolo_id = p_id), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 3. ESCRITA: reencaminhar e devolver
-- ---------------------------------------------------------------------
create or replace function public.reencaminhar_protocolo(
  p_protocolo_id bigint, p_setor_id bigint, p_justificativa text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_p public.protocolos%rowtype;
  v_just text; v_msg text; v_agora timestamptz := now(); v_novo text; v_de text; v_sla timestamptz; v_mid bigint;
begin
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  if not found or v_perfil.papel not in ('adm', 'gestor') then
    raise exception 'Seu perfil não tem permissão para reencaminhar protocolos.' using errcode = '42501';
  end if;
  v_just := regexp_replace(btrim(coalesce(p_justificativa, '')), '\s+', ' ', 'g');
  if length(v_just) not between 10 and 500 then raise exception 'Informe a justificativa (de 10 a 500 caracteres).'; end if;
  select * into v_p from public.protocolos where id = p_protocolo_id for update;
  if not found then raise exception 'Protocolo não encontrado.'; end if;
  if v_p.status <> 'pendente_setor' then
    raise exception 'Só é possível reencaminhar depois do recebimento do ADM e antes da conclusão no setor.';
  end if;
  select nome into v_novo from public.setores where id = p_setor_id and ativo;
  if v_novo is null then raise exception 'Escolha o novo setor de destino.'; end if;
  if p_setor_id is not distinct from v_p.setor_destino_id then raise exception 'O protocolo já está encaminhado a este setor.'; end if;
  v_msg := public._checar_pin(v_uid, p_pin);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;

  select nome into v_de from public.setores where id = v_p.setor_destino_id;
  v_sla := public._somar_horas_uteis(v_agora, case when v_p.urgente then (public._param_min('sla_setor_urgente_min', 240) / 60.0)
                                                   else (public._param_min('sla_setor_min', 540) / 60.0) end);
  insert into public.movimentacoes (protocolo_id, tipo, de_setor_id, de_setor_nome, para_setor_id, para_setor_nome,
                                    justificativa, usuario_id, usuario_nome, em)
  values (v_p.id, 'reencaminhado', v_p.setor_destino_id, v_de, p_setor_id, v_novo, v_just, v_uid, v_perfil.nome, v_agora)
  returning id into v_mid;
  perform set_config('app.alteracao_autorizada', 'REDIRECIONAR', true);
  update public.protocolos set setor_destino_id = p_setor_id, devolvido = false, sla_limite = v_sla where id = v_p.id;
  perform set_config('app.alteracao_autorizada', '', true);
  perform public._enfileirar_email('reenc:' || v_p.id || ':' || v_mid, 'REENCAMINHADO', v_p.id,
            public._emails(array['super_setor'], p_setor_id),
            '[Protocolo' || case when v_p.urgente then ' URGENTE' else '' end || '] ' || v_p.numero || ' encaminhado ao seu setor',
            public._texto_email(v_p.numero, v_p.tipo, v_p.urgente, v_p.prazo_data, v_sla,
                                'Uma demanda foi reencaminhada ao setor ' || v_novo || '.'));
  perform public._auditar(v_uid, v_perfil.nome, 'PROTOCOLO_REENCAMINHADO', v_p.id,
            jsonb_build_object('numero', v_p.numero, 'de', v_de, 'para', v_novo, 'justificativa', v_just));
  return jsonb_build_object('ok', true, 'id', v_p.id, 'numero', v_p.numero);
end $$;

create or replace function public.devolver_protocolo(p_protocolo_id bigint, p_justificativa text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_p public.protocolos%rowtype;
  v_just text; v_msg text; v_agora timestamptz := now(); v_de text; v_sla timestamptz; v_mid bigint;
begin
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  if not found or v_perfil.papel not in ('super_setor', 'gestor') then
    raise exception 'Seu perfil não tem permissão para devolver protocolos.' using errcode = '42501';
  end if;
  v_just := regexp_replace(btrim(coalesce(p_justificativa, '')), '\s+', ' ', 'g');
  if length(v_just) not between 10 and 500 then raise exception 'Informe a justificativa (de 10 a 500 caracteres).'; end if;
  select * into v_p from public.protocolos where id = p_protocolo_id for update;
  if not found then raise exception 'Protocolo não encontrado.'; end if;
  if v_perfil.papel = 'super_setor' and (v_p.status <> 'pendente_setor' or v_p.devolvido
                                         or v_p.setor_destino_id is distinct from v_perfil.setor_id) then
    raise exception 'Protocolo não encontrado.';
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
            jsonb_build_object('numero', v_p.numero, 'de', v_de, 'justificativa', v_just));
  return jsonb_build_object('ok', true, 'id', v_p.id, 'numero', v_p.numero);
end $$;

-- exclusão e backup passam a cobrir o novo histórico
create or replace function public.excluir_protocolo(
  p_protocolo_id bigint, p_justificativa text, p_pin_gestor text, p_excluir_trilha boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare g public.perfis%rowtype := public._exigir_gestor(); p public.protocolos%rowtype; v_msg text;
        v_just text := regexp_replace(btrim(coalesce(p_justificativa, '')), '\s+', ' ', 'g');
        v_fotos jsonb; v_etapas int; v_trilha int := 0;
begin
  select * into p from public.protocolos where id = p_protocolo_id for update;
  if not found then raise exception 'Protocolo não encontrado.'; end if;
  if length(v_just) < 10 or length(v_just) > 500 then raise exception 'Informe a justificativa (de 10 a 500 caracteres).'; end if;
  v_msg := public._checar_pin(g.user_id, p_pin_gestor);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;

  select coalesce(jsonb_agg(caminho), '[]'::jsonb) into v_fotos from public.protocolo_fotos where protocolo_id = p.id;
  select count(*)::int into v_etapas from public.tramites where protocolo_id = p.id;

  perform set_config('app.alteracao_autorizada', 'DELETE', true);
  delete from public.tramites where protocolo_id = p.id;
  delete from public.correcoes_descricao where protocolo_id = p.id;
  delete from public.prazo_historico where protocolo_id = p.id;
  delete from public.movimentacoes where protocolo_id = p.id;
  delete from public.protocolo_fotos where protocolo_id = p.id;
  delete from public.fila_email where protocolo_id = p.id;
  if p_excluir_trilha then
    delete from public.auditoria where protocolo_id = p.id;
    get diagnostics v_trilha = row_count;
  end if;
  delete from public.protocolos where id = p.id;
  perform set_config('app.alteracao_autorizada', '', true);
  if p_excluir_trilha then perform public._reancorar_auditoria(); end if;

  perform public._auditar(g.user_id, g.nome, 'PROTOCOLO_EXCLUIDO', p.id,
            jsonb_build_object('numero', p.numero, 'tipo', p.tipo, 'situacao', p.status, 'etapas_registradas', v_etapas,
                               'fotos', jsonb_array_length(v_fotos), 'trilha_removida', v_trilha, 'justificativa', v_just));
  return jsonb_build_object('ok', true, 'numero', p.numero, 'fotos', v_fotos, 'trilha_removida', v_trilha);
end $$;

create or replace function public.exportar_backup() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_perfil public.perfis%rowtype; v_prot jsonb; v_tram jsonb; v_aud jsonb; v_mov jsonb;
begin
  select * into v_perfil from public.perfis where user_id = public._uid() and ativo;
  if not found or v_perfil.papel <> 'gestor' then
    raise exception 'Apenas o gestor pode exportar o backup.' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(to_jsonb(p) order by p.id), '[]'::jsonb) into v_prot from public.protocolos p;
  select coalesce(jsonb_agg((to_jsonb(t) - 'assinatura_png') order by t.id), '[]'::jsonb) into v_tram from public.tramites t;
  select coalesce(jsonb_agg(to_jsonb(m) order by m.id), '[]'::jsonb) into v_mov from public.movimentacoes m;
  select coalesce(jsonb_agg(to_jsonb(a) order by a.id), '[]'::jsonb) into v_aud from public.auditoria a;
  perform public._auditar(public._uid(), v_perfil.nome, 'BACKUP_EXPORTADO', null,
            jsonb_build_object('protocolos', jsonb_array_length(v_prot), 'tramites', jsonb_array_length(v_tram),
                               'eventos', jsonb_array_length(v_aud)));
  return jsonb_build_object('gerado_em', now(), 'versao_schema', public.versao_schema(),
                            'protocolos', v_prot, 'tramites', v_tram, 'movimentacoes', v_mov, 'auditoria', v_aud);
end $$;

-- ---------------------------------------------------------------------
-- 4. LEMBRETES EM ESCADA (tempo máximo estourado)
--    1º aviso: responsável (ADM ou setor), quando o tempo estoura.
--    2º aviso: de novo ao responsável, "sla_lembrete_min" horas úteis depois.
--    3º aviso: responsável + gestor, "sla_escalada_min" horas úteis depois.
--    Sem e-mail cadastrado no responsável, o aviso vai direto ao gestor. A cada novo encaminhamento a escada recomeça.
-- ---------------------------------------------------------------------
insert into public.parametros (chave, valor, descricao) values
  ('sla_lembrete_min', '4:00', 'Horas úteis depois de estourar o tempo máximo para repetir o aviso ao responsável.'),
  ('sla_escalada_min', '8:00', 'Horas úteis depois de estourar o tempo máximo para avisar também o gestor.')
on conflict (chave) do nothing;

create or replace function public._verificar_sla() returns int
language plpgsql security definer set search_path = public as $$
declare
  r public.protocolos%rowtype; v_hoje date := (now() at time zone public._fuso())::date;
  v_aviso int := public._param_int('alerta_prazo_dias', 2); v_n int := 0;
  v_atual text[]; v_gest text[]; v_dest text[]; v_dias int; v_etapa int; v_nivel int; v_ciclo text; v_lem int; v_esc int;
begin
  v_lem := public._param_min('sla_lembrete_min', 240);
  v_esc := greatest(public._param_min('sla_escalada_min', 480), v_lem);
  v_gest := public._emails(array['gestor']);
  for r in select * from public.protocolos where status <> 'concluido' order by id loop
    v_etapa := case when r.status = 'pendente_adm' or r.devolvido then 2 else 3 end;
    v_atual := case when v_etapa = 2 then public._emails(array['adm'])
                    else public._emails(array['super_setor'], r.setor_destino_id) end;
    v_dest  := (select coalesce(array_agg(distinct e), '{}') from unnest(v_atual || v_gest) e);

    if r.sla_limite is not null and now() > r.sla_limite then
      v_nivel := case when now() >= public._somar_horas_uteis(r.sla_limite, v_esc / 60.0) then 3
                      when now() >= public._somar_horas_uteis(r.sla_limite, v_lem / 60.0) then 2 else 1 end;
      v_ciclo := extract(epoch from r.sla_limite)::bigint::text;
      if public._enfileirar_email('sla:' || r.id || ':' || v_etapa || ':' || v_nivel || ':' || v_ciclo, 'SLA', r.id,
           case when v_nivel = 3 or cardinality(v_atual) = 0 then v_dest else v_atual end,
           '[Protocolo ATRASADO' || case v_nivel when 1 then '' when 2 then ' · 2º aviso' else ' · escalado ao gestor' end || '] '
             || r.numero || ' sem recebimento no tempo previsto',
           public._texto_email(r.numero, r.tipo, r.urgente, r.prazo_data, r.sla_limite,
             case v_nivel when 1 then 'ATENÇÃO: ' when 2 then 'LEMBRETE: ' else 'ESCALADO AO GESTOR: ' end
             || 'o tempo máximo para o recebimento ' || case v_etapa when 2 then 'do ADM' else 'do setor de destino' end || ' foi ultrapassado.')) then
        v_n := v_n + 1;
        perform public._auditar(null, 'sistema', 'ALERTA_SLA', r.id, jsonb_build_object('numero', r.numero, 'etapa', v_etapa, 'nivel', v_nivel));
      end if;
    end if;

    if r.prazo_data is not null then
      v_dias := r.prazo_data - v_hoje;
      if v_dias < 0 then
        if public._enfileirar_email('vencido:' || r.id, 'PRAZO_VENCIDO', r.id, v_dest,
             '[Protocolo VENCIDO] ' || r.numero || ' passou do prazo',
             public._texto_email(r.numero, r.tipo, r.urgente, r.prazo_data, null, 'URGENTE: o prazo desta demanda VENCEU e ela ainda não foi concluída.')) then
          v_n := v_n + 1;
          perform public._auditar(null, 'sistema', 'ALERTA_PRAZO_VENCIDO', r.id, jsonb_build_object('numero', r.numero));
        end if;
      elsif v_dias <= v_aviso then
        if public._enfileirar_email('prazo:' || r.id, 'PRAZO_PROXIMO', r.id, v_dest,
             '[Protocolo] ' || r.numero || ' vence em ' || v_dias || case when v_dias = 1 then ' dia' else ' dias' end,
             public._texto_email(r.numero, r.tipo, r.urgente, r.prazo_data, null, 'O prazo desta demanda está próximo e ela ainda não foi concluída.')) then
          v_n := v_n + 1;
          perform public._auditar(null, 'sistema', 'ALERTA_PRAZO_PROXIMO', r.id, jsonb_build_object('numero', r.numero, 'dias', v_dias));
        end if;
      end if;
    end if;
  end loop;
  return v_n;
end $$;

-- a escalada precisa fazer sentido: o aviso ao gestor não pode vir antes do lembrete
create or replace function public.painel_salvar_parametros(p_valores jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.perfis%rowtype := public._exigir_gestor(); k text; v text; v_ant text; v_alt jsonb := '{}'::jsonb;
begin
  if p_valores is null or jsonb_typeof(p_valores) <> 'object' then raise exception 'Nada para salvar.'; end if;
  for k in select jsonb_object_keys(p_valores) loop
    begin
      v := public._validar_parametro(k, p_valores ->> k);
    exception when others then
      raise exception '%: %', k, sqlerrm;
    end;
    select valor into v_ant from public.parametros where chave = k;
    if v_ant is distinct from v then
      update public.parametros set valor = v where chave = k;
      v_alt := v_alt || jsonb_build_object(k, jsonb_build_object('anterior', v_ant, 'valor', v));
    end if;
  end loop;
  perform public._checar_expediente();
  if public._param_min('sla_escalada_min', 480) < public._param_min('sla_lembrete_min', 240) then
    raise exception 'O aviso ao gestor não pode vir antes do 2º aviso ao responsável.';
  end if;
  if v_alt <> '{}'::jsonb then
    perform public._auditar(g.user_id, g.nome, 'PARAMETROS_ALTERADOS', null, jsonb_build_object('alteracoes', v_alt));
  end if;
  return jsonb_build_object('ok', true, 'alterados', (select count(*) from jsonb_object_keys(v_alt))::int);
end $$;

-- ---------------------------------------------------------------------
-- 5. PRIVILÉGIOS E VERSÃO
-- ---------------------------------------------------------------------
insert into public.schema_versao (versao, arquivo) values (8, '08_fluxo.sql') on conflict (versao) do nothing;

revoke all on function public.reencaminhar_protocolo(bigint, bigint, text, text), public.devolver_protocolo(bigint, text, text),
  public._sou_responsavel(text, boolean, text, boolean), public._tramite_bloqueia_devolvido() from public, anon;
grant execute on function public.reencaminhar_protocolo(bigint, bigint, text, text), public.devolver_protocolo(bigint, text, text)
  to authenticated;
grant execute on function public._sou_responsavel(text, boolean, text, boolean) to authenticated;
revoke all on function public.listar_livro(text, text, date, date, int, int, text, text), public.minhas_pendencias(),
  public.resumo_livro(), public.detalhe_protocolo(bigint), public.exportar_backup(), public.excluir_protocolo(bigint, text, text, boolean),
  public.painel_salvar_parametros(jsonb) from public, anon;
grant execute on function public.listar_livro(text, text, date, date, int, int, text, text), public.minhas_pendencias(),
  public.resumo_livro(), public.detalhe_protocolo(bigint), public.exportar_backup(), public.excluir_protocolo(bigint, text, text, boolean),
  public.painel_salvar_parametros(jsonb) to authenticated;
