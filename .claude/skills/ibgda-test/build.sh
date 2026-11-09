#!/usr/bin/env bash
# Configure and build Intel SHMEM (unit/perf tests + examples) against Intel MPI.
# Usage: build.sh [extra cmake -D args...]
# Env: I_SHMEM_SRC, I_SHMEM_BUILD, I_SHMEM_INSTALL, I_SHMEM_AOT_DEVICE_TYPES, JOBS,
#      BUILD_UNIT_TESTS (default OFF for faster builds; ON for ctest unit tests)
set -eo pipefail

WORKSPACE_ROOT=${WORKSPACE_ROOT:-"$HOME/shmem-workspace"}
I_SHMEM_SRC=${I_SHMEM_SRC:-"$WORKSPACE_ROOT/repos/ishmem"}
I_SHMEM_BUILD=${I_SHMEM_BUILD:-"$WORKSPACE_ROOT/build/ishmem"}
I_SHMEM_INSTALL=${I_SHMEM_INSTALL:-"$WORKSPACE_ROOT/install/ishmem"}
I_SHMEM_AOT_DEVICE_TYPES=${I_SHMEM_AOT_DEVICE_TYPES:-0x674f}
JOBS=${JOBS:-$(nproc)}
BUILD_UNIT_TESTS=${BUILD_UNIT_TESTS:-OFF}

if [[ ! -f "$I_SHMEM_SRC/CMakeLists.txt" ]]; then
    echo "ERROR: ishmem source not found at $I_SHMEM_SRC" >&2
    echo "  git clone https://github.com/intel-innersource/libraries.runtimes.hpc.shmem.ishmem.git $I_SHMEM_SRC" >&2
    exit 1
fi

if ! command -v icpx >/dev/null || [[ -z ${I_MPI_ROOT:-} ]]; then
    source /opt/intel/oneapi/setvars.sh >/dev/null
fi

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
    -DISHMEM_AOT_DEVICE_TYPES="$I_SHMEM_AOT_DEVICE_TYPES" \
    -DENABLE_IBGDA=1 \
    -DISHMEM_IBGDA_NIC_VENDOR=MLX5 \
    "$@" 2>&1 | tee "$I_SHMEM_BUILD/configure.log"
cmake --build "$I_SHMEM_BUILD" -j "$JOBS" 2>&1 | tee "$I_SHMEM_BUILD/build.log"
cmake --install "$I_SHMEM_BUILD" 2>&1 | tee "$I_SHMEM_BUILD/install.log"
