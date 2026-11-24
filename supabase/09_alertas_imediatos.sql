-- =====================================================================
-- MIGRAÇÃO 09 — Alertas imediatos (sem prazo de espera) e e-mail imediato pelo Brevo
-- Rode DEPOIS da 08 (ou use instalacao_completa.sql). Pode ser executada mais de uma vez.
--
--  1. Fim do "tempo máximo de recebimento" (SLA): não existe mais espera para avisar.
--     O ADM é avisado no ato do registro; o setor, no ato do encaminhamento (no sistema e por e-mail).
--     Os parâmetros sla_* são removidos; a coluna sla_limite fica sempre vazia (compatibilidade).
--     Os avisos de PRAZO DO DOCUMENTO (próximo de vencer / vencido) continuam.
--  2. E-mail imediato: toda entrada na fila de e-mails é enviada na hora pela API do Brevo
--     (extensão pg_net do Supabase). Se o Brevo não estiver configurado ou falhar, a fila continua
--     sendo atendida pela rotina de SMTP do GitHub Actions (plano B).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. FIM DO TEMPO MÁXIMO (SLA)
-- ---------------------------------------------------------------------
create or replace function public._sem_sla() returns trigger
language plpgsql as $$
begin
  new.sla_limite := null;
  return new;
end $$;

drop trigger if exists trg_protocolos_sem_sla on public.protocolos;
create trigger trg_protocolos_sem_sla before insert or update on public.protocolos
  for each row execute function public._sem_sla();

-- limpa o que já existia (a própria trigger zera sla_limite; o update só dispara o gatilho)
update public.protocolos set sla_limite = null where sla_limite is not null;

delete from public.parametros where chave like 'sla\_%';

-- texto do e-mail: sem "limite para o seu recebimento"
create or replace function public._texto_email(
  p_numero text, p_tipo text, p_urgente boolean, p_prazo date, p_sla timestamptz, p_intro text) returns text
language sql stable security definer set search_path = public as $$
  select p_intro || E'\n\n'
      || 'Protocolo: ' || p_numero || E'\n'
      || 'Tipo: ' || case p_tipo when 'judicial' then 'Demanda judicial' else 'Correspondência' end
      || case when p_urgente then ' (URGENTE)' else '' end || E'\n'
      || 'Prazo: ' || coalesce(to_char(p_prazo, 'DD/MM/YYYY'), 'sem prazo informado') || E'\n'
      || E'\nAcesse o sistema para confirmar o recebimento'
      || case when public._param_text('url_sistema', '') <> '' then ': ' || public._param_text('url_sistema', '') else '.' end
      || E'\n\nAviso automático do Livro de Protocolo. Por segurança, este e-mail não traz a descrição do documento.'
$$;

-- verificação periódica: só o PRAZO do documento (o aviso de chegada/encaminhamento já sai na hora)
create or replace function public._verificar_sla() returns int
language plpgsql security definer set search_path = public as $$
declare
  r public.protocolos%rowtype; v_hoje date := (now() at time zone public._fuso())::date;
  v_aviso int := public._param_int('alerta_prazo_dias', 2); v_n int := 0;
  v_atual text[]; v_gest text[]; v_dest text[]; v_dias int; v_etapa int;
begin
  perform public._conciliar_envios();
  v_gest := public._emails(array['gestor']);
  for r in select * from public.protocolos where status <> 'concluido' and prazo_data is not null order by id loop
    v_etapa := case when r.status = 'pendente_adm' or r.devolvido then 2 else 3 end;
    v_atual := case when v_etapa = 2 then public._emails(array['adm'])
                    else public._emails(array['super_setor'], r.setor_destino_id) end;
    v_dest  := (select coalesce(array_agg(distinct e), '{}') from unnest(v_atual || v_gest) e);
    v_dias  := r.prazo_data - v_hoje;
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
  end loop;
  return v_n;
end $$;

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
  if v_alt <> '{}'::jsonb then
    perform public._auditar(g.user_id, g.nome, 'PARAMETROS_ALTERADOS', null, jsonb_build_object('alteracoes', v_alt));
  end if;
  return jsonb_build_object('ok', true, 'alterados', (select count(*) from jsonb_object_keys(v_alt))::int);
end $$;

