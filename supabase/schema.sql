-- =====================================================================
-- LIVRO DE PROTOCOLO ELETRÔNICO — CECAN / LNRCC
-- Esquema completo para Supabase (PostgreSQL 15+): tabelas, triggers,
-- funções RPC e Row Level Security.
--
-- COMO USAR: Supabase → SQL Editor → New query → cole TODO este arquivo → Run.
-- É idempotente para funções/políticas; para recomeçar do zero use o bloco
-- "RESET" comentado no final (apaga todos os dados!).
--
-- MODELO DE SEGURANÇA (resumo)
--  1. Nenhum cliente (anon/authenticated) tem INSERT/UPDATE/DELETE direto em
--     tabela alguma. Toda escrita passa por funções RPC SECURITY DEFINER que
--     validam perfil, sequência, PIN, descrição e gravam a auditoria.
--  2. RLS ligado em todas as tabelas; a leitura exige perfil ativo e, para
--     'super_setor', só enxerga o que aguarda recebimento ou foi recebido no
--     próprio setor (minimização de dados — LGPD).
--  3. Triggers impedem UPDATE/DELETE/TRUNCATE em etapas, correções e auditoria,
--     e alteração dos campos originais do protocolo — valem até para a service_role.
--  4. Auditoria com encadeamento de hash (SHA-256) verificável por RPC.
--  5. Data/hora SEMPRE do relógio do servidor (now()); o cliente nunca as envia.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- Fuso usado para numeração anual e filtros por data (altere aqui, se preciso)
create or replace function public._fuso() returns text
language sql immutable as $$ select 'America/Fortaleza'::text $$;

-- ---------------------------------------------------------------------
-- 1. TABELAS
-- ---------------------------------------------------------------------
create table if not exists public.setores (
  id    bigint generated always as identity primary key,
  nome  text not null unique check (length(btrim(nome)) between 2 and 80),
  ativo boolean not null default true
);

-- Perfil de cada usuário do Supabase Auth.
-- papel: portaria (1ª etapa) | adm (2ª) | super_setor (3ª) | gestor (consulta/auditoria)
create table if not exists public.perfis (
  user_id           uuid primary key references auth.users(id) on delete restrict,
  nome              text not null check (length(btrim(nome)) between 2 and 120),
  papel             text not null check (papel in ('portaria','adm','super_setor','gestor')),
  setor_id          bigint references public.setores(id),
  ativo             boolean not null default true,
  pin_hash          text,                         -- bcrypt; NUNCA exposto ao cliente (ver GRANTs)
  pin_falhas        int not null default 0,
  pin_bloqueado_ate timestamptz,
  created_at        timestamptz not null default now(),
  check (papel <> 'super_setor' or setor_id is not null)
);

create table if not exists public.sequencias (
  ano    int primary key,
  ultimo int not null
);

create table if not exists public.protocolos (
  id         bigint generated always as identity primary key,
  numero     text not null unique,
  descricao  text not null check (length(descricao) between 5 and 300),
  status     text not null check (status in ('pendente_adm','pendente_setor','concluido')),
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id)
);
create index if not exists ix_protocolos_status  on public.protocolos(status);
create index if not exists ix_protocolos_created on public.protocolos(created_at desc);

-- Uma linha por etapa concluída (1 = Portaria, 2 = ADM, 3 = Super/Setor)
create table if not exists public.tramites (
  id              bigint generated always as identity primary key,
  protocolo_id    bigint not null references public.protocolos(id),
  etapa           smallint not null check (etapa in (1,2,3)),
  recebido_em     timestamptz not null default now(),   -- data + horário (servidor)
  usuario_id      uuid not null references auth.users(id),
  usuario_nome    text not null,                        -- cópia do nome na data do ato
  setor_id        bigint references public.setores(id), -- só na etapa 3
  setor_nome      text,
  assinatura_tipo text not null check (assinatura_tipo in ('pin','pin_canvas')),
  assinatura_png  text check (assinatura_png is null or (
                    length(assinatura_png) <= 270000
                    and assinatura_png ~ '^data:image/png;base64,iVBORw0KGgo[A-Za-z0-9+/=]*$')),
  selo            text not null,                        -- SHA-256 de integridade do ato
  unique (protocolo_id, etapa),
  check ((etapa = 3) = (setor_id is not null))
);

