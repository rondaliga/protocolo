#!/usr/bin/env bash
# Cria o banco do teste E2E (stubs do Supabase + schema.sql + usuários de teste). Rode com acesso ao psql.
set -euo pipefail
cd "$(dirname "$0")/../../supabase"
DB=${1:-protocolo_e2e}
psql -v ON_ERROR_STOP=1 -qc "drop database if exists $DB" postgres
psql -v ON_ERROR_STOP=1 -qc "create database $DB" postgres
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f tests/00_stubs_supabase.sql
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f schema.sql >/dev/null 2>&1
psql -v ON_ERROR_STOP=1 -q -d "$DB" >/dev/null <<'SQL'
insert into auth.users (email) values ('portaria@teste.local'),('adm@teste.local'),('juridico@teste.local'),('farmacia@teste.local'),('gestor@teste.local');
select public.admin_cadastrar_perfil('portaria@teste.local','Maria (Portaria)','portaria',null,'1111');
select public.admin_cadastrar_perfil('adm@teste.local','João (Administração)','adm',null,'2222');
select public.admin_cadastrar_perfil('juridico@teste.local','Ana (Jurídico)','super_setor','Jurídico','3333');
select public.admin_cadastrar_perfil('farmacia@teste.local','Carlos (Farmácia)','super_setor','Farmácia','4444');
select public.admin_cadastrar_perfil('gestor@teste.local','Paula (Gestão)','gestor',null,'5555');
SQL
echo "banco $DB pronto"
