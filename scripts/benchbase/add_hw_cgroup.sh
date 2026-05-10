#KEYWORD="132.231.189.16\("
#KEYWORD="127.0.0.1\("
#KEYWORD="132.231.91.171\("

KEYWORD="132.231.8.189\("
count=0

while read -r pid; do
    echo "$pid" | sudo tee /sys/fs/cgroup/parent/hw/cgroup.procs >&2
    count=$((count + 1))
done < <(pgrep -f "$KEYWORD")

# Output ONLY the raw count
echo "$count"
