#!/bin/bash
# scan_nodes_florence.sh
#
# Submit the ishmem debug smoke test (slurm_ishmem_debug.sh) to every available
# Florence node, one job per node, to find nodes with defects — in particular
# the GLIBC mismatch:
#   examples/2_get: /lib64/libc.so.6: version `GLIBC_2.34' not found ...
#
# Each per-node job writes results/<cluster>/ishmem/scan-YYYYMMDD-JOBID/<node>.log.
# After the jobs finish, grep those logs for the GLIBC error (see summary hint
# printed at the end).
#
# Usage:
#   ./scan_nodes_florence.sh                 # scan all available nodes
#   PARTITION=all ./scan_nodes_florence.sh   # override partition (default: all)
#   STATES=idle   ./scan_nodes_florence.sh   # override node states to include

set -u

PARTITION=${PARTITION:-all}
# States considered "available" to land a job on. drain/down/resv excluded.
STATES=${STATES:-idle,alloc,mix,comp}
DEBUG_JOB=${HOME}/shmem-workspace/slurm_ishmem_debug.sh

# Enumerate candidate nodes (unique), skipping drained/down/reserved.
mapfile -t NODES < <(sinfo -h -p "${PARTITION}" -t "${STATES}" -o "%n" | sort -u)

if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "ERROR: no available nodes found in partition '${PARTITION}' (states: ${STATES})" >&2
  exit 1
fi

# One shared, timestamped output dir per scan — all per-node jobs write here.
# Passed to each debug job via SCAN_OUT_DIR so logs from one run stay together.
CLUSTER=${CLUSTER:-florence}
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
export SCAN_OUT_DIR=${HOME}/shmem-workspace/results/${CLUSTER}/ishmem/scan-${TIMESTAMP}
mkdir -p "${SCAN_OUT_DIR}"

echo "INFO: submitting debug smoke test to ${#NODES[@]} node(s) in partition '${PARTITION}':"
printf '  %s\n' "${NODES[@]}"
echo "INFO: shared output dir: ${SCAN_OUT_DIR}"

for node in "${NODES[@]}"; do
  jid=$(sbatch --parsable \
          --partition="${PARTITION}" \
          --nodelist="${node}" \
          --nodes=1 \
          --job-name="ishmem-dbg-${node}" \
          --export=ALL,SCAN_OUT_DIR="${SCAN_OUT_DIR}" \
          "${DEBUG_JOB}")
  echo "  submitted ${node} -> job ${jid}"
done

echo
echo "INFO: once jobs complete, find defective nodes with:"
echo "  grep -l \"GLIBC_2\\.\" ${SCAN_OUT_DIR}/*.log"
echo "  grep -h RESULT ${SCAN_OUT_DIR}/*.log | sort -u"
