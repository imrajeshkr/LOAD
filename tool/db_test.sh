#!/usr/bin/env bash
# Run a SQL test file against the Load database inside a transaction that is
# ALWAYS rolled back. Any migrations passed with -m are applied first, in the
# same transaction, so a test exercises the migration without persisting it.
#
#   ./tool/db_test.sh supabase/tests/foo_test.sql
#   ./tool/db_test.sh -m supabase/migrations_v2/v2_0021_x.sql supabase/tests/foo_test.sql
set -euo pipefail
cd "$(dirname "$0")/.."

MIGRATIONS=()
while [ "${1:-}" = "-m" ]; do MIGRATIONS+=("$2"); shift 2; done
TEST_FILE="${1:?usage: db_test.sh [-m migration.sql]... <test.sql>}"

# A file containing its own COMMIT closes the wrapping transaction below, and
# everything after it is written to the live database while this script still
# prints "rolled back, nothing persisted". That has happened once: a generated
# migration carried begin/commit and its inserts went to production during what
# was supposed to be a dry run. The harness owns the transaction — refuse any
# file that tries to own it too.
for f in "${MIGRATIONS[@]:-}" "$TEST_FILE"; do
  [ -n "$f" ] || continue
  if grep -Eqi '^[[:space:]]*(commit|begin|rollback|end)[[:space:]]*;' "$f"; then
    echo "refusing to run $f: it contains its own transaction control." >&2
    echo "db_test.sh wraps files in BEGIN/ROLLBACK; an inner COMMIT would" >&2
    echo "persist changes during a dry run. Remove it and re-run." >&2
    exit 3
  fi
done

PW=$(grep -m1 '^LOAD_SUPABASE_DB_PASSWORD=' .env | cut -d= -f2- \
     | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
[ -n "$PW" ] || { echo "LOAD_SUPABASE_DB_PASSWORD not found in .env" >&2; exit 2; }

CONN="host=aws-0-ap-northeast-1.pooler.supabase.com port=5432 \
user=postgres.saiwblhqfyxpwkgnhptd dbname=postgres sslmode=require"

RUNNER=$(mktemp /tmp/db_test_XXXXXX)
trap 'rm -f "$RUNNER"' EXIT
{
  echo "\\set ON_ERROR_STOP on"
  echo "BEGIN;"
  for m in "${MIGRATIONS[@]:-}"; do [ -n "$m" ] && echo "\\i /work/$m"; done
  echo "\\i /work/$TEST_FILE"
  echo "ROLLBACK;"
  echo "\\echo '--- rolled back, nothing persisted ---'"
} > "$RUNNER"

docker run --rm -e PGPASSWORD="$PW" \
  -v "$PWD:/work:ro" -v "$RUNNER:/runner.sql:ro" \
  postgres:17-alpine \
  psql "$CONN" -v ON_ERROR_STOP=1 -f /runner.sql
