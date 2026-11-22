-- =====================================================================
-- 04 — Logo do sistema, formatos de hora, salvar parâmetros de uma vez e exclusões (gestor)
-- Rode DEPOIS de schema.sql, 02_prazos_alertas.sql e 03_painel_gestor.sql. Pode rodar de novo sem problema.
-- (Se rodar o 02 ou o 03 de novo depois deste, rode o 04 mais uma vez.)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. FORMATOS DE HORA E DE DURAÇÃO
--    Hora do dia  : 8 · 8h · 8h30 · 8:30 · 08:30           → guardada como HH:MM
--    Duração (SLA): 90min · 1h30 · 1:30 · 2h · 1,5 · 1d     → guardada como H:MM
--                   (número puro = horas; "d" = uma jornada de expediente)
-- ---------------------------------------------------------------------
create or replace function public._parse_hhmm(p text) returns time
language plpgsql immutable as $$
declare m text[]; h int; n int;
begin
  m := regexp_match(lower(btrim(coalesce(p, ''))), '^(\d{1,2})\s*(?:[:h]\s*(\d{2})?)?$');
  if m is null then return null; end if;
  h := m[1]::int; n := coalesce(m[2]::int, 0);
  if n > 59 or h > 24 or (h = 24 and n > 0) then return null; end if;
  if h = 24 then return time '23:59'; end if;
  return make_time(h, n, 0);
end $$;

create or replace function public._fmt_hhmm(p time) returns text
language sql immutable as $$ select to_char(p, 'HH24:MI') $$;

create or replace function public._fmt_duracao(p_min int) returns text
language sql immutable as $$ select (p_min / 60)::text || ':' || lpad((p_min % 60)::text, 2, '0') $$;

create or replace function public._param_hhmm(p_chave text, p_padrao text) returns time
language sql stable security definer set search_path = public as $$
  select coalesce(public._parse_hhmm((select valor from public.parametros where chave = p_chave)),
                  public._parse_hhmm(p_padrao))
$$;

-- minutos de expediente por dia (base para "1d")
create or replace function public._minutos_expediente() returns int
language sql stable security definer set search_path = public as $$
  select greatest(1, (extract(epoch from (public._param_hhmm('expediente_fim', '17:00')
                                          - public._param_hhmm('expediente_inicio', '08:00'))) / 60)::int)
$$;

create or replace function public._parse_duracao_min(p text) returns int
language plpgsql stable security definer set search_path = public as $$
declare v text := lower(btrim(coalesce(p, ''))); m text[];
begin
  v := replace(v, ',', '.');
  m := regexp_match(v, '^(\d{1,3}):(\d{2})$');
  if m is not null then
    if m[2]::int > 59 then return null; end if;
    return m[1]::int * 60 + m[2]::int;
  end if;
  m := regexp_match(v, '^(\d{1,3}(?:\.\d{1,2})?)$');                         -- número puro = horas
  if m is not null then return round(m[1]::numeric * 60)::int; end if;
  m := regexp_match(v, '^(\d{1,3})\s*(?:h|hr|hrs|hora|horas)(?:\s*(\d{1,2})\s*(?:m|min|minutos?)?)?$');
  if m is not null then
    if coalesce(m[2]::int, 0) > 59 then return null; end if;
    return m[1]::int * 60 + coalesce(m[2]::int, 0);
  end if;
  m := regexp_match(v, '^(\d{1,5})\s*(?:m|min|minuto|minutos)$');
  if m is not null then return m[1]::int; end if;
  m := regexp_match(v, '^(\d{1,2}(?:\.\d)?)\s*(?:d|dia|dias)$');
  if m is not null then return round(m[1]::numeric * public._minutos_expediente())::int; end if;
  return null;
end $$;

create or replace function public._param_min(p_chave text, p_padrao_min int) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(public._parse_duracao_min((select valor from public.parametros where chave = p_chave)), p_padrao_min)
$$;


-- Parâmetros novos (tempos máximos agora em minutos, escritos como H:MM) + migração dos antigos
insert into public.parametros (chave, valor, descricao) values
  ('sla_adm_min',             '4:00', 'Tempo máximo (horas úteis) para o ADM receber.'),
  ('sla_adm_urgente_min',     '2:00', 'Tempo máximo do ADM para demandas urgentes.'),
  ('sla_setor_min',           '9:00', 'Tempo máximo para o setor de destino receber (9h = 1 dia útil).'),
  ('sla_setor_urgente_min',   '4:00', 'Tempo máximo do setor para demandas urgentes.')
