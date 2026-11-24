-- Simula, num PostgreSQL comum, o mínimo do Supabase que o schema.sql precisa.
-- SÓ PARA TESTES LOCAIS — NÃO execute no Supabase real (ele já tem tudo isso).
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon')          then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role')  then create role service_role nologin bypassrls; end if;
end $$;
create schema if not exists auth;
create table if not exists auth.users (
  instance_id uuid, id uuid primary key default gen_random_uuid(), aud text, role text, email text unique,
  encrypted_password text, email_confirmed_at timestamptz, last_sign_in_at timestamptz, banned_until timestamptz,
  raw_app_meta_data jsonb, raw_user_meta_data jsonb, created_at timestamptz default now(), updated_at timestamptz default now(),
  confirmation_token varchar, recovery_token varchar, email_change varchar, email_change_token_new varchar);
create table if not exists auth.identities (
  id uuid primary key, user_id uuid references auth.users(id) on delete cascade, provider_id text, identity_data jsonb,
  provider text, last_sign_in_at timestamptz, created_at timestamptz, updated_at timestamptz);
create table if not exists auth.sessions (id uuid primary key default gen_random_uuid(), user_id uuid references auth.users(id) on delete cascade);
create table if not exists auth.mfa_factors (id uuid primary key default gen_random_uuid(), user_id uuid references auth.users(id) on delete cascade,
  friendly_name text, factor_type text default 'totp', status text default 'unverified', created_at timestamptz default now());
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create schema if not exists extensions;
grant usage on schema auth, extensions to anon, authenticated, service_role;

-- Storage (stub mínimo)
create schema if not exists storage;
create table if not exists storage.buckets (id text primary key, name text, public boolean default false,
  file_size_limit bigint, allowed_mime_types text[]);
create table if not exists storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text,
  owner uuid, metadata jsonb default '{}'::jsonb);
alter table storage.objects enable row level security;
create or replace function storage.foldername(name text) returns text[] language sql immutable as
$$ select string_to_array(name, '/') $$;
grant usage on schema storage to anon, authenticated, service_role;
grant select, insert, delete on storage.objects to authenticated;

-- pg_net (stub mínimo): registra a requisição e responde 201 na hora. SÓ PARA TESTES LOCAIS.
create schema if not exists net;
create table if not exists net.http_log (id bigint generated always as identity primary key, url text, body jsonb, headers jsonb);
create table if not exists net._http_response (id bigint primary key, status_code int, content text, timed_out boolean, error_msg text, created timestamptz default now());
create or replace function net.http_post(url text, body jsonb default '{}', params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 5000)
returns bigint language plpgsql as $$
declare v bigint;
begin
  insert into net.http_log (url, body, headers) values (url, body, headers) returning id into v;
  insert into net._http_response (id, status_code, content) values (v, case when headers->>'api-key' like 'chave-ruim%' then 401 else 201 end, '{"messageId":"x"}');
  return v;
end $$;
