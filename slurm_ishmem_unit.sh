#!/bin/bash
#SBATCH --job-name=ishmem-unit
#SBATCH --output=%x.o%j
#SBATCH --error=%x.e%j
#SBATCH --nodes=1
#SBATCH --time=00:30:00

set -x

# ─── Environment ─────────────────────────────────────────────────────────────
source ${HOME}/shmem-workspace/config.sh
source ${HOME}/shmem-workspace/build/latest/setup_ishmem.sh

# ─── Paths / job identity ────────────────────────────────────────────────────
JOBID=${SLURM_JOBID%%.*}
TIMESTAMP=$(date +%Y%m%d)
ISHMEM_DIR=${HOME}/shmem-workspace/build/latest/ishmem

# ranks-per-node for the 2-rank runs: 1 per node on 2 nodes, 2 on 1 node.
# I_MPI_PERHOST is Intel MPI's equivalent of `mpirun -ppn`; exporting it makes
# both the direct mpirun smoke tests and the mpirun calls inside ctest honor it.
nnodes=${SLURM_NNODES:-1}
export I_MPI_PERHOST=$(( 2 / nnodes ))

out_dir=${HOME}/shmem-workspace/results/${CLUSTER}/ishmem/unit-N${nnodes}-${TIMESTAMP}-${JOBID}
mkdir -p ${out_dir}

# ─── Capture node / environment info ─────────────────────────────────────────
{
  echo "===== job ====="
  echo "date       : $(date)"
  echo "hostname   : $(hostname)"
  echo "jobid      : ${JOBID}"
  echo "out_dir    : ${out_dir}"
  echo "===== slurm ====="
  env | grep -E '^SLURM_' | sort
  echo "===== cluster/platform ====="
  env | grep -E '^(CLUSTER|PLATFORM|HAVE_SHMEMX)='
  echo "===== cpu ====="
  lscpu
  echo "===== memory ====="
  free -h
  echo "===== fabric (fi_info) ====="
  fi_info 2>/dev/null | grep -E 'provider|fabric|domain|type' | head -40
  echo "===== gpu (sycl-ls) ====="
  sycl-ls 2>/dev/null
  echo "===== relevant env ====="
  env | grep -E '^(FI_|I_MPI_|ISHMEM_|SHMEM_|ZE_|OFI_)' | grep -v LMOD | sort
} > ${out_dir}/env.txt 2>&1

# ─── Run tests (2 ranks) for each runtime ────────────────────────────────────
# For each runtime, first run the examples/2_get smoke test with debug output.
# If that run fails (non-zero exit), skip the rest of the unit tests for that
# runtime.
cd ${ISHMEM_DIR}

# ---- MPI runtime ----
echo "INFO: [MPI] Running examples/2_get smoke test..."
ISHMEM_RUNTIME=MPI ISHMEM_DEBUG=1 I_MPI_DEBUG=5 \
  mpirun -np 2 ishmrun examples/2_get \
  2>&1 | tee ${out_dir}/rt-mpi.debug.log
smoke_rc=${PIPESTATUS[0]}

if [[ ${smoke_rc} -ne 0 ]]; then
  echo "ERROR: [MPI] examples/2_get failed (exit ${smoke_rc}) — skipping unit tests." \
    | tee -a ${out_dir}/rt-mpi.debug.log
else
  echo "INFO: [MPI] Running ISHMEM unit tests..."
  ISHMEM_RUNTIME=MPI ctest --test-dir test/unit --timeout 30 \
    2>&1 | tee ${out_dir}/rt-mpi.log
fi
sleep 1

# ---- OPENSHMEM runtime ----
# Florence requires the verbs interface pinned to ib0.
if [[ "${CLUSTER}" == "florence" ]]; then
  export FI_VERBS_IFACE="ib0"
  echo "INFO: [OPENSHMEM] Florence — exported FI_VERBS_IFACE=ib0"
fi

echo "INFO: [OPENSHMEM] Running examples/2_get smoke test..."
ISHMEM_RUNTIME=OPENSHMEM SHMEM_DEBUG=1 \
  mpirun -np 2 ishmrun examples/2_get \
  2>&1 | tee ${out_dir}/rt-sos.debug.log
smoke_rc=${PIPESTATUS[0]}

if [[ ${smoke_rc} -ne 0 ]]; then
  echo "ERROR: [OPENSHMEM] examples/2_get failed (exit ${smoke_rc}) — skipping unit tests." \
    | tee -a ${out_dir}/rt-sos.debug.log
else
  echo "INFO: [OPENSHMEM] Running ISHMEM unit tests..."
  ISHMEM_RUNTIME=OPENSHMEM ctest --test-dir test/unit --timeout 30 \
    2>&1 | tee ${out_dir}/rt-sos.log
fi

echo "INFO: Results written to ${out_dir}"
