-- =====================================================================
-- MIGRAÇÃO 13 — Contas técnicas de teste e separação do histórico operacional
-- Rode DEPOIS da 12 (ou use instalacao_completa.sql). Pode ser executada mais de uma vez.
--
-- Objetivo: permitir validações técnicas no ambiente real sem misturar os protocolos de teste
-- com o histórico operacional, SEM jamais ocultar nada da trilha de auditoria (ela continua
-- mostrando a todos os gestores tudo o que acontece, inclusive os atos de teste — apenas com
-- uma etiqueta "TESTE" a mais). O que muda é só o que entra no Livro de protocolos e nos
-- relatórios/indicadores: por padrão eles mostram somente produção; um gestor específico
-- (definido abaixo) pode alternar para ver também os registros de teste.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Conta técnica (qualquer gestor pode marcar; fica registrado na auditoria)
-- ---------------------------------------------------------------------
alter table public.perfis add column if not exists conta_teste boolean not null default false;

-- ---------------------------------------------------------------------
-- 2. Ambiente do protocolo: 'producao' (padrão) ou 'teste'
--    Herdado automaticamente de quem registra (perfis.conta_teste), nunca escolhido à mão.
-- ---------------------------------------------------------------------
alter table public.protocolos add column if not exists ambiente text not null default 'producao'
  check (ambiente in ('producao', 'teste'));
create index if not exists ix_protocolos_ambiente on public.protocolos(ambiente);

-- ---------------------------------------------------------------------
-- 3. Quem pode ver os registros de teste nos relatórios e no Livro.
--    Autorização fixa no código (não fica em "parametros", que qualquer gestor edita pela tela
--    de Sistema) — exatamente para que nenhum gestor consiga se autoconceder essa visão.
-- ---------------------------------------------------------------------
create or replace function public._pode_ver_teste(p_perfil public.perfis) returns boolean
language sql immutable as $$
  select p_perfil.papel = 'gestor' and lower(coalesce(p_perfil.email, '')) = 'rauancosta50@hotmail.com'
$$;

-- Lê perfis.email/conta_teste (colunas que o cliente não enxerga diretamente) com privilégio do dono da
-- função, não de quem chama — necessário porque v_livro é "security invoker" e não pode exigir que cada
-- usuário autenticado tenha select nessas colunas (isso exporia e-mails de outras pessoas).
create or replace function public._visibilidade_teste() returns text
language sql stable security definer set search_path = public as $$
  select case
           when exists (select 1 from public.perfis g where g.user_id = public._uid() and g.ativo and g.conta_teste) then 'teste'
           when exists (select 1 from public.perfis g where g.user_id = public._uid() and g.ativo and public._pode_ver_teste(g)) then 'todos'
           else 'producao'
         end
$$;

create or replace function public._meu_pode_ver_teste() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis g where g.user_id = public._uid() and g.ativo and public._pode_ver_teste(g))
$$;

-- ---------------------------------------------------------------------
-- 4. registrar_protocolo: grava o ambiente de acordo com quem está registrando
-- ---------------------------------------------------------------------
create or replace function public.registrar_protocolo(
  p_descricao text, p_pin text, p_assinatura text default null,
  p_tipo text default 'correspondencia', p_urgente boolean default false, p_foto_caminho text default null,
  p_assinatura_modo text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_desc text; v_png text; v_msg text; v_modo text;
  v_agora timestamptz := now(); v_ano int; v_n int; v_num text; v_id bigint;
  v_tipo text := coalesce(p_tipo, 'correspondencia'); v_urg boolean; v_ambiente text;
  v_foto text := nullif(btrim(coalesce(p_foto_caminho, '')), ''); v_tam int;
  v_dias int; v_prazo date; v_sla timestamptz;
begin
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  if not found or v_perfil.papel not in ('portaria', 'gestor') then
    raise exception 'Seu perfil não tem permissão para registrar protocolos.' using errcode = '42501';
  end if;
  if v_tipo not in ('judicial', 'correspondencia') then raise exception 'Tipo de documento inválido.'; end if;
  v_urg := (v_tipo = 'judicial');          -- toda demanda judicial é urgente; o parâmetro p_urgente é ignorado
  v_ambiente := case when v_perfil.conta_teste then 'teste' else 'producao' end;
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

  insert into public.protocolos (numero, descricao, status, created_at, created_by, tipo, urgente, prazo_data, sla_limite, ambiente)
  values (v_num, v_desc, 'pendente_adm', v_agora, v_uid, v_tipo, v_urg, v_prazo, v_sla, v_ambiente) returning id into v_id;
  perform public._inserir_tramite(v_id, v_num, 1, v_uid, v_perfil.nome, null, null, v_png, v_agora, p_assinatura_modo);
  if v_foto is not null then
    insert into public.protocolo_fotos (protocolo_id, caminho, tamanho, enviado_por, enviado_em)
    values (v_id, v_foto, v_tam, v_uid, v_agora);
  end if;
  perform public._auditar(v_uid, v_perfil.nome, 'PROTOCOLO_CRIADO', v_id,
            jsonb_build_object('numero', v_num, 'descricao', v_desc, 'tipo', v_tipo, 'urgente', v_urg,
                               'prazo', v_prazo, 'foto', v_foto is not null, 'assinatura', v_modo,
                               'ambiente', v_ambiente));
  -- protocolo de teste não dispara e-mail real para o ADM: evita avisar a equipe de um registro fictício
  if v_ambiente = 'producao' then
    perform public._enfileirar_email('chegada:' || v_id, 'CHEGADA', v_id, public._emails(array['adm']),
              '[Protocolo' || case when v_urg then ' URGENTE' else '' end || '] ' || v_num || ' aguardando o ADM',
              public._texto_email(v_num, v_tipo, v_urg, v_prazo, v_sla, 'Chegou uma nova demanda na Portaria e aguarda o recebimento do ADM.'));
  end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'numero', v_num, 'ambiente', v_ambiente);
