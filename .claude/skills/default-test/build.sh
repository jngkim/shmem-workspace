#!/usr/bin/env bash
# Configure and build Intel SHMEM (unit/perf tests + examples) against Intel MPI.
# Usage: build.sh [extra cmake -D args...]
# Env: I_SHMEM_SRC, I_SHMEM_BUILD, I_SHMEM_INSTALL, I_SHMEM_AOT_DEVICE_TYPES, JOBS,
#      AGAMA_SETUP (see env.sh),
#      BUILD_UNIT_TESTS (default ON; OFF skips the unit tests for a faster build)
set -eo pipefail

WORKSPACE_ROOT=${WORKSPACE_ROOT:-"$HOME/shmem-workspace"}
I_SHMEM_SRC=${I_SHMEM_SRC:-"$WORKSPACE_ROOT/repos/ishmem"}
I_SHMEM_BUILD=${I_SHMEM_BUILD:-"$WORKSPACE_ROOT/build/ishmem"}
I_SHMEM_INSTALL=${I_SHMEM_INSTALL:-"$WORKSPACE_ROOT/install/ishmem"}
# hq-cri-d32-c has CRI GPUs (0x674f; ocloc maps it to cri)
[[ $(hostname -s) == hq-cri-d32-c ]] && AOT_DEFAULT=0x674f || AOT_DEFAULT="xe-hpc,xe2"
I_SHMEM_AOT_DEVICE_TYPES=${I_SHMEM_AOT_DEVICE_TYPES:-$AOT_DEFAULT}
JOBS=${JOBS:-$(nproc)}
BUILD_UNIT_TESTS=${BUILD_UNIT_TESTS:-ON}

if [[ ! -f "$I_SHMEM_SRC/CMakeLists.txt" ]]; then
    echo "ERROR: ishmem source not found at $I_SHMEM_SRC" >&2
    echo "  git clone https://github.com/intel-innersource/libraries.runtimes.hpc.shmem.ishmem.git $I_SHMEM_SRC" >&2
    exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

mkdir -p "$I_SHMEM_BUILD"
cmake -S "$I_SHMEM_SRC" -B "$I_SHMEM_BUILD" \
    -DCMAKE_C_COMPILER=icx \
    -DCMAKE_CXX_COMPILER=icpx \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX="$I_SHMEM_INSTALL" \
    -DENABLE_MPI=ON \
    -DMPI_DIR="$I_MPI_ROOT" \
    -DISHMEM_DEFAULT_RUNTIME=mpi \
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
