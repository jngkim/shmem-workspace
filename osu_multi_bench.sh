#!/bin/bash

OSU_BUILD=${OSU_BUILD:-${HOME}/shmem-workspace/build/osu-bench}
DEBUG_AFFINITY=${DEBUG_AFFINITY:-0}

export _library_path=$LD_LIBRARY_PATH

nnodes=${NNODES}

BENCH=(atomics barrier put_mr)

mpi_exe=${OSU_BUILD}/mpi/collective/blocking/osu_barrier
m=barrier
for ppn in "${PPN_LIST[@]}"; do
  nranks=$(( nnodes * ppn ))
  echo "mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${mpi_exe} "
  mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${mpi_exe} | tee -a ${out_dir}/mpi.${m}.N${nnodes}.p${ppn}.dat
done

# sos tests
echo "Adding SOS_OFI_LIB_PATH=${SOS_OFI_LIB_PATH}"
export LD_LIBRARY_PATH=${SOS_OFI_LIB_PATH}:$_library_path
if [[ "${PLATFORM}" == "ib" ]]; then
  export FI_PROVIDER=verbs
  #export FI_VERBS_IFACE="ib0"
fi

if [[ "${DEBUG_AFFINITY}" == "1" ]]; then
  m=barrier
  shm_exe=${OSU_BUILD}/openshmem/osu_oshm_${m}
  export SHMEM_DEBUG=1
  for ppn in "${PPN_LIST[@]}"; do
    nranks=$(( nnodes * ppn ))
    echo "mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${mpi_exe} "
    mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shmem_exe} | tee -a ${out_dir}/sos.${m}.N${nnodes}.p${ppn}.debug.dat
  done
  unset SHMEM_DEBUG
fi

for m in "${BENCH[@]}";
do
  shm_exe=${OSU_BUILD}/openshmem/osu_oshm_${m}
  for ppn in "${PPN_LIST[@]}"; do
  nranks=$(( nnodes * ppn ))
    echo "mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} heap "
    mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} heap | tee -a ${out_dir}/sos.${m}.N${nnodes}.p${ppn}.dat 
  done
done

if [[ "${HAVE_SHMEMX}" -eq 1 ]]; then
  export LD_LIBRARY_PATH=$_library_path
  source ${HOME}/shmem-workspace/config.cray-shmem.sh
  for m in "${BENCH[@]}";
  do
    shm_exe=${OSU_BUILD}/shmemx/osu_oshm_${m}
    for ppn in "${PPN_LIST[@]}"; do
      nranks=$(( nnodes * ppn ))
      echo "mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} heap "
      mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} heap | tee -a ${out_dir}/shmemx.${m}.N${nnodes}.p${ppn}.dat 
    done
  done
fi

# sos-ucx tests
if [[ -n "${SOS_UCX_INSTALL}" ]]; then
  export UCX_WARN_UNUSED_ENV_VARS=n
  export LD_LIBRARY_PATH=${SOS_UCX_INSTALL}/lib:$_library_path
  for m in "${BENCH[@]}";
  do
    shm_exe=${OSU_BUILD}/openshmem/osu_oshm_${m}
    for ppn in "${PPN_LIST[@]}"; do
      nranks=$(( nnodes * ppn ))
      echo "mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${mpi_exe} "
      timeout 60 mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shmem_exe} | tee -a ${out_dir}/sos-ucx.${m}.N${nnodes}.p${ppn}.dat
    done
  done
fi