create table if not exists public.correcoes_descricao (
  id                 bigint generated always as identity primary key,
  protocolo_id       bigint not null references public.protocolos(id),
  descricao_anterior text not null,
  descricao_nova     text not null check (length(descricao_nova) between 5 and 300),
  justificativa      text not null check (length(justificativa) between 10 and 500),
  usuario_id         uuid not null references auth.users(id),
  usuario_nome       text not null,
  corrigido_em       timestamptz not null default now()
);

create table if not exists public.auditoria (
  id            bigint generated always as identity primary key,
  ocorrido_em   timestamptz not null default now(),
  usuario_id    uuid,
  usuario_nome  text,
  acao          text not null,
  protocolo_id  bigint,
  detalhes      jsonb not null default '{}'::jsonb,
  hash_anterior text not null,
  hash          text not null
);
create index if not exists ix_auditoria_protocolo on public.auditoria(protocolo_id);

-- ---------------------------------------------------------------------
-- 2. FUNÇÕES AUXILIARES DE PERFIL (usadas pelas políticas RLS)
--    SECURITY DEFINER evita recursão de RLS entre as tabelas.
-- ---------------------------------------------------------------------
create or replace function public.meu_papel() returns text
language sql stable security definer set search_path = public as $$
  select papel from public.perfis where user_id = auth.uid() and ativo
$$;

create or replace function public.meu_setor() returns bigint
language sql stable security definer set search_path = public as $$
  select setor_id from public.perfis where user_id = auth.uid() and ativo
$$;

