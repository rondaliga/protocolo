-- =====================================================================
-- INSTALAÇÃO COMPLETA (gerado por scripts/gerar_instalacao.py — não edite à mão)
-- Ordem: schema.sql → 02_prazos_alertas.sql → 03_painel_gestor.sql → 04_logo_horas_exclusoes.sql → 05_melhorias.sql → 06_inatividade.sql → 07_mfa.sql → 08_fluxo.sql → 09_alertas_imediatos.sql → 10_relatorios_push_diagnostico.sql
-- =====================================================================

-- >>>>>>>>>> schema.sql >>>>>>>>>>
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
-- 1b. IDENTIDADE EFETIVA (verificação em duas etapas)
--     Todas as políticas e funções usam public._uid() no lugar de auth.uid().
--     Ela devolve o usuário só quando o acesso está completo: se o usuário tem a verificação em duas etapas
--     ativa (ou é gestor e o parâmetro "mfa_gestor_obrigatorio" está ligado) e a sessão ainda não passou
--     pelo código (aal1), devolve NULL — o servidor trata a sessão como não autenticada, mesmo com a senha certa.
-- ---------------------------------------------------------------------
create or replace function public._uid() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_aal text; v_exige boolean := false;
begin
  if v_uid is null then return null; end if;
  begin
    v_aal := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'aal', 'aal1');
  exception when others then v_aal := 'aal1'; end;
  if v_aal = 'aal2' then return v_uid; end if;
  if exists (select 1 from auth.mfa_factors where user_id = v_uid and status::text = 'verified') then return null; end if;
  begin
    select (valor = 'true') into v_exige from public.parametros where chave = 'mfa_gestor_obrigatorio';
    if coalesce(v_exige, false) and exists (select 1 from public.perfis where user_id = v_uid and ativo and papel = 'gestor') then return null; end if;
  exception when undefined_table then null; end;
  return v_uid;
end $$;

-- ---------------------------------------------------------------------
-- 2. FUNÇÕES AUXILIARES DE PERFIL (usadas pelas políticas RLS)
--    SECURITY DEFINER evita recursão de RLS entre as tabelas.
-- ---------------------------------------------------------------------
create or replace function public.meu_papel() returns text
language sql stable security definer set search_path = public as $$
  select papel from public.perfis where user_id = public._uid() and ativo
$$;

create or replace function public.meu_setor() returns bigint
language sql stable security definer set search_path = public as $$
  select setor_id from public.perfis where user_id = public._uid() and ativo
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
  v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_desc text; v_png text; v_msg text;
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
  v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_p public.protocolos%rowtype;
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
  v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_p public.protocolos%rowtype;
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
declare v_uid uuid := public._uid(); v_nome text; v_msg text;
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
declare v_uid uuid := public._uid(); v_nome text;
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
declare v_uid uuid := public._uid(); v_nome text;
begin
  select nome into v_nome from public.perfis where user_id = v_uid and ativo;
  if v_nome is null then raise exception 'Perfil não encontrado.' using errcode = '42501'; end if;
  if p_evento not in ('LOGIN', 'LOGOUT', 'LOGOUT_INATIVIDADE') then raise exception 'Evento inválido.'; end if;
  perform public._auditar(v_uid, v_nome, p_evento, null, '{}');
end $$;

-- ---------------------------------------------------------------------
-- 7. VISÃO E RPCs DE LEITURA (SECURITY INVOKER => respeitam a RLS)
-- ---------------------------------------------------------------------
-- (drop antes: o CREATE OR REPLACE não permite remover colunas; o 02 recria a visão ampliada)
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
  using (user_id = public._uid() or public.meu_papel() = 'gestor');

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
grant execute on function public._uid() to anon, authenticated;     -- usada por todas as políticas RLS
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

-- >>>>>>>>>> 02_prazos_alertas.sql >>>>>>>>>>
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
              and (storage.foldername(name))[1] = public._uid()::text);

