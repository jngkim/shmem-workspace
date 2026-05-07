#!/bin/bash
# Level Zero environment variables
export ZE_FLAT_DEVICE_HIERARCHY=FLAT
export ZE_ENABLE_PCI_ID_DEVICE_MAPPING=1
export NEOReadDebugKeys=1
export ISHMEM_RUNTIME=MPI

if [ -d /opt/cray ]; then
  # Cray CXI : Aurora/Borealis
  export OFI_INSTALL=/opt/cray/libfabric/1.22.0
  export PALS_PMI=pmix
  export FI_CXI_OPTIMIZED_MRS=0
  export FI_CXI_DEFAULT_CQ_SIZE=131072
  export FI_MR_CACHE_MAX_COUNT=32768
  export FI_MR_CACHE_MAX_SIZE=-1
  export SHMEM_BOUNCE_SIZE=8192
else
  export I_MPI_OFFLOAD=1
  export I_MPI_OFFLOAD_RDMA=1

  export MLX5_SCATTER_TO_CQE=0
  # workaround for hangs with single-node runs
  export FI_VERBS_IFACE="ib0"
fi

set_gpu_env()
{
    local output=$(ONEAPI_DEVICE_SELECTOR=level_zero:* sycl-ls 2>/dev/null)

    if [ $(echo $output | grep -Po "Intel.*Arc.*B[0-9]+ Graphics" | wc -l) -gt 0 ]; then
        # Intel(R) Arc(TM) B-Series GPU Family
        # Necessary for GPU IPC
        export RenderCompressedBuffersEnabled=0
        # Atomic ops from the GPU require Xe-Links - instead route atomic ops through the host
        export ISHMEM_ENABLE_DEVICE_ATOMICS=0
        # 2026-03-23
        export UseKmdMigration=1

    elif [ $(echo $output | grep -Po "Intel.*Data.*Center.*GPU" | wc -l) -gt 0 ]; then
        export EnableImplicitScaling=0
    fi
}
set_gpu_env
