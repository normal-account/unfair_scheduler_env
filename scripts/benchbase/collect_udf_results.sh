#!/usr/bin/env bash
set -euo pipefail

OUTFILE="udf_outputs.txt"

# Optional: set these if needed
# export PGHOST=localhost
# export PGPORT=5432
# export PGUSER=postgres
# export PGDATABASE=your_db_name

: > "$OUTFILE"
total_completed_runs=0

while IFS='|' read -r worker_id completed_runs started_at last_completed; do
    #echo "worker_id=$worker_id completed_runs=$completed_runs started_at=$started_at last_completed=$last_completed" >> "$OUTFILE"
    total_completed_runs=$((total_completed_runs + completed_runs))
done < <(
    psql -U aida-user -d benchbase -At -F '|' -c "
        SELECT worker_id, completed_runs, started_at, last_completed
        FROM udf_runs
        ORDER BY worker_id;
    "
)

echo "$total_completed_runs"

#cat "$OUTFILE"
