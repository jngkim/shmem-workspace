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

export BASE=${BASE:-${HOME}/shmem-workspace/build/latest}
OSU_BUILD=${OSU_BUILD:-${HOME}/shmem-workspace/build/osu-bench}
SOS_LIB=${SOS_LIB:-sos}

# applicaion speicifc settings
app=cust_nail_clone
min_bytes=${MIN_BYTES:-1024}
max_bytes=${MAX_BYTES:-8192}

# skip PUT scan since it is expacted to be less critical than AMO scan
PUT_LIST=(0)
AMO_LIST=(0 20 40 60 80 100)

export CVARS="-genv LD_LIBRARY_PATH=$BASE/install/$SOS_LIB/lib:$LD_LIBRARY_PATH"
shm_exe=${OSU_BUILD}/openshmem/${app}
export NIC_MAPPER=""
for ppn in 64  $BIND1C_MAX; do
  nranks=$(( nnodes * ppn ))
  for put in "${PUT_LIST[@]}"; do
    for amo in "${AMO_LIST[@]}"; do
      echo "SOS: N=${nnodes} PPN=${ppn} AMO=${amo} PUT=${put} NIC=8"
      opts="heap ${put} ${amo} ${min_bytes} ${max_bytes}"
      timeout 300 mpirun ${CVARS} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${NIC_MAPPER} ${shm_exe} ${opts} \
        | tee -a ${out_dir}/sos.nic8.N${nnodes}.p${ppn}.dat 
      done
  done
done

export NIC_MAPPER=${HOME}/shmem-workspace/cxi_mapper.sh
for ppn in 64  $BIND1C_MAX; do
  nranks=$(( nnodes * ppn ))
  for put in "${PUT_LIST[@]}"; do
    for amo in "${AMO_LIST[@]}"; do
      echo "SOS: N=${nnodes} PPN=${ppn} AMO=${amo} PUT=${put} NIC=2"
      opts="heap ${put} ${amo} ${min_bytes} ${max_bytes}"
      timeout 300 mpirun ${CVARS} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${NIC_MAPPER} ${shm_exe} ${opts} \
        | tee -a ${out_dir}/sos.nic2.N${nnodes}.p${ppn}.dat 
      done
  done
done

if [[ "${HAVE_SHMEMX}" -eq 1 ]]; then
source ${HOME}/shmem-workspace/config.cray-shmem.sh
shm_exe=${OSU_BUILD}/shmemx/${app}
for ppn in 64  $BIND1C_MAX; do
  nranks=$(( nnodes * ppn ))
  NVAR=""
  for put in "${PUT_LIST[@]}"; do
    for amo in "${AMO_LIST[@]}"; do
      echo "SHMEMX: N=${nnodes} PPN=${ppn} AMO=${amo} PUT=${put} NIC=8"
      opts="heap ${put} ${amo} ${min_bytes} ${max_bytes}"
      timeout 300 mpirun ${NVAR} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} ${opts} \
        | tee -a ${out_dir}/shmemx.nic8.N${nnodes}.p${ppn}.dat
      done
  done
done

export SHMEM_OFI_NIC_POLICY=USER
for ppn in 64  $BIND1C_MAX; do
  nranks=$(( nnodes * ppn ))
  NVAR="-genv SHMEM_OFI_NIC_MAPPING=0:0-$((ppn/2-1));4:$((ppn/2))-$((ppn-1))"
  for put in "${PUT_LIST[@]}"; do
    for amo in "${AMO_LIST[@]}"; do
      echo "SHMEMX: N=${nnodes} PPN=${ppn} AMO=${amo} PUT=${put} NIC=2"
      opts="heap ${put} ${amo} ${min_bytes} ${max_bytes}"
      timeout 300 mpirun ${NVAR} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} ${opts} \
        | tee -a ${out_dir}/shmemx.nic2.N${nnodes}.p${ppn}.dat
    done
  done
done
fi
