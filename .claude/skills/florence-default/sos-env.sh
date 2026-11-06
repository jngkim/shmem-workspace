#!/usr/bin/env bash
# Run-time environment for an ishmem build with the bundled SOS (build.sh RUNTIME=sos), layered on
# top of env.sh. Source it inside the job, after env.sh (srun.sh loads env.sh):
#   srun.sh bash -c 'source .../sos-env.sh; mpiexec -n 2 ishmrun ...'
#
# The build bakes in the bundled libsma.so path and the SHMEM_OFI_PROVIDER of its provider preset
# (cmake summary: "SOS provider"), so neither has to be set here.
# Env:
#   ISHMEM_INSTALL  install prefix of the sos build (default ~/shmem-workspace/install/ishmem-sos);
#                   only used for PATH (oshrun/oshcc) and the sanity check below
#   SOS_PROVIDER    unset (default): use the build's preset; or shm / verbs to force
#                   SHMEM_OFI_PROVIDER (must match the preset the build was configured with)
#   SOS_RUNTIME     value for ISHMEM_RUNTIME (default OPENSHMEM); set MPI to run the same binaries
#                   over Intel MPI (env.sh already set ISHMEM_RUNTIME=MPI, so it cannot be the knob)

ISHMEM_INSTALL=${ISHMEM_INSTALL:-$HOME/shmem-workspace/install/ishmem-sos}
SOS_PREFIX=$ISHMEM_INSTALL/lib/ishmem/sos

export ISHMEM_RUNTIME=${SOS_RUNTIME:-OPENSHMEM}
export PATH=$SOS_PREFIX/bin:$PATH

# SOS-only workarounds on Florence (harmless for shm): verbs does not pick ib0 by itself under
# SOS, and mlx5 scatter-to-CQE memcpy()s small RDMA READ payloads into device memory on the CPU
export FI_VERBS_IFACE=ib0
export MLX5_SCATTER_TO_CQE=0

case ${SOS_PROVIDER:-} in
    "") ;;
    shm)   export SHMEM_OFI_PROVIDER=shm ;;
    verbs) export SHMEM_OFI_PROVIDER="verbs;ofi_rxm" ;;
    *)
        echo "sos-env.sh: SOS_PROVIDER must be unset, shm or verbs, got '$SOS_PROVIDER'" >&2
        return 1 2>/dev/null || exit 1
        ;;
esac

if [[ ! -f $SOS_PREFIX/lib/libsma.so ]]; then
    echo "sos-env.sh: WARNING: $SOS_PREFIX/lib/libsma.so not found (build/install RUNTIME=sos first)" >&2
fi
