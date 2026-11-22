-- =====================================================================
-- MIGRAÇÃO 02 — Prazos, tempos máximos (SLA), foto, destino e alertas
-- Rode no SQL Editor DEPOIS do schema.sql (pode rodar de novo sem problema).
--
-- O que muda no processo:
--   1. Portaria registra NO ATO da chegada: tipo (judicial/correspondência), urgência e FOTO
--      do envelope/capa (obrigatória para judiciais).
--   2. O sistema calcula o PRAZO (padrão por tipo, em dias úteis, sem feriados cadastrados) e o
--      TEMPO MÁXIMO (SLA) de cada etapa, contado só em horas úteis (expediente + dias úteis).
--   3. O ADM, ao receber, ESCOLHE o setor de destino (ex.: Superintendência). Só esse setor
--      enxerga e recebe o protocolo. O ADM pode ajustar o prazo (com justificativa e PIN).
--   4. Alertas: no sistema (função minhas_pendencias) e por e-mail (fila_email), com escalada
--      ao gestor quando o SLA ou o prazo estoura.
--   Valores padrão: judicial = 5 dias úteis; correspondência = sem prazo; ADM = 4h úteis
--   (2h se urgente); setor = 9h úteis (≈ 1 dia útil). Ajuste com admin_definir_parametro().
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. PARÂMETROS, FERIADOS E INTEGRAÇÃO
-- ---------------------------------------------------------------------
create table if not exists public.parametros (
  chave     text primary key,
  valor     text not null,
  descricao text
);
insert into public.parametros (chave, valor, descricao) values
  ('prazo_judicial_dias',        '5',  'Prazo padrão (dias úteis) de demandas judiciais. O ADM pode ajustar por protocolo.'),
  ('prazo_correspondencia_dias', '0',  'Prazo padrão (dias úteis) de correspondências. 0 = sem prazo.'),
  ('sla_adm_horas',              '4',  'Tempo máximo (horas úteis) para o ADM receber.'),
  ('sla_adm_urgente_horas',      '2',  'Idem, para demandas judiciais marcadas como urgentes.'),
  ('sla_setor_horas',            '9',  'Tempo máximo (horas úteis) para o setor de destino receber (9h = 1 dia útil).'),
  ('sla_setor_urgente_horas',    '4',  'Idem, para urgentes.'),
  ('expediente_inicio',          '8',  'Hora de início do expediente (para horas úteis).'),
  ('expediente_fim',             '17', 'Hora de fim do expediente.'),
  ('alerta_prazo_dias',          '2',  'Avisar (e-mail/escalada) quando faltarem até N dias para o prazo.'),
  ('foto_obrigatoria_judicial',  'true', 'Judiciais exigem foto do envelope ou da capa (true/false).'),
  ('url_sistema',                '',   'Endereço do sistema (https://...), usado nos e-mails.')
on conflict (chave) do nothing;

create table if not exists public.feriados (
  data      date primary key,
  descricao text not null
);
-- Feriados nacionais de data fixa (2026-2027). CADASTRE os móveis (Carnaval, Sexta-feira Santa,
-- Corpus Christi) e os estaduais/municipais com admin_cadastrar_feriado().
insert into public.feriados (data, descricao) values
  ('2026-11-02','Finados'), ('2026-11-15','Proclamação da República'), ('2026-11-20','Consciência Negra'),
  ('2026-12-25','Natal'), ('2027-01-01','Confraternização Universal'), ('2027-04-21','Tiradentes'),
  ('2027-05-01','Dia do Trabalho'), ('2027-09-07','Independência'), ('2027-10-12','Nossa Senhora Aparecida'),
  ('2027-11-02','Finados'), ('2027-11-15','Proclamação da República'), ('2027-11-20','Consciência Negra'),
  ('2027-12-25','Natal')
on conflict (data) do nothing;

-- Segredo (guardado como hash) usado pela rotina agendada que envia os e-mails
create table if not exists public.integracao (
  id           int primary key default 1 check (id = 1),
  segredo_hash text not null
);

create or replace function public._param_text(p_chave text, p_padrao text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select valor from public.parametros where chave = p_chave), p_padrao)
$$;
create or replace function public._param_int(p_chave text, p_padrao int) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select nullif(valor, '')::int from public.parametros where chave = p_chave), p_padrao)
$$;

