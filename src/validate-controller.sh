# 0) Who's running?
pgrep -a slurmctld
pgrep -a slurmd
systemctl status slurmctld --no-pager -l
systemctl status slurmd     --no-pager -l

# 1) On-disk config (may not exist on node in configless mode)
echo "---- /etc/slurm/slurm.conf (if any) ----"
sudo ls -l /etc/slurm/slurm.conf 2>/dev/null || echo "no /etc/slurm/slurm.conf"
sudo md5sum /etc/slurm/slurm.conf 2>/dev/null || true
sudo sed -n '1,120p' /etc/slurm/slurm.conf 2>/dev/null || true

# 2) In-memory view from the controller (authoritative)
echo "---- scontrol show config (controller view) ----"
scontrol show config | egrep -i 'ClusterName|SlurmctldHost|SlurmctldParameters|Configless|SlurmctldPort|SlurmdPort|StateSaveLocation|SlurmdSpoolDir|AuthType|GresTypes|SelectType|AccountingStorageType'

# 3) What environment/args each daemon is using (e.g., --conf-server)
for svc in slurmctld slurmd; do
  pid=$(pgrep -n "$svc" || true)
  echo "---- $svc PID=$pid ----"
  if [ -n "$pid" ]; then
    echo "cmdline:"; tr '\0' ' ' < /proc/$pid/cmdline; echo
    echo "env (SLURM_* only):"; strings /proc/$pid/environ | grep -E '^SLURM|^SLURM_' || true
    echo "open slurm.conf (if any):"; sudo lsof -p $pid 2>/dev/null | grep slurm.conf || echo "none"
  fi
done

# 4) If configless is expected, confirm it's actually ON
echo "---- Configless status ----"
scontrol show config | grep -i 'Configless\|SlurmctldParameters'

# 5) Bonus: show how slurmd was pointed to the controller (Debian/Ubuntu)
echo "---- /etc/default/slurmd (if present) ----"
sudo sed -n '1,80p' /etc/default/slurmd 2>/dev/null || echo "no /etc/default/slurmd"
