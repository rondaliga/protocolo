#!/usr/bin/env bash
# Valida supabase/schema.sql num PostgreSQL local descartável (precisa de psql e de um servidor PG 15+).
# Uso:  PGHOST=localhost PGUSER=postgres ./run_local.sh      (cria e apaga o banco "protocolo_teste")
set -euo pipefail
cd "$(dirname "$0")"
DB=protocolo_teste
psql -v ON_ERROR_STOP=1 -qc "drop database if exists $DB" postgres
psql -v ON_ERROR_STOP=1 -qc "create database $DB" postgres
psql -v ON_ERROR_STOP=1 -q -d $DB -f 00_stubs_supabase.sql
psql -v ON_ERROR_STOP=1 -q -d $DB -f ../schema.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d $DB -f ../02_prazos_alertas.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d $DB -f ../03_painel_gestor.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d $DB -f ../04_logo_horas_exclusoes.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d $DB -f ../05_melhorias.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d $DB -f ../05_melhorias.sql >/dev/null   # idempotente: segunda execução também deve passar
psql -v ON_ERROR_STOP=1 -q -d $DB -f ../06_inatividade.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d $DB -f ../06_inatividade.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d $DB -f ../07_mfa.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d $DB -f ../07_mfa.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d $DB -f ../08_fluxo.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d $DB -f ../08_fluxo.sql >/dev/null
psql -v ON_ERROR_STOP=1 -q -d $DB -f 02_testes.sql 2>&1 | sed -E 's/^psql:[^ ]+ [0-9]+: //'
psql -qc "drop database $DB" postgres
