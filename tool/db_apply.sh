#!/usr/bin/env bash
# Apply migration(s) to the Load database, for real. The counterpart to
# db_test.sh: same connection, same container, but the transaction COMMITS.
#
#   ./tool/db_apply.sh supabase/migrations_v2/v2_0029_x.sql [more.sql ...]
#
# All files are applied in ONE transaction, in the order given: either every
# migration lands or none does. ON_ERROR_STOP means the first failure aborts
# and rolls the whole batch back.
#
# The target project is pinned in CONN below — Load (saiwblhqfyxpwkgnhptd).
# It is spelled out rather than read from a variable so that a mistyped
# environment can never point this at a different project.
set -euo pipefail
cd "$(dirname "$0")/.."

[ "$#" -ge 1 ] || { echo "usage: db_apply.sh <migration.sql> [more.sql ...]" >&2; exit 2; }
for f in "$@"; do
  [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }
done

PW=$(grep -m1 '^LOAD_SUPABASE_DB_PASSWORD=' .env | cut -d= -f2- \
     | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
[ -n "$PW" ] || { echo "LOAD_SUPABASE_DB_PASSWORD not found in .env" >&2; exit 2; }

CONN="host=aws-0-ap-northeast-1.pooler.supabase.com port=5432 \
user=postgres.saiwblhqfyxpwkgnhptd dbname=postgres sslmode=require"

RUNNER=$(mktemp /tmp/db_apply_XXXXXX)
trap 'rm -f "$RUNNER"' EXIT
{
  echo "\\set ON_ERROR_STOP on"
  echo "BEGIN;"
  for m in "$@"; do echo "\\i /work/$m"; done
  echo "COMMIT;"
  echo "\\echo '--- committed ---'"
} > "$RUNNER"

echo "Applying to Load (saiwblhqfyxpwkgnhptd):"
printf '  %s\n' "$@"

docker run --rm -e PGPASSWORD="$PW" \
  -v "$PWD:/work:ro" -v "$RUNNER:/runner.sql:ro" \
  postgres:17-alpine \
  psql "$CONN" -v ON_ERROR_STOP=1 -f /runner.sql