-- ---------------------------------------------------------------------
-- 2. DIAS ÚTEIS E HORAS ÚTEIS (fuso da unidade)
-- ---------------------------------------------------------------------
create or replace function public._eh_util(p_d date) returns boolean
language sql stable security definer set search_path = public as $$
  select extract(isodow from p_d) < 6 and not exists (select 1 from public.feriados f where f.data = p_d)
$$;

-- Primeiro instante (hora local) dentro do expediente, em dia útil, a partir de p_l
create or replace function public._util_local(p_l timestamp) returns timestamp
language plpgsql stable security definer set search_path = public as $$
declare v_ini time := public._param_hhmm('expediente_inicio', '08:00');
        v_fim time := public._param_hhmm('expediente_fim', '17:00');
        l timestamp := p_l; d date;
begin
  loop
    d := l::date;
    if public._eh_util(d) then
      if l::time < v_ini then return d + v_ini; end if;
      if l::time < v_fim then return l; end if;
    end if;
    l := (d + 1) + v_ini;
  end loop;
end $$;

create or replace function public._somar_horas_uteis(p_ts timestamptz, p_horas numeric) returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare v_ini time := public._param_hhmm('expediente_inicio', '08:00');
        v_fim time := public._param_hhmm('expediente_fim', '17:00');
        l timestamp := public._util_local(p_ts at time zone public._fuso());
        resto int := round(p_horas * 60)::int; disp int;
begin
  loop
    disp := floor(extract(epoch from ((l::date + v_fim) - l)) / 60)::int;
    if resto <= disp then l := l + make_interval(mins => resto); exit; end if;
    resto := resto - disp;
    l := public._util_local((l::date + 1) + v_ini);
  end loop;
  return l at time zone public._fuso();
end $$;

create or replace function public._somar_dias_uteis(p_d date, p_n int) returns date
language plpgsql stable security definer set search_path = public as $$
declare d date := p_d; k int := 0;
begin
  while k < p_n loop
    d := d + 1;
    if public._eh_util(d) then k := k + 1; end if;
  end loop;
  return d;
end $$;

create or replace function public._dias_restantes(p_prazo date, p_status text) returns int
language sql stable set search_path = public as $$
  select case when p_status = 'concluido' or p_prazo is null then null
              else p_prazo - (now() at time zone public._fuso())::date end
$$;

-- antecedência do aviso (dias), lida com privilégio do dono porque as funções chamadoras rodam com o usuário logado
create or replace function public._alerta_dias() returns int
language sql stable security definer set search_path = public as $$
  select greatest(public._param_int('alerta_prazo_dias', 2), 0)
$$;

-- semáforo: concluido | sem_prazo | vencido | critico (<= "alerta_prazo_dias", padrão 2) | atencao (<= 5, ou o alerta se maior) | ok
create or replace function public._semaforo(p_prazo date, p_status text) returns text
language sql stable set search_path = public as $$
  select case when p_status = 'concluido' then 'concluido'
              when p_prazo is null then 'sem_prazo'
              when p_prazo - (now() at time zone public._fuso())::date < 0 then 'vencido'
              when p_prazo - (now() at time zone public._fuso())::date <= public._alerta_dias() then 'critico'
              when p_prazo - (now() at time zone public._fuso())::date <= greatest(public._alerta_dias(), 5) then 'atencao'
              else 'ok' end
$$;

-- ---------------------------------------------------------------------
-- 3. NOVAS COLUNAS E TABELAS
-- ---------------------------------------------------------------------
alter table public.protocolos
  add column if not exists tipo text not null default 'correspondencia' check (tipo in ('judicial','correspondencia')),
  add column if not exists urgente boolean not null default false,
  add column if not exists prazo_data date,
  add column if not exists setor_destino_id bigint references public.setores(id),
  add column if not exists sla_limite timestamptz;
create index if not exists ix_protocolos_prazo on public.protocolos(prazo_data) where status <> 'concluido';

alter table public.perfis add column if not exists email text;   -- usado só para avisos por e-mail
update public.perfis p set email = lower(u.email) from auth.users u where u.id = p.user_id and p.email is null;

create table if not exists public.prazo_historico (
  id             bigint generated always as identity primary key,
  protocolo_id   bigint not null references public.protocolos(id),
  prazo_anterior date,
  prazo_novo     date not null,
  justificativa  text not null check (length(justificativa) between 10 and 500),
  usuario_id     uuid not null references auth.users(id),
  usuario_nome   text not null,
  ajustado_em    timestamptz not null default now()
);

