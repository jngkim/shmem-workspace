#!/bin/bash

check_bad_termination() {
  # check if any of debug.dat file contains "BAD TERMINATION"
  if grep -q "BAD TERMINATION" ${out_dir}/*.debug.dat; then
    echo "ERROR: BAD TERMINATION detected in debug output. Please check ${out_dir}/*.debug.dat for details."
    grep "RANK " ${out_dir}/*.debug.dat | tee -a ${out_dir}/bad_termination_summary.txt
    exit 1
  else
    echo "Debug output looks good, no BAD TERMINATION found."
  fi
}

OSU_SRC=${OSU_SRC:-${HOME}/shmem-workspace/repos/osu-micro-benchmarks-7.5.2}
OSU_BUILD=${OSU_BUILD:-${HOME}/shmem-workspace/build/osu-bench}
DEBUG_AFFINITY=${DEBUG_AFFINITY:-1}

mkdir -p ${OSU_BUILD}

mpi_put=${OSU_BUILD}/mpi/one-sided/osu_put_latency
p2p_put=${OSU_BUILD}/mpi/pt2pt/standard/osu_latency
shm_put=${OSU_BUILD}/openshmem/osu_oshm_put

SKIP_OSU_BUILD=${SKIP_OSU_BUILD:-1}
if [[ ! -f ${shm_put} ]] || [[ "${SKIP_OSU_BUILD}" == "0" ]]; then
  cmake -S ${OSU_SRC}/c/mpi -B ${OSU_BUILD}/mpi \
    -DCMAKE_CXX_COMPILER=mpicxx -DCMAKE_C_COMPILER=mpicc
  cmake --build ${OSU_BUILD}/mpi --parallel

  export PKG_CONFIG_PATH=${SOS_INSTALL}/lib/pkgconfig:$PKG_CONFIG_PATH
  cmake -S ${OSU_SRC}/c/openshmem -B ${OSU_BUILD}/openshmem \
    -DCMAKE_CXX_COMPILER=mpicxx -DCMAKE_C_COMPILER=mpicc
  cmake --build ${OSU_BUILD}/openshmem --parallel
fi

MPI_BIND2_C="${BIND2_C}"
MPI_BIND2_S="${BIND2_S}"
MPI_BIND2_N="${BIND2_N}"
if [[ "${USE_I_MPI:-0}" -eq 1 ]]; then
  MPI_BIND2_C="${IMPI_BIND2_C}"
  MPI_BIND2_S="${IMPI_BIND2_S}"
  MPI_BIND2_N="${IMPI_BIND2_N}"
fi

export _library_path=$LD_LIBRARY_PATH

if [[ "${DEBUG_AFFINITY}" == "1" ]]; then
  export I_MPI_DEBUG=5
  timeout 10 mpirun -np 2 -ppn 2 ${MPI_BIND2_C} ${mpi_put} 2>&1 | tee -a ${out_dir}/mpi.core.debug.dat
  timeout 10 mpirun -np 2 -ppn 2 ${MPI_BIND2_S} ${mpi_put} 2>&1 | tee -a ${out_dir}/mpi.socket.debug.dat
  timeout 10 mpirun -np 2 -ppn 1 ${MPI_BIND2_N} ${mpi_put} 2>&1 | tee -a ${out_dir}/mpi.node.debug.dat
  unset I_MPI_DEBUG
  #check_bad_termination
fi
echo "running ${mpi_put}"
for a in {1..10}; do timeout 10 mpirun -np 2 -ppn 2 ${MPI_BIND2_C} ${mpi_put} >> ${out_dir}/mpi.core.dat   ; sleep 2 ; done
for a in {1..10}; do timeout 10 mpirun -np 2 -ppn 2 ${MPI_BIND2_S} ${mpi_put} >> ${out_dir}/mpi.socket.dat ; sleep 2 ; done
for a in {1..10}; do timeout 10 mpirun -np 2 -ppn 1 ${MPI_BIND2_N} ${mpi_put} >> ${out_dir}/mpi.node.dat   ; sleep 2 ; done
echo "running ${p2p_put}"
for a in {1..10}; do timeout 10 mpirun -np 2 -ppn 2 ${MPI_BIND2_C} ${p2p_put} >> ${out_dir}/mpi2.core.dat   ; sleep 2 ; done
for a in {1..10}; do timeout 10 mpirun -np 2 -ppn 2 ${MPI_BIND2_S} ${p2p_put} >> ${out_dir}/mpi2.socket.dat ; sleep 2 ; done
for a in {1..10}; do timeout 10 mpirun -np 2 -ppn 1 ${MPI_BIND2_N} ${p2p_put} >> ${out_dir}/mpi2.node.dat   ; sleep 2 ; done

echo "Adding SOS_OFI_LIB_PATH=${SOS_OFI_LIB_PATH}"
export LD_LIBRARY_PATH=${SOS_OFI_LIB_PATH}:$_library_path
export FI_PROVIDER=verbs
if [[ "${CLUSTER}" == "florence" ]]; then
  # Workaround for intra-node hangs
  export FI_VERBS_IFACE="ib0"
fi

if [[ "${DEBUG_AFFINITY}" == "1" ]]; then
  export SHMEM_DEBUG=1
  timeout 10 mpirun -np 2 -ppn 2 ${BIND2_C} ${shm_put} heap 2>&1 | tee -a ${out_dir}/sos.core.debug.dat
  timeout 10 mpirun -np 2 -ppn 2 ${BIND2_S} ${shm_put} heap 2>&1 | tee -a ${out_dir}/sos.socket.debug.dat
  timeout 10 mpirun -np 2 -ppn 1 ${BIND2_N} ${shm_put} heap 2>&1 | tee -a ${out_dir}/sos.node.debug.dat
  unset SHMEM_DEBUG
  #check_bad_termination
fi

echo "Running ${shm_put}"
for a in {1..10}; do timeout 10 mpirun -np 2 -ppn 2 ${BIND2_C} ${shm_put} heap >> ${out_dir}/sos.core.dat   ; sleep 2 ; done
for a in {1..10}; do timeout 10 mpirun -np 2 -ppn 2 ${BIND2_S} ${shm_put} heap >> ${out_dir}/sos.socket.dat ; sleep 2 ; done
for a in {1..10}; do timeout 10 mpirun -np 2 -ppn 1 ${BIND2_N} ${shm_put} heap >> ${out_dir}/sos.node.dat   ; sleep 2 ; done

unset FI_PROVIDER
unset FI_VERBS_IFACE
if [[ -n "${SOS_UCX_INSTALL}" ]]; then
  export LD_LIBRARY_PATH=${SOS_UCX_INSTALL}/lib:$_library_path
  echo "Running ${shm_put}"
  for a in {1..10}; do timeout 10 mpirun -np 2 -ppn 2 ${BIND2_C} ${shm_put} heap >> ${out_dir}/sos-ucx.core.dat   ; sleep 2 ; done
  for a in {1..10}; do timeout 10 mpirun -np 2 -ppn 2 ${BIND2_S} ${shm_put} heap >> ${out_dir}/sos-ucx.socket.dat ; sleep 2 ; done
  for a in {1..10}; do timeout 10 mpirun -np 2 -ppn 1 ${BIND2_N} ${shm_put} heap >> ${out_dir}/sos-ucx.node.dat   ; sleep 2 ; done
  export LD_LIBRARY_PATH=$_library_path
fi
