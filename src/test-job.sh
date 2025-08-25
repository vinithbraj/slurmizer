# Create a test script
cat > test_job_1.sh <<'EOF'
#!/bin/bash
#SBATCH -J testjob
#SBATCH --error slurm-%j.err
#SBATCH --output slurm-%j.out
#SBATCH -p debug      # partition name from your slurm.conf

echo "Hello from $(hostname) at $(date) - Starting"
sleep 30
echo "Hello from $(hostname) at $(date) - Done"

EOF

# Submit
sbatch test_job_1.sh