create table if not exists public.protocolo_fotos (
  id           bigint generated always as identity primary key,
  protocolo_id bigint not null references public.protocolos(id),
  caminho      text not null unique,              -- caminho no bucket privado "protocolo-fotos"
  tamanho      int,
  enviado_por  uuid not null references auth.users(id),
  enviado_em   timestamptz not null default now()
);

create table if not exists public.fila_email (
  id            bigint generated always as identity primary key,
  chave         text not null unique,             -- evita avisos duplicados (ex.: 'chegada:12')
  evento        text not null,
  protocolo_id  bigint,
  destinatarios text[] not null,
  assunto       text not null,
  corpo         text not null,
  status        text not null default 'pendente' check (status in ('pendente','enviado','erro')),
  tentativas    int not null default 0,
  erro          text,
  criado_em     timestamptz not null default now(),
  enviado_em    timestamptz
);

do $$
declare t text;
begin
  foreach t in array array['prazo_historico','protocolo_fotos'] loop
    execute format('drop trigger if exists trg_%1$s_imutavel on public.%1$s', t);
    execute format('create trigger trg_%1$s_imutavel before update or delete on public.%1$s
                    for each row execute function public._bloquear_alteracao()', t);
    execute format('drop trigger if exists trg_%1$s_sem_truncate on public.%1$s', t);
    execute format('create trigger trg_%1$s_sem_truncate before truncate on public.%1$s
                    for each statement execute function public._bloquear_alteracao()', t);
  end loop;
end $$;

-- tipo/urgência imutáveis; destino definido uma única vez
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
  if old.setor_destino_id is not null and new.setor_destino_id is distinct from old.setor_destino_id then
    raise exception 'O setor de destino já foi definido e não pode ser alterado.' using errcode = '42501';
  end if;
  if new.status is distinct from old.status and not (
       (old.status = 'pendente_adm'   and new.status = 'pendente_setor') or
       (old.status = 'pendente_setor' and new.status = 'concluido')) then
    raise exception 'Transição de status inválida.' using errcode = '42501';
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 4. VISIBILIDADE: o setor só enxerga o que foi encaminhado a ele
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
         and ((p.status = 'pendente_setor' and p.setor_destino_id = public.meu_setor())
              or exists (select 1 from public.tramites t
                          where t.protocolo_id = p.id and t.etapa = 3
                            and t.setor_id = public.meu_setor())))
    else false
  end
$$;

-- ---------------------------------------------------------------------
-- 5. FOTO (Storage privado) — bucket e políticas
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('protocolo-fotos', 'protocolo-fotos', false, 1572864, array['image/jpeg'])
on conflict (id) do update
  set public = false, file_size_limit = 1572864, allowed_mime_types = array['image/jpeg'];

-- Só a Portaria envia, e só para a própria pasta (<uid>/arquivo.jpg). Sem UPDATE/DELETE: foto imutável.
drop policy if exists fotos_insert on storage.objects;
create policy fotos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'protocolo-fotos' and public.meu_papel() = 'portaria'
              and (storage.foldername(name))[1] = auth.uid()::text);

-- Lê quem enviou (a própria pasta) ou quem pode ver o protocolo ao qual a foto foi vinculada
drop policy if exists fotos_select on storage.objects;
create policy fotos_select on storage.objects for select to authenticated
  using (bucket_id = 'protocolo-fotos'
         and ((storage.foldername(name))[1] = auth.uid()::text
              or exists (select 1 from public.protocolo_fotos f
                          where f.caminho = name and public.pode_ver_protocolo(f.protocolo_id))));

-- ---------------------------------------------------------------------
-- 6. FILA DE E-MAIL (sem dados sensíveis: nunca inclui a descrição do documento)
-- ---------------------------------------------------------------------
create or replace function public._emails(p_papeis text[], p_setor bigint default null) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct lower(email)), '{}')
    from public.perfis
   where ativo and email is not null and papel = any(p_papeis)
     and (papel <> 'super_setor' or p_setor is null or setor_id = p_setor)
$$;

create or replace function public._enfileirar_email(
  p_chave text, p_evento text, p_pid bigint, p_dest text[], p_assunto text, p_corpo text) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if p_dest is null or cardinality(p_dest) = 0 then return false; end if;
  insert into public.fila_email (chave, evento, protocolo_id, destinatarios, assunto, corpo)
  values (p_chave, p_evento, p_pid, p_dest, p_assunto, p_corpo)
  on conflict (chave) do nothing returning id into v_id;
  return v_id is not null;
