#!/usr/bin/env bash
# Configure and build Intel SHMEM (IBGDA on, unit/perf tests + examples) with oneAPI 2026.2
# (/usr/local/intel/2026.2/oneapi-vars.sh) and its Intel MPI, in a clean env.
# Usage: build.sh [extra cmake -D args...]
# Env: I_SHMEM_SRC, I_SHMEM_BUILD (build/ishmem-o262), I_SHMEM_INSTALL (install/ishmem-o262),
#      I_SHMEM_AOT_DEVICE_TYPES (0x674f), JOBS (nproc), BUILD_UNIT_TESTS (ON)
[ -z "$CLEAN_ENV" ] && exec env -i HOME="$HOME" PATH=/usr/bin:/bin TERM=dumb CLEAN_ENV=1 \
    I_SHMEM_SRC="$I_SHMEM_SRC" I_SHMEM_BUILD="$I_SHMEM_BUILD" I_SHMEM_INSTALL="$I_SHMEM_INSTALL" \
    I_SHMEM_AOT_DEVICE_TYPES="$I_SHMEM_AOT_DEVICE_TYPES" JOBS="$JOBS" BUILD_UNIT_TESTS="$BUILD_UNIT_TESTS" \
    bash "$0" "$@"
set -eo pipefail

ONEAPI_VARS=/usr/local/intel/2026.2/oneapi-vars.sh
WORKSPACE_ROOT="$HOME/shmem-workspace"
I_SHMEM_SRC=${I_SHMEM_SRC:-"$WORKSPACE_ROOT/repos/ishmem"}
I_SHMEM_BUILD=${I_SHMEM_BUILD:-"$WORKSPACE_ROOT/build/ishmem-o262"}
I_SHMEM_INSTALL=${I_SHMEM_INSTALL:-"$WORKSPACE_ROOT/install/ishmem-o262"}
I_SHMEM_AOT_DEVICE_TYPES=${I_SHMEM_AOT_DEVICE_TYPES:-0x674f}
JOBS=${JOBS:-$(nproc)}
BUILD_UNIT_TESTS=${BUILD_UNIT_TESTS:-ON}

if [[ ! -f "$I_SHMEM_SRC/CMakeLists.txt" ]]; then
    echo "ERROR: ishmem source not found at $I_SHMEM_SRC" >&2
    exit 1
fi

source "$ONEAPI_VARS" >/dev/null 2>&1 || true   # oneapi-vars.sh may return non-zero on warnings
if [[ "$CMPLR_ROOT" != /usr/local/intel/* || -z "$I_MPI_ROOT" ]]; then
    echo "ERROR: $ONEAPI_VARS did not set up 2026.2 (CMPLR_ROOT=$CMPLR_ROOT I_MPI_ROOT=$I_MPI_ROOT)" >&2
    exit 1
fi
echo "toolchain: CMPLR_ROOT=$CMPLR_ROOT I_MPI_ROOT=$I_MPI_ROOT"

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
    -DENABLE_IBGDA=ON \
    -DISHMEM_IBGDA_NIC_VENDOR=MLX5 \
    "$@" 2>&1 | tee "$I_SHMEM_BUILD/configure.log"
cmake --build "$I_SHMEM_BUILD" -j "$JOBS" 2>&1 | tee "$I_SHMEM_BUILD/build.log"
cmake --install "$I_SHMEM_BUILD" 2>&1 | tee "$I_SHMEM_BUILD/install.log"
