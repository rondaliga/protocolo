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
psql -v ON_ERROR_STOP=1 -q -d $DB -f 02_testes.sql 2>&1 | sed -E 's/^psql:[^ ]+ [0-9]+: //'
psql -qc "drop database $DB" postgres