create or replace function public.pode_ver_protocolo(p_id bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select case public.meu_papel()
    when 'gestor'   then true
    when 'portaria' then true
    when 'adm'      then true
    when 'super_setor' then exists (
      select 1 from public.protocolos p
       where p.id = p_id
         and (p.status = 'pendente_setor'
              or exists (select 1 from public.tramites t
                          where t.protocolo_id = p.id and t.etapa = 3
                            and t.setor_id = public.meu_setor())))
    else false
  end
$$;

-- ---------------------------------------------------------------------
-- 3. TRIGGERS: IMUTABILIDADE E SEQUÊNCIA (defesa em profundidade)
-- ---------------------------------------------------------------------
create or replace function public._bloquear_alteracao() returns trigger
language plpgsql as $$
begin
  raise exception 'Registro imutável: % em % não é permitido.', tg_op, tg_table_name
    using errcode = '42501';
end $$;

create or replace function public._protocolos_guarda() returns trigger
language plpgsql as $$
begin
  if new.id is distinct from old.id or new.numero is distinct from old.numero
     or new.descricao is distinct from old.descricao or new.created_at is distinct from old.created_at
     or new.created_by is distinct from old.created_by then
    raise exception 'Campos originais do protocolo são imutáveis. Use a correção com justificativa.'
      using errcode = '42501';
  end if;
  if new.status is distinct from old.status and not (
       (old.status = 'pendente_adm'   and new.status = 'pendente_setor') or
       (old.status = 'pendente_setor' and new.status = 'concluido')) then
    raise exception 'Transição de status inválida.' using errcode = '42501';
  end if;
  return new;
end $$;

create or replace function public._tramite_sequencia() returns trigger
language plpgsql as $$
begin
  if new.etapa > 1 and not exists (
       select 1 from public.tramites where protocolo_id = new.protocolo_id and etapa = new.etapa - 1) then
    raise exception 'Etapa anterior ainda não foi registrada.' using errcode = '23514';
  end if;
  return new;
end $$;

create or replace function public._tramite_atualiza_status() returns trigger
language plpgsql as $$
begin
  update public.protocolos
     set status = case new.etapa when 1 then 'pendente_adm' when 2 then 'pendente_setor' else 'concluido' end
   where id = new.protocolo_id;
  return null;
end $$;

drop trigger if exists trg_protocolos_guarda on public.protocolos;
create trigger trg_protocolos_guarda before update on public.protocolos
  for each row execute function public._protocolos_guarda();

drop trigger if exists trg_protocolos_sem_delete on public.protocolos;
create trigger trg_protocolos_sem_delete before delete on public.protocolos
  for each row execute function public._bloquear_alteracao();

drop trigger if exists trg_tramites_sequencia on public.tramites;
create trigger trg_tramites_sequencia before insert on public.tramites
  for each row execute function public._tramite_sequencia();

drop trigger if exists trg_tramites_status on public.tramites;
create trigger trg_tramites_status after insert on public.tramites
  for each row execute function public._tramite_atualiza_status();

do $$
declare t text;
begin
  foreach t in array array['tramites','correcoes_descricao','auditoria'] loop
    execute format('drop trigger if exists trg_%1$s_imutavel on public.%1$s', t);
    execute format('create trigger trg_%1$s_imutavel before update or delete on public.%1$s
                    for each row execute function public._bloquear_alteracao()', t);
  end loop;
  foreach t in array array['protocolos','tramites','correcoes_descricao','auditoria','sequencias'] loop
    execute format('drop trigger if exists trg_%1$s_sem_truncate on public.%1$s', t);
    execute format('create trigger trg_%1$s_sem_truncate before truncate on public.%1$s
                    for each statement execute function public._bloquear_alteracao()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 4. AUDITORIA ENCADEADA
-- ---------------------------------------------------------------------
create or replace function public._hash_auditoria(
  p_anterior text, p_quando timestamptz, p_uid uuid, p_acao text, p_pid bigint, p_det jsonb)
returns text language sql immutable set search_path = public, extensions as $$
  select encode(digest(concat_ws('|', p_anterior,
           to_char(p_quando at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
           coalesce(p_uid::text, ''), p_acao, coalesce(p_pid::text, ''), p_det::text), 'sha256'), 'hex')
$$;

create or replace function public._auditar(
  p_uid uuid, p_nome text, p_acao text, p_pid bigint, p_det jsonb)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_ant text; v_quando timestamptz := now(); v_det jsonb := coalesce(p_det, '{}'::jsonb);
begin
  perform pg_advisory_xact_lock(7355608);               -- serializa a cadeia de hash
  select hash into v_ant from public.auditoria order by id desc limit 1;
  v_ant := coalesce(v_ant, repeat('0', 64));
  insert into public.auditoria (ocorrido_em, usuario_id, usuario_nome, acao, protocolo_id, detalhes,
                                hash_anterior, hash)
  values (v_quando, p_uid, p_nome, p_acao, p_pid, v_det, v_ant,
          public._hash_auditoria(v_ant, v_quando, p_uid, p_acao, p_pid, v_det));
end $$;

-- ---------------------------------------------------------------------
-- 5. VALIDAÇÕES INTERNAS
-- ---------------------------------------------------------------------
create or replace function public._validar_descricao(p text) returns text
language plpgsql immutable as $$
declare v text := regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g');
begin
  if length(v) not between 5 and 300 then
    raise exception 'A descrição deve ter entre 5 e 300 caracteres.';
  end if;
  if v ~ '(?<!\d)\d{3}\.?\d{3}\.?\d{3}-?\d{2}(?!\d)' then
    raise exception 'A descrição parece conter um CPF. Informe apenas o necessário para identificar o documento (ex.: tipo, número do ofício, órgão de origem).';
  end if;
  return v;
end $$;

create or replace function public._validar_assinatura(p text) returns text
language plpgsql immutable as $$
begin
  if p is null or p = '' then return null; end if;
  if length(p) > 270000 or p !~ '^data:image/png;base64,iVBORw0KGgo[A-Za-z0-9+/=]*$' then
    raise exception 'Assinatura inválida ou grande demais.';
  end if;
  return p;
end $$;

-- Confere o PIN do usuário. Retorna NULL se válido ou a mensagem de erro.
-- NÃO levanta exceção em caso de falha, para que o contador de tentativas seja gravado.
create or replace function public._checar_pin(p_uid uuid, p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v public.perfis%rowtype;
begin
  select * into v from public.perfis where user_id = p_uid for update;
  if v.pin_hash is null then
    return 'PIN ainda não cadastrado. Peça ao gestor para definir o seu PIN.';
  end if;
  if v.pin_bloqueado_ate is not null and v.pin_bloqueado_ate > now() then
    return 'Aceite temporariamente bloqueado por tentativas inválidas. Aguarde alguns minutos.';
  end if;
  if p_pin is not null and p_pin ~ '^\d{4,6}$' and v.pin_hash = crypt(p_pin, v.pin_hash) then
    if v.pin_falhas > 0 or v.pin_bloqueado_ate is not null then
      update public.perfis set pin_falhas = 0, pin_bloqueado_ate = null where user_id = p_uid;
    end if;
    return null;
  end if;
  if v.pin_falhas + 1 >= 5 then
    update public.perfis set pin_falhas = 0, pin_bloqueado_ate = now() + interval '5 minutes'
     where user_id = p_uid;
    perform public._auditar(p_uid, v.nome, 'USUARIO_BLOQUEADO', null, '{"motivo":"pin"}');
  else
    update public.perfis set pin_falhas = pin_falhas + 1 where user_id = p_uid;
    perform public._auditar(p_uid, v.nome, 'FALHA_PIN', null, '{}');
  end if;
  return 'PIN inválido.';
end $$;

create or replace function public._inserir_tramite(
  p_pid bigint, p_numero text, p_etapa int, p_uid uuid, p_nome text,
  p_setor_id bigint, p_setor_nome text, p_png text, p_quando timestamptz)
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
          case when p_png is null then 'pin' else 'pin_canvas' end, p_png, v_selo);
end $$;

-- ---------------------------------------------------------------------
-- 6. RPCs DE ESCRITA (única porta de entrada para gravar dados)
--    Retornam jsonb {ok:true,...} ou {ok:false,erro:"..."} (falha de PIN);
--    demais erros de negócio levantam exceção (mensagem chega ao cliente).
-- ---------------------------------------------------------------------

-- 1ª etapa — Portaria cria o protocolo
create or replace function public.registrar_protocolo(
  p_descricao text, p_pin text, p_assinatura text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid(); v_perfil public.perfis%rowtype; v_desc text; v_png text; v_msg text;
  v_agora timestamptz := now(); v_ano int; v_n int; v_num text; v_id bigint;
begin
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  if not found or v_perfil.papel <> 'portaria' then
    raise exception 'Seu perfil não tem permissão para registrar protocolos.' using errcode = '42501';
  end if;
  v_desc := public._validar_descricao(p_descricao);
  v_png  := public._validar_assinatura(p_assinatura);
  v_msg  := public._checar_pin(v_uid, p_pin);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;

  v_ano := extract(year from v_agora at time zone public._fuso())::int;
  insert into public.sequencias (ano, ultimo) values (v_ano, 1)
    on conflict (ano) do update set ultimo = public.sequencias.ultimo + 1
    returning ultimo into v_n;                        -- trava a linha: numeração sem lacunas
  v_num := v_ano::text || '-' || lpad(v_n::text, 4, '0');

  insert into public.protocolos (numero, descricao, status, created_at, created_by)
  values (v_num, v_desc, 'pendente_adm', v_agora, v_uid) returning id into v_id;
  perform public._inserir_tramite(v_id, v_num, 1, v_uid, v_perfil.nome, null, null, v_png, v_agora);
  perform public._auditar(v_uid, v_perfil.nome, 'PROTOCOLO_CRIADO', v_id,
                          jsonb_build_object('numero', v_num, 'descricao', v_desc));
  return jsonb_build_object('ok', true, 'id', v_id, 'numero', v_num);
end $$;

-- 2ª etapa (ADM) e 3ª etapa (Super/Setor)
create or replace function public.confirmar_etapa(
  p_protocolo_id bigint, p_etapa int, p_pin text, p_assinatura text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid(); v_perfil public.perfis%rowtype; v_p public.protocolos%rowtype;
  v_png text; v_msg text; v_agora timestamptz := now(); v_setor_nome text; v_papel text;
begin
  if p_etapa not in (2, 3) then raise exception 'Etapa inválida.'; end if;
  v_papel := case p_etapa when 2 then 'adm' else 'super_setor' end;
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  if not found or v_perfil.papel <> v_papel then
    raise exception 'Seu perfil não tem permissão para esta etapa.' using errcode = '42501';
  end if;
  select * into v_p from public.protocolos where id = p_protocolo_id for update;
  if not found then raise exception 'Protocolo não encontrado.'; end if;

  if v_p.status = 'concluido' then raise exception 'Este protocolo já foi concluído.'; end if;
  if p_etapa = 3 and v_p.status = 'pendente_adm' then
    -- o setor ainda não pode ver este protocolo: não revelamos que ele existe
    raise exception 'Protocolo não encontrado.';
  end if;
  if p_etapa = 2 and v_p.status <> 'pendente_adm' then
    raise exception 'O recebimento do ADM já foi registrado para este protocolo.';
  end if;
  if exists (select 1 from public.tramites where protocolo_id = v_p.id and usuario_id = v_uid) then
    raise exception 'Segregação de funções: você já assinou outra etapa deste protocolo.'
      using errcode = '42501';
  end if;

  v_png := public._validar_assinatura(p_assinatura);
  v_msg := public._checar_pin(v_uid, p_pin);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;

  if p_etapa = 3 then select nome into v_setor_nome from public.setores where id = v_perfil.setor_id; end if;
  perform public._inserir_tramite(v_p.id, v_p.numero, p_etapa, v_uid, v_perfil.nome,
            case when p_etapa = 3 then v_perfil.setor_id end, v_setor_nome, v_png, v_agora);
  perform public._auditar(v_uid, v_perfil.nome,
            case p_etapa when 2 then 'RECEBIMENTO_ADM' else 'RECEBIMENTO_SETOR' end, v_p.id,
            jsonb_build_object('numero', v_p.numero, 'setor', v_setor_nome,
                               'assinatura', case when v_png is null then 'pin' else 'pin_canvas' end));
  return jsonb_build_object('ok', true, 'id', v_p.id, 'numero', v_p.numero);
end $$;

-- Correção de descrição: original preservada, justificativa + PIN obrigatórios
create or replace function public.corrigir_descricao(
  p_protocolo_id bigint, p_nova text, p_justificativa text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid(); v_perfil public.perfis%rowtype; v_p public.protocolos%rowtype;
  v_nova text; v_just text; v_atual text; v_msg text; v_agora timestamptz := now();
begin
  select * into v_perfil from public.perfis where user_id = v_uid and ativo;
  if not found or v_perfil.papel not in ('portaria', 'adm', 'gestor') then
    raise exception 'Seu perfil não tem permissão para corrigir descrições.' using errcode = '42501';
  end if;
  v_nova := public._validar_descricao(p_nova);
  v_just := regexp_replace(btrim(coalesce(p_justificativa, '')), '\s+', ' ', 'g');
  if length(v_just) not between 10 and 500 then
    raise exception 'Informe uma justificativa de 10 a 500 caracteres.';
  end if;
  select * into v_p from public.protocolos where id = p_protocolo_id for update;
  if not found then raise exception 'Protocolo não encontrado.'; end if;
  v_msg := public._checar_pin(v_uid, p_pin);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;

  select coalesce((select descricao_nova from public.correcoes_descricao
                    where protocolo_id = v_p.id order by id desc limit 1), v_p.descricao) into v_atual;
  if v_nova = v_atual then raise exception 'A nova descrição é igual à atual.'; end if;

  insert into public.correcoes_descricao (protocolo_id, descricao_anterior, descricao_nova, justificativa,
                                          usuario_id, usuario_nome, corrigido_em)
  values (v_p.id, v_atual, v_nova, v_just, v_uid, v_perfil.nome, v_agora);
  perform public._auditar(v_uid, v_perfil.nome, 'DESCRICAO_CORRIGIDA', v_p.id,
            jsonb_build_object('anterior', v_atual, 'nova', v_nova, 'justificativa', v_just));
  return jsonb_build_object('ok', true, 'id', v_p.id);
end $$;

-- O próprio usuário troca o seu PIN (exige o PIN atual)
create or replace function public.alterar_meu_pin(p_atual text, p_novo text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_uid uuid := auth.uid(); v_nome text; v_msg text;
begin
  select nome into v_nome from public.perfis where user_id = v_uid and ativo;
  if v_nome is null then raise exception 'Perfil não encontrado.' using errcode = '42501'; end if;
  if p_novo is null or p_novo !~ '^\d{4,6}$' then raise exception 'O novo PIN deve ter de 4 a 6 dígitos numéricos.'; end if;
  v_msg := public._checar_pin(v_uid, p_atual);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;
  update public.perfis set pin_hash = crypt(p_novo, gen_salt('bf', 10)) where user_id = v_uid;
  perform public._auditar(v_uid, v_nome, 'PIN_ALTERADO', null, '{}');
  return jsonb_build_object('ok', true);
end $$;

-- Registra no log que uma ficha/livro foi impresso ou exportado (LGPD: rastreabilidade)
create or replace function public.registrar_exportacao(
  p_tipo text, p_protocolo_id bigint default null, p_filtros text default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_uid uuid := auth.uid(); v_nome text;
begin
  select nome into v_nome from public.perfis where user_id = v_uid and ativo;
  if v_nome is null then raise exception 'Perfil não encontrado.' using errcode = '42501'; end if;
  if p_tipo not in ('FICHA', 'LIVRO') then raise exception 'Tipo inválido.'; end if;
  perform public._auditar(v_uid, v_nome, 'IMPRESSAO_' || p_tipo, p_protocolo_id,
            jsonb_build_object('filtros', left(coalesce(p_filtros, ''), 300)));
end $$;

-- Registra entrada/saída do sistema na trilha de auditoria
-- (tentativas de login que falham ficam no log do próprio Supabase Auth).
create or replace function public.registrar_acesso(p_evento text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_uid uuid := auth.uid(); v_nome text;
begin
  select nome into v_nome from public.perfis where user_id = v_uid and ativo;
  if v_nome is null then raise exception 'Perfil não encontrado.' using errcode = '42501'; end if;
  if p_evento not in ('LOGIN', 'LOGOUT', 'LOGOUT_INATIVIDADE') then raise exception 'Evento inválido.'; end if;
  perform public._auditar(v_uid, v_nome, p_evento, null, '{}');
end $$;

-- ---------------------------------------------------------------------
-- 7. VISÃO E RPCs DE LEITURA (SECURITY INVOKER => respeitam a RLS)
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
       (t3.assinatura_png is not null) as e3_png, t3.setor_nome as e3_setor
  from public.protocolos p
  left join public.tramites t1 on t1.protocolo_id = p.id and t1.etapa = 1
  left join public.tramites t2 on t2.protocolo_id = p.id and t2.etapa = 2
  left join public.tramites t3 on t3.protocolo_id = p.id and t3.etapa = 3;

create or replace function public.listar_livro(
  p_q text default null, p_status text default null,
  p_data_ini date default null, p_data_fim date default null,
  p_limite int default 25, p_offset int default 0)
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare v_like text; v_total bigint; v_itens jsonb;
begin
  p_limite := least(greatest(coalesce(p_limite, 25), 1), 500);
  p_offset := greatest(coalesce(p_offset, 0), 0);
  v_like := case when nullif(btrim(p_q), '') is null then null
                 else '%' || replace(replace(replace(left(btrim(p_q), 100), '\', '\\'), '%', '\%'), '_', '\_') || '%' end;

  select count(*) into v_total from public.v_livro v
   where (v_like is null or v.numero ilike v_like or v.descricao ilike v_like)
     and (p_status is null or v.status = p_status)
     and (p_data_ini is null or (v.created_at at time zone public._fuso())::date >= p_data_ini)
     and (p_data_fim is null or (v.created_at at time zone public._fuso())::date <= p_data_fim);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.id desc), '[]'::jsonb) into v_itens
    from (select * from public.v_livro v
           where (v_like is null or v.numero ilike v_like or v.descricao ilike v_like)
             and (p_status is null or v.status = p_status)
             and (p_data_ini is null or (v.created_at at time zone public._fuso())::date >= p_data_ini)
             and (p_data_fim is null or (v.created_at at time zone public._fuso())::date <= p_data_fim)
           order by v.id desc limit p_limite offset p_offset) x;

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
    'concluido',      count(*) filter (where status = 'concluido'))
  from public.v_livro
$$;

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
                from public.correcoes_descricao c where c.protocolo_id = p_id), '[]'::jsonb));
end $$;

-- Verifica a cadeia de hash da auditoria (somente gestor)
create or replace function public.verificar_auditoria() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r record; v_ant text := repeat('0', 64); v_total int := 0;
begin
  if public.meu_papel() is distinct from 'gestor' then
    raise exception 'Apenas o gestor pode verificar a auditoria.' using errcode = '42501';
  end if;
  for r in select * from public.auditoria order by id loop
    v_total := v_total + 1;
    if r.hash_anterior <> v_ant
       or r.hash <> public._hash_auditoria(v_ant, r.ocorrido_em, r.usuario_id, r.acao, r.protocolo_id, r.detalhes) then
      return jsonb_build_object('ok', false, 'total', v_total, 'primeira_falha_id', r.id);
    end if;
    v_ant := r.hash;
  end loop;
  return jsonb_build_object('ok', true, 'total', v_total, 'primeira_falha_id', null);
end $$;

-- ---------------------------------------------------------------------
-- 8. ADMINISTRAÇÃO (só pelo SQL Editor / service_role — NÃO exposto ao cliente)
-- ---------------------------------------------------------------------
-- Cria/atualiza o perfil de um usuário já criado em Authentication → Users.
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
  insert into public.perfis (user_id, nome, papel, setor_id, pin_hash)
  values (v_uid, btrim(p_nome), p_papel, v_setor, crypt(p_pin, gen_salt('bf', 10)))
  on conflict (user_id) do update
    set nome = excluded.nome, papel = excluded.papel, setor_id = excluded.setor_id,
        pin_hash = excluded.pin_hash, ativo = true, pin_falhas = 0, pin_bloqueado_ate = null;
  perform public._auditar(null, 'admin (SQL Editor)', 'PERFIL_CADASTRADO', null,
            jsonb_build_object('email', lower(btrim(p_email)), 'papel', p_papel, 'setor', p_setor));
  return 'Perfil de ' || p_email || ' (' || p_papel || ') cadastrado.';
end $$;

create or replace function public.admin_desativar_perfil(p_email text, p_ativo boolean default false) returns text
language plpgsql security definer set search_path = public as $$
begin
  update public.perfis set ativo = p_ativo where user_id = (select id from auth.users where lower(email) = lower(btrim(p_email)));
  if not found then raise exception 'Perfil não encontrado.'; end if;
  perform public._auditar(null, 'admin (SQL Editor)', case when p_ativo then 'PERFIL_REATIVADO' else 'PERFIL_DESATIVADO' end,
            null, jsonb_build_object('email', lower(btrim(p_email))));
  return 'ok';
end $$;

create or replace function public.admin_desbloquear_pin(p_email text) returns text
language plpgsql security definer set search_path = public as $$
begin
  update public.perfis set pin_falhas = 0, pin_bloqueado_ate = null
   where user_id = (select id from auth.users where lower(email) = lower(btrim(p_email)));
  if not found then raise exception 'Perfil não encontrado.'; end if;
  return 'ok';
end $$;

-- ---------------------------------------------------------------------
-- 9. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------
alter table public.setores             enable row level security;
alter table public.perfis              enable row level security;
alter table public.sequencias          enable row level security;
alter table public.protocolos          enable row level security;
alter table public.tramites            enable row level security;
alter table public.correcoes_descricao enable row level security;
alter table public.auditoria           enable row level security;

drop policy if exists p_setores_select on public.setores;
create policy p_setores_select on public.setores for select to authenticated
  using (public.meu_papel() is not null);

drop policy if exists p_perfis_select on public.perfis;
create policy p_perfis_select on public.perfis for select to authenticated
  using (user_id = auth.uid() or public.meu_papel() = 'gestor');

drop policy if exists p_protocolos_select on public.protocolos;
create policy p_protocolos_select on public.protocolos for select to authenticated
  using (public.pode_ver_protocolo(id));

drop policy if exists p_tramites_select on public.tramites;
create policy p_tramites_select on public.tramites for select to authenticated
  using (public.pode_ver_protocolo(protocolo_id));

drop policy if exists p_correcoes_select on public.correcoes_descricao;
create policy p_correcoes_select on public.correcoes_descricao for select to authenticated
  using (public.pode_ver_protocolo(protocolo_id));

drop policy if exists p_auditoria_select on public.auditoria;
create policy p_auditoria_select on public.auditoria for select to authenticated
  using (public.meu_papel() = 'gestor');
-- Sem NENHUMA policy de INSERT/UPDATE/DELETE: o cliente só escreve via RPC.
-- 'sequencias' não tem policy alguma: inacessível ao cliente.

-- ---------------------------------------------------------------------
-- 10. PRIVILÉGIOS (camada extra além da RLS)
-- ---------------------------------------------------------------------
revoke all on all tables    in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

alter default privileges in schema public revoke all on tables    from public, anon, authenticated;
alter default privileges in schema public revoke all on sequences from public, anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;

grant usage on schema public to authenticated;
grant select on public.setores, public.protocolos, public.tramites,
                public.correcoes_descricao, public.auditoria, public.v_livro to authenticated;
-- perfis: o cliente NÃO pode ler pin_hash / contadores (privilégio por coluna)
grant select (user_id, nome, papel, setor_id, ativo) on public.perfis to authenticated;

grant execute on function
  public.meu_papel(), public.meu_setor(), public.pode_ver_protocolo(bigint),
  public.registrar_protocolo(text, text, text), public.confirmar_etapa(bigint, int, text, text),
  public.corrigir_descricao(bigint, text, text, text), public.alterar_meu_pin(text, text),
  public.registrar_exportacao(text, bigint, text), public.registrar_acesso(text),
  public.listar_livro(text, text, date, date, int, int), public.resumo_livro(),
  public.detalhe_protocolo(bigint), public.verificar_auditoria(),
  public._fuso()
  to authenticated;

-- ---------------------------------------------------------------------
-- 11. DADOS INICIAIS (exemplos — ajuste os setores à sua unidade)
-- ---------------------------------------------------------------------
insert into public.setores (nome) values
  ('Jurídico'), ('Diretoria'), ('Recursos Humanos'), ('Farmácia')
on conflict (nome) do nothing;

-- =====================================================================
-- RESET (CUIDADO: apaga TODOS os dados). Descomente só se quiser recomeçar.
-- =====================================================================
-- drop view if exists public.v_livro;
-- drop table if exists public.auditoria, public.correcoes_descricao, public.tramites,
--   public.protocolos, public.sequencias, public.perfis, public.setores cascade;
