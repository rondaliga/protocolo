#!/usr/bin/env bash
# Backup cifrado do banco (schema public: protocolos, etapas, trilha, parâmetros, perfis, setores, logotipo).
# Uso:  SUPABASE_DB_URL=postgresql://... BACKUP_PASSPHRASE=... bash scripts/backup_pg.sh [pasta_de_saida]
# Gera  <pasta>/protocolo-AAAAMMDD-HHMM.dump.gpg  (AES-256). O arquivo SEM cifra nunca fica no disco depois do script.
# NÃO inclui as fotos do Storage (o pg_dump só leva o banco) nem as senhas dos usuários (schema auth).
# Para restaurar: veja a seção "Backup agendado" do README (gpg -d ... | pg_restore).
set -euo pipefail

: "${SUPABASE_DB_URL:?Defina SUPABASE_DB_URL (string de conexão do banco)}"
: "${BACKUP_PASSPHRASE:?Defina BACKUP_PASSPHRASE (frase longa para cifrar o backup)}"
if [ "${#BACKUP_PASSPHRASE}" -lt 16 ]; then echo "ERRO: BACKUP_PASSPHRASE deve ter pelo menos 16 caracteres." >&2; exit 2; fi

saida="${1:-backups}"; mkdir -p "$saida"
carimbo="$(date -u +%Y%m%d-%H%M)"
bruto="$(mktemp "${TMPDIR:-/tmp}/protocolo.XXXXXX")"
trap 'shred -u "$bruto" 2>/dev/null || rm -f "$bruto"' EXIT

pg_dump --dbname="$SUPABASE_DB_URL" --schema=public --format=custom --no-owner --no-privileges --file="$bruto"

# confere que o dump é legível e que a trilha de auditoria está dentro (um backup vazio seria pior que nenhum)
lista="$(pg_restore --list "$bruto")"
for tabela in protocolos auditoria tramites perfis parametros; do
  grep -q "TABLE DATA public $tabela " <<<"$lista" || { echo "ERRO: tabela $tabela ausente no dump." >&2; exit 3; }
done

alvo="$saida/protocolo-$carimbo.dump.gpg"
gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 \
    --output "$alvo" "$bruto" 3<<<"$BACKUP_PASSPHRASE"

# prova de restauração: decifra e lista o conteúdo
gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 --decrypt "$alvo" 3<<<"$BACKUP_PASSPHRASE" | pg_restore --list >/dev/null
echo "backup ok: $alvo ($(du -h "$alvo" | cut -f1))"
