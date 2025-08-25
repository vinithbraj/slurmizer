squeue -o "%.18i %.9P %.8T %.19S %.10M %.20R %.8m %.6C %.9b" --me
# or all users:
squeue -o "%.18i %.9P %.8T %.19S %.10M %.20R %.8m %.6C %.9b"


sinfo -R                         # why nodes are in DRAIN/DOWN (if any)
sinfo -o "%P %a %l %D %t %C"     # partition up? nodes idle?
scontrol show partition          # limits, allowed users, default partition?
scontrol show node vinith-VMware-Virtual-Platform    # state, reason, gres, memory

PART=$(sinfo -h --format=%P | head -1 | tr -d '*')
srun -p "$PART" -N1 -n1 -c1 --mem=100M --time=00:01:00 --pty bash -lc 'hostname; sleep 5'

MEM_MB="$(free -m | awk '/Mem:/ {printf "%d", $2*0.95}')"
echo "MEM_MB=$MEM_MB"