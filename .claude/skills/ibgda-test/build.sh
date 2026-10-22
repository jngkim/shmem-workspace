#!/usr/bin/env bash
# Configure and build Intel SHMEM (unit/perf tests + examples) against Intel MPI.
# Usage: build.sh [extra cmake -D args...]
# Env: ISHMEM_SRC, ISHMEM_BUILD, ISHMEM_INSTALL, ISHMEM_AOT_DEVICE_TYPES, JOBS,
#      BUILD_UNIT_TESTS (default OFF for faster builds; ON for ctest unit tests)
set -eo pipefail

WORKSPACE_ROOT=${WORKSPACE_ROOT:-"$HOME/shmem-workspace"}
ISHMEM_SRC=${ISHMEM_SRC:-"$WORKSPACE_ROOT/repos/ishmem"}
ISHMEM_BUILD=${ISHMEM_BUILD:-"$WORKSPACE_ROOT/build/ishmem"}
ISHMEM_INSTALL=${ISHMEM_INSTALL:-"$WORKSPACE_ROOT/install/ishmem"}
ISHMEM_AOT_DEVICE_TYPES=${ISHMEM_AOT_DEVICE_TYPES:-xe3}
JOBS=${JOBS:-$(nproc)}
BUILD_UNIT_TESTS=${BUILD_UNIT_TESTS:-OFF}

if [[ ! -f "$ISHMEM_SRC/CMakeLists.txt" ]]; then
    echo "ERROR: ishmem source not found at $ISHMEM_SRC" >&2
    echo "  git clone https://github.com/intel-innersource/libraries.runtimes.hpc.shmem.ishmem.git $ISHMEM_SRC" >&2
    exit 1
fi

if ! command -v icpx >/dev/null || [[ -z ${I_MPI_ROOT:-} ]]; then
    source /opt/intel/oneapi/setvars.sh >/dev/null
fi

mkdir -p "$ISHMEM_BUILD"
cmake -S "$ISHMEM_SRC" -B "$ISHMEM_BUILD" \
    -DCMAKE_C_COMPILER=icx \
    -DCMAKE_CXX_COMPILER=icpx \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX="$ISHMEM_INSTALL" \
    -DENABLE_MPI=ON \
    -DMPI_DIR="$I_MPI_ROOT" \
    -DISHMEM_DEFAULT_RUNTIME=mpi \
    -DBUILD_UNIT_TESTS="$BUILD_UNIT_TESTS" \
    -DBUILD_PERF_TESTS=ON \
    -DBUILD_EXAMPLES=ON \
    -DCTEST_LAUNCHER=mpi \
    -DENABLE_OPENSHMEM=OFF \
    -DISHMEM_AOT_DEVICE_TYPES="$ISHMEM_AOT_DEVICE_TYPES" \
    -DENABLE_IBGDA=1 \
    -DISHMEM_IBGDA_NIC_VENDOR=MLX5 \
    "$@" 2>&1 | tee "$ISHMEM_BUILD/configure.log"
cmake --build "$ISHMEM_BUILD" -j "$JOBS" 2>&1 | tee "$ISHMEM_BUILD/build.log"
cmake --install "$ISHMEM_BUILD" 2>&1 | tee "$ISHMEM_BUILD/install.log"
