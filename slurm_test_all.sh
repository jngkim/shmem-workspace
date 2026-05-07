#!/bin/bash
#SBATCH --job-name=ishmem
#SBATCH --output=%x.o%j
#SBATCH --error=%x.e%j
#SBATCH --nodes=1
##SBATCH --ntasks=2
##SBATCH --ntasks-per-node=2
#SBATCH --time=01:00:00

set -x

nnodes=${NNODES:-$SLURM_NNODES}
LOCAL_WORLD_SIZE=${PPN:-2}
WORLD_SIZE=$(( nnodes * LOCAL_WORLD_SIZE ))

JOBID=${SLURM_JOBID%%.*}
JOB_NAME=${SLURM_JOB_NAME:-ishmem}
SOS_LAUNCHER=mpirun

source ${HOME}/shmem-workspace/test_all.sh
