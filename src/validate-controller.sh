#!/usr/bin/env bash
# ============================================================
# Script purpose:
#   This is a Slurm diagnostic script.
#   It helps check:
#     1. Which Slurm daemons (slurmctld, slurmd) are running.
#     2. What configuration files exist on disk.
#     3. What configuration is actually loaded into memory.
#     4. How each daemon was started (arguments, environment).
#     5. Whether "configless" mode is active.
#     6. On Ubuntu/Debian, whether /etc/default/slurmd has extra args.
#
#   Useful when debugging config mismatches or "unable to process slurm.conf".
# ============================================================

# 0) Who's running?  → Show if daemons are alive and their processes
pgrep -a slurmctld                     # print PID + cmdline of slurmctld if running
pgrep -a slurmd                        # print PID + cmdline of slurmd if running
systemctl status slurmctld --no-pager -l   # detailed systemd status for slurmctld
systemctl status slurmd     --no-pager -l  # detailed systemd status for slurmd

# 1) On-disk config (may not exist on compute node in configless mode)
echo "---- /etc/slurm/slurm.conf (if any) ----"
sudo ls -l /etc/slurm/slurm.conf 2>/dev/null || echo "no /etc/slurm/slurm.conf"   # list the file if it exists
sudo md5sum /etc/slurm/slurm.conf 2>/dev/null || true                            # checksum for comparison
sudo sed -n '1,120p' /etc/slurm/slurm.conf 2>/dev/null || true                   # print first 120 lines

# 2) In-memory view from the controller (authoritative source of truth)
echo "---- scontrol show config (controller view) ----"
scontrol show config | egrep -i \
  'ClusterName|SlurmctldHost|SlurmctldParameters|Configless|SlurmctldPort|SlurmdPort|StateSaveLocation|SlurmdSpoolDir|AuthType|GresTypes|SelectType|AccountingStorageType'
# filters key config fields so you can quickly compare with file

# 3) What environment/args each daemon is using
#    This helps detect if --conf-server or other flags were used.
for svc in slurmctld slurmd; do
  pid=$(pgrep -n "$svc" || true)            # get the newest PID
  echo "---- $svc PID=$pid ----"
  if [ -n "$pid" ]; then
    echo "cmdline:"; tr '\0' ' ' < /proc/$pid/cmdline; echo   # print process command line
    echo "env (SLURM_* only):"; strings /proc/$pid/environ | grep -E '^SLURM|^SLURM_' || true
    echo "open slurm.conf (if any):"; sudo lsof -p $pid 2>/dev/null | grep slurm.conf || echo "none"
  fi
done

# 4) If configless is expected, confirm it’s actually ON
echo "---- Configless status ----"
scontrol show config | grep -i 'Configless\|SlurmctldParameters'

# 5) Bonus: show how slurmd was pointed to the controller (Ubuntu/Debian-specific)
echo "---- /etc/default/slurmd (if present) ----"
sudo sed -n '1,80p' /etc/default/slurmd 2>/dev/null || echo "no /etc/default/slurmd"
