#!/bin/bash
# config.sh - Multi-cluster / multi-platform configuration for ishmem testing
#
# Source this script from PBS or SLURM job scripts.
# Cluster is detected from standard PBS/SLURM env vars, then used to set PLATFORM.
#
# Supported clusters : aurora | borealis | florence
# Supported platforms: cray (Cray CXI) | ib (InfiniBand / verbs)
#
# Override: export CLUSTER=<name> before sourcing to skip auto-detection.

# ─── Cluster detection from scheduler env vars ───────────────────────────────
if [[ -z "${CLUSTER:-}" ]]; then
    # SLURM_CLUSTER_NAME on SLURM systems, PBS_O_HOST on PBS systems
    _hint="${CLUSTER_NAME:-${SLURM_CLUSTER_NAME:-${PBS_O_HOST:-$(hostname)}}}"
    case "${_hint,,}" in
        *aurora*)   CLUSTER=aurora   ;;
        *sunspot*)  CLUSTER=sunspot  ;;
        *borealis*) CLUSTER=borealis ;;
        *florence*) CLUSTER=florence ;;
        *compute*)  CLUSTER=florence ;;  # Florence compute-node hostnames
        *anbmg*)    CLUSTER=anbmg    ;;
        *)          CLUSTER=unknown  ;;
    esac
fi
export CLUSTER

HAVE_SHMEMX=0  # default; set to 1 for platforms with shmemx support
# ─── Platform derived from cluster ────────────────────────────────────────────
case "${CLUSTER}" in
  aurora|sunspot)
    PLATFORM=cray
    HAVE_SHMEMX=1
    ;;
  borealis)
    PLATFORM=cray
    ;;
  florence|anbmg)
    PLATFORM=ib
    ;;
  *) # check if macOS
      if [[ "$(uname)" == "Darwin" ]]; then
          PLATFORM=mac
      elif [[ "$(uname -s)" == "Linux" ]]; then
          PLATFORM=linux
      else
          PLATFORM=unknown
      fi
    ;;
esac
export PLATFORM
export HAVE_SHMEMX

echo "INFO: Cluster=${CLUSTER}  Platform=${PLATFORM}  HAVE_SHMEMX=${HAVE_SHMEMX}"

# ─── Level Zero / GPU (common to all Intel GPU clusters) ─────────────────────
export ZE_FLAT_DEVICE_HIERARCHY=FLAT
export ZE_ENABLE_PCI_ID_DEVICE_MAPPING=1
export EnableImplicitScaling=0
export NEOReadDebugKeys=1
export ISHMEM_RUNTIME=MPI

#export SHMEM_SYMMETRIC_SIZE=3G

# ─── Platform-specific settings ───────────────────────────────────────────────
case "${PLATFORM}" in
  cray)
    # Cray CXI — Aurora and Borealis
    export OFI_INSTALL="${OFI_INSTALL:-/opt/cray/libfabric/1.22.0}"
    export PALS_PMI=pmix
    #export FI_PROVIDER=cxi
    #export FI_CXI_OPTIMIZED_MRS=0
    #export FI_CXI_DEFAULT_CQ_SIZE=131072
    #export FI_MR_CACHE_MAX_COUNT=32768
    #export FI_MR_CACHE_MAX_SIZE=-1
    #export FI_CXI_RDZV_THRESHOLD=12288
    #export FI_CXI_RDZV_EAGER_SIZE=8192
    #NO: export SHMEM_BOUNCE_SIZE=8192
    ;;
  ib)
    # InfiniBand / verbs — Florence
    export USE_I_MPI=1
    export I_MPI_OFFLOAD=1
    export I_MPI_OFFLOAD_RDMA=1
    export I_MPI_CXX=icpx
    export I_MPI_CC=icx

    export SHMEM_CMA_PUT_MAX=524288
    export UCX_WARN_UNUSED_ENV_VARS=n
    # if problems on IB happen, check these ENVs
    #unset FI_PROVIDER_PATH
    #export FI_PROVIDER=verbs
    #export MLX5_SCATTER_TO_CQE=0
    #export FI_VERBS_IFACE="ib0"

    # Arc B-Series GPU workarounds (Borealis; harmless on Aurora)
    _out=$(ONEAPI_DEVICE_SELECTOR=level_zero:* sycl-ls 2>/dev/null)
    if echo "${_out}" | grep -qP "Intel.*Arc.*B[0-9]+ Graphics"; then
      export RenderCompressedBuffersEnabled=0
      export ISHMEM_ENABLE_DEVICE_ATOMICS=0
      export UseKmdMigration=1
      echo "INFO: Arc B-Series GPU detected — applied GPU workarounds"
    fi
 
    ;;
  *)
    echo "WARNING: Unknown platform — no platform-specific env vars applied"
    ;;
esac
