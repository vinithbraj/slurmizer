#!/usr/bin/env bash
# ============================================================
# Script purpose:
#   Quick diagnostic + sanity check for Slurm scheduling.
#   It shows:
#     1. Current jobs in the queue (yours or all users).
#     2. Partition and node status (why nodes might be DRAIN/DOWN).
#     3. Partition configuration and node details.
#     4. Runs a tiny interactive job via srun to confirm scheduling works.
#     5. Calculates usable memory (95% of total).
#
#   Use this after bringing Slurm online to verify that jobs can be queued
#   and run, and to check node/partition health.
# ============================================================

# --- Show jobs in the queue (your jobs only) ---
squeue -o "%.18i %.9P %.8T %.19S %.10M %.20R %.8m %.6C %.9b" --me
# Columns: jobid | partition | state | start time | time used | reason | mem | cores | tres/burst

# --- Or all jobs (all users) ---
squeue -o "%.18i %.9P %.8T %.19S %.10M %.20R %.8m %.6C %.9b"

# --- Node/partition health info ---
sinfo -R                         # show reasons why nodes are DRAIN/DOWN, if any
sinfo -o "%P %a %l %D %t %C"     # summary: partition | avail? | time limit | node count | state | CPU usage
scontrol show partition          # detailed partition configs: limits, defaults, allowed users
scontrol show node vinith-VMware-Virtual-Platform    # detailed info for one node (adjust hostname)

# --- Grab the first partition name (strip * for default) ---
PART=$(sinfo -h --format=%P | head -1 | tr -d '*')

# --- Launch a tiny interactive test job ---
# -p "$PART"   → partition name
# -N1          → 1 node
# -n1          → 1 task
# -c1          → 1 CPU
# --mem=100M   → memory request
# --time=1min  → runtime limit
# --pty bash   → interactive pseudo-terminal
srun -p "$PART" -N1 -n1 -c1 --mem=100M --time=00:01:00 --pty bash -lc 'hostname; sleep 5'

# --- Calculate 95% of total system memory in MB ---
#   (useful for setting RealMemory in slurm.conf)
MEM_MB="$(free -m | awk '/Mem:/ {printf "%d", $2*0.95}')"
echo "MEM_MB=$MEM_MB"
