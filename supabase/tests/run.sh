#!/usr/bin/env bash
# Runs migrations + seed + integration tests against a local PostgreSQL.
# Usage: PGHOST=... PGPORT=... PGUSER=postgres ./run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
P="psql -v ON_ERROR_STOP=1 -q"
$P -c "drop database if exists myhato_test" -c "create database myhato_test"
for f in tests/supabase_stub.sql migrations/*.sql seed/dev_seed.sql tests/integration_test.sql tests/worker_test.sql tests/payments_test.sql; do
  echo "== $f"
  $P -d myhato_test -f "$f"
done