end $$;

create or replace function public._texto_email(
  p_numero text, p_tipo text, p_urgente boolean, p_prazo date, p_sla timestamptz, p_intro text) returns text
language sql stable security definer set search_path = public as $$
  select p_intro || E'\n\n'
      || 'Protocolo: ' || p_numero || E'\n'
      || 'Tipo: ' || case p_tipo when 'judicial' then 'Demanda judicial' else 'Correspondência' end
      || case when p_urgente then ' (URGENTE)' else '' end || E'\n'
      || 'Prazo: ' || coalesce(to_char(p_prazo, 'DD/MM/YYYY'), 'sem prazo informado') || E'\n'
      || case when p_sla is not null
              then 'Limite para o seu recebimento: ' || to_char(p_sla at time zone public._fuso(), 'DD/MM/YYYY HH24:MI') || E'\n'
              else '' end
      || E'\nAcesse o sistema para confirmar o recebimento'
      || case when public._param_text('url_sistema', '') <> '' then ': ' || public._param_text('url_sistema', '') else '.' end
      || E'\n\nAviso automático do Livro de Protocolo. Por segurança, este e-mail não traz a descrição do documento.'
$$;

-- ---------------------------------------------------------------------
-- 7. RPCs DE ESCRITA ATUALIZADAS
-- ---------------------------------------------------------------------
drop function if exists public.registrar_protocolo(text, text, text);
drop function if exists public.confirmar_etapa(bigint, int, text, text);

