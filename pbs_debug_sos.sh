#!/bin/bash
#PBS -N debug
#PBS -l nodes=2
#PBS -l walltime=00:30:00
#PBS -j n
#PBS -A Intel-Punchlist
#PBS -l filesystems=home

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
env | grep FI_ | grep -v LMOD  >> ${out_dir}/env.txt
env | grep SHMEM_  >> ${out_dir}/env.txt

cp $PBS_NODEFILE ${out_dir}/hostfile

export NNODES=${nnodes}

export BASE=${BASE:-${HOME}/shmem-workspace/build/latest}
source ${BASE}/setup_sos_ofi.sh

OSU_BUILD=${OSU_BUILD:-${HOME}/shmem-workspace/build/osu-bench}

cd ${out_dir}
ppn=8
nranks=$(( nnodes * ppn ))
export BIND8_N="--cpu-bind list:1-12:14-25:27-38:40-51:53-64:66-77:79-90:92-103"

m=atomics2
shm_exe=${OSU_BUILD}/openshmem/osu_oshm_${m}

echo "SOS"
export SHMEM_DEBUG=1
mpirun -np ${nranks} -ppn ${ppn} ${BIND8_N}  ${shm_exe} heap int fadd
export FI_LOG_LEVEL=debug 
mpirun -np ${nranks} -ppn ${ppn} ${BIND8_N} \
	-outfile-pattern sos.fadd.rank%r.out \
	-errfile-pattern sos.fadd.rank%r.err \
	${shm_exe} heap int fadd

echo "SHMEMX"
source ${HOME}/shmem-workspace/config.cray-shmem.sh
shm_exe=${OSU_BUILD}/shmemx/osu_oshm_${m}
mpirun -np ${nranks} -ppn ${ppn} ${BIND8_N}  ${shm_exe} heap int fadd
export SHMEM_DEBUG_LEVEL=5 
mpirun -np ${nranks} -ppn ${ppn} ${BIND8_N} \
	-outfile-pattern shmemx.fadd.rank%r.out \
	-errfile-pattern shmemx.fadd.rank%r.err \
	${shm_exe} heap int fadd