-- Lê quem enviou (a própria pasta) ou quem pode ver o protocolo ao qual a foto foi vinculada
drop policy if exists fotos_select on storage.objects;
create policy fotos_select on storage.objects for select to authenticated
  using (bucket_id = 'protocolo-fotos'
         and ((storage.foldername(name))[1] = public._uid()::text
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
  v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_desc text; v_png text; v_msg text;
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
  v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_p public.protocolos%rowtype;
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
  v_uid uuid := public._uid(); v_perfil public.perfis%rowtype; v_p public.protocolos%rowtype;
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

-- >>>>>>>>>> 03_painel_gestor.sql >>>>>>>>>>
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

-- >>>>>>>>>> 04_logo_horas_exclusoes.sql >>>>>>>>>>
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

-- >>>>>>>>>> 05_melhorias.sql >>>>>>>>>>
-- =====================================================================
-- 05 · MELHORIAS: controle de versão do schema, índices, backup e retenção (LGPD)
-- Rode DEPOIS de schema.sql → 02 → 03 → 04. É idempotente: pode ser reexecutado.
-- =====================================================================

-- 1. Controle de versão: registra quais arquivos já foram aplicados ----------------------------
create table if not exists public.schema_versao (
  versao      int primary key,
  arquivo     text not null,
  aplicado_em timestamptz not null default now()
);
alter table public.schema_versao enable row level security;      -- sem políticas: só funções do servidor leem
revoke all on public.schema_versao from anon, authenticated;
insert into public.schema_versao (versao, arquivo) values
  (1, 'schema.sql'), (2, '02_prazos_alertas.sql'), (3, '03_painel_gestor.sql'),
  (4, '04_logo_horas_exclusoes.sql'), (5, '05_melhorias.sql')
on conflict (versao) do nothing;

create or replace function public.versao_schema() returns int
language sql stable security definer set search_path = public as $$
  select coalesce(max(versao), 0) from public.schema_versao
$$;

-- 2. Índices para os filtros e junções mais usados ----------------------------------------------
create index if not exists ix_protocolos_setor_destino on public.protocolos(setor_destino_id) where setor_destino_id is not null;
create index if not exists ix_protocolos_criador       on public.protocolos(created_by);
create index if not exists ix_tramites_protocolo       on public.tramites(protocolo_id);
create index if not exists ix_fotos_protocolo          on public.protocolo_fotos(protocolo_id);
create index if not exists ix_auditoria_ocorrido       on public.auditoria(ocorrido_em desc);
create index if not exists ix_auditoria_acao           on public.auditoria(acao, ocorrido_em desc);

-- 3. Backup (somente gestor): protocolos, etapas e trilha em JSON; o ato fica registrado ---------
create or replace function public.exportar_backup() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_perfil public.perfis%rowtype; v_prot jsonb; v_tram jsonb; v_aud jsonb;
begin
  select * into v_perfil from public.perfis where user_id = public._uid() and ativo;
  if not found or v_perfil.papel <> 'gestor' then
    raise exception 'Apenas o gestor pode exportar o backup.' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(to_jsonb(p) order by p.id), '[]'::jsonb) into v_prot from public.protocolos p;
  -- a imagem da assinatura não entra no backup leve (continua no banco); o selo de integridade segue junto
  select coalesce(jsonb_agg((to_jsonb(t) - 'assinatura_png') order by t.id), '[]'::jsonb) into v_tram from public.tramites t;
  select coalesce(jsonb_agg(to_jsonb(a) order by a.id), '[]'::jsonb) into v_aud from public.auditoria a;
  perform public._auditar(public._uid(), v_perfil.nome, 'BACKUP_EXPORTADO', null,
            jsonb_build_object('protocolos', jsonb_array_length(v_prot), 'tramites', jsonb_array_length(v_tram),
                               'eventos', jsonb_array_length(v_aud)));
  return jsonb_build_object('gerado_em', now(), 'versao_schema', public.versao_schema(),
                            'protocolos', v_prot, 'tramites', v_tram, 'auditoria', v_aud);
end $$;

-- 4. Retenção (LGPD): quantos protocolos concluídos passaram do prazo de guarda -------------------
-- Apenas informa; a exclusão continua sendo ato explícito do gestor (excluir_protocolo), com justificativa e PIN.
create or replace function public.retencao_resumo(p_meses int default 60) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_perfil public.perfis%rowtype; v_corte timestamptz; v_n int; v_f int; v_mais timestamptz;
begin
  select * into v_perfil from public.perfis where user_id = public._uid() and ativo;
  if not found or v_perfil.papel <> 'gestor' then
    raise exception 'Apenas o gestor pode consultar a retenção.' using errcode = '42501';
  end if;
  if p_meses is null or p_meses not between 1 and 600 then raise exception 'Informe o prazo de guarda entre 1 e 600 meses.'; end if;
  v_corte := now() - make_interval(months => p_meses);
  select count(*), min(p.created_at) into v_n, v_mais from public.protocolos p
   where p.status = 'concluido' and p.created_at < v_corte;
  select count(*) into v_f from public.protocolo_fotos f join public.protocolos p on p.id = f.protocolo_id
   where p.status = 'concluido' and p.created_at < v_corte;
  return jsonb_build_object('meses', p_meses, 'corte', v_corte, 'protocolos', v_n, 'fotos', v_f, 'mais_antigo', v_mais);
end $$;

-- 5. Permissões -------------------------------------------------------------------------------------
revoke all on function public.versao_schema(), public.exportar_backup(), public.retencao_resumo(int)
  from public, anon, authenticated;
grant execute on function public.versao_schema(), public.exportar_backup(), public.retencao_resumo(int) to authenticated;

-- >>>>>>>>>> 06_inatividade.sql >>>>>>>>>>
-- =====================================================================
-- 06 · TEMPO DE INATIVIDADE AJUSTÁVEL (logout automático)
-- Rode DEPOIS de schema.sql → 02 → 03 → 04 → 05. Idempotente.
-- O gestor ajusta o tempo em "Prazos e regras"; o padrão passa a ser 6 horas.
-- =====================================================================

insert into public.parametros (chave, valor, descricao) values
  ('sessao_inatividade_min', '6:00', 'Tempo sem uso (horas:minutos) após o qual o sistema encerra a sessão. De 5 min a 24 h.')
on conflict (chave) do nothing;

-- Quem ainda estava no padrão antigo de 30 minutos do navegador não tem valor no banco: passa a valer o padrão acima.

-- validação e tipo do novo parâmetro (cópias das funções do 04 com o ramo novo)
create or replace function public._validar_parametro(p_chave text, p_valor text) returns text
language plpgsql stable security definer set search_path = public as $$
declare v text := btrim(coalesce(p_valor, '')); n int; t time; m int;
begin
  if not exists (select 1 from public.parametros where chave = p_chave) then
    raise exception 'Parâmetro desconhecido: %.', p_chave;
  end if;
  if p_chave = 'url_sistema' then
    if v <> '' and v !~ '^https://[^\s]+$' then raise exception 'O endereço do sistema deve começar com https://'; end if;
  elsif p_chave in ('foto_obrigatoria_judicial', 'gestor_ignora_segregacao', 'mfa_gestor_obrigatorio') then
    if v not in ('true', 'false') then raise exception 'Use true ou false.'; end if;
  elsif p_chave in ('expediente_inicio', 'expediente_fim') then
    t := public._parse_hhmm(v);
    if t is null then raise exception 'Hora inválida. Use um formato como 08:00, 8h30 ou 17.'; end if;
    v := public._fmt_hhmm(t);
  elsif p_chave = 'sessao_inatividade_min' then
    if v ~* '\d\s*(d|dia|dias)$' then raise exception 'Use horas ou minutos (por exemplo 6h, 6:00 ou 90min); "dia" não vale aqui.'; end if;
    m := public._parse_duracao_min(v);
    if m is null then raise exception 'Tempo inválido. Use um formato como 6h, 6:00, 90min ou 1,5.'; end if;
    if m < 5 then raise exception 'O tempo de inatividade deve ser de pelo menos 5 minutos.'; end if;
    if m > 1440 then raise exception 'O tempo de inatividade não pode passar de 24 horas.'; end if;
    v := public._fmt_duracao(m);
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
              when p_chave in ('foto_obrigatoria_judicial', 'gestor_ignora_segregacao', 'mfa_gestor_obrigatorio') then 'booleano'
              when p_chave in ('expediente_inicio', 'expediente_fim') then 'hora'
              when p_chave like 'sla\_%\_min' or p_chave = 'sessao_inatividade_min' then 'duracao'
              else 'numero' end
$$;


-- lido por qualquer usuário logado (o navegador aplica o tempo ao entrar)
create or replace function public.sessao_config() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('inatividade_min', public._param_min('sessao_inatividade_min', 360))
$$;

insert into public.schema_versao (versao, arquivo) values (6, '06_inatividade.sql') on conflict (versao) do nothing;

revoke all on function public.sessao_config() from public, anon;
grant execute on function public.sessao_config() to authenticated;

-- >>>>>>>>>> 07_mfa.sql >>>>>>>>>>
-- =====================================================================
-- 07 · VERIFICAÇÃO EM DUAS ETAPAS (TOTP) — apoio no banco
-- Rode DEPOIS de schema.sql → 02 → 03 → 04 → 05 → 06. Idempotente.
-- O cadastro e a conferência do código ficam no Supabase Auth (MFA/TOTP). Aqui o banco:
--   • recusa sessões sem o código quando ele é exigido (função public._uid(), definida no schema.sql);
--   • guarda o parâmetro "mfa_gestor_obrigatorio";
--   • registra na trilha quem ativou/desativou; permite ao gestor redefinir o acesso de quem perdeu o aparelho.
-- =====================================================================

insert into public.parametros (chave, valor, descricao) values
  ('mfa_gestor_obrigatorio', 'false', 'Quando "true", todo gestor precisa ter a verificação em duas etapas (código do aplicativo autenticador) para entrar.')
on conflict (chave) do nothing;

-- Situação do usuário logado. Usa o auth.uid() cru de propósito: precisa responder também antes do código (aal1).
create or replace function public.mfa_estado() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_aal text; v_tem boolean; v_gestor boolean; v_exige boolean;
begin
  if v_uid is null then raise exception 'Sessão inválida.' using errcode = '28000'; end if;
  begin v_aal := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'aal', 'aal1');
  exception when others then v_aal := 'aal1'; end;
  v_tem := exists (select 1 from auth.mfa_factors where user_id = v_uid and status::text = 'verified');
  v_gestor := exists (select 1 from public.perfis where user_id = v_uid and ativo and papel = 'gestor');
  v_exige := v_gestor and coalesce((select valor = 'true' from public.parametros where chave = 'mfa_gestor_obrigatorio'), false);
  return jsonb_build_object('aal', v_aal, 'tem_fator', v_tem, 'exigido', v_exige, 'gestor', v_gestor);
