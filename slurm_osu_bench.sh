#!/bin/bash
#SBATCH --job-name=osumb
#SBATCH --output=%x.o%j
#SBATCH --error=%x.e%j
#SBATCH --nodes=2
#SBATCH --time=00:30:00

set -x

nnodes=${NNODES:-$SLURM_NNODES}
LOCAL_WORLD_SIZE=${PPN:-2}
WORLD_SIZE=$(( nnodes * LOCAL_WORLD_SIZE ))
echo "WORLD_SIZE="${WORLD_SIZE} "LOCAL_WORLD_SIZE="${LOCAL_WORLD_SIZE}

JOBID=${SLURM_JOB_ID%%.*}
JOB_NAME=${SLURM_JOB_NAME:-osumb}
TIMESTAMP=$(date +%Y%m%d)

source ${HOME}/shmem-workspace/cpu_bind.sh
source ${HOME}/shmem-workspace/config.v2.sh

out_dir=${HOME}/shmem-workspace/results/${CLUSTER}/${JOB_NAME}.${JOBID}
mkdir -p ${out_dir}

env | grep CLUSTER >> ${out_dir}/env.txt
env | grep PLATFORM >> ${out_dir}/env.txt
env | grep SLURM >> ${out_dir}/env.txt

export BASE=${BASE:-${HOME}/shmem-workspace/build/latest}
export OFI_INSTALL=${OFI_INSTALL:-${BASE}/install/ofi}
export SOS_OFI_INSTALL=${BASE}/install/sos
export SOS_UCX_INSTALL=${BASE}/install/sos-ucx
export SOS_OFI_LIB_PATH=${SOS_OFI_INSTALL}/lib:${OFI_INSTALL}/lib

# GPU is not used
unset I_MPI_OFFLOAD
unset I_MPI_OFFLOAD_RDMA
export NNODES=${nnodes}

if [[ "$JOB_NAME" == *"pair"* ]]; then
  echo "Running two-rank benchmarks"
  source ${HOME}/shmem-workspace/osu_pair_bench.sh
fi

if [[ "$JOB_NAME" == *"multi"* ]]; then
  echo "Running multi-rank benchmarks"
  source ${HOME}/shmem-workspace/osu_multi_bench.sh
fi
