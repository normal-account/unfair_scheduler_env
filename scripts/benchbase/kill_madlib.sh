#!/usr/bin/env bash
set -euo pipefail

DB="${DB:-benchbase}"

psql -d "$DB" -v ON_ERROR_STOP=1 -qAt <<'SQL' >/dev/null
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = current_database()
  AND pid <> pg_backend_pid()
  AND application_name LIKE 'madlib_worker_%';
SQL

echo "Successfully killed MADlib workload."