end $$;

-- Quem ativou ou desativou: o próprio usuário (já com o código) avisa a trilha; o banco confere o estado real.
create or replace function public.mfa_registrar_evento(p_evento text) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public._uid(); v_nome text; v_tem boolean;
begin
  if v_uid is null then raise exception 'Sessão inválida.' using errcode = '28000'; end if;
  select nome into v_nome from public.perfis where user_id = v_uid and ativo;
  if v_nome is null then raise exception 'Usuário sem perfil ativo.'; end if;
  v_tem := exists (select 1 from auth.mfa_factors where user_id = v_uid and status::text = 'verified');
  if p_evento = 'MFA_ATIVADO' and v_tem then perform public._auditar(v_uid, v_nome, 'MFA_ATIVADO', null, '{}'::jsonb);
  elsif p_evento = 'MFA_DESATIVADO' and not v_tem then perform public._auditar(v_uid, v_nome, 'MFA_DESATIVADO', null, '{}'::jsonb);
  else raise exception 'Evento não confere com a situação atual da verificação em duas etapas.'; end if;
end $$;

-- Gestor: quais usuários têm a verificação ativa (para o selo na lista de usuários)
create or replace function public.painel_mfa_usuarios() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare g public.perfis%rowtype := public._exigir_gestor();
begin
  return coalesce((select jsonb_agg(distinct user_id) from auth.mfa_factors where status::text = 'verified'), '[]'::jsonb);
