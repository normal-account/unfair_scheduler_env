KEYWORD="\[local\]"
count=0

while read -r pid; do
    # >&2 sends the PID printed by 'tee' to standard error
    echo "$pid" | sudo tee /sys/fs/cgroup/parent/lw/cgroup.procs >&2
    count=$((count + 1))
done < <(pgrep -f "$KEYWORD")

# This is the ONLY thing sent to standard output
echo "$count"