-- 1ª etapa — Portaria registra no ato da chegada (tipo, urgência, foto)
create or replace function public.registrar_protocolo(
  p_descricao text, p_pin text, p_assinatura text default null,
  p_tipo text default 'correspondencia', p_urgente boolean default false, p_foto_caminho text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid(); v_perfil public.perfis%rowtype; v_desc text; v_png text; v_msg text;
  v_agora timestamptz := now(); v_ano int; v_n int; v_num text; v_id bigint;
  v_tipo text := coalesce(p_tipo, 'correspondencia'); v_urg boolean := coalesce(p_urgente, false);
  v_foto text := nullif(btrim(coalesce(p_foto_caminho, '')), ''); v_tam int;
  v_dias int; v_prazo date; v_sla timestamptz;
begin
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  if not found or v_perfil.papel <> 'portaria' then
    raise exception 'Seu perfil não tem permissão para registrar protocolos.' using errcode = '42501';
  end if;
  if v_tipo not in ('judicial', 'correspondencia') then raise exception 'Tipo de documento inválido.'; end if;
  if v_urg and v_tipo <> 'judicial' then
    raise exception 'A marcação de urgência vale apenas para demandas judiciais.';
  end if;
  v_desc := public._validar_descricao(p_descricao);
  v_png  := public._validar_assinatura(p_assinatura);

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
  perform public._inserir_tramite(v_id, v_num, 1, v_uid, v_perfil.nome, null, null, v_png, v_agora);
  if v_foto is not null then
    insert into public.protocolo_fotos (protocolo_id, caminho, tamanho, enviado_por, enviado_em)
    values (v_id, v_foto, v_tam, v_uid, v_agora);
  end if;
  perform public._auditar(v_uid, v_perfil.nome, 'PROTOCOLO_CRIADO', v_id,
            jsonb_build_object('numero', v_num, 'descricao', v_desc, 'tipo', v_tipo, 'urgente', v_urg,
                               'prazo', v_prazo, 'foto', v_foto is not null));
  perform public._enfileirar_email('chegada:' || v_id, 'CHEGADA', v_id, public._emails(array['adm']),
            '[Protocolo' || case when v_urg then ' URGENTE' else '' end || '] ' || v_num || ' aguardando o ADM',
            public._texto_email(v_num, v_tipo, v_urg, v_prazo, v_sla, 'Chegou uma nova demanda na Portaria e aguarda o recebimento do ADM.'));
  return jsonb_build_object('ok', true, 'id', v_id, 'numero', v_num);
end $$;

-- 2ª etapa (ADM escolhe o setor de destino) e 3ª etapa (setor de destino)
create or replace function public.confirmar_etapa(
  p_protocolo_id bigint, p_etapa int, p_pin text, p_assinatura text default null,
  p_setor_destino_id bigint default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid(); v_perfil public.perfis%rowtype; v_p public.protocolos%rowtype;
  v_png text; v_msg text; v_agora timestamptz := now(); v_setor_nome text; v_papel text;
  v_dest_nome text; v_sla timestamptz;
begin
  if p_etapa not in (2, 3) then raise exception 'Etapa inválida.'; end if;
  v_papel := case p_etapa when 2 then 'adm' else 'super_setor' end;
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  if not found or v_perfil.papel <> v_papel then
    raise exception 'Seu perfil não tem permissão para esta etapa.' using errcode = '42501';
  end if;
  select * into v_p from public.protocolos where id = p_protocolo_id for update;
  if not found then raise exception 'Protocolo não encontrado.'; end if;

  if v_p.status = 'concluido' then
    if p_etapa = 3 and v_p.setor_destino_id is distinct from v_perfil.setor_id then
      raise exception 'Protocolo não encontrado.';
    end if;
    raise exception 'Este protocolo já foi concluído.';
  end if;
  if p_etapa = 3 and (v_p.status = 'pendente_adm' or v_p.setor_destino_id is distinct from v_perfil.setor_id) then
    raise exception 'Protocolo não encontrado.';       -- não revela protocolos de outros setores
  end if;
  if p_etapa = 2 and v_p.status <> 'pendente_adm' then
    raise exception 'O recebimento do ADM já foi registrado para este protocolo.';
  end if;
  if exists (select 1 from public.tramites where protocolo_id = v_p.id and usuario_id = v_uid) then
    raise exception 'Segregação de funções: você já assinou outra etapa deste protocolo.' using errcode = '42501';
  end if;
  if p_etapa = 2 then
    select nome into v_dest_nome from public.setores where id = p_setor_destino_id and ativo;
    if v_dest_nome is null then raise exception 'Informe o setor de destino do documento.'; end if;
  end if;

  v_png := public._validar_assinatura(p_assinatura);
  v_msg := public._checar_pin(v_uid, p_pin);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;

  if p_etapa = 3 then select nome into v_setor_nome from public.setores where id = v_perfil.setor_id; end if;
  perform public._inserir_tramite(v_p.id, v_p.numero, p_etapa, v_uid, v_perfil.nome,
            case when p_etapa = 3 then v_perfil.setor_id end, v_setor_nome, v_png, v_agora);

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
            jsonb_build_object('numero', v_p.numero, 'setor', coalesce(v_setor_nome, v_dest_nome),
                               'assinatura', case when v_png is null then 'pin' else 'pin_canvas' end));
  return jsonb_build_object('ok', true, 'id', v_p.id, 'numero', v_p.numero);
end $$;

-- ADM/gestor ajustam o prazo (ex.: prazo real informado no documento). Justificativa + PIN; histórico imutável.
create or replace function public.ajustar_prazo(
  p_protocolo_id bigint, p_nova_data date, p_justificativa text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid(); v_perfil public.perfis%rowtype; v_p public.protocolos%rowtype;
  v_just text; v_msg text; v_agora timestamptz := now();
begin
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  if not found or v_perfil.papel not in ('adm', 'gestor') then
    raise exception 'Seu perfil não tem permissão para ajustar prazos.' using errcode = '42501';
  end if;
  v_just := regexp_replace(btrim(coalesce(p_justificativa, '')), '\s+', ' ', 'g');
  if length(v_just) not between 10 and 500 then raise exception 'Informe uma justificativa de 10 a 500 caracteres.'; end if;
  select * into v_p from public.protocolos where id = p_protocolo_id for update;
  if not found then raise exception 'Protocolo não encontrado.'; end if;
  if v_p.status = 'concluido' then raise exception 'Protocolo concluído: o prazo não pode mais ser alterado.'; end if;
  if p_nova_data is null or p_nova_data < (v_p.created_at at time zone public._fuso())::date
     or p_nova_data > (v_agora at time zone public._fuso())::date + 730 then
    raise exception 'Data de prazo inválida.';
  end if;
  if p_nova_data is not distinct from v_p.prazo_data then raise exception 'O novo prazo é igual ao atual.'; end if;
  v_msg := public._checar_pin(v_uid, p_pin);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;

  insert into public.prazo_historico (protocolo_id, prazo_anterior, prazo_novo, justificativa, usuario_id, usuario_nome, ajustado_em)
  values (v_p.id, v_p.prazo_data, p_nova_data, v_just, v_uid, v_perfil.nome, v_agora);
  update public.protocolos set prazo_data = p_nova_data where id = v_p.id;
  perform public._auditar(v_uid, v_perfil.nome, 'PRAZO_AJUSTADO', v_p.id,
            jsonb_build_object('numero', v_p.numero, 'anterior', v_p.prazo_data, 'novo', p_nova_data, 'justificativa', v_just));
  return jsonb_build_object('ok', true, 'id', v_p.id);
end $$;

-- ---------------------------------------------------------------------
-- 8. LEITURA: visão com prazo/SLA/foto, listagem com alertas, pendências, detalhe
-- ---------------------------------------------------------------------
create or replace view public.v_livro with (security_invoker = true) as
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
       case p.status when 'pendente_adm' then t1.recebido_em when 'pendente_setor' then t2.recebido_em end as aguardando_desde,
       (select count(*) from public.protocolo_fotos f where f.protocolo_id = p.id)::int as n_fotos
  from public.protocolos p
  left join public.tramites t1 on t1.protocolo_id = p.id and t1.etapa = 1
  left join public.tramites t2 on t2.protocolo_id = p.id and t2.etapa = 2
  left join public.tramites t3 on t3.protocolo_id = p.id and t3.etapa = 3
  left join public.setores sd on sd.id = p.setor_destino_id;

drop function if exists public.listar_livro(text, text, date, date, int, int);
create or replace function public.listar_livro(
  p_q text default null, p_status text default null,
  p_data_ini date default null, p_data_fim date default null,
  p_limite int default 25, p_offset int default 0,
  p_alerta text default null, p_ordem text default 'recentes')
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare v_like text; v_total bigint; v_itens jsonb;
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
            or (p_alerta = 'abertos'  and v.status <> 'concluido')
            or (p_alerta = 'vencidos' and v.semaforo = 'vencido')
            or (p_alerta = 'criticos' and v.semaforo = 'critico')
            or (p_alerta = 'sla'      and v.sla_estourado))
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
    'alerta_dias',    public._alerta_dias())
  from public.v_livro