end $$;

-- ---------------------------------------------------------------------
-- 5. Livro de protocolos (v_livro / listar_livro / resumo_livro).
--    Regra de visibilidade dos registros de TESTE (nunca afeta a trilha de auditoria):
--      - conta técnica de teste (perfis.conta_teste): só enxerga os próprios protocolos de teste,
--        isolados dos de produção, para validar o fluxo completo sem tocar em dados reais;
--      - demais contas (inclusive os outros gestores): nunca veem registros de teste;
--      - o gestor autorizado (_pode_ver_teste): por padrão só produção; um filtro explícito
--        ("Incluir registros de teste", aplicado em listar_livro/resumo_livro) mostra os dois.
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
       (select count(*) from public.movimentacoes m where m.protocolo_id = p.id)::int as n_movimentacoes,
       p.ambiente
  from public.protocolos p
  left join public.tramites t1 on t1.protocolo_id = p.id and t1.etapa = 1
  left join public.tramites t2 on t2.protocolo_id = p.id and t2.etapa = 2
  left join public.tramites t3 on t3.protocolo_id = p.id and t3.etapa = 3
  left join public.setores sd on sd.id = p.setor_destino_id
 where case public._visibilidade_teste()
         -- conta técnica de teste: só enxerga (e só mexe n)os próprios protocolos de teste,
         -- isolados dos de produção — nunca mistura com o trabalho real da equipe.
         when 'teste' then p.ambiente = 'teste'
         -- gestor autorizado a ver teste: enxerga os dois aqui; o padrão "só produção" é aplicado
         -- em listar_livro/resumo_livro/minhas_pendencias (telas de uso diário), nunca escondido de verdade.
         when 'todos' then true
         else p.ambiente = 'producao'
       end;
grant select on public.v_livro to authenticated;

drop function if exists public.listar_livro(text, text, date, date, int, int);
drop function if exists public.listar_livro(text, text, date, date, int, int, text, text);
create or replace function public.listar_livro(
  p_q text default null, p_status text default null,
  p_data_ini date default null, p_data_fim date default null,
  p_limite int default 25, p_offset int default 0,
  p_alerta text default null, p_ordem text default 'recentes', p_incluir_teste boolean default false)
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare v_like text; v_total bigint; v_itens jsonb; v_hoje date := (now() at time zone public._fuso())::date;
  v_so_producao boolean;
