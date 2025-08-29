1. Run the controller script 
2. Run the gpu node script
3. Run the slurm web script 
4. Enable slurmdbd in addition to slurm in /etc/systemd/system/slurmrestd.service/override.conf - reload systemctl daemon-reload
and reboot.
5. Ensure the munge keys are properly shared copy munge key from controller to worker /etc/munge/munge.key
6. Ensure the controller and worker are able to resolve each other (add mutual entries in /etc/hosts)