$$;

-- O que PRECISA da atenção do usuário agora (alimenta o sino do sistema)
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
    'fotos', coalesce((select jsonb_agg(jsonb_build_object('caminho', f.caminho, 'enviado_em', f.enviado_em) order by f.id)
                from public.protocolo_fotos f where f.protocolo_id = p_id), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 9. ESCALADA AUTOMÁTICA (SLA e prazo) — gera avisos por e-mail e registra na auditoria
-- ---------------------------------------------------------------------
create or replace function public._verificar_sla() returns int
language plpgsql security definer set search_path = public as $$
declare
  r public.protocolos%rowtype; v_hoje date := (now() at time zone public._fuso())::date;
  v_aviso int := public._param_int('alerta_prazo_dias', 2); v_n int := 0;
  v_atual text[]; v_dest text[]; v_dias int; v_etapa int;
begin
  for r in select * from public.protocolos where status <> 'concluido' order by id loop
    v_etapa := case r.status when 'pendente_adm' then 2 else 3 end;
    v_atual := case r.status when 'pendente_adm' then public._emails(array['adm'])
                             else public._emails(array['super_setor'], r.setor_destino_id) end;
    v_dest  := (select coalesce(array_agg(distinct e), '{}') from unnest(v_atual || public._emails(array['gestor'])) e);

    if r.sla_limite is not null and now() > r.sla_limite then
      if public._enfileirar_email('sla:' || r.id || ':' || v_etapa, 'SLA', r.id, v_dest,
           '[Protocolo ATRASADO] ' || r.numero || ' sem recebimento no tempo previsto',
           public._texto_email(r.numero, r.tipo, r.urgente, r.prazo_data, r.sla_limite,
             'ATENÇÃO: o tempo máximo para o recebimento ' || case v_etapa when 2 then 'do ADM' else 'do setor de destino' end || ' foi ultrapassado.')) then
        v_n := v_n + 1;
        perform public._auditar(null, 'sistema', 'ALERTA_SLA', r.id, jsonb_build_object('numero', r.numero, 'etapa', v_etapa));
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

-- ---------------------------------------------------------------------
-- 10. INTEGRAÇÃO COM A ROTINA DE E-MAIL (GitHub Actions) — protegida por segredo próprio
--     (não usa service_role; o segredo só permite verificar SLA e ler/marcar a fila)
-- ---------------------------------------------------------------------
create or replace function public._segredo_ok(p_segredo text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v text;
begin
  select segredo_hash into v from public.integracao where id = 1;
  if v is null or p_segredo is null or length(p_segredo) < 32
     or v <> encode(digest(p_segredo, 'sha256'), 'hex') then
    perform pg_sleep(1);                              -- dificulta tentativas em série
    raise exception 'Não autorizado.' using errcode = '42501';
  end if;
end $$;

create or replace function public.integracao_verificar(p_segredo text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public._segredo_ok(p_segredo);
  return jsonb_build_object('avisos_novos', public._verificar_sla());
end $$;

create or replace function public.integracao_fila(p_segredo text, p_limite int default 20) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public._segredo_ok(p_segredo);
  return coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'destinatarios', f.destinatarios,
                          'assunto', f.assunto, 'corpo', f.corpo) order by f.id)
                     from (select * from public.fila_email
                            where status in ('pendente', 'erro') and tentativas < 5
                            order by id limit least(greatest(coalesce(p_limite, 20), 1), 50)) f), '[]'::jsonb);
