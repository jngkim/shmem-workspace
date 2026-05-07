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
collect_=${HOME}/shmem-workspace/collect_telemetry.sh 

collect_telemetry() {
  local out_file=$1
  for c in \
    atu_cache_hit_base_page_size_0 \
    atu_cache_miss_0 \
    ixe_disp_amo_events \
    ixe_disp_lpe_amos_ok \
    pct_retry_trs_put \
    mst_stalled_waiting_put_crdts \
    $(seq -f 'pct_req_rsp_latency_%g' 0 31); do
      total=0
      for n in /sys/class/cxi/cxi*/device/telemetry/$c; do
        val=$(cat $n | cut -d'@' -f1)
        total=$((total + val))
      done
      echo "$c: $total" | tee -a ${out_file}
    done
}

# create an array to select binding: 64:BIND64_N, 50:BIND2C 102:BIND1C
PPN_LIST=(64 50 102)
declare -A BINDINGS
BINDINGS[64]=$BIND64_N
BINDINGS[50]=$BIND2C
BINDINGS[102]=$BIND1C

# export FI_LOG_LEVEL=info 
# export FI_LOG_PROV=cxi
# fi_info -p cxi -v 2>&1 | grep -i "mr_mode\|inject\|progress\|op_flags" | tee -a ${out_dir}/fi_info.default.txt
#
for m in atomics2 barrier put_mr;
do
  for ppn in "${PPN_LIST[@]}"; do
    nranks=$(( nnodes * ppn ))
    output=${out_dir}/sos.${m}.N${nnodes}.p${ppn}.dat
    shm_exe=${OSU_BUILD}/openshmem/osu_oshm_${m}
    pdsh -w ^$PBS_NODEFILE ${collect} $collect_ ${output}
    #echo "------------------------------" | tee -a ${output}
    #if m == atomics2, int fadd
    if [[ "${m}" == "atomics2" ]]; then
      mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} heap int fadd | tee -a ${output}
    else
      mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} heap | tee -a ${output}
    fi
    
    #echo "------------------------------" | tee -a ${output}
    pdsh -w ^$PBS_NODEFILE ${collect} $collect_ ${output}
  done
done


source ${HOME}/shmem-workspace/config.cray-shmem.sh
for m in atomics2 barrier put_mr;
do
  shm_exe=${OSU_BUILD}/shmemx/osu_oshm_${m}
  for ppn in "${PPN_LIST[@]}"; do
    nranks=$(( nnodes * ppn ))
    output=${out_dir}/shmemx.${m}.N${nnodes}.p${ppn}.dat
    pdsh -w ^$PBS_NODEFILE ${collect} $collect_ ${output}
    #echo "------------------------------" | tee -a ${output}
    if [[ "${m}" == "atomics2" ]]; then
      mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} heap int fadd | tee -a ${output}
    else
      mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} heap | tee -a ${output}
    fi
    #echo "------------------------------" | tee -a ${output}
    pdsh -w ^$PBS_NODEFILE ${collect} $collect_ ${output}
  done
done
