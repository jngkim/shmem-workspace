#!/bin/bash
#PBS -N nail
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

source ${HOME}/shmem-workspace/config.sh
source ${HOME}/shmem-workspace/cpu_bind.sh exclude

out_dir=${HOME}/shmem-workspace/results/${CLUSTER}/${JOB_NAME}.${JOBID}
mkdir -p ${out_dir}

env | grep CLUSTER >> ${out_dir}/env.txt
env | grep PLATFORM >> ${out_dir}/env.txt
env | grep SLURM >> ${out_dir}/env.txt
env | grep FI | grep -v LMOD  >> ${out_dir}/env.txt
#cp $PBS_NODEFILE ${out_dir}/hostfile
cat $PBS_NODEFILE |  cut -d '.' -f 1 | tee -a ${out_dir}/hostfile

export NNODES=${nnodes}

export BASE=${BASE:-${HOME}/shmem-workspace/build/latest}
OSU_BUILD=${OSU_BUILD:-${HOME}/shmem-workspace/build/osu-bench}

##declare -ax SOS_LIST=(sos sos-cma)
#declare -ax SOS_LIST=(sos sos-barrier)
#
#export NIC_MAPPER=${NIC_MAPPER:-}
#echo "INFO: NIC_MAPPER=${NIC_MAPPER}"
#echo "INFO: SHMEM_OFI_NIC_POLICY=${SHMEM_OFI_NIC_POLICY}"
#
min_bytes=512
max_bytes=32768

X=sos
export CVARS="-genv LD_LIBRARY_PATH=$BASE/install/$X/lib:$LD_LIBRARY_PATH"
shm_exe=${OSU_BUILD}/openshmem/cust_nail_clone
for ppn in "${PPN_LIST[@]}"; do
  nranks=$(( nnodes * ppn ))
  for put in 0 20 40 60 80 100; do
    for amo in 0 20 40 60 80 100; do
      echo "SOS: N=${nnodes} PPN=${ppn} AMO=${amo} PUT=${put} "
      timeout 300 mpirun ${CVARS} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${NIC_MAPPER} ${shm_exe} heap  ${amo} ${put}
    done
  done
done

source ${HOME}/shmem-workspace/config.cray-shmem.sh
shm_exe=${OSU_BUILD}/shmemx/cust_nail_clone
for ppn in "${PPN_LIST[@]}"; do
  nranks=$(( nnodes * ppn ))
  # if SHMEM_OFI_NIC_POLICY=USER, set NVAR; otherwise, empty (use default provider selection)
  NVAR=$([[ "${SHMEM_OFI_NIC_POLICY}" == "USER" ]] && echo "-genv SHMEM_OFI_NIC_MAPPING=0:0-$((ppn/2-1));4:$((ppn/2))-$((ppn-1))")
  for put in 0 20 40 60 80 100; do
    for amo in 0 20 40 60 80 100; do
      echo "SHMEMX: N=${nnodes} PPN=${ppn} AMO=${amo} PUT=${put} "
      timeout 300 mpirun ${NVAR} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} heap ${shm_exe} heap  ${amo} ${put}
    done
  done
done

