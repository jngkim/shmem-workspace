#!/bin/bash
################################################################################
# Node-Scaling Study for SHMEM Contention Benchmarks
#
# Purpose: Orchestrates a scaling study that runs the contention benchmark
#          across multiple node counts, automatically chaining jobs.
#
# Usage:
#   qsub -N nail_scaling -l nodes=2 -l filesystems=home pbs_scaling_study.sh
#
# The framework automatically:
#   1. Runs nail_contention.sh with the allocated node count
#   2. Submits the next job in the NODE_COUNTS sequence
#   3. After the last job, submits a cleanup job to organize output files
#
# To customize the scaling sweep, set NODE_COUNTS before submitting:
#   export NODE_COUNTS="2 4 8 16"
#   qsub -N nail_scaling -l nodes=2 -l filesystems=home pbs_scaling_study.sh
#
################################################################################

#PBS -N nail
#PBS -l nodes=2
#PBS -l walltime=00:30:00
#PBS -l filesystems=home
#PBS -j n
#PBS -A Intel-Punchlist

# ── Configuration ────────────────────────────────────────────────────────────
# Node counts to sweep across. Modify this array to change the scaling study.
declare -a NODE_COUNTS=(2 4 8)

# The benchmark script to run at each node count
SCRIPT_TO_RUN="${HOME}/shmem-workspace/nail_contention.sh"

# Convert array to space-separated string for passing to pbs_node_scaling.sh
NODE_COUNTS_STR="${NODE_COUNTS[*]}"

# ── Invoke the generic scaling framework ──────────────────────────────────────
export SCRIPT_TO_RUN
export NODE_COUNTS="$NODE_COUNTS_STR"

source "${HOME}/shmem-workspace/pbs_node_scaling.sh"
