#!/usr/bin/env bash
# Cria o banco do teste E2E (stubs do Supabase + schema.sql + usuários de teste). Rode com acesso ao psql.
set -euo pipefail
cd "$(dirname "$0")/../../supabase"
DB=${1:-protocolo_e2e}
psql -v ON_ERROR_STOP=1 -qc "drop database if exists $DB" postgres
psql -v ON_ERROR_STOP=1 -qc "create database $DB" postgres
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f tests/00_stubs_supabase.sql
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f schema.sql >/dev/null 2>&1
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f 02_prazos_alertas.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f 03_painel_gestor.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f 04_logo_horas_exclusoes.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f 05_melhorias.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f 06_inatividade.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f 07_mfa.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f 08_fluxo.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$DB" >/dev/null <<'SQL'
insert into auth.users (email) values ('portaria@teste.local'),('adm@teste.local'),('juridico@teste.local'),('farmacia@teste.local'),('gestor@teste.local');
select public.admin_cadastrar_perfil('portaria@teste.local','Maria (Portaria)','portaria',null,'1111');
select public.admin_cadastrar_perfil('adm@teste.local','João (Administração)','adm',null,'2222');
select public.admin_cadastrar_perfil('juridico@teste.local','Ana (Jurídico)','super_setor','Jurídico','3333');
select public.admin_cadastrar_perfil('farmacia@teste.local','Carlos (Farmácia)','super_setor','Farmácia','4444');
select public.admin_cadastrar_perfil('gestor@teste.local','Paula (Gestão)','gestor',null,'5555');
SQL
psql -v ON_ERROR_STOP=1 -q -d "$DB" -c "update auth.users set encrypted_password = extensions.crypt('Trocar@123', extensions.gen_salt('bf'))"
echo "banco $DB pronto"
