#!/usr/bin/env bash
# Backup & restore verification (Layer 8 — proves RPO is achievable).
# Backups you never restore are not backups. This:
#   1. seeds a row in the demo Postgres
#   2. pg_dumps it
#   3. restores the dump into a throwaway database
#   4. verifies the row survived the round-trip
# Mirrors the production CronJob in ../k3s/manifests/backup-cronjob.yaml.
set -euo pipefail
cd "$(dirname "$0")/.."

PG=sre-demo-postgres
PG_USER="$(grep -E '^PG_USER=' .env.sre 2>/dev/null | cut -d= -f2)"; PG_USER="${PG_USER:-sre}"
PG_DB="$(grep -E '^PG_DB=' .env.sre 2>/dev/null | cut -d= -f2)"; PG_DB="${PG_DB:-sre}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TOKEN="backup_probe_${STAMP}"

run() { docker exec -i -e PGPASSWORD="${PG_PASSWORD:-sre}" "$PG" "$@"; }

echo "▶ Seeding probe row ($TOKEN)…"
run psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -c \
  "CREATE TABLE IF NOT EXISTS backup_probe(id serial primary key, token text, created_at timestamptz default now());" >/dev/null
run psql -U "$PG_USER" -d "$PG_DB" -c "INSERT INTO backup_probe(token) VALUES ('$TOKEN');" >/dev/null

echo "▶ pg_dump → /tmp/${TOKEN}.sql"
run pg_dump -U "$PG_USER" -d "$PG_DB" > "/tmp/${TOKEN}.sql"
SIZE=$(wc -c < "/tmp/${TOKEN}.sql")
echo "  dump size: ${SIZE} bytes"

echo "▶ Restoring into throwaway DB restore_${STAMP}…"
run psql -U "$PG_USER" -d "$PG_DB" -c "DROP DATABASE IF EXISTS restore_${STAMP};" >/dev/null 2>&1 || true
run createdb -U "$PG_USER" "restore_${STAMP}"
docker exec -i -e PGPASSWORD="${PG_PASSWORD:-sre}" "$PG" \
  psql -U "$PG_USER" -d "restore_${STAMP}" < "/tmp/${TOKEN}.sql" >/dev/null

echo "▶ Verifying probe row survived the round-trip…"
FOUND=$(run psql -U "$PG_USER" -d "restore_${STAMP}" -tAc \
  "SELECT count(*) FROM backup_probe WHERE token='$TOKEN';")
run psql -U "$PG_USER" -d "$PG_DB" -c "DROP DATABASE IF EXISTS restore_${STAMP};" >/dev/null 2>&1 || true

if [ "${FOUND// /}" = "1" ]; then
  echo "✓ RESTORE VERIFIED — backup is recoverable (RPO objective met)."
else
  echo "✗ RESTORE FAILED — probe row not found after restore!"; exit 1
fi