end $$;

create or replace function public.integracao_marcar(p_segredo text, p_id bigint, p_ok boolean, p_erro text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._segredo_ok(p_segredo);
  update public.fila_email
     set status = case when p_ok then 'enviado' else 'erro' end, tentativas = tentativas + 1,
         erro = case when p_ok then null else left(p_erro, 300) end,
         enviado_em = case when p_ok then now() end
   where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- 11. ADMINISTRAÇÃO (SQL Editor)
-- ---------------------------------------------------------------------
create or replace function public.admin_definir_parametro(p_chave text, p_valor text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.parametros where chave = p_chave) then
    raise exception 'Parâmetro desconhecido: %. Veja: select * from public.parametros;', p_chave;
  end if;
  if p_chave = 'url_sistema' then
    if p_valor <> '' and p_valor !~ '^https://' then raise exception 'url_sistema deve começar com https://'; end if;
  elsif p_chave = 'foto_obrigatoria_judicial' then
    if p_valor not in ('true', 'false') then raise exception 'Use true ou false.'; end if;
  elsif p_valor !~ '^\d{1,3}$' then
    raise exception 'Informe um número inteiro (0 a 999).';
  elsif p_chave in ('expediente_inicio', 'expediente_fim') and p_valor::int > 23 then
    raise exception 'Hora inválida.';
  end if;
  update public.parametros set valor = p_valor where chave = p_chave;
  perform public._auditar(null, 'admin (SQL Editor)', 'PARAMETRO_ALTERADO', null, jsonb_build_object('chave', p_chave, 'valor', p_valor));
  return p_chave || ' = ' || p_valor;
end $$;

create or replace function public.admin_cadastrar_feriado(p_data date, p_descricao text) returns text
language plpgsql security definer set search_path = public as $$
begin
  insert into public.feriados (data, descricao) values (p_data, btrim(p_descricao))
  on conflict (data) do update set descricao = excluded.descricao;
  return 'Feriado ' || to_char(p_data, 'DD/MM/YYYY') || ' cadastrado.';
end $$;

-- Define o segredo da rotina de e-mail. Gere um valor longo e aleatório (ver README).
create or replace function public.admin_definir_segredo_integracao(p_segredo text) returns text
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_segredo is null or length(p_segredo) < 32 then raise exception 'Use um segredo com pelo menos 32 caracteres.'; end if;
  insert into public.integracao (id, segredo_hash) values (1, encode(digest(p_segredo, 'sha256'), 'hex'))
  on conflict (id) do update set segredo_hash = excluded.segredo_hash;
  perform public._auditar(null, 'admin (SQL Editor)', 'SEGREDO_INTEGRACAO_DEFINIDO', null, '{}');
  return 'Segredo definido.';
end $$;

-- admin_cadastrar_perfil agora também guarda o e-mail (para os avisos)
create or replace function public.admin_cadastrar_perfil(
  p_email text, p_nome text, p_papel text, p_setor text, p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_uid uuid; v_setor bigint;
begin
  select id into v_uid from auth.users where lower(email) = lower(btrim(p_email));
  if v_uid is null then raise exception 'Usuário % não existe em Authentication → Users.', p_email; end if;
  if p_pin is null or p_pin !~ '^\d{4,6}$' then raise exception 'PIN deve ter de 4 a 6 dígitos numéricos.'; end if;
  if p_papel = 'super_setor' then
    select id into v_setor from public.setores where nome = p_setor and ativo;
    if v_setor is null then raise exception 'Setor "%" não cadastrado/ativo.', p_setor; end if;
  end if;
  insert into public.perfis (user_id, nome, papel, setor_id, pin_hash, email)
  values (v_uid, btrim(p_nome), p_papel, v_setor, crypt(p_pin, gen_salt('bf', 10)), lower(btrim(p_email)))
  on conflict (user_id) do update
    set nome = excluded.nome, papel = excluded.papel, setor_id = excluded.setor_id, email = excluded.email,
        pin_hash = excluded.pin_hash, ativo = true, pin_falhas = 0, pin_bloqueado_ate = null;
  perform public._auditar(null, 'admin (SQL Editor)', 'PERFIL_CADASTRADO', null,
            jsonb_build_object('email', lower(btrim(p_email)), 'papel', p_papel, 'setor', p_setor));
  return 'Perfil de ' || p_email || ' (' || p_papel || ') cadastrado.';
end $$;

-- ---------------------------------------------------------------------
-- 12. RLS E PRIVILÉGIOS DAS NOVAS PEÇAS
-- ---------------------------------------------------------------------
alter table public.parametros      enable row level security;
alter table public.feriados        enable row level security;
alter table public.integracao      enable row level security;
alter table public.fila_email      enable row level security;
alter table public.prazo_historico enable row level security;
alter table public.protocolo_fotos enable row level security;

drop policy if exists p_prazos_select on public.prazo_historico;
create policy p_prazos_select on public.prazo_historico for select to authenticated
  using (public.pode_ver_protocolo(protocolo_id));
drop policy if exists p_fotos_select on public.protocolo_fotos;
create policy p_fotos_select on public.protocolo_fotos for select to authenticated
  using (public.pode_ver_protocolo(protocolo_id));
-- parametros/feriados/integracao/fila_email: SEM policies => inacessíveis ao cliente

revoke all on public.parametros, public.feriados, public.integracao, public.fila_email,
              public.prazo_historico, public.protocolo_fotos from public, anon, authenticated;
revoke all on function
  public._param_text(text, text), public._param_int(text, int), public._eh_util(date), public._util_local(timestamp),
  public._somar_horas_uteis(timestamptz, numeric), public._somar_dias_uteis(date, int),
  public._dias_restantes(date, text), public._semaforo(date, text), public._alerta_dias(), public._emails(text[], bigint),
  public._enfileirar_email(text, text, bigint, text[], text, text),
  public._texto_email(text, text, boolean, date, timestamptz, text), public._verificar_sla(), public._segredo_ok(text),
  public.registrar_protocolo(text, text, text, text, boolean, text),
  public.confirmar_etapa(bigint, int, text, text, bigint), public.ajustar_prazo(bigint, date, text, text),
  public.listar_livro(text, text, date, date, int, int, text, text), public.minhas_pendencias(),
  public.integracao_verificar(text), public.integracao_fila(text, int), public.integracao_marcar(text, bigint, boolean, text),
  public.admin_definir_parametro(text, text), public.admin_cadastrar_feriado(date, text),
  public.admin_definir_segredo_integracao(text), public.admin_cadastrar_perfil(text, text, text, text, text)
  from public, anon, authenticated;

grant select on public.prazo_historico, public.protocolo_fotos, public.v_livro to authenticated;
grant usage on schema public to anon;       -- anon só enxerga as 3 funções integracao_* (abaixo)
grant execute on function
  public.registrar_protocolo(text, text, text, text, boolean, text),
  public.confirmar_etapa(bigint, int, text, text, bigint), public.ajustar_prazo(bigint, date, text, text),
  public.listar_livro(text, text, date, date, int, int, text, text), public.minhas_pendencias(),
  public._dias_restantes(date, text), public._semaforo(date, text), public._alerta_dias()
  to authenticated;
grant execute on function
  public.integracao_verificar(text), public.integracao_fila(text, int), public.integracao_marcar(text, bigint, boolean, text)
  to anon;

-- Setor novo para o fluxo (ajuste os nomes à sua unidade)
insert into public.setores (nome) values ('Superintendência') on conflict (nome) do nothing;
