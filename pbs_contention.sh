#!/bin/bash
#PBS -N osu.combo
#PBS -l nodes=2
#PBS -l walltime=01:00:00
#PBS -j n
#PBS -A Intel-Punchlist

#set -x

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
export BASE=${BASE:-${HOME}/shmem-workspace/build/latest}
export NO_VNI="--no-vni"
OSU_BUILD=${OSU_BUILD:-${HOME}/shmem-workspace/build/osu-bench}
min_bytes=${MIN_BYTES:-1024}
max_bytes=${MAX_BYTES:-8192}

out_dir=${HOME}/shmem-workspace/results/${CLUSTER}/${JOB_NAME}.${JOBID}
mkdir -p ${out_dir}
env | grep CLUSTER >> ${out_dir}/env.txt
env | grep PLATFORM >> ${out_dir}/env.txt
env | grep SLURM >> ${out_dir}/env.txt
env | grep FI | grep -v LMOD  >> ${out_dir}/env.txt
#cp $PBS_NODEFILE ${out_dir}/hostfile
cat $PBS_NODEFILE |  cut -d '.' -f 1 | tee -a ${out_dir}/hostfile

declare -ax APP_LIST=(single bucket)
declare -Ax APP_BIN
APP_BIN["single"]=fadd_put_single
APP_BIN["bucket"]=fadd_put_bucket

PUT_LIST=(0 1)
AMO_LIST=(0 1)

SOS=(sos sos-xpmem sos-opt)
out_dir_top=$out_dir

run_sos_barrier() {
  app_tag="barrier"
  out_dir=${out_dir_top}/${app_tag}
  mkdir -p ${out_dir}
  app=osu_oshm_barrier

  for SOS_LIB in "${SOS[@]}"; do
    export CVARS="-genv LD_LIBRARY_PATH=$BASE/install/$SOS_LIB/lib:$LD_LIBRARY_PATH"
    shm_exe=${OSU_BUILD}/openshmem/${app}
    export NIC_MAPPER=""
    for ppn in 64  $BIND1C_MAX; do
      nranks=$(( nnodes * ppn ))
      timeout 300 mpirun ${CVARS} ${NO_VNI} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${NIC_MAPPER} ${shm_exe} \
        | tee -a ${out_dir}/${SOS_LIB}.nic8.N${nnodes}.p${ppn}.dat 
    done

    export NIC_MAPPER=${HOME}/shmem-workspace/cxi_mapper.sh
    for ppn in 64  $BIND1C_MAX; do
      nranks=$(( nnodes * ppn ))
      timeout 300 mpirun ${CVARS} ${NO_VNI} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${NIC_MAPPER} ${shm_exe} \
        | tee -a ${out_dir}/${SOS_LIB}.nic2.N${nnodes}.p${ppn}.dat 
    done
  done
}

run_sos_barrier

# applicaion speicifc settings
for app_tag in "${APP_LIST[@]}"; do
  out_dir=${out_dir_top}/${app_tag}
  mkdir -p ${out_dir}
  app=${APP_BIN[$app_tag]}

  for SOS_LIB in "${SOS[@]}"; do
    export CVARS="-genv LD_LIBRARY_PATH=$BASE/install/$SOS_LIB/lib:$LD_LIBRARY_PATH"
    shm_exe=${OSU_BUILD}/openshmem/${app}
    export NIC_MAPPER=""
    for ppn in 64  $BIND1C_MAX; do
      nranks=$(( nnodes * ppn ))
      for put in "${PUT_LIST[@]}"; do
        for amo in "${AMO_LIST[@]}"; do
          echo "SOS: N=${nnodes} PPN=${ppn} AMO=${amo} PUT=${put} NIC=8"
          opts="heap ${put} ${amo} ${min_bytes} ${max_bytes}"
          timeout 300 mpirun ${CVARS} ${NO_VNI} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${NIC_MAPPER} ${shm_exe} ${opts} \
            | tee -a ${out_dir}/${SOS_LIB}.nic8.N${nnodes}.p${ppn}.dat 
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
            timeout 300 mpirun ${CVARS} ${NO_VNI} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${NIC_MAPPER} ${shm_exe} ${opts} \
              | tee -a ${out_dir}/${SOS_LIB}.nic2.N${nnodes}.p${ppn}.dat 
            done
          done
        done

      done

    done  # app_tag

if [[ "${HAVE_SHMEMX}" -eq 1 ]]; then
source ${HOME}/shmem-workspace/config.cray-shmem.sh

run_shmemx_barrier() {
  SOS_LIB=$1
  app_tag="barrier"
  out_dir=${out_dir_top}/${app_tag}
  mkdir -p ${out_dir}
  app=osu_oshm_barrier

  shm_exe=${OSU_BUILD}/shmemx/${app}
  unset SHMEM_OFI_NIC_POLICY
  for ppn in 64  $BIND1C_MAX; do
    nranks=$(( nnodes * ppn ))
    NVAR=""
    timeout 300 mpirun ${NVAR} ${NO_VNI} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} \
      | tee -a ${out_dir}/shmemx.nic8.N${nnodes}.p${ppn}.dat
  done
  export SHMEM_OFI_NIC_POLICY=USER
  for ppn in 64  $BIND1C_MAX; do
    nranks=$(( nnodes * ppn ))
    NVAR="-genv SHMEM_OFI_NIC_MAPPING=0:0-$((ppn/2-1));4:$((ppn/2))-$((ppn-1))"
    timeout 300 mpirun ${NVAR} ${NO_VNI} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} \
      | tee -a ${out_dir}/shmemx.nic2.N${nnodes}.p${ppn}.dat
  done
}

run_shmemx_barrier
for app_tag in "${APP_LIST[@]}"; do
  out_dir=${out_dir_top}/${app_tag}
  mkdir -p ${out_dir}
  app=${APP_BIN[$app_tag]}
  shm_exe=${OSU_BUILD}/shmemx/${app}

  unset SHMEM_OFI_NIC_POLICY
  for ppn in 64  $BIND1C_MAX; do
    nranks=$(( nnodes * ppn ))
    NVAR=""
    for put in "${PUT_LIST[@]}"; do
      for amo in "${AMO_LIST[@]}"; do
        echo "SHMEMX: N=${nnodes} PPN=${ppn} AMO=${amo} PUT=${put} NIC=8"
        opts="heap ${put} ${amo} ${min_bytes} ${max_bytes}"
        timeout 300 mpirun ${NVAR} ${NO_VNI} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} ${opts} \
          | tee -a ${out_dir}/shmemx.nic8.N${nnodes}.p${ppn}.dat
        done
      done
    done # ppn

    export SHMEM_OFI_NIC_POLICY=USER
    for ppn in 64  $BIND1C_MAX; do
      nranks=$(( nnodes * ppn ))
      NVAR="-genv SHMEM_OFI_NIC_MAPPING=0:0-$((ppn/2-1));4:$((ppn/2))-$((ppn-1))"
      for put in "${PUT_LIST[@]}"; do
        for amo in "${AMO_LIST[@]}"; do
          echo "SHMEMX: N=${nnodes} PPN=${ppn} AMO=${amo} PUT=${put} NIC=2"
          opts="heap ${put} ${amo} ${min_bytes} ${max_bytes}"
          timeout 300 mpirun ${NVAR} ${NO_VNI} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} ${opts} \
            | tee -a ${out_dir}/shmemx.nic2.N${nnodes}.p${ppn}.dat
          done
        done
      done # ppn

    done # app_tag
fi
