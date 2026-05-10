#!/usr/bin/env bash

KEYWORD="132.231.8.189\("
set -euo pipefail

if [[ -z "${POSTGRESQL:-}" ]]; then
  echo "Error: variable POSTGRESQL is not set. run the env file in bin directory first"
  exit 1
fi

if [[ -z "${CLIENTS:-}" || ! "$CLIENTS" =~ ^[0-9]+$ || "$CLIENTS" -lt 1 ]]; then
  echo "Error: CLIENTS must be a positive integer (got: '${CLIENTS:-unset}')"
  exit 1
fi

HIGH_FIFO_PRIO=90
LOW_FIFO_PRIO=90

CPUS=()
for ((i=0; i<CLIENTS; i++)); do
  CPUS+=( $((i*2)) )
done
CPULIST="$(IFS=,; echo "${CPUS[*]}")"

run_udf=false
same_prio=false
read_only=false
no_clients=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udf)
      run_udf=true
      ;;
    --same-prio)
      same_prio=true
      ;;
    --read-only)
      read_only=true
      ;;
    --no-clients)
      no_clients=true
      ;;
    *)
      echo "Error: unknown argument: $1"
      echo "Usage: $0 [--udf] [--same-prio] [--read-only] [--no-clients]"
      exit 1
      ;;
  esac
  shift
done

psql -U aida-user -d benchbase -c "TRUNCATE TABLE public.udf_runs;"

if [[ "$no_clients" != true ]]; then
  ./wait_bb.sh
  sleep 1
fi

if [[ "$run_udf" == true ]]; then
  echo "Starting UDFs..."
  for i in $(seq 1 "$CLIENTS"); do
    #$POSTGRESQL/bin/psql -U admin -d benchbase -c "select * from cpu_spin_continuous()" &
    "$POSTGRESQL/bin/psql" -U admin -d benchbase -c "call tpch_q17_worker('$i', 1);" &
  done
  sleep 1
else
  echo "NOT starting UDFs."
fi

if [[ "$no_clients" == true ]]; then
  client_count=0
  echo "Skipping high-priority client block (--no-clients)."
else
  echo "Setting SCHED_RR prio $HIGH_FIFO_PRIO and pinning to CPUs $CPULIST for processes containing '$KEYWORD'..."
  mapfile -t high_pids < <(pgrep -f "$KEYWORD" || true)
  client_count=${#high_pids[@]}

  if (( client_count )); then
    for pid in "${high_pids[@]}"; do
      echo "  -> PID $pid (HW)"
      sudo chrt -r -p "$HIGH_FIFO_PRIO" "$pid"
      echo "$CPULIST"
      sudo taskset -pc "$CPULIST" "$pid" >/dev/null
    done
  else
    echo "  (none found)"
  fi
fi

mapfile -t low_pids < <(pgrep -f "\[local\]" || true)
udf_count=${#low_pids[@]}

if [[ "$same_prio" != true ]]; then
  echo Adding low weight group...
  ./add_lw_cgroup.sh

  if [[ "$no_clients" == true ]]; then
    echo "No-clients mode: waiting 60 seconds..."
    sleep 60
  else
    ./wait_bb.sh --end
  fi

  throughput=$(./collect_udf_results.sh)
  echo "UDF throughput: $throughput"

  if [[ "$read_only" == true ]]; then
    echo "Read-only mode, not writing UDF throughput."
  elif [[ "$run_udf" == true ]]; then
    if [[ "$same_prio" == true ]]; then
      outfile="results/udf_${client_count}_${udf_count}_rr_same_prio.csv"
    else
      outfile="results/udf_${client_count}_${udf_count}_rr.csv"
    fi
    echo "$throughput" > "$outfile"
    echo "Saved throughput to $outfile"
  fi

  ./kill_burns.sh
  exit 0
fi

echo "Setting SCHED_RR prio $LOW_FIFO_PRIO and pinning to CPUs $CPULIST for processes containing '[local]'..."
if (( udf_count )); then
  for pid in "${low_pids[@]}"; do
    echo "  -> PID $pid (LW)"
    sudo chrt -r -p "$LOW_FIFO_PRIO" "$pid"
    echo "$CPULIST"
    sudo taskset -pc "$CPULIST" "$pid" >/dev/null
  done
else
  echo "  (none found)"
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
  echo "Read-only mode, not writing UDF throughput."
elif [[ "$run_udf" == true ]]; then
  if [[ "$same_prio" == true ]]; then
    outfile="results/udf_${client_count}_${udf_count}_rr_same_prio.csv"
  else
    outfile="results/udf_${client_count}_${udf_count}_rr.csv"
  fi

  echo "$throughput" > "$outfile"
  echo "Saved throughput to $outfile"
fi

./kill_burns.sh
