#!/usr/bin/env bash

set -euo pipefail

if [[ -z "${POSTGRESQL:-}" ]]; then
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

CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup/parent}"

HW_CGROUP="$CGROUP_ROOT/hw"
HW_LOW_CGROUP="$CGROUP_ROOT/hw_low"
LW_CGROUP="$CGROUP_ROOT/lw"
LW_HIGH_CGROUP="$CGROUP_ROOT/lw_high"

HW_WEIGHT="${HW_WEIGHT:-10000}"
HW_LOW_WEIGHT="${HW_LOW_WEIGHT:-6667}"
LW_WEIGHT="${LW_WEIGHT:-2}"
LW_HIGH_WEIGHT="${LW_HIGH_WEIGHT:-3}"

ensure_cgroup() {
  local cg="$1"
  local weight="$2"

  sudo mkdir -p "$cg"

  if [[ -w "$cg/cpu.weight" || -e "$cg/cpu.weight" ]]; then
    echo "$weight" | sudo tee "$cg/cpu.weight" >/dev/null
  fi

  #if [[ -n "$CPULIST" && -e "$cg/cpuset.cpus" ]]; then
  #  echo "$CPULIST" | sudo tee "$cg/cpuset.cpus" >/dev/null
  #fi
}

move_pid_to_cgroup() {
  local pid="$1"
  local cg="$2"

  echo "$pid" | sudo tee "$cg/cgroup.procs" >/dev/null
}

split_pids_between_cgroups() {
  local first_cgroup="$1"
  local second_cgroup="$2"
  shift 2

  local pids=("$@")
  local count="${#pids[@]}"

  if [[ "$count" -eq 0 ]]; then
    echo "Error: no PIDs provided for cgroup assignment"
    exit 1
  fi

  local first_count=$(( (count + 1) / 2 ))

  for i in "${!pids[@]}"; do
    if (( i < first_count )); then
      move_pid_to_cgroup "${pids[$i]}" "$first_cgroup"
    else
      move_pid_to_cgroup "${pids[$i]}" "$second_cgroup"
    fi
  done
}

get_client_pids() {
  psql -U admin -d benchbase -Atc "
    SELECT pid
    FROM pg_stat_activity
    WHERE datname = 'benchbase'
      AND pid <> pg_backend_pid()
      AND backend_type = 'client backend'
      AND query NOT LIKE 'call tpch_q17_worker(%'
    ORDER BY pid
  "
}

get_udf_pids() {
  psql -U aida-user -d benchbase -Atc "
    SELECT pid
    FROM pg_stat_activity
    WHERE datname = 'benchbase'
      AND query LIKE 'call tpch_q17_worker(%'
    ORDER BY pid
  "
}

# echo Killing burns...
# ./kill_burns.sh

psql -U aida-user -d benchbase -c "TRUNCATE TABLE public.udf_runs;"

if [[ "$no_clients" != true ]]; then
  echo "Waiting..."
  ./wait_bb.sh
  sleep 1
fi

