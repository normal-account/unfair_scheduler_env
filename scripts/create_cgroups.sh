: "${CLIENTS:?Error: The CLIENTS environment variable is not set.}"

echo 50000 | sudo tee /sys/kernel/debug/tracing/buffer_size_kb

echo 0 | sudo tee "/sys/kernel/debug/tracing/events/enable"

sudo mkdir /sys/fs/cgroup/parent
sudo mkdir /sys/fs/cgroup/parent/lw
sudo mkdir /sys/fs/cgroup/parent/lw_high
sudo mkdir /sys/fs/cgroup/parent/hw
sudo mkdir /sys/fs/cgroup/parent/hw_low
sudo mkdir /sys/fs/cgroup/parent/hw_postgres

echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo

echo +cpu +cpuset | sudo tee /sys/fs/cgroup/cgroup.subtree_control
echo +cpu +cpuset | sudo tee /sys/fs/cgroup/parent/cgroup.subtree_control

echo 1 | sudo tee /sys/fs/cgroup/parent/lw/cpu.weight
echo 4 | sudo tee /sys/fs/cgroup/parent/lw_high/cpu.weight
echo 10000 | sudo tee /sys/fs/cgroup/parent/hw/cpu.weight
echo 2500 | sudo tee /sys/fs/cgroup/parent/hw_low/cpu.weight

cpus=$(seq -s, 0 2 $((2*(CLIENTS-1))))
echo "$cpus" | sudo tee /sys/fs/cgroup/parent/hw/cpuset.cpus
echo "$cpus" | sudo tee /sys/fs/cgroup/parent/hw_low/cpuset.cpus
echo "$cpus" | sudo tee /sys/fs/cgroup/parent/lw/cpuset.cpus
echo "$cpus" | sudo tee /sys/fs/cgroup/parent/lw_high/cpuset.cpus


