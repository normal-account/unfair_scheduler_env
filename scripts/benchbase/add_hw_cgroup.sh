KEYWORD='([0-9]{1,3}\.){3}[0-9]{1,3}\('
count=0

while read -r pid; do
    echo "$pid" | sudo tee /sys/fs/cgroup/parent/hw/cgroup.procs >&2
    count=$((count + 1))
done < <(pgrep -f "$KEYWORD")

# Output ONLY the raw count
echo "$count"
