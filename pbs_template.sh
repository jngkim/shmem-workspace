#!/bin/bash
#PBS -N osumb
#PBS -l nodes=2
#PBS -l walltime=00:30:00
#PBS -j n
#PBS -A Intel-Punchlist

nnodes_avail=$(wc $PBS_NODEFILE| awk '{print $1}')
nnodes=${NNODES:-$nnodes_avail}
LOCAL_WORLD_SIZE=${PPN:-2}
WORLD_SIZE=$(( nnodes * LOCAL_WORLD_SIZE ))
echo "WORLD_SIZE="${WORLD_SIZE} "LOCAL_WORLD_SIZE="${LOCAL_WORLD_SIZE}

JOBID=${PBS_JOBID%%.*}
JOB_NAME=${PBS_JOBNAME:-osumb}
TIMESTAMP=$(date +%Y%m%d)

cd $PBS_O_WORKDIR

outdir=/home/jnkim/shmem-workspace/dummy
# show how to pass ENVs to pbsdsh
pbsdsh -- env TELEMETRY_OUTDIR=$outdir /home/jnkim/shmem-workspace/cxi_telemetry_snapshot.sh
