#!/usr/bin/env bash
set -o pipefail

source /opt/intel/oneapi/compiler/latest/env/vars.sh &&
source /opt/intel/oneapi/umf/latest/env/vars.sh &&
source /opt/intel/oneapi/tcm/latest/env/vars.sh &&
source "$HOME/intel/oneapi/libfabric/latest/env/vars.sh" &&
source /opt/intel/oneapi/dpl/latest/env/vars.sh &&
source "$HOME/share/agama-ppa/38308/setup-env.sh" || exit 1

set -e

WORKSPACE_ROOT=${WORKSPACE_ROOT:-"$HOME/shmem-workspace"}
ISHMEM_SRC=${ISHMEM_SRC:-"$WORKSPACE_ROOT/repos/ishmem"}
ISHMEM_BUILD=${ISHMEM_BUILD:-"$WORKSPACE_ROOT/build/ishmem-mpich"}
ISHMEM_INSTALL=${ISHMEM_INSTALL:-"$WORKSPACE_ROOT/install/ishmem-mpich"}
MPICH_INSTALL=${MPICH_INSTALL:-"$WORKSPACE_ROOT/install/mpich"}
JOBS=${JOBS:-32}

test -f "$ISHMEM_SRC/CMakeLists.txt"
if [[ ! -x "$MPICH_INSTALL/bin/mpicxx" ]]; then
    printf 'MPICH not found in %s; run build-mpich.sh first.\n' "$MPICH_INSTALL" >&2
    exit 1
fi

unset I_MPI_ROOT
export MPI_HOME="$MPICH_INSTALL"
export PATH="$MPICH_INSTALL/bin:$PATH"
export LD_LIBRARY_PATH="$MPICH_INSTALL/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PKG_CONFIG_PATH="$MPICH_INSTALL/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export ISHMEM_RUNTIME=MPI
export ISHMEM_MPI_LIB_NAME="$MPICH_INSTALL/lib/libmpi.so"

command -v icx icpx mpicxx mpiexec
icx --version
icpx --version
"$MPICH_INSTALL/bin/mpichversion"
mkdir -p "$ISHMEM_BUILD"

cmake -S "$ISHMEM_SRC" -B "$ISHMEM_BUILD" \
    -DCMAKE_C_COMPILER=icx \
    -DCMAKE_CXX_COMPILER=icpx \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$ISHMEM_INSTALL" \
    -DMPI_DIR="$MPICH_INSTALL" \
    -DMPI_CXX_COMPILER="$MPICH_INSTALL/bin/mpicxx" \
    -DMPI_CXX_INCLUDE_DIRS="$MPICH_INSTALL/include" \
    -DMPIEXEC_EXECUTABLE="$MPICH_INSTALL/bin/mpiexec" \
    -DENABLE_MPI=ON \
    -DENABLE_OPENSHMEM=OFF \
    -DISHMEM_DEFAULT_RUNTIME=MPI \
    -DISHMEM_AOT_DEVICE_TYPES=xe-hpc \
    -DENABLE_AOT_COMPILATION=ON \
    -DISHMEM_HOST_LINK_TYPE=SHARED \
    -DBUILD_EXAMPLES=ON \
    -DBUILD_UNIT_TESTS="${BUILD_UNIT_TESTS:-OFF}" \
    -DBUILD_PERF_TESTS=OFF \
    -DBUILD_APPS=OFF \
    -DCTEST_LAUNCHER=mpi \
    "$@" 2>&1 | tee "$ISHMEM_BUILD/configure-output.log"
cmake --build "$ISHMEM_BUILD" --parallel "$JOBS" 2>&1 | tee "$ISHMEM_BUILD/build.log"
cmake --install "$ISHMEM_BUILD" 2>&1 | tee "$ISHMEM_BUILD/install.log"

if [[ ${RUN_TESTS:-1} != 0 ]]; then
    export LD_LIBRARY_PATH="$ISHMEM_INSTALL/lib:$LD_LIBRARY_PATH"
    for example in 1_helloworld 2_get; do
        timeout 120 "$MPICH_INSTALL/bin/mpiexec" -launcher fork -n 2 \
            "$ISHMEM_BUILD/examples/$example" 2>&1 | tee "$ISHMEM_BUILD/$example.log"
    done
fi

printf '\nISHMEM with MPICH installed in %s\n' "$ISHMEM_INSTALL"