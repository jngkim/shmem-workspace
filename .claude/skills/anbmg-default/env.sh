#!/usr/bin/env bash
# Toolchain/runtime environment for building and running Intel SHMEM on the anbmg compute nodes
# (anbmg-c[01-02], Ubuntu 24.04, 2x Intel Arc B-series GPUs). Source it inside a Slurm job:
#   source ~/shmem-workspace/.claude/skills/anbmg-default/env.sh
# Env: ONEAPI_VARS (oneAPI env script, default 2026.0),
#      AGAMA_SETUP (GPU runtime setup script sourced after oneAPI; set empty to skip)

ONEAPI_VARS=${ONEAPI_VARS:-/opt/intel/oneapi/2026.0/oneapi-vars.sh}
if ! command -v icpx >/dev/null || [[ -z ${I_MPI_ROOT:-} ]]; then
    source "$ONEAPI_VARS" >/dev/null
fi

AGAMA_SETUP=${AGAMA_SETUP-/home/tsantosf/teixeira-setup-scripts/install-intel-graphics-ppa.sh}
if [[ -n ${AGAMA_SETUP:-} ]]; then
    source "$AGAMA_SETUP" --load >/dev/null
fi

# Runtime settings for BMG (same as ~/setup-env.sh on Arc B-series).
export ZE_FLAT_DEVICE_HIERARCHY=FLAT
export ZE_ENABLE_PCI_ID_DEVICE_MAPPING=1
export EnableImplicitScaling=0
export NEOReadDebugKeys=1
export RenderCompressedBuffersEnabled=0
export UseKmdMigration=1
export ISHMEM_ENABLE_DEVICE_ATOMICS=0   # BMG has no peer-to-peer atomics; never enable
export ISHMEM_RUNTIME=${ISHMEM_RUNTIME:-MPI}   # set ISHMEM_RUNTIME=PMI for RUNTIME=pmi builds
export I_MPI_OFFLOAD=1
export I_MPI_OFFLOAD_RDMA=1
