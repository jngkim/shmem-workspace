#!/bin/bash

OSU_BUILD=${OSU_BUILD:-${HOME}/shmem-workspace/build/osu-bench}
DEBUG_AFFINITY=${DEBUG_AFFINITY:-0}
NREPS_MPI=${NREPS_MPI:-5}
NREPS_SHM=${NREPS_SHM:-5}

mkdir -p ${OSU_BUILD}

mpi_put=${OSU_BUILD}/mpi/one-sided/osu_put_latency
p2p_put=${OSU_BUILD}/mpi/pt2pt/standard/osu_latency
shm_put=${OSU_BUILD}/openshmem/osu_oshm_put

MPI_BIND2_C="${BIND2_C}"
MPI_BIND2_S="${BIND2_S}"
MPI_BIND2_N="${BIND2_N}"
if [[ "${USE_I_MPI:-0}" -eq 1 ]]; then
  MPI_BIND2_C="${IMPI_BIND2_C}"
  MPI_BIND2_S="${IMPI_BIND2_S}"
  MPI_BIND2_N="${IMPI_BIND2_N}"
fi

if [[ "${DEBUG_AFFINITY}" == "1" ]]; then
  export I_MPI_DEBUG=5
  timeout 10 mpirun -np 2 -ppn 2 ${MPI_BIND2_C} ${mpi_put} 2>&1 | tee -a ${out_dir}/mpi.core.debug.dat
  timeout 10 mpirun -np 2 -ppn 2 ${MPI_BIND2_S} ${mpi_put} 2>&1 | tee -a ${out_dir}/mpi.socket.debug.dat
  timeout 10 mpirun -np 2 -ppn 1 ${NO_VNI} ${MPI_BIND2_N} ${mpi_put} 2>&1 | tee -a ${out_dir}/mpi.node.debug.dat
  unset I_MPI_DEBUG
  #check_bad_termination
fi

for m in cas put fop;
do
 mpi_exe=${OSU_BUILD}/mpi/one-sided/osu_${m}_latency
 for a in $(seq 1 ${NREPS_MPI}); do timeout 10 mpirun -np 2 -ppn 2 ${MPI_BIND2_C} ${mpi_exe} >> ${out_dir}/mpi.${m}.core.dat   ; sleep 2 ; done
 for a in $(seq 1 ${NREPS_MPI}); do timeout 10 mpirun -np 2 -ppn 2 ${MPI_BIND2_S} ${mpi_exe} >> ${out_dir}/mpi.${m}.socket.dat ; sleep 2 ; done
 for a in $(seq 1 ${NREPS_MPI}); do timeout 10 mpirun -np 2 -ppn 1 ${NO_VNI} ${MPI_BIND2_N} ${mpi_exe} >> ${out_dir}/mpi.${m}.node.dat   ; sleep 2 ; done
done

mpi_exe=${OSU_BUILD}/mpi/collective/blocking/osu_barrier
for a in $(seq 1 ${NREPS_MPI}); do timeout 10 mpirun -np 2 -ppn 2 ${MPI_BIND2_C} ${mpi_exe} >> ${out_dir}/mpi.barrier.core.dat   ; sleep 2 ; done
for a in $(seq 1 ${NREPS_MPI}); do timeout 10 mpirun -np 2 -ppn 2 ${MPI_BIND2_S} ${mpi_exe} >> ${out_dir}/mpi.barrier.socket.dat ; sleep 2 ; done
for a in $(seq 1 ${NREPS_MPI}); do timeout 10 mpirun -np 2 -ppn 1 ${NO_VNI} ${MPI_BIND2_N} ${mpi_exe} >> ${out_dir}/mpi.barrier.node.dat   ; sleep 2 ; done

#if [[ "${PLATFORM}" == "ib" ]]; then
# export FI_PROVIDER=verbs
# if [[ "${CLUSTER}" == "florence" ]]; then
#   # Workaround for intra-node hangs
#   export FI_VERBS_IFACE="ib0"
# fi
#fi

if [[ "${DEBUG_AFFINITY}" == "1" ]]; then
  export SHMEM_DEBUG=1
  for X in "${SOS_LIST[@]}"; do
    export CVARS="-genv LD_LIBRARY_PATH=$BASE/install/$X/lib:$LD_LIBRARY_PATH"
    timeout 60 mpirun ${CVARS} -np 2 -ppn 2 ${BIND2_C} ${shm_put} heap 2>&1 | tee -a ${out_dir}/$X.core.debug.dat
    timeout 60 mpirun ${CVARS} -np 2 -ppn 2 ${BIND2_S} ${shm_put} heap 2>&1 | tee -a ${out_dir}/$X.socket.debug.dat
    timeout 60 mpirun ${CVARS} -np 2 -ppn 1 ${NO_VNI} ${BIND2_N} ${shm_put} heap 2>&1 | tee -a ${out_dir}/$X.node.debug.dat
    #check_bad_termination
  done
  unset SHMEM_DEBUG
fi

for X in "${SOS_LIST[@]}"; do
  export CVARS="-genv LD_LIBRARY_PATH=$BASE/install/$X/lib:$LD_LIBRARY_PATH"
  for m in atomics barrier put; do
    shm_exe=${OSU_BUILD}/openshmem/osu_oshm_${m}
    for a in $(seq 1 ${NREPS_SHM}); do timeout 60 mpirun ${CVARS} -np 2 -ppn 2 ${BIND2_C} ${shm_exe} heap | tee -a ${out_dir}/$X.${m}.core.dat ; sleep 2 ; done
    for a in $(seq 1 ${NREPS_SHM}); do timeout 60 mpirun ${CVARS} -np 2 -ppn 2 ${BIND2_S} ${shm_exe} heap | tee -a ${out_dir}/$X.${m}.socket.dat ; sleep 2 ; done
    for a in $(seq 1 ${NREPS_SHM}); do timeout 60 mpirun ${CVARS} -np 2 -ppn 1 ${NO_VNI} ${BIND2_N} ${shm_exe} heap | tee -a ${out_dir}/$X.${m}.node.dat ; sleep 2 ; done
  done
done

if [[ "${HAVE_SHMEMX}" -eq 1 ]]; then
  source ${HOME}/shmem-workspace/config.cray-shmem.sh 
  for m in atomics barrier put;
  do
    shm_exe=${OSU_BUILD}/shmemx/osu_oshm_${m}
    echo "mpirun -np 2 -ppn 2 ${BIND2_C} osu_oshm_${m} heap "
    for a in $(seq 1 ${NREPS_SHM}); do timeout 30 mpirun -np 2 -ppn 2 ${BIND2_C} ${shm_exe} heap | tee -a ${out_dir}/shmemx.${m}.core.dat ; sleep 2 ; done
    echo "mpirun -np 2 -ppn 2 ${BIND2_S} osu_oshm_${m} heap "
    for a in $(seq 1 ${NREPS_SHM}); do timeout 30 mpirun -np 2 -ppn 2 ${BIND2_S} ${shm_exe} heap | tee -a ${out_dir}/shmemx.${m}.socket.dat ; sleep 2 ; done
    echo "mpirun -np 2 -ppn 1 ${BIND2_N} osu_oshm_${m} heap "
    for a in $(seq 1 ${NREPS_SHM}); do timeout 30 mpirun -np 2 -ppn 1 ${NO_VNI} ${BIND2_N} ${shm_exe} heap | tee -a ${out_dir}/shmemx.${m}.node.dat ; sleep 2 ; done
  done
fi
