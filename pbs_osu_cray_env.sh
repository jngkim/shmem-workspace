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
env | grep FI_ | grep -v LMOD  >> ${out_dir}/env.txt
env | grep SHMEM_  >> ${out_dir}/env.txt

cp $PBS_NODEFILE ${out_dir}/hostfile

export NNODES=${nnodes}

export BASE=${BASE:-${HOME}/shmem-workspace/build/latest}
source ${BASE}/setup_sos_ofi.sh

OSU_BUILD=${OSU_BUILD:-${HOME}/shmem-workspace/build/osu-bench}

# BounceBuffer size
BBSIZE=( 0 512 1024 2048 4096 8192 16384)
# Binding map
PPN_LIST=(64 $BIND2C_MAX $BIND1C_MAX)
declare -A BINDINGS
BINDINGS[64]=$BIND64_N
BINDINGS[$BIND2C_MAX]=$BIND2C
BINDINGS[$BIND1C_MAX]=$BIND1C

#for m in atomics barrier put_mr;
for m in put_mr; do
  shm_exe=${OSU_BUILD}/openshmem/osu_oshm_${m}
  for ppn in "${PPN_LIST[@]}"; do
    nranks=$(( nnodes * ppn ))
    for bounce_buffer in "${BBSIZE[@]}"; do
      export SHMEM_BOUNCE_SIZE=${bounce_buffer}
      echo "SHMEM_BOUNCE_SIZE: ${bounce_buffer}" | tee -a ${out_dir}/sos.${m}.N${nnodes}.p${ppn}.dat
      mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} heap | tee -a ${out_dir}/sos.${m}.N${nnodes}.p${ppn}.dat 
      echo
    done
  done
done

if [[ "${HAVE_SHMEMX}" -eq 1 ]]; then
  unset SHMEM_BOUNCE_SIZE
  source ${HOME}/shmem-workspace/config.cray-shmem.sh
  for m in put_mr; do
    shm_exe=${OSU_BUILD}/shmemx/osu_oshm_${m}

    for ppn in "${PPN_LIST[@]}"; do
      nranks=$(( nnodes * ppn ))
      mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} heap | tee -a ${out_dir}/shmemx.${m}.N${nnodes}.p${ppn}.dat
      echo
    done
  done
fi