end $$;

-- Gestor: redefine a verificação de OUTRO usuário (perdeu o celular). Ele entra só com senha e cadastra de novo.
create or replace function public.painel_resetar_mfa(p_user_id uuid, p_pin_gestor text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare g public.perfis%rowtype := public._exigir_gestor(); a public.perfis%rowtype; v_msg text; v_n int;
begin
  select * into a from public.perfis where user_id = p_user_id;
  if not found then raise exception 'Usuário não encontrado.'; end if;
  if a.user_id = g.user_id then raise exception 'Peça a outro gestor para redefinir a sua verificação em duas etapas.'; end if;
  v_msg := public._checar_pin(g.user_id, p_pin_gestor);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;
  delete from auth.mfa_factors where user_id = p_user_id; get diagnostics v_n = row_count;
  delete from auth.sessions where user_id = p_user_id;                   -- derruba as sessões abertas
  perform public._auditar(g.user_id, g.nome, 'MFA_REDEFINIDO', null, jsonb_build_object('email', a.email, 'nome', a.nome, 'fatores', v_n));
  return jsonb_build_object('ok', true, 'fatores', v_n);
end $$;

-- Recuperação pelo SQL Editor (último recurso, ex.: único gestor perdeu o celular):
--   select public.admin_resetar_mfa('gestor@exemplo.com');
create or replace function public.admin_resetar_mfa(p_email text) returns int
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_n int;
begin
  select user_id into v_id from public.perfis where lower(email) = lower(p_email);
  if v_id is null then raise exception 'E-mail não encontrado.'; end if;
  delete from auth.mfa_factors where user_id = v_id; get diagnostics v_n = row_count;
  delete from auth.sessions where user_id = v_id;
  perform public._auditar(null, 'SQL Editor', 'MFA_REDEFINIDO', null, jsonb_build_object('email', lower(p_email), 'fatores', v_n));
  return v_n;
end $$;

insert into public.schema_versao (versao, arquivo) values (7, '07_mfa.sql') on conflict (versao) do nothing;

revoke all on function public.mfa_estado(), public.mfa_registrar_evento(text), public.painel_mfa_usuarios(),
  public.painel_resetar_mfa(uuid, text), public.admin_resetar_mfa(text) from public, anon, authenticated;
grant execute on function public.mfa_estado(), public.mfa_registrar_evento(text), public.painel_mfa_usuarios(),
  public.painel_resetar_mfa(uuid, text) to authenticated;

-- >>>>>>>>>> 08_fluxo.sql >>>>>>>>>>
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

-- >>>>>>>>>> 09_alertas_imediatos.sql >>>>>>>>>>
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
  update public.email_brevo set ativo = false, atualizado_em = now() where id = 1;
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

-- >>>>>>>>>> 10_relatorios_push_diagnostico.sql >>>>>>>>>>
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
  update public.push_config set ativo = false, atualizado_em = now() where id = 1;
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