if [[ "$run_udf" == true ]]; then
  echo "Starting UDFs..."
  for i in $(seq 1 "$(($CLIENTS*2))"); do
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

  mapfile -t client_pids < <(get_client_pids)
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
  echo "Assigning client backends: half to hw, half to hw_low..."

  sleep 1

  ensure_cgroup "$HW_CGROUP" "$HW_WEIGHT"
  ensure_cgroup "$HW_LOW_CGROUP" "$HW_LOW_WEIGHT"

  mapfile -t client_pids < <(get_client_pids)
  client_count=${#client_pids[@]}

  if [[ "$client_count" -eq 0 ]]; then
    echo "Error: could not find client backend PIDs in pg_stat_activity"
    exit 1
  fi

  split_pids_between_cgroups "$HW_CGROUP" "$HW_LOW_CGROUP" "${client_pids[@]}"

  echo "Assigned $client_count client backend(s):"
  echo "  first half  -> $HW_CGROUP"
  echo "  second half -> $HW_LOW_CGROUP"
fi

if [[ "$run_udf" == true ]]; then
  if [[ "$idle" == true ]]; then
    echo "Setting UDF backends to SCHED_IDLE and pinning to CPULIST..."

    sleep 1

    mapfile -t udf_pids < <(get_udf_pids)
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

    mapfile -t udf_pids < <(get_udf_pids)
    udf_count=${#udf_pids[@]}

    if [[ "$udf_count" -eq 0 ]]; then
      echo "Error: could not find UDF backend PIDs in pg_stat_activity"
      exit 1
    fi

    for pid in "${udf_pids[@]}"; do
      sudo taskset -cp "$CPULIST" "$pid"
      sudo renice -n 19 -p "$pid" >/dev/null
    done

  else
    if [[ "$same_prio" == true ]]; then
      echo "Warning: --same-prio was passed, but this split-cgroup script assigns UDFs to lw/lw_high as requested."
    fi

    echo "Assigning UDF backends: half to lw, half to lw_high..."

    sleep 1

    ensure_cgroup "$LW_CGROUP" "$LW_WEIGHT"
    ensure_cgroup "$LW_HIGH_CGROUP" "$LW_HIGH_WEIGHT"

    mapfile -t udf_pids < <(get_udf_pids)
    udf_count=${#udf_pids[@]}

    if [[ "$udf_count" -eq 0 ]]; then
      echo "Error: could not find UDF backend PIDs in pg_stat_activity"
      exit 1
    fi

    split_pids_between_cgroups "$LW_CGROUP" "$LW_HIGH_CGROUP" "${udf_pids[@]}"

    echo "Assigned $udf_count UDF backend(s):"
    echo "  first half  -> $LW_CGROUP"
    echo "  second half -> $LW_HIGH_CGROUP"
  fi
else
  udf_count=0
fi

if [[ "$no_clients" == true ]]; then
  echo "No-clients mode: waiting 60 seconds..."
  sleep 60
else
  ./wait_bb.sh --end
fi

if [[ "$run_udf" == true ]]; then
  udf_split_point=$((udf_count / 2))
  throughput_output=$(./collect_udf_results_mixed.sh --split --split-point "$udf_split_point")

  total_throughput=$(echo "$throughput_output" | awk -F, '$1 == "total" { print $2 }')
  lw_throughput=$(echo "$throughput_output" | awk -F, '$1 == "lw" { print $2 }')
  lw_high_throughput=$(echo "$throughput_output" | awk -F, '$1 == "lw_high" { print $2 }')

  echo "Total UDF throughput: $total_throughput"
  echo "lw UDF throughput: $lw_throughput"
  echo "lw_high UDF throughput: $lw_high_throughput"

  if [[ "$read_only" == true ]]; then
    echo "Read-only mode, not writing UDF throughput."
  else
    if grep -qx "enabled" /sys/kernel/sched_ext/state; then
      sched_name="ufs"
    else
      sched_name="eevdf"
    fi

    mkdir -p results

    if [[ "$idle" == true ]]; then
      outfile="results/udf_${client_count}_${udf_count}_${sched_name}_idle.csv"
      echo "$total_throughput" > "$outfile"
      echo "Saved throughput to $outfile"

    elif [[ "$nice_mode" == true ]]; then
      outfile="results/udf_${client_count}_${udf_count}_${sched_name}_nice.csv"
      echo "$total_throughput" > "$outfile"
      echo "Saved throughput to $outfile"

    elif [[ "$same_prio" == true ]]; then
      outfile="results/udf_${client_count}_${udf_count}_${sched_name}_same_prio_split.csv"
      echo "$total_throughput" > "$outfile"
      echo "Saved throughput to $outfile"

    else
      lw_outfile="results/udf_${client_count}_${udf_count}_${sched_name}_split_lw.csv"
      lw_high_outfile="results/udf_${client_count}_${udf_count}_${sched_name}_split_lw_high.csv"
      total_outfile="results/udf_${client_count}_${udf_count}_${sched_name}_split.csv"

      echo "$lw_throughput" > "$lw_outfile"
      echo "$lw_high_throughput" > "$lw_high_outfile"
      echo "$total_throughput" > "$total_outfile"

      echo "Saved throughput to:"
      echo "  $lw_outfile"
      echo "  $lw_high_outfile"
      echo "  $total_outfile"
    fi
  fi
else
  echo "No UDFs were started; skipping UDF throughput collection."
fi

./kill_burns.sh
