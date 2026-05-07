#!/bin/bash
#PBS -N osumb
#PBS -l nodes=2
#PBS -l walltime=00:30:00
#PBS -j n
#PBS -A Intel-Punchlist

set -x

nnodes_avail=$(wc $PBS_NODEFILE| awk '{print $1}')
nnodes=${NNODES:-$nnodes_avail}
LOCAL_WORLD_SIZE=${PPN:-2}
WORLD_SIZE=$(( nnodes * LOCAL_WORLD_SIZE ))
echo "WORLD_SIZE="${WORLD_SIZE} "LOCAL_WORLD_SIZE="${LOCAL_WORLD_SIZE}

JOBID=${PBS_JOBID%%.*}
JOB_NAME=${PBS_JOBNAME:-osumb}
TIMESTAMP=$(date +%Y%m%d)

source ${HOME}/shmem-workspace/cpu_bind.sh exclude
source ${HOME}/shmem-workspace/config.v2.sh

out_dir=${HOME}/shmem-workspace/results/${CLUSTER}/${JOB_NAME}.${JOBID}
mkdir -p ${out_dir}

env | grep CLUSTER >> ${out_dir}/env.txt
env | grep PLATFORM >> ${out_dir}/env.txt
env | grep SLURM >> ${out_dir}/env.txt
env | grep FI | grep -v LMOD  >> ${out_dir}/env.txt
cp $PBS_NODEFILE ${out_dir}/hostfile

export NNODES=${nnodes}

export BASE=${BASE:-${HOME}/shmem-workspace/build/latest}
source ${BASE}/setup_sos_ofi.sh

if [[ "$JOB_NAME" == *"pair"* ]]; then
  echo "Running two-rank benchmarks"
  source ${HOME}/shmem-workspace/osu_pair_bench.sh
fi

if [[ "$JOB_NAME" == *"multi"* ]]; then
  echo "Running multi-rank benchmarks"
  source ${HOME}/shmem-workspace/osu_multi_bench.sh
fi
