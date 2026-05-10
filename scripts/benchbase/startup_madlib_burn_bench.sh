#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${POSTGRESQL:-}" ]]; then
  echo "Error: variable POSTGRESQL is not set. run the env file in bin directory first"
  exit 1
fi

if [[ -z "${CLIENTS:-}" ]]; then
  echo "Error: variable CLIENTS is not set."
  exit 1
fi

sudo true

run_madlib=false
same_prio=false
no_clients=false
read_only=false
idle=false
nice_mode=false

DB="madlibtest"
CLIENT_USER="admin"
MAINT_USER="aida-user"

MADLIB_SOURCE_TABLE="public.ml_logreg_data_medium"
MADLIB_MODEL_PREFIX="ml_logreg_model"
MADLIB_DRAIN_TIMEOUT="${MADLIB_DRAIN_TIMEOUT:-300}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --madlib|--udf)
      # --udf kept as a backwards-compatible alias.
      run_madlib=true
      ;;
    --same-prio)
      same_prio=true
      ;;
    --no-clients)
      no_clients=true
      ;;
    --read-only)
      read_only=true
      ;;
    --idle)
      idle=true
      ;;
    --nice)
      nice_mode=true
      ;;
    *)
      echo "Error: unknown argument: $1"
      echo "Usage: $0 [--madlib] [--same-prio] [--no-clients] [--read-only] [--idle] [--nice]"
      exit 1
      ;;
  esac
  shift
done

CPUS=()
for ((i=0; i<CLIENTS; i++)); do
  CPUS+=( $((i*2)) )
done
CPULIST="$(IFS=,; echo "${CPUS[*]}")"