-- ---------------------------------------------------------------------
-- 2. E-MAIL IMEDIATO PELO BREVO (API) — chave guardada só no banco, nunca no navegador
-- ---------------------------------------------------------------------
do $$ begin
  create extension if not exists pg_net with schema extensions;
exception when others then
  raise notice 'pg_net não pôde ser ativada automaticamente (%). No Supabase: Database > Extensions > pg_net.', sqlerrm;
end $$;

create table if not exists public.email_brevo (
  id               int primary key default 1 check (id = 1),
  api_key          text not null,
  remetente_email  text not null,
  remetente_nome   text not null default 'Livro de Protocolo',
  ativo            boolean not null default true,
  atualizado_em    timestamptz not null default now()
);
alter table public.email_brevo enable row level security;          -- sem policies: o navegador nunca lê
revoke all on public.email_brevo from public, anon, authenticated;

alter table public.fila_email add column if not exists net_id bigint;
alter table public.fila_email add column if not exists canal text;
alter table public.fila_email add column if not exists enviando_desde timestamptz;
alter table public.fila_email drop constraint if exists fila_email_status_check;
alter table public.fila_email add constraint fila_email_status_check
  check (status in ('pendente', 'enviando', 'enviado', 'erro'));

-- envia um item da fila agora (a chamada HTTP só sai depois que a transação é confirmada)
create or replace function public._enviar_imediato(p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c public.email_brevo%rowtype; f public.fila_email%rowtype; v_net bigint;
begin
  select * into c from public.email_brevo where id = 1 and ativo;
  if not found then return; end if;
  select * into f from public.fila_email where id = p_id;
  if not found or f.status <> 'pendente' then return; end if;
  execute 'select net.http_post(url := $1, body := $2, headers := $3)' into v_net
    using 'https://api.brevo.com/v3/smtp/email',
          jsonb_build_object(
            'sender',      jsonb_build_object('name', c.remetente_nome, 'email', c.remetente_email),
            'to',          jsonb_build_array(jsonb_build_object('email', c.remetente_email)),
            'bcc',         (select jsonb_agg(jsonb_build_object('email', e)) from unnest(f.destinatarios) e),
            'subject',     f.assunto,
            'textContent', f.corpo),
          jsonb_build_object('api-key', c.api_key, 'content-type', 'application/json', 'accept', 'application/json');
  update public.fila_email set status = 'enviando', net_id = v_net, canal = 'brevo', enviando_desde = now() where id = p_id;
exception when others then
  -- nunca derruba o registro do protocolo: o item continua "pendente" e o plano B (SMTP) o envia
  update public.fila_email set erro = left('Envio imediato: ' || sqlerrm, 300) where id = p_id;
end $$;

create or replace function public._trg_fila_email_imediato() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public._enviar_imediato(new.id);
  return null;
end $$;

drop trigger if exists trg_fila_email_imediato on public.fila_email;
create trigger trg_fila_email_imediato after insert on public.fila_email
  for each row execute function public._trg_fila_email_imediato();

-- confere as respostas do Brevo: 2xx = enviado; erro = "erro" (o SMTP tenta de novo); sem resposta em 10 min = volta à fila
create or replace function public._conciliar_envios() returns int
language plpgsql security definer set search_path = public as $$
declare r record; v_resp record; v_n int := 0;
begin
  if to_regclass('net._http_response') is null then return 0; end if;
  for r in select id, net_id, enviando_desde from public.fila_email where status = 'enviando' loop
    execute 'select status_code, left(coalesce(error_msg, content, ''''), 200) as txt from net._http_response where id = $1'
      into v_resp using r.net_id;
    if v_resp.status_code is not null and v_resp.status_code between 200 and 299 then
      update public.fila_email set status = 'enviado', enviado_em = now(), erro = null, tentativas = tentativas + 1 where id = r.id;
      v_n := v_n + 1;
    elsif v_resp.status_code is not null or exists (select 1 from net._http_response where id = r.net_id) then
      update public.fila_email set status = 'erro', tentativas = tentativas + 1,
             erro = left('Brevo ' || coalesce(v_resp.status_code::text, '?') || ': ' || coalesce(v_resp.txt, ''), 300) where id = r.id;
    elsif r.enviando_desde < now() - interval '10 minutes' then
      update public.fila_email set status = 'pendente', erro = 'Sem resposta do Brevo; reenviando pela rotina de SMTP.' where id = r.id;
    end if;
  end loop;
  return v_n;
end $$;

-- a fila do SMTP (GitHub Actions) também confere as respostas antes de listar
create or replace function public.integracao_fila(p_segredo text, p_limite int default 20) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public._segredo_ok(p_segredo);
  perform public._conciliar_envios();
  return coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'destinatarios', f.destinatarios,
                          'assunto', f.assunto, 'corpo', f.corpo) order by f.id)
                     from (select * from public.fila_email
                            where status in ('pendente', 'erro') and tentativas < 5
                            order by id limit least(greatest(coalesce(p_limite, 20), 1), 50)) f), '[]'::jsonb);
end $$;

-- Configuração do Brevo (rodar no SQL Editor do Supabase; não fica acessível ao navegador)
create or replace function public.admin_configurar_brevo(p_api_key text, p_remetente_email text, p_remetente_nome text default 'Livro de Protocolo')
returns text language plpgsql security definer set search_path = public as $$
begin
  if coalesce(length(trim(p_api_key)), 0) < 20 then return 'ERRO: a chave de API do Brevo parece incompleta.'; end if;
  if p_remetente_email is null or p_remetente_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return 'ERRO: e-mail do remetente inválido.'; end if;
  insert into public.email_brevo (id, api_key, remetente_email, remetente_nome, ativo, atualizado_em)
  values (1, trim(p_api_key), lower(trim(p_remetente_email)), left(coalesce(nullif(trim(p_remetente_nome), ''), 'Livro de Protocolo'), 80), true, now())
  on conflict (id) do update set api_key = excluded.api_key, remetente_email = excluded.remetente_email,
    remetente_nome = excluded.remetente_nome, ativo = true, atualizado_em = now();
  return 'OK: Brevo configurado. Remetente: ' || lower(trim(p_remetente_email)) || '. Use o botão "Enviar e-mail de teste" no Painel > Sistema.';
end $$;

create or replace function public.admin_desativar_brevo() returns text
language sql security definer set search_path = public as $$
  update public.email_brevo set ativo = false, atualizado_em = now();
  select 'OK: envio imediato desativado (a rotina de SMTP continua valendo, se configurada).'::text
$$;

-- Botão do gestor: e-mail de teste para o próprio endereço (sai na hora, como os demais)
create or replace function public.painel_email_teste() returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.perfis%rowtype := public._exigir_gestor(); v_id bigint; v_ok boolean;
begin
  if g.email is null then raise exception 'Seu usuário não tem e-mail cadastrado.'; end if;
  perform public._conciliar_envios();
  insert into public.fila_email (chave, evento, destinatarios, assunto, corpo)
  values ('teste:' || g.user_id || ':' || extract(epoch from clock_timestamp())::bigint, 'TESTE', array[lower(g.email)],
          '[Protocolo] E-mail de teste',
          'Este é um e-mail de teste do Livro de Protocolo. Se você o recebeu, o envio de avisos está funcionando.' ||
          E'\n\nAviso automático do Livro de Protocolo.')
  returning id into v_id;
  perform public._auditar(g.user_id, g.nome, 'EMAIL_TESTE', null, jsonb_build_object('destino', lower(g.email)));
  select (status = 'enviando') into v_ok from public.fila_email where id = v_id;
  return jsonb_build_object('ok', true, 'imediato', coalesce(v_ok, false), 'destino', lower(g.email));
end $$;

-- Saúde do sistema: inclui o estado do envio imediato
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
    'brevo_configurado', exists (select 1 from public.email_brevo where ativo));
end $$;

-- ---------------------------------------------------------------------
-- 3. PRIVILÉGIOS E VERSÃO
-- ---------------------------------------------------------------------
insert into public.schema_versao (versao, arquivo) values (9, '09_alertas_imediatos.sql') on conflict (versao) do nothing;

revoke all on function public._sem_sla(), public._enviar_imediato(bigint), public._trg_fila_email_imediato(),
  public._conciliar_envios(), public.admin_configurar_brevo(text, text, text), public.admin_desativar_brevo(),
  public.painel_email_teste(), public.painel_resumo(), public.integracao_fila(text, int) from public, anon, authenticated;
grant execute on function public.painel_email_teste(), public.painel_resumo() to authenticated;
grant execute on function public.integracao_fila(text, int) to anon, authenticated;