on conflict (chave) do nothing;

do $$
declare r record;
begin
  for r in select chave, valor from public.parametros where chave in
           ('sla_adm_horas', 'sla_adm_urgente_horas', 'sla_setor_horas', 'sla_setor_urgente_horas') loop
    if r.valor ~ '^\d{1,3}$' then
      update public.parametros set valor = public._fmt_duracao(r.valor::int * 60)
       where chave = replace(r.chave, '_horas', '_min');
    end if;
    delete from public.parametros where chave = r.chave;
  end loop;
  update public.parametros set valor = public._fmt_hhmm(public._param_hhmm(chave, case chave
           when 'expediente_inicio' then '08:00' else '17:00' end))
   where chave in ('expediente_inicio', 'expediente_fim');
  update public.parametros set descricao = 'Hora em que o expediente começa (formato HH:MM). Conta para as horas úteis.'
   where chave = 'expediente_inicio';
  update public.parametros set descricao = 'Hora em que o expediente termina (formato HH:MM).'
   where chave = 'expediente_fim';
end $$;

-- ---------------------------------------------------------------------
-- 2. VALIDAÇÃO / SALVAR PARÂMETROS
-- ---------------------------------------------------------------------
create or replace function public._validar_parametro(p_chave text, p_valor text) returns text
language plpgsql stable security definer set search_path = public as $$
declare v text := btrim(coalesce(p_valor, '')); n int; t time; m int;
begin
  if not exists (select 1 from public.parametros where chave = p_chave) then
    raise exception 'Parâmetro desconhecido: %.', p_chave;
  end if;
  if p_chave = 'url_sistema' then
    if v <> '' and v !~ '^https://[^\s]+$' then raise exception 'O endereço do sistema deve começar com https://'; end if;
  elsif p_chave in ('foto_obrigatoria_judicial', 'gestor_ignora_segregacao') then
    if v not in ('true', 'false') then raise exception 'Use true ou false.'; end if;
  elsif p_chave in ('expediente_inicio', 'expediente_fim') then
    t := public._parse_hhmm(v);
    if t is null then raise exception 'Hora inválida. Use um formato como 08:00, 8h30 ou 17.'; end if;
    v := public._fmt_hhmm(t);
  elsif p_chave like 'sla\_%\_min' then
    m := public._parse_duracao_min(v);
    if m is null then raise exception 'Tempo inválido. Use um formato como 4:00, 4h30, 90min ou 1d.'; end if;
    if m < 5 then raise exception 'O tempo máximo deve ser de pelo menos 5 minutos.'; end if;
    if m > 14400 then raise exception 'O tempo máximo não pode passar de 240 horas.'; end if;
    v := public._fmt_duracao(m);
  else
    if v !~ '^\d{1,3}$' then raise exception 'Informe um número inteiro de 0 a 365.'; end if;
    n := v::int;
    if n > 365 then raise exception 'Valor máximo: 365 dias.'; end if;
    v := n::text;
  end if;
  return v;
end $$;

create or replace function public._tipo_parametro(p_chave text) returns text
language sql immutable as $$
  select case when p_chave = 'url_sistema' then 'texto'
              when p_chave in ('foto_obrigatoria_judicial', 'gestor_ignora_segregacao') then 'booleano'
              when p_chave in ('expediente_inicio', 'expediente_fim') then 'hora'
              when p_chave like 'sla\_%\_min' then 'duracao'
              else 'numero' end
$$;

-- o fim do expediente tem de ser depois do início (checado depois de gravar; a exceção desfaz tudo)
create or replace function public._checar_expediente() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if public._param_hhmm('expediente_fim', '17:00') <= public._param_hhmm('expediente_inicio', '08:00') then
    raise exception 'O fim do expediente deve ser depois do início.';
  end if;
end $$;