cleanup() {
  DB="$DB" ./kill_madlib.sh >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

get_madlib_pids() {
  psql -U "$MAINT_USER" -d "$DB" -Atc "
    SELECT pid
    FROM pg_stat_activity
    WHERE datname = '$DB'
      AND pid <> pg_backend_pid()
      AND backend_type = 'client backend'
      AND application_name LIKE 'madlib_worker_%'
    ORDER BY application_name, pid;
  "
}

wait_for_madlib_pids() {
  local tries=30

  for _ in $(seq 1 "$tries"); do
    mapfile -t madlib_pids < <(get_madlib_pids)

    if [[ "${#madlib_pids[@]}" -ge "$CLIENTS" ]]; then
      return 0
    fi

    sleep 0.5
  done

  mapfile -t madlib_pids < <(get_madlib_pids)
}

start_madlib_worker() {
  local i="$1"

  mkdir -p logs

  PGAPPNAME="madlib_worker_${i}" "$POSTGRESQL/bin/psql" \
    -U "$CLIENT_USER" \
    -d "$DB" \
    -v ON_ERROR_STOP=1 \
    >> "logs/madlib_worker_${i}.log" 2>&1 <<SQL &
SET default_transaction_isolation = 'read committed';
CALL public.run_madlib_worker(${i});
SQL
}

stop_madlib_gracefully() {
  local start_time
  local now
  local active_count

  echo "Requesting MADlib workers to stop after current iteration..."

  psql -U "$MAINT_USER" -d "$DB" -v ON_ERROR_STOP=1 -qAtc "
    UPDATE public.madlib_control
    SET stop_requested = true;
  " >/dev/null

  start_time=$(date +%s)

  while true; do
    active_count=$(
      psql -U "$MAINT_USER" -d "$DB" -qAtc "
        SELECT count(*)
        FROM pg_stat_activity
        WHERE datname = '$DB'
          AND application_name LIKE 'madlib_worker_%';
      "
    )

    if [[ "$active_count" -eq 0 ]]; then
      echo "MADlib workers finished their current iteration."
      break
    fi

    now=$(date +%s)

    if (( now - start_time >= MADLIB_DRAIN_TIMEOUT )); then
      echo "Timed out waiting for MADlib workers to finish; killing remaining workers."
      DB="$DB" ./kill_madlib.sh || true
      break
    fi

    sleep 1
  done
}

echo "Killing existing MADlib workloads..."
DB="$DB" ./kill_madlib.sh || true

echo "Checking MADlib source table..."

SOURCE_REL="${MADLIB_SOURCE_TABLE#*.}"

for i in $(seq 1 "$CLIENTS"); do
  if [[ "$SOURCE_REL" == "${MADLIB_MODEL_PREFIX}_${i}" ||
        "$SOURCE_REL" == "${MADLIB_MODEL_PREFIX}_${i}_summary" ]]; then
    echo "Error: MADLIB_SOURCE_TABLE=$MADLIB_SOURCE_TABLE conflicts with generated model table names."
    exit 1
  fi
done

source_table_exists=$(
  psql -U "$MAINT_USER" -d "$DB" -Atc \
    "SELECT to_regclass('${MADLIB_SOURCE_TABLE}') IS NOT NULL;"
)

if [[ "$source_table_exists" != "t" ]]; then
  if [[ "$MADLIB_SOURCE_TABLE" != "public.ml_logreg_data_medium" ]]; then
    echo "Error: MADLIB_SOURCE_TABLE=${MADLIB_SOURCE_TABLE} does not exist, and auto-create is only defined for public.ml_logreg_data_medium."
    exit 1
  fi

  echo "MADlib source table ${MADLIB_SOURCE_TABLE} does not exist. Recreating medium data table..."

  psql -U "$MAINT_USER" -d "$DB" -v ON_ERROR_STOP=1 <<'SQL'
CREATE UNLOGGED TABLE public.ml_logreg_data_medium AS
WITH raw AS (
    SELECT
        g.id,
        x.features_without_intercept,
        random() AS r
    FROM generate_series(1, 200000) AS g(id)
    CROSS JOIN LATERAL (
        SELECT array_agg((random() * 2.0 - 1.0) + 0.0 * g.id ORDER BY j) AS features_without_intercept
        FROM generate_series(1, 32) AS j
    ) AS x
),
scored AS (
    SELECT
        id,
        array_prepend(1.0, features_without_intercept) AS features,
        0.2 + (
            SELECT sum(
                features_without_intercept[j] *
                CASE
                    WHEN j % 4 = 0 THEN 0.40
                    WHEN j % 4 = 1 THEN -0.30
                    WHEN j % 4 = 2 THEN 0.20
                    ELSE -0.10
                END
            )
            FROM generate_subscripts(features_without_intercept, 1) AS j
        ) AS score,
        r
    FROM raw
)
SELECT
    id,
    features,
    CASE
        WHEN r < 1.0 / (1.0 + exp(-score)) THEN 1
        ELSE 0
    END AS y
FROM scored;

ANALYZE public.ml_logreg_data_medium;

GRANT SELECT ON TABLE public.ml_logreg_data_medium TO admin;
SQL

  echo "Recreated ${MADLIB_SOURCE_TABLE}."
fi

echo "Preparing MADlib run/control tables and worker procedure..."
psql -U "$MAINT_USER" -d "$DB" -v ON_ERROR_STOP=1 <<SQL
DROP TABLE IF EXISTS public.madlib_runs;

CREATE TABLE public.madlib_runs (
  worker_id integer NOT NULL,
  num_iterations integer NOT NULL,
  completed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

DROP TABLE IF EXISTS public.madlib_control;

CREATE TABLE public.madlib_control (
  stop_requested boolean NOT NULL
);

INSERT INTO public.madlib_control VALUES (false);

GRANT SELECT, INSERT ON TABLE public.madlib_runs TO ${CLIENT_USER};
GRANT SELECT ON TABLE public.madlib_control TO ${CLIENT_USER};
GRANT USAGE, CREATE ON SCHEMA public TO ${CLIENT_USER};

DO \$\$
DECLARE
  i integer;
BEGIN
  FOR i IN 1..${CLIENTS} LOOP
    EXECUTE format('DROP TABLE IF EXISTS public.%I', '${MADLIB_MODEL_PREFIX}_' || i);
    EXECUTE format('DROP TABLE IF EXISTS public.%I', '${MADLIB_MODEL_PREFIX}_' || i || '_summary');
  END LOOP;
END;
\$\$;

CREATE OR REPLACE PROCEDURE public.run_madlib_worker(p_worker_id integer)
LANGUAGE plpgsql
AS \$\$
DECLARE
  model_name text := '${MADLIB_MODEL_PREFIX}_' || p_worker_id;
  summary_name text := '${MADLIB_MODEL_PREFIX}_' || p_worker_id || '_summary';
  iters integer;
BEGIN
  LOOP
    EXIT WHEN EXISTS (
      SELECT 1
      FROM public.madlib_control
      WHERE stop_requested
    );

    EXECUTE format('DROP TABLE IF EXISTS public.%I', model_name);
    EXECUTE format('DROP TABLE IF EXISTS public.%I', summary_name);

    PERFORM madlib.logregr_train(
      '${MADLIB_SOURCE_TABLE}',
      'public.' || model_name,
      'y',
      'features',
      NULL,
      50,
      'irls'
    );

    EXECUTE format('SELECT num_iterations FROM public.%I', model_name)
    INTO iters;

    INSERT INTO public.madlib_runs(worker_id, num_iterations, completed_at)
    VALUES (p_worker_id, iters, clock_timestamp());

    COMMIT;
  END LOOP;
END;
\$\$;

GRANT EXECUTE ON PROCEDURE public.run_madlib_worker(integer) TO ${CLIENT_USER};
SQL

if [[ "$no_clients" != true ]]; then
  ./wait_bb.sh
  sleep 1
fi

if [[ "$run_madlib" == true ]]; then
  echo "Starting MADlib workers..."
  rm -f logs/madlib_worker_*.log

  for i in $(seq 1 "$CLIENTS"); do
    start_madlib_worker "$i"
  done
else
  echo "NOT starting MADlib workers."
fi

if [[ "$no_clients" == true ]]; then
  client_count=0
elif [[ "$nice_mode" == true ]]; then
  echo "Setting client backends to nice -20 and pinning to CPULIST..."

  sleep 1

  mapfile -t client_pids < <(
    psql -U "$CLIENT_USER" -d "$DB" -Atc "
      SELECT pid
      FROM pg_stat_activity
      WHERE datname = '$DB'
        AND pid <> pg_backend_pid()
        AND backend_type = 'client backend'
        AND application_name NOT LIKE 'madlib_worker_%'
    "
  )

  client_count=${#client_pids[@]}

  if [[ "$client_count" -eq 0 ]]; then
    echo "Error: could not find client backend PIDs in pg_stat_activity"
    exit 1
  fi

  for pid in "${client_pids[@]}"; do
    sudo taskset -cp "$CPULIST" "$pid"
    sudo renice -n -20 -p "$pid" >/dev/null
  done
else
  echo "Adding high-weight group..."
  client_count=$(./add_hw_cgroup.sh)
fi

if [[ "$run_madlib" == true ]]; then
  wait_for_madlib_pids
  madlib_count=${#madlib_pids[@]}

  if [[ "$madlib_count" -eq 0 ]]; then
    echo "Error: could not find MADlib backend PIDs in pg_stat_activity"
    echo "Check logs/madlib_worker_*.log for errors."
    exit 1
  fi

  if [[ "$idle" == true ]]; then
    echo "Setting MADlib backends to SCHED_IDLE and pinning to CPULIST..."

    for pid in "${madlib_pids[@]}"; do
      sudo taskset -cp "$CPULIST" "$pid"
      sudo chrt -i -p 0 "$pid"
    done
  elif [[ "$nice_mode" == true ]]; then
    echo "Setting MADlib backends to nice 19 and pinning to CPULIST..."

    for pid in "${madlib_pids[@]}"; do
      sudo taskset -cp "$CPULIST" "$pid"
      sudo renice -n 19 -p "$pid" >/dev/null
    done
  elif [[ "$same_prio" == true ]]; then
    echo "Adding low-weight group as high-weight group..."
    madlib_count=$(./add_lw_cgroup_as_hw.sh)
  else
    echo "Adding low-weight group..."
    madlib_count=$(./add_lw_cgroup.sh)
  fi
else
  madlib_count=0
fi

if [[ "$no_clients" == true ]]; then
  echo "No-clients mode: waiting 60 seconds..."
  sleep 60
else
  ./wait_bb.sh --end
fi

if [[ "$run_madlib" == true ]]; then
  stop_madlib_gracefully
fi

madlib_stats=$(
  psql -U "$MAINT_USER" -d "$DB" -Atc "
    SELECT
      count(*) || ',' || COALESCE(sum(num_iterations), 0)
    FROM public.madlib_runs;
  "
)

completed_runs="${madlib_stats%,*}"
iterations="${madlib_stats#*,}"

echo "MADlib completed runs: $completed_runs"
echo "MADlib iterations: $iterations"

if [[ "$read_only" == true ]]; then
  echo "Read-only mode, not writing MADlib results."
elif [[ "$run_madlib" == true ]]; then
  mkdir -p results

  if [[ -r /sys/kernel/sched_ext/state ]] && grep -qx "enabled" /sys/kernel/sched_ext/state; then
    sched_name="ufs"
  else
    sched_name="eevdf"
  fi

  if [[ "$idle" == true ]]; then
    outfile="results/madlib_${client_count}_${madlib_count}_${sched_name}_idle.csv"
  elif [[ "$nice_mode" == true ]]; then
    outfile="results/madlib_${client_count}_${madlib_count}_${sched_name}_nice.csv"
  elif [[ "$same_prio" == true ]]; then
    outfile="results/madlib_${client_count}_${madlib_count}_${sched_name}_same_prio.csv"
  else
    outfile="results/madlib_${client_count}_${madlib_count}_${sched_name}.csv"
  fi

  echo "${completed_runs},${iterations}" > "$outfile"
  echo "Saved MADlib results to $outfile"
fi

DB="$DB" ./kill_madlib.sh || true
trap - EXIT INT TERM
