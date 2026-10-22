#!/usr/bin/env bash
# Quick IBGDA check: 2-PE put_nbi_bw (device mode) over mlx5 NICs.
# Usage: ibgda-quick.sh [GPU_INDEX1] [GPU_INDEX2] [-- CMD [ARGS...]]
#   CMD replaces the default put_nbi_bw run, using the same IBGDA launch environment.
#   PE 0 uses GPU GPU_INDEX1 (default 4) and NIC mlx5_<NIC_DEVICE1>,
#   PE 1 uses GPU GPU_INDEX2 (default 6) and NIC mlx5_<NIC_DEVICE2>.
# Env: NIC_DEVICE1/NIC_DEVICE2 (default: same as the GPU index), ISHMEM_BUILD,
#      I_MPI_FABRICS (default shm), TIMEOUT (default 120)
set -eo pipefail

WORKSPACE_ROOT=${WORKSPACE_ROOT:-"$HOME/shmem-workspace"}
ISHMEM_BUILD=${ISHMEM_BUILD:-"$WORKSPACE_ROOT/build/ishmem"}
PERF_DIR="$ISHMEM_BUILD/test/performance"

GPU_ARGS=()
while [[ $# -gt 0 && $1 != "--" ]]; do
    GPU_ARGS+=("$1")
    shift
done
[[ ${1:-} == "--" ]] && shift
GPU_INDEX1=${GPU_ARGS[0]:-4}
GPU_INDEX2=${GPU_ARGS[1]:-6}
NIC_DEVICE1=${NIC_DEVICE1:-$GPU_INDEX1}
NIC_DEVICE2=${NIC_DEVICE2:-$GPU_INDEX2}
I_MPI_FABRICS=${I_MPI_FABRICS:-shm}
TIMEOUT=${TIMEOUT:-120}
MAX_NELEMS=$((32768 * 1024 / 8))

if [[ $# -gt 0 ]]; then
    CMD=("$@")
else
    CMD=("$PERF_DIR/put_nbi_bw" --csv -m "$MAX_NELEMS" --test_modes device)
fi

if ! command -v "${CMD[0]}" >/dev/null; then
    echo "ERROR: ${CMD[0]} not found; build with build.sh first" >&2
    exit 1
fi

if ! command -v mpirun >/dev/null; then
    source /opt/intel/oneapi/setvars.sh >/dev/null
fi

timeout "$TIMEOUT" mpirun -n 2 \
  -genv ISHMEM_IB_ENABLE_IBGDA 1 \
  -genv ISHMEM_IBGDA_DIRECT_DOORBELL 1 \
  -genv ISHMEM_ENABLE_GPU_IPC 0 \
  -genv ISHMEM_ENABLE_ACCESSIBLE_HOST_HEAP 0 \
  -genv ISHMEM_SYMMETRIC_SIZE 268435456 \
  -genv ZE_ENABLE_PCI_ID_DEVICE_ORDER 1 \
  -genv ISHMEM_IBGDA_QPS_PER_PE 1 \
  -genv ISHMEM_IBGDA_DB_BATCH_SIZE 1 \
  -genv ISHMEM_IB_TRAFFIC_CLASS 96 \
  -genv I_MPI_FABRICS "$I_MPI_FABRICS" \
  -genv ISHMEM_DEBUG 0 \
  bash -c '
    if [ "$PMI_RANK" = "0" ]; then
      export ZE_AFFINITY_MASK='"${GPU_INDEX1}"'
      export ISHMEM_IBGDA_NIC=mlx5_'"${NIC_DEVICE1}"'
    else
      export ZE_AFFINITY_MASK='"${GPU_INDEX2}"'
      export ISHMEM_IBGDA_NIC=mlx5_'"${NIC_DEVICE2}"'
    fi
    exec "$@"
  ' ishmem-pe "${CMD[@]}" 2>&1
