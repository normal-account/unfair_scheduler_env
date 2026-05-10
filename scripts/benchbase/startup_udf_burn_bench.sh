#!/usr/bin/env bash

if [[ -z "$POSTGRESQL" ]]; then
  echo "Error: variable POSTGRESQL is not set. run the env file in bin directory first"
  exit 1
fi

sudo true

run_udf=false
same_prio=false
no_clients=false
read_only=false
idle=false
nice_mode=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udf)
      run_udf=true
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
      echo "Usage: $0 [--udf] [--same-prio] [--no-clients] [--read-only] [--idle] [--nice]"
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

echo Killing burns...
./kill_burns.sh

psql -U aida-user -d benchbase -c "TRUNCATE TABLE public.udf_runs;"

if [[ "$no_clients" != true ]]; then
  ./wait_bb.sh
  sleep 1
fi

if [[ "$run_udf" == true ]]; then
  echo "Starting UDFs..."
  for i in $(seq 1 "$CLIENTS"); do
    #"$POSTGRESQL/bin/psql" -U admin -d benchbase -c "select * from cpu_spin_continuous()" &
    "$POSTGRESQL/bin/psql" -U admin -d benchbase -c "call tpch_q17_worker('$i', 1);" &
  done
else
  echo "NOT starting UDFs."
fi

if [[ "$no_clients" == true ]]; then
  client_count=0
elif [[ "$nice_mode" == true ]]; then
  echo "Setting client backends to nice -20 and pinning to CPULIST..."

  sleep 1

  mapfile -t client_pids < <(
    psql -U admin -d benchbase -Atc "
      SELECT pid
      FROM pg_stat_activity
      WHERE datname = 'benchbase'
        AND pid <> pg_backend_pid()
        AND backend_type = 'client backend'
        AND query NOT LIKE 'call tpch_q17_worker(%'
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

if [[ "$idle" == true ]]; then
  echo "Setting UDF backends to SCHED_IDLE and pinning to CPULIST..."

  sleep 1

  mapfile -t udf_pids < <(
    psql -U aida-user -d benchbase -Atc "
      SELECT pid
      FROM pg_stat_activity
      WHERE datname = 'benchbase'
      AND query LIKE 'call tpch_q17_worker(%'
    "
  )

  udf_count=${#udf_pids[@]}

  if [[ "$udf_count" -eq 0 ]]; then
    echo "Error: could not find UDF backend PIDs in pg_stat_activity"
    exit 1
  fi

  for pid in "${udf_pids[@]}"; do
    sudo taskset -cp "$CPULIST" "$pid"
    sudo chrt -i -p 0 "$pid"
  done
elif [[ "$nice_mode" == true ]]; then
  echo "Setting UDF backends to nice 19 and pinning to CPULIST..."

  sleep 1

  mapfile -t udf_pids < <(
    psql -U aida-user -d benchbase -Atc "
      SELECT pid
      FROM pg_stat_activity
      WHERE datname = 'benchbase'
      AND query LIKE 'call tpch_q17_worker(%'
    "
  )

  udf_count=${#udf_pids[@]}

  if [[ "$udf_count" -eq 0 ]]; then
    echo "Error: could not find UDF backend PIDs in pg_stat_activity"
    exit 1
  fi

  for pid in "${udf_pids[@]}"; do
    sudo taskset -cp "$CPULIST" "$pid"
    sudo renice -n 19 -p "$pid" >/dev/null
  done
elif [[ "$same_prio" == true ]]; then
  echo "Adding low-weight group as high-weight group..."
  udf_count=$(./add_lw_cgroup_as_hw.sh)
else
  echo "Adding low-weight group..."
  udf_count=$(./add_lw_cgroup.sh)
fi

if [[ "$no_clients" == true ]]; then
  echo "No-clients mode: waiting 60 seconds..."
  sleep 60
else
  ./wait_bb.sh --end
fi

throughput=$(./collect_udf_results.sh)
echo "UDF throughput: $throughput"

if [[ "$read_only" == true ]]; then
  echo Read-only mode, not writing UDF throughput.
elif [[ "$run_udf" == true ]]; then
  if grep -qx "enabled" /sys/kernel/sched_ext/state; then
    sched_name="ufs"
  else
    sched_name="eevdf"
  fi

  if [[ "$idle" == true ]]; then
    outfile="results/udf_${client_count}_${udf_count}_${sched_name}_idle.csv"
  elif [[ "$nice_mode" == true ]]; then
    outfile="results/udf_${client_count}_${udf_count}_${sched_name}_nice.csv"
  elif [[ "$same_prio" == true ]]; then
    outfile="results/udf_${client_count}_${udf_count}_${sched_name}_same_prio.csv"
  else
    outfile="results/udf_${client_count}_${udf_count}_${sched_name}.csv"
  fi

  echo "$throughput" > "$outfile"
  echo "Saved throughput to $outfile"
fi

./kill_burns.sh
