#!/bin/bash

OSU_BUILD=${OSU_BUILD:-${HOME}/shmem-workspace/build/osu-bench}
DEBUG_AFFINITY=${DEBUG_AFFINITY:-0}

nnodes=${NNODES}

BENCH=(atomics barrier put_mr)

mpi_exe=${OSU_BUILD}/mpi/collective/blocking/osu_barrier
m=barrier
for ppn in "${PPN_LIST[@]}"; do
  nranks=$(( nnodes * ppn ))
  echo "mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${mpi_exe} "
  mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${mpi_exe} | tee -a ${out_dir}/mpi.${m}.N${nnodes}.p${ppn}.dat
done

# if [[ "${PLATFORM}" == "ib" ]]; then
#   export FI_PROVIDER=verbs
#   #export FI_VERBS_IFACE="ib0"
# fi

if [[ "${DEBUG_AFFINITY}" == "1" ]]; then
  m=barrier
  X=sos
  shm_exe=${OSU_BUILD}/openshmem/osu_oshm_${m}
  export SHMEM_DEBUG=1
  export CVARS="-genv LD_LIBRARY_PATH=$BASE/install/$X/lib:$LD_LIBRARY_PATH"
  for ppn in "${PPN_LIST[@]}"; do
    nranks=$(( nnodes * ppn ))
    echo "mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${NIC_MAPPER} ${mpi_exe} "
    mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${NIC_MAPPER} ${shmem_exe} | tee -a ${out_dir}/sos.${m}.N${nnodes}.p${ppn}.debug.dat
  done
  unset SHMEM_DEBUG
fi

for X in "${SOS_LIST[@]}"; do
  export CVARS="-genv LD_LIBRARY_PATH=$BASE/install/$X/lib:$LD_LIBRARY_PATH"
  for m in "${BENCH[@]}"; do
    shm_exe=${OSU_BUILD}/openshmem/osu_oshm_${m}
    for ppn in "${PPN_LIST[@]}"; do
      nranks=$(( nnodes * ppn ))
      echo "mpirun -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${NIC_MAPPER} ${shm_exe} heap "
      timeout 300 mpirun ${CVARS} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${NIC_MAPPER} ${shm_exe} heap | tee -a ${out_dir}/$X.${m}.N${nnodes}.p${ppn}.dat 
    done
  done
done

if [[ "${HAVE_SHMEMX}" -eq 1 ]]; then
  source ${HOME}/shmem-workspace/config.cray-shmem.sh
  for m in "${BENCH[@]}";
  do
    shm_exe=${OSU_BUILD}/shmemx/osu_oshm_${m}
    for ppn in "${PPN_LIST[@]}"; do
      nranks=$(( nnodes * ppn ))
      # if SHMEM_OFI_NIC_POLICY=USER, set NVAR; otherwise, empty (use default provider selection)
      NVAR=$([[ "${SHMEM_OFI_NIC_POLICY}" == "USER" ]] && echo "-genv SHMEM_OFI_NIC_MAPPING=0:0-$((ppn/2-1));4:$((ppn/2))-$((ppn-1))")
      echo "mpirun ${NVAR} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} heap "
      timeout 300 mpirun ${NVAR} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} heap | tee -a ${out_dir}/shmemx.${m}.N${nnodes}.p${ppn}.dat
    done
  done
fi
