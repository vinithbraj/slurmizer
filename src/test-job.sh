# --- Create a new batch script named test_job_1.sh ---
cat > test_job_1.sh <<'EOF'
#!/bin/bash                     # Use bash as the shell for this job script

#SBATCH -J testjob              # Job name (shows up in squeue/sacct)
#SBATCH --error slurm-%j.err    # File to write STDERR (errors), %j expands to job ID
#SBATCH --output slurm-%j.out   # File to write STDOUT (normal output), %j expands to job ID
#SBATCH -p debug                # Partition to submit to (must exist in slurm.conf)

# --- Commands that will run on the allocated compute node(s) ---

echo "Hello from $(hostname) at $(date) - Starting"   # Print node + timestamp
sleep 30                                             # Simulate a workload (30s sleep)
echo "Hello from $(hostname) at $(date) - Done"      # Print node + timestamp again

EOF
# --- End of script file ---

# --- Submit the job script to Slurm ---
sbatch test_job_1.sh