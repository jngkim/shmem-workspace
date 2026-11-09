#!/usr/bin/env bash
# Configure and build Intel SHMEM (unit/perf tests + examples) against Intel MPI.
# Usage: build.sh [extra cmake -D args...]
# Outside a Slurm job it re-launches itself on a compute node via srun.sh (SLURM_TIME, SRUN_ARGS).
# Env: I_SHMEM_SRC, I_SHMEM_BUILD, I_SHMEM_INSTALL, I_SHMEM_AOT_DEVICE_TYPES, JOBS,
#      AGAMA_SETUP (see env.sh),
#      BUILD_UNIT_TESTS (default ON; OFF skips the unit tests for a faster build),
#      RUNTIME (mpi (default) or pmi: -DENABLE_PMI=ON -DENABLE_MPI=OFF, needs a branch with the PMI runtime)
set -eo pipefail

if [[ -z ${SLURM_JOB_ID:-} ]]; then
    SELF=$(readlink -f "${BASH_SOURCE[0]}")
    exec "$(dirname "$SELF")/srun.sh" "$SELF" "$@"
fi

WORKSPACE_ROOT=${WORKSPACE_ROOT:-"$HOME/shmem-workspace"}
I_SHMEM_SRC=${I_SHMEM_SRC:-"$WORKSPACE_ROOT/repos/ishmem"}
I_SHMEM_BUILD=${I_SHMEM_BUILD:-"$WORKSPACE_ROOT/build/ishmem"}
I_SHMEM_INSTALL=${I_SHMEM_INSTALL:-"$WORKSPACE_ROOT/install/ishmem"}
I_SHMEM_AOT_DEVICE_TYPES=${I_SHMEM_AOT_DEVICE_TYPES:-"xe2"}
JOBS=${JOBS:-$(nproc)}
BUILD_UNIT_TESTS=${BUILD_UNIT_TESTS:-ON}
RUNTIME=${RUNTIME:-mpi}

if [[ ! -f "$I_SHMEM_SRC/CMakeLists.txt" ]]; then
    echo "ERROR: ishmem source not found at $I_SHMEM_SRC" >&2
    echo "  git clone https://github.com/intel-innersource/libraries.runtimes.hpc.shmem.ishmem.git $I_SHMEM_SRC" >&2
    exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

case "$RUNTIME" in
    mpi) RUNTIME_ARGS=(-DENABLE_MPI=ON -DMPI_DIR="$I_MPI_ROOT" -DISHMEM_DEFAULT_RUNTIME=mpi) ;;
    pmi) RUNTIME_ARGS=(-DENABLE_PMI=ON -DENABLE_MPI=OFF -DISHMEM_DEFAULT_RUNTIME=PMI) ;;
    *)   echo "ERROR: RUNTIME must be mpi or pmi, got '$RUNTIME'" >&2; exit 1 ;;
esac

mkdir -p "$I_SHMEM_BUILD"
cmake -S "$I_SHMEM_SRC" -B "$I_SHMEM_BUILD" \
    -DCMAKE_C_COMPILER=icx \
    -DCMAKE_CXX_COMPILER=icpx \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX="$I_SHMEM_INSTALL" \
    "${RUNTIME_ARGS[@]}" \
    -DBUILD_UNIT_TESTS="$BUILD_UNIT_TESTS" \
    -DBUILD_PERF_TESTS=ON \
    -DBUILD_EXAMPLES=ON \
    -DCTEST_LAUNCHER=mpi \
    -DENABLE_OPENSHMEM=OFF \
    -DENABLE_IBGDA=OFF \
    -DISHMEM_AOT_DEVICE_TYPES="$I_SHMEM_AOT_DEVICE_TYPES" \
    "$@" 2>&1 | tee "$I_SHMEM_BUILD/configure.log"
cmake --build "$I_SHMEM_BUILD" -j "$JOBS" 2>&1 | tee "$I_SHMEM_BUILD/build.log"
cmake --install "$I_SHMEM_BUILD" 2>&1 | tee "$I_SHMEM_BUILD/install.log"
