#!/usr/bin/env bash
# Toolchain/runtime environment for building and running Intel SHMEM on Florence compute nodes
# (compute[11-44], 4x PVC = 8 tiles, InfiniBand/mlx5). Source it inside a Slurm job:
#   source ~/shmem-workspace/.claude/skills/florence-default/env.sh
# ~/.bashrc returns early for non-interactive shells, so this replicates its module loads.
# Env: ONEAPI_MODULE (default oneapi/2026.2), AGAMA_MODULE (default intel-comp-rt/agama-ci-devel/1250,
#      set empty to skip), GCC_MODULE (default gcc/13.2.0)

if ! command -v module >/dev/null 2>&1; then
    source /usr/share/Modules/init/bash
fi
module load "${GCC_MODULE:-gcc/13.2.0}" "${ONEAPI_MODULE:-oneapi/2026.2}" >/dev/null 2>&1
AGAMA_MODULE=${AGAMA_MODULE-intel-comp-rt/agama-ci-devel/1250}
[[ -n $AGAMA_MODULE ]] && module load "$AGAMA_MODULE" >/dev/null 2>&1
module load cmake >/dev/null 2>&1

export CLUSTER=florence
export I_MPI_CXX=icpx
export I_MPI_CC=icx
export I_MPI_HYDRA_BOOTSTRAP=ssh

# PVC runtime settings: expose the 8 tiles as 8 flat devices, one PE per tile.
export ZE_FLAT_DEVICE_HIERARCHY=FLAT
export ZE_ENABLE_PCI_ID_DEVICE_MAPPING=1
export EnableImplicitScaling=0
export NEOReadDebugKeys=1
export ISHMEM_RUNTIME=${ISHMEM_RUNTIME:-MPI}
export I_MPI_OFFLOAD=1
export I_MPI_OFFLOAD_RDMA=1

# InfiniBand / verbs: FI_VERBS_IFACE=ib0 and MLX5_SCATTER_TO_CQE=0 are SOS (OPENSHMEM runtime)
# workarounds only; they are not needed for the MPI runtime, so they are not set here.

export PATH=${ISHMEM_SRC:-$HOME/shmem-workspace/repos/ishmem}/scripts:$PATH
