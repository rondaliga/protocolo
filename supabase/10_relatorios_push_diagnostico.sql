-- =====================================================================
-- MIGRAÇÃO 10 — Relatórios gerenciais, verificação da instalação e avisos no aparelho (Web Push)
-- Rode DEPOIS da 09 (ou use instalacao_completa.sql). Pode ser executada mais de uma vez.
--  1. painel_relatorio(inicio, fim)  — números do período (somente gestor; sem descrição de documentos)
--  2. painel_diagnostico()           — conferência da instalação (somente gestor)
--  3. Web Push gratuito              — inscrições dos aparelhos + envio por Edge Function do Supabase
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. RELATÓRIO GERENCIAL
-- ---------------------------------------------------------------------
create or replace function public.painel_relatorio(p_inicio date default null, p_fim date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  g public.perfis%rowtype := public._exigir_gestor();
  v_fuso text := public._fuso();
  v_hoje date := (now() at time zone public._fuso())::date;
  v_ini date := coalesce(p_inicio, (now() at time zone public._fuso())::date - 29);
  v_fim date := coalesce(p_fim, (now() at time zone public._fuso())::date);
  v_tot jsonb; v_tempo jsonb; v_setor jsonb; v_dia jsonb; v_atr jsonb; v_mov jsonb;
begin
  if v_fim < v_ini then raise exception 'A data final não pode ser anterior à data inicial.'; end if;
  if v_fim - v_ini > 366 then raise exception 'Escolha um período de até 12 meses.'; end if;

  create temporary table if not exists _rel_base (
    id bigint, numero text, tipo text, urgente boolean, status text, prazo date, devolvido boolean,
    dia date, t1 timestamptz, t2 timestamptz, t3 timestamptz, setor text) on commit drop;
  delete from _rel_base;
  insert into _rel_base
  select p.id, p.numero, p.tipo, p.urgente, p.status, p.prazo_data, coalesce(p.devolvido, false),
         (p.created_at at time zone v_fuso)::date, t1.recebido_em, t2.recebido_em, t3.recebido_em,
         coalesce(t3.setor_nome, s.nome, 'Sem setor definido')
    from public.protocolos p
    left join public.tramites t1 on t1.protocolo_id = p.id and t1.etapa = 1
    left join public.tramites t2 on t2.protocolo_id = p.id and t2.etapa = 2
    left join public.tramites t3 on t3.protocolo_id = p.id and t3.etapa = 3
    left join public.setores s on s.id = p.setor_destino_id
   where (p.created_at at time zone v_fuso)::date between v_ini and v_fim;

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

  select jsonb_build_object('reencaminhados', count(*) filter (where tipo = 'reencaminhado'),
                            'devolvidos', count(*) filter (where tipo = 'devolvido')) into v_mov
    from public.movimentacoes where (em at time zone v_fuso)::date between v_ini and v_fim;

  perform public._auditar(g.user_id, g.nome, 'RELATORIO_GERADO', null,
            jsonb_build_object('inicio', v_ini, 'fim', v_fim));
  return jsonb_build_object('periodo', jsonb_build_object('inicio', v_ini, 'fim', v_fim), 'totais', v_tot,
           'tempo_horas', v_tempo, 'por_setor', v_setor, 'por_dia', v_dia, 'atrasados', v_atr, 'movimentacoes', v_mov);
end $$;

-- ---------------------------------------------------------------------
-- 2. VERIFICAÇÃO DA INSTALAÇÃO
-- ---------------------------------------------------------------------
create or replace function public.painel_diagnostico() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  g public.perfis%rowtype := public._exigir_gestor();
  v_itens jsonb := '[]'::jsonb; v_aux text; v_n int; v_t text; v_sem text := '';
  v_arquivos int := 10;
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

-- ---------------------------------------------------------------------
-- 3. AVISOS NO APARELHO (WEB PUSH) — gratuito, via Edge Function do Supabase
-- ---------------------------------------------------------------------
create table if not exists public.push_config (
  id              int primary key default 1 check (id = 1),
  url             text not null check (url ~ '^https://'),
  segredo         text not null check (length(segredo) >= 24),
  vapid_publica   text not null check (length(vapid_publica) between 80 and 100),
  ativo           boolean not null default true,
  atualizado_em   timestamptz not null default now()
);
alter table public.push_config enable row level security;
revoke all on public.push_config from public, anon, authenticated;

create table if not exists public.push_inscricoes (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  endpoint    text not null unique check (endpoint ~ '^https://' and length(endpoint) <= 700),
  p256dh      text not null check (length(p256dh) between 60 and 120),
  auth        text not null check (length(auth) between 16 and 40),
  agente      text check (length(agente) <= 160),
  criado_em   timestamptz not null default now()
);
create index if not exists ix_push_user on public.push_inscricoes(user_id);
alter table public.push_inscricoes enable row level security;
revoke all on public.push_inscricoes from public, anon, authenticated;

create or replace function public.push_chave_publica() returns text
language sql stable security definer set search_path = public as $$
  select vapid_publica from public.push_config where ativo
$$;

create or replace function public.push_registrar(p_endpoint text, p_p256dh text, p_auth text, p_agente text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public._uid();
begin
  if v_uid is null or not exists (select 1 from public.perfis where user_id = v_uid and ativo) then raise exception 'Acesso negado.'; end if;
  if not exists (select 1 from public.push_config where ativo) then raise exception 'Os avisos no aparelho ainda não foram ativados pelo gestor.'; end if;
  if p_endpoint is null or p_endpoint !~ '^https://' or length(p_endpoint) > 700 then raise exception 'Aparelho inválido para receber avisos.'; end if;
  insert into public.push_inscricoes (user_id, endpoint, p256dh, auth, agente)
  values (v_uid, p_endpoint, p_p256dh, p_auth, left(p_agente, 160))
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
    agente = excluded.agente, criado_em = now();
  delete from public.push_inscricoes where user_id = v_uid and id not in
    (select id from public.push_inscricoes where user_id = v_uid order by criado_em desc, id desc limit 5);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.push_remover(p_endpoint text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public._uid();
begin
  if v_uid is null then raise exception 'Acesso negado.'; end if;
  delete from public.push_inscricoes where user_id = v_uid and endpoint = p_endpoint;
  return jsonb_build_object('ok', true);
end $$;

-- envia o aviso aos aparelhos dos usuários cujos e-mails estão na lista (nunca derruba a operação)
create or replace function public._enviar_push(p_emails text[], p_titulo text, p_corpo text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c public.push_config%rowtype; v_subs jsonb;
begin
  select * into c from public.push_config where id = 1 and ativo;
  if not found or p_emails is null then return; end if;
  select jsonb_agg(jsonb_build_object('endpoint', i.endpoint, 'keys', jsonb_build_object('p256dh', i.p256dh, 'auth', i.auth)))
    into v_subs
    from public.push_inscricoes i join public.perfis p on p.user_id = i.user_id
   where p.ativo and lower(p.email) = any (select lower(e) from unnest(p_emails) e);
  if v_subs is null then return; end if;
  execute 'select net.http_post(url := $1, body := $2, headers := $3)' using
    c.url,
    jsonb_build_object('subs', v_subs, 'payload', jsonb_build_object('title', left(p_titulo, 120), 'body', left(p_corpo, 200), 'url', './')),
    jsonb_build_object('x-push-secret', c.segredo, 'content-type', 'application/json');
exception when others then
  null;
end $$;

-- a mesma entrada da fila de e-mails dispara o e-mail imediato e o aviso no aparelho
create or replace function public._trg_fila_email_imediato() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public._enviar_imediato(new.id);
  perform public._enviar_push(new.destinatarios, regexp_replace(new.assunto, '^\[[^]]*\]\s*', ''), 'Toque para abrir o Livro de Protocolo.');
  return null;
end $$;

create or replace function public.admin_configurar_push(p_url text, p_segredo text, p_vapid_publica text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if p_url is null or p_url !~ '^https://[^ ]+$' then return 'ERRO: o endereço da função deve começar com https://'; end if;
  if coalesce(length(trim(p_segredo)), 0) < 24 then return 'ERRO: o segredo deve ter pelo menos 24 caracteres.'; end if;
  if coalesce(length(trim(p_vapid_publica)), 0) not between 80 and 100 then return 'ERRO: chave pública inválida (confira se copiou inteira).'; end if;
  insert into public.push_config (id, url, segredo, vapid_publica, ativo, atualizado_em)
  values (1, trim(p_url), trim(p_segredo), trim(p_vapid_publica), true, now())
  on conflict (id) do update set url = excluded.url, segredo = excluded.segredo, vapid_publica = excluded.vapid_publica,
    ativo = true, atualizado_em = now();
  return 'OK: avisos no aparelho configurados. Cada usuário ativa em Minha conta > Avisos neste aparelho.';
end $$;

create or replace function public.admin_desativar_push() returns text
language sql security definer set search_path = public as $$
  update public.push_config set ativo = false, atualizado_em = now();
  select 'OK: avisos no aparelho desativados.'::text
$$;

-- painel_resumo: acrescenta o estado dos avisos no aparelho
create or replace function public.painel_resumo() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public._exigir_gestor();
  perform public._conciliar_envios();
  return jsonb_build_object(
    'usuarios_ativos',   (select count(*) from public.perfis where ativo),
    'usuarios_inativos', (select count(*) from public.perfis where not ativo),
    'sem_email',         (select count(*) from public.perfis where ativo and email is null),
    'pin_bloqueado',     (select count(*) from public.perfis where pin_bloqueado_ate > now()),
    'email_pendente',    (select count(*) from public.fila_email where status in ('pendente', 'enviando')),
    'email_erro',        (select count(*) from public.fila_email where status = 'erro'),
    'email_enviado',     (select count(*) from public.fila_email where status = 'enviado'),
    'ultimo_erro_email', (select erro from public.fila_email where status = 'erro' order by id desc limit 1),
    'integracao_configurada', exists (select 1 from public.integracao),
    'brevo_configurado', exists (select 1 from public.email_brevo where ativo),
    'push_configurado',  exists (select 1 from public.push_config where ativo),
    'push_aparelhos',    (select count(*) from public.push_inscricoes));
end $$;

-- ---------------------------------------------------------------------
-- 4. PRIVILÉGIOS E VERSÃO
-- ---------------------------------------------------------------------
insert into public.schema_versao (versao, arquivo) values (10, '10_relatorios_push_diagnostico.sql') on conflict (versao) do nothing;

revoke all on function public.painel_relatorio(date, date), public.painel_diagnostico(), public.push_chave_publica(),
  public.push_registrar(text, text, text, text), public.push_remover(text), public._enviar_push(text[], text, text),
  public._trg_fila_email_imediato(), public.admin_configurar_push(text, text, text), public.admin_desativar_push(),
  public.painel_resumo() from public, anon, authenticated;
grant execute on function public.painel_relatorio(date, date), public.painel_diagnostico(), public.push_chave_publica(),
  public.push_registrar(text, text, text, text), public.push_remover(text), public.painel_resumo() to authenticated;