begin
  p_limite := least(greatest(coalesce(p_limite, 25), 1), 500);
  p_offset := greatest(coalesce(p_offset, 0), 0);
  v_like := case when nullif(btrim(p_q), '') is null then null
                 else '%' || replace(replace(replace(left(btrim(p_q), 100), '\', '\\'), '%', '\%'), '_', '\_') || '%' end;
  -- só restringe a produção quando quem pediu PODE ver teste e optou por não incluir (demais perfis já
  -- vêm filtrados pela própria v_livro, então aqui não há nada a restringir)
  v_so_producao := public._visibilidade_teste() = 'todos' and not coalesce(p_incluir_teste, false);

  with f as (
    select v.* from public.v_livro v
     where (v_like is null or v.numero ilike v_like or v.descricao ilike v_like)
       and (p_status is null or v.status = p_status)
       and (p_data_ini is null or (v.created_at at time zone public._fuso())::date >= p_data_ini)
       and (p_data_fim is null or (v.created_at at time zone public._fuso())::date <= p_data_fim)
       and (not v_so_producao or v.ambiente = 'producao')
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
  return jsonb_build_object('total', v_total, 'itens', v_itens, 'pode_ver_teste', public._meu_pode_ver_teste());
end $$;

drop function if exists public.resumo_livro();
create or replace function public.resumo_livro(p_incluir_teste boolean default false) returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare v_so_producao boolean := public._visibilidade_teste() = 'todos' and not coalesce(p_incluir_teste, false);
begin
  return (
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
      'alerta_dias',    public._alerta_dias(),
      'pode_ver_teste', public._meu_pode_ver_teste())
    from public.v_livro v where not v_so_producao or v.ambiente = 'producao'
  );
end $$;

-- "meus pendentes" / sino de pendências: o gestor autorizado a ver teste também fica, aqui, restrito
-- a produção por padrão (é uma notificação de trabalho real, não uma tela com filtro de teste).
create or replace function public.minhas_pendencias() returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare v_papel text := public.meu_papel(); v_itens jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_itens from (
    select v.id, v.numero, v.tipo, v.urgente, v.status, v.prazo_data, v.dias_restantes, v.semaforo,
           v.aguardando_desde, v.sla_limite, v.sla_estourado, v.setor_destino_nome, v.devolvido
      from public.v_livro v
     where v.status <> 'concluido'
       and (v.ambiente = 'producao' or public._visibilidade_teste() = 'teste')
       and ((v_papel = 'adm' and (v.status = 'pendente_adm' or v.devolvido))
         or (v_papel = 'super_setor' and v.status = 'pendente_setor' and not v.devolvido)
         or (v_papel = 'gestor' and (v.semaforo in ('vencido', 'critico') or v.sla_estourado)))
     order by v.sla_estourado desc, (v.semaforo = 'vencido') desc, v.urgente desc, v.dias_restantes nulls last, v.id
  ) x;
  return jsonb_build_object('papel', v_papel, 'total', jsonb_array_length(v_itens), 'itens', v_itens,
    'urgentes', (select count(*) from jsonb_array_elements(v_itens) e
                  where (e ->> 'sla_estourado')::boolean or e ->> 'semaforo' = 'vencido'));
end $$;

-- ---------------------------------------------------------------------
-- 6. Relatório gerencial (painel_relatorio): por padrão só produção.
--    p_incluir_teste só tem efeito para quem _pode_ver_teste; senão é ignorado (sempre produção).
-- ---------------------------------------------------------------------
drop function if exists public.painel_relatorio(date, date);
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
  v_tot jsonb; v_tempo jsonb; v_setor jsonb; v_dia jsonb; v_atr jsonb; v_mov jsonb;
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

  select coalesce(jsonb_agg(jsonb_build_object('dia', d::date, 'n', coalesce(c.n, 0)) order by d), '[]'::jsonb) into v_dia
    from generate_series(v_ini, v_fim, interval '1 day') d
    left join (select dia, count(*)::int n from _rel_base group by dia) c on c.dia = d::date;

  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_atr from (
    select jsonb_build_object('numero', numero, 'setor', case when status = 'pendente_adm' then 'ADM' else setor end,
             'dias_atraso', v_hoje - prazo, 'urgente', urgente, 'tipo', tipo) as x
      from _rel_base where status <> 'concluido' and prazo < v_hoje order by prazo, numero limit 10) q;

  select jsonb_build_object('reencaminhados', count(*) filter (where m.tipo = 'reencaminhado'),
                            'devolvidos', count(*) filter (where m.tipo = 'devolvido')) into v_mov
    from public.movimentacoes m join public.protocolos p on p.id = m.protocolo_id
   where (m.em at time zone v_fuso)::date between v_ini and v_fim
     and (v_incl_teste or p.ambiente = 'producao');

  perform public._auditar(g.user_id, g.nome, 'RELATORIO_GERADO', null,
            jsonb_build_object('inicio', v_ini, 'fim', v_fim, 'incluiu_teste', v_incl_teste));
  return jsonb_build_object('periodo', jsonb_build_object('inicio', v_ini, 'fim', v_fim), 'totais', v_tot,
           'tempo_horas', v_tempo, 'por_setor', v_setor, 'por_dia', v_dia, 'atrasados', v_atr, 'movimentacoes', v_mov,
           'pode_ver_teste', public._pode_ver_teste(g), 'incluiu_teste', v_incl_teste);
end $$;

-- ---------------------------------------------------------------------
-- 7. Marcar/desmarcar uma conta como técnica de teste.
--    Restrito ao gestor autorizado (_pode_ver_teste): é ele quem decide quais contas geram
--    registros de teste, já que só ele enxerga o filtro correspondente nos relatórios/Livro.
--    Isso NUNCA esconde o usuário nem suas ações — só classifica os protocolos que ele registra,
--    e a mudança em si fica registrada na trilha de auditoria normalmente.
-- ---------------------------------------------------------------------
create or replace function public.painel_definir_conta_teste(p_user_id uuid, p_teste boolean, p_pin_gestor text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare g public.perfis%rowtype := public._exigir_gestor(); a public.perfis%rowtype; v_msg text;
begin
  if not public._pode_ver_teste(g) then
    raise exception 'Apenas o gestor responsável pelos testes técnicos pode fazer isso.' using errcode = '42501';
  end if;
  select * into a from public.perfis where user_id = p_user_id;
  if not found then raise exception 'Usuário não encontrado.'; end if;
  v_msg := public._checar_pin(g.user_id, p_pin_gestor);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;
  update public.perfis set conta_teste = coalesce(p_teste, false) where user_id = p_user_id;
  perform public._auditar(g.user_id, g.nome, case when p_teste then 'CONTA_MARCADA_TESTE' else 'CONTA_DESMARCADA_TESTE' end,
            null, jsonb_build_object('email', a.email, 'nome', a.nome));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 8. painel_listar_usuarios: acrescenta conta_teste (a tela só mostra o botão de marcar/desmarcar
--    para o gestor autorizado, mas o dado em si não é sigiloso).
-- ---------------------------------------------------------------------
create or replace function public.painel_listar_usuarios() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._exigir_gestor();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'user_id', p.user_id, 'email', coalesce(p.email, u.email), 'nome', p.nome, 'papel', p.papel,
      'setor_id', p.setor_id, 'setor_nome', s.nome, 'ativo', p.ativo,
      'pin_bloqueado', (p.pin_bloqueado_ate is not null and p.pin_bloqueado_ate > now()),
      'sem_pin', p.pin_hash is null, 'conta_teste', p.conta_teste,
      'deve_trocar_senha', p.deve_trocar_senha, 'deve_trocar_pin', p.deve_trocar_pin,
      'ultimo_acesso', u.last_sign_in_at, 'criado_em', p.created_at) order by p.ativo desc, p.nome)
    from public.perfis p
    join auth.users u on u.id = p.user_id
    left join public.setores s on s.id = p.setor_id), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- 9. Diagnóstico (painel_diagnostico): só atualiza a contagem de arquivos (12 → 13).
-- ---------------------------------------------------------------------
create or replace function public.painel_diagnostico() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  g public.perfis%rowtype := public._exigir_gestor();
  v_itens jsonb := '[]'::jsonb; v_aux text; v_n int; v_t text; v_sem text := '';
  v_arquivos int := 13;
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
  foreach v_t in array array['protocolos', 'tramites', 'perfis', 'auditoria', 'parametros', 'fila_email', 'email_brevo', 'push_inscricoes', 'push_config', 'integracao'] loop
    if to_regclass('public.' || v_t) is not null then
      if has_table_privilege('anon', 'public.' || v_t, 'select') or has_table_privilege('anon', 'public.' || v_t, 'insert') then
        v_aux := coalesce(v_aux || ', ', '') || v_t || ' (visitante)';
      end if;
    end if;
  end loop;
  foreach v_t in array array['email_brevo', 'push_inscricoes', 'push_config', 'integracao', 'fila_email'] loop
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

insert into public.schema_versao (versao, arquivo) values (13, '13_ambiente_teste.sql') on conflict (versao) do nothing;

revoke all on function public._pode_ver_teste(public.perfis), public._visibilidade_teste(), public._meu_pode_ver_teste(),
  public.painel_definir_conta_teste(uuid, boolean, text),
  public.listar_livro(text, text, date, date, int, int, text, text, boolean), public.resumo_livro(boolean),
  public.registrar_protocolo(text, text, text, text, boolean, text, text), public.painel_relatorio(date, date, boolean)
  from public, anon, authenticated;
grant execute on function public._visibilidade_teste(), public._meu_pode_ver_teste(),
  public.painel_definir_conta_teste(uuid, boolean, text),
  public.listar_livro(text, text, date, date, int, int, text, text, boolean), public.resumo_livro(boolean),
  public.registrar_protocolo(text, text, text, text, boolean, text, text), public.painel_relatorio(date, date, boolean)
  to authenticated;
grant select on public.v_livro to authenticated;
