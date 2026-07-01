#!/bin/bash
#SBATCH --job-name=ishmem-dbg
#SBATCH --output=%x.o%j
#SBATCH --error=%x.e%j
#SBATCH --nodes=1
#SBATCH --time=00:10:00

# Debug batch script: run the examples/2_get smoke test on a single node.
# Intended to be submitted per-node (via --nodelist) by scan_nodes_florence.sh
# to identify nodes where ishmem fails.

set -x

# ─── Environment ─────────────────────────────────────────────────────────────
source ${HOME}/shmem-workspace/config.sh
source ${HOME}/shmem-workspace/build/latest/setup_ishmem.sh

# ─── Paths / job identity ────────────────────────────────────────────────────
JOBID=${SLURM_JOBID%%.*}
TIMESTAMP=$(date +%Y%m%d)
NODE=$(hostname -s)
ISHMEM_DIR=${HOME}/shmem-workspace/build/latest/ishmem

# Use the shared scan dir when launched by scan_nodes_florence.sh; otherwise
# fall back to a per-job dir for standalone runs.
out_dir=${SCAN_OUT_DIR:-${HOME}/shmem-workspace/results/${CLUSTER}/ishmem/scan-${TIMESTAMP}-${JOBID}}
mkdir -p ${out_dir}

# Florence requires the verbs interface pinned to ib0.
if [[ "${CLUSTER}" == "florence" ]]; then
  export FI_VERBS_IFACE="ib0"
fi

# Single node → 2 ranks on this node.
export I_MPI_PERHOST=2

# ─── Run smoke test on this node ─────────────────────────────────────────────
cd ${ISHMEM_DIR}

# Record this node's glibc — the defect we hunt is a GLIBC_2.34/2.32 mismatch,
# so knowing each node's glibc version pinpoints the bad ones.
{
  echo "NODE: ${NODE}"
  echo "glibc: $(ldd --version | head -1)"
  echo "GLIBC symbols available: $(strings /lib64/libc.so.6 | grep -c '^GLIBC_2\.3[24]$') of GLIBC_2.32/2.34"
} | tee ${out_dir}/${NODE}.log

echo "INFO: [${NODE}] Running examples/2_get smoke test (MPI runtime)..."
ISHMEM_RUNTIME=MPI ISHMEM_DEBUG=1 I_MPI_DEBUG=5 \
  mpirun -np 2 ishmrun examples/2_get \
  2>&1 | tee -a ${out_dir}/${NODE}.log
rc=${PIPESTATUS[0]}

if [[ ${rc} -eq 0 ]]; then
  echo "RESULT: ${NODE} PASS" | tee -a ${out_dir}/${NODE}.log
else
  echo "RESULT: ${NODE} FAIL (exit ${rc})" | tee -a ${out_dir}/${NODE}.log
fi

exit ${rc}