create or replace function public.admin_definir_parametro(p_chave text, p_valor text) returns text
language plpgsql security definer set search_path = public as $$
declare v text := public._validar_parametro(p_chave, p_valor);
begin
  update public.parametros set valor = v where chave = p_chave;
  perform public._checar_expediente();
  perform public._auditar(null, 'admin (SQL Editor)', 'PARAMETRO_ALTERADO', null, jsonb_build_object('chave', p_chave, 'valor', v));
  return p_chave || ' = ' || v;
end $$;

create or replace function public.painel_definir_parametro(p_chave text, p_valor text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.perfis%rowtype := public._exigir_gestor(); v text := public._validar_parametro(p_chave, p_valor); v_ant text;
begin
  select valor into v_ant from public.parametros where chave = p_chave;
  if v_ant = v then return jsonb_build_object('ok', true, 'alterado', false); end if;
  update public.parametros set valor = v where chave = p_chave;
  perform public._checar_expediente();
  perform public._auditar(g.user_id, g.nome, 'PARAMETRO_ALTERADO', null,
            jsonb_build_object('chave', p_chave, 'anterior', v_ant, 'valor', v));
  return jsonb_build_object('ok', true, 'alterado', true);
end $$;

-- Salva vários parâmetros de uma vez (tudo ou nada): é o botão único "Salvar alterações" da tela
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
-- 3. LOGO DO SISTEMA (uma imagem para o cabeçalho, o login e todas as impressões)
-- ---------------------------------------------------------------------
create table if not exists public.identidade (
  id            int primary key default 1 check (id = 1),
  logo          text check (logo is null or (length(logo) <= 400000
                  and logo ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$')),
  atualizado_em timestamptz not null default now()
);
insert into public.identidade (id) values (1) on conflict do nothing;
alter table public.identidade enable row level security;      -- sem policies: só pelas funções abaixo
revoke all on public.identidade from public, anon, authenticated;

create or replace function public.identidade_publica() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('logo', logo, 'atualizado_em', atualizado_em) from public.identidade where id = 1
$$;

create or replace function public.painel_definir_logo(p_logo text, p_pin_gestor text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare g public.perfis%rowtype := public._exigir_gestor(); v_msg text;
begin
  if p_logo is null or p_logo !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$'
     or p_logo !~ '^data:image/(png;base64,iVBORw0KGgo|jpeg;base64,/9j/|webp;base64,UklGR)' then
    raise exception 'Imagem inválida. Use PNG, JPEG ou WebP.';
  end if;
  if length(p_logo) > 400000 then raise exception 'Imagem muito grande (máximo de cerca de 290 KB).'; end if;
  v_msg := public._checar_pin(g.user_id, p_pin_gestor);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;
  update public.identidade set logo = p_logo, atualizado_em = now() where id = 1;
  perform public._auditar(g.user_id, g.nome, 'LOGO_ALTERADO', null, jsonb_build_object('acao', 'definida', 'tamanho_bytes', length(p_logo)));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.painel_remover_logo(p_pin_gestor text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare g public.perfis%rowtype := public._exigir_gestor(); v_msg text;
begin
  v_msg := public._checar_pin(g.user_id, p_pin_gestor);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;
  update public.identidade set logo = null, atualizado_em = now() where id = 1;
  perform public._auditar(g.user_id, g.nome, 'LOGO_ALTERADO', null, jsonb_build_object('acao', 'restaurada ao padrão'));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 4. EXCLUSÕES (somente gestor, com PIN e justificativa; tudo fica registrado)
--    As tabelas continuam imutáveis para qualquer outro caminho: só as funções abaixo ligam,
--    dentro da própria transação, uma autorização que o cliente não consegue acionar.
-- ---------------------------------------------------------------------
create or replace function public._bloquear_alteracao() returns trigger
language plpgsql as $$
begin
  if tg_op in ('DELETE', 'UPDATE')
     and position(tg_op in coalesce(current_setting('app.alteracao_autorizada', true), '')) > 0 then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  raise exception 'Registro imutável: % em % não é permitido.', tg_op, tg_table_name
    using errcode = '42501';
end $$;

-- Refaz a cadeia de hash dos registros que sobraram (depois de uma exclusão)
create or replace function public._reancorar_auditoria() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare r record; v_ant text := repeat('0', 64); v_novo text;
begin
  perform pg_advisory_xact_lock(7355608);
  perform set_config('app.alteracao_autorizada', 'UPDATE', true);
  for r in select * from public.auditoria order by id loop
    v_novo := public._hash_auditoria(v_ant, r.ocorrido_em, r.usuario_id, r.acao, r.protocolo_id, r.detalhes);
    if r.hash_anterior <> v_ant or r.hash <> v_novo then
      update public.auditoria set hash_anterior = v_ant, hash = v_novo where id = r.id;
    end if;
    v_ant := v_novo;
  end loop;
  perform set_config('app.alteracao_autorizada', '', true);
end $$;

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

create or replace function public.limpar_trilha(
  p_modo text, p_data_ini date, p_data_fim date, p_justificativa text, p_pin_gestor text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare g public.perfis%rowtype := public._exigir_gestor(); v_msg text; v_n int;
        v_just text := regexp_replace(btrim(coalesce(p_justificativa, '')), '\s+', ' ', 'g');
begin
  if p_modo not in ('tudo', 'periodo') then raise exception 'Escolha o que excluir: todo o período ou um intervalo de datas.'; end if;
  if p_modo = 'periodo' then
    if p_data_ini is null or p_data_fim is null then raise exception 'Informe a data inicial e a final.'; end if;
    if p_data_fim < p_data_ini then raise exception 'A data final deve ser igual ou posterior à inicial.'; end if;
  end if;
  if length(v_just) < 10 or length(v_just) > 500 then raise exception 'Informe a justificativa (de 10 a 500 caracteres).'; end if;
  v_msg := public._checar_pin(g.user_id, p_pin_gestor);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;

  perform pg_advisory_xact_lock(7355608);
  perform set_config('app.alteracao_autorizada', 'DELETE', true);
  delete from public.auditoria a
   where p_modo = 'tudo'
      or ((a.ocorrido_em at time zone public._fuso())::date between p_data_ini and p_data_fim);
  get diagnostics v_n = row_count;
  perform set_config('app.alteracao_autorizada', '', true);
  if v_n = 0 then return jsonb_build_object('ok', true, 'removidos', 0); end if;
  perform public._reancorar_auditoria();
  perform public._auditar(g.user_id, g.nome, 'TRILHA_EXCLUIDA', null,
            jsonb_build_object('removidos', v_n, 'modo', p_modo, 'de', p_data_ini, 'ate', p_data_fim, 'justificativa', v_just));
  return jsonb_build_object('ok', true, 'removidos', v_n);
end $$;

-- o gestor enxerga todas as fotos (inclusive as já desvinculadas: o DELETE do Storage exige poder "ver" a linha)
drop policy if exists fotos_select on storage.objects;
create policy fotos_select on storage.objects for select to authenticated
  using (bucket_id = 'protocolo-fotos'
         and ((storage.foldername(name))[1] = public._uid()::text
              or public.meu_papel() = 'gestor'
              or exists (select 1 from public.protocolo_fotos f
                          where f.caminho = name and public.pode_ver_protocolo(f.protocolo_id))));

-- o gestor pode apagar a foto do bucket (a linha do banco é removida por excluir_protocolo)
drop policy if exists fotos_delete on storage.objects;
create policy fotos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'protocolo-fotos' and public.meu_papel() = 'gestor');

-- ---------------------------------------------------------------------
-- 5. PERMISSÕES
-- ---------------------------------------------------------------------
revoke all on function
  public.identidade_publica(), public.painel_definir_logo(text, text), public.painel_remover_logo(text),
  public.painel_salvar_parametros(jsonb), public.excluir_protocolo(bigint, text, text, boolean),
  public.limpar_trilha(text, date, date, text, text), public._reancorar_auditoria(), public._checar_expediente(),
  public._parse_hhmm(text), public._parse_duracao_min(text), public._param_min(text, int), public._param_hhmm(text, text),
  public._fmt_hhmm(time), public._fmt_duracao(int), public._minutos_expediente()
  from public, anon, authenticated;

grant execute on function public.identidade_publica() to anon, authenticated;
grant execute on function
  public.painel_definir_logo(text, text), public.painel_remover_logo(text), public.painel_salvar_parametros(jsonb),
  public.excluir_protocolo(bigint, text, text, boolean), public.limpar_trilha(text, date, date, text, text)
  to authenticated;
