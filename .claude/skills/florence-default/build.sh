#!/usr/bin/env bash
# Configure and build Intel SHMEM (unit/perf tests + examples) against Intel MPI.
# Usage: build.sh [extra cmake -D args...]
# Outside a Slurm job it re-launches itself on a compute node via srun.sh (SLURM_TIME, SRUN_ARGS).
# Env: ISHMEM_SRC, ISHMEM_BUILD, ISHMEM_INSTALL, ISHMEM_AOT_DEVICE_TYPES, JOBS,
#      ONEAPI_MODULE, AGAMA_MODULE (see env.sh),
#      BUILD_UNIT_TESTS (default ON; OFF skips the unit tests for a faster build),
#      RUNTIME (mpi (default);
#               pmi: -DENABLE_PMI=ON -DENABLE_MPI=OFF, needs a branch with the PMI runtime;
#               sos: bundled SOS (-DENABLE_OPENSHMEM=ON -DISHMEM_SOS=bundled), needs a branch with
#                    third_party/sos (fork/sos/bundled)),
#      RUNTIME=sos only:
#        SOS_MPI      ON (default: -DENABLE_MPI=ON, SOS uses pmi-mpi, default runtime MPI) or
#                     OFF (-DENABLE_MPI=OFF, SOS uses pmi-simple, default runtime OPENSHMEM)
#        SOS_PROVIDER auto (default; fi_info probe cxi -> verbs -> shm), cxi, verbs or shm
#        SOS_FLAGS    replaces the provider preset (ISHMEM_SOS_CONFIGURE_FLAGS, ';'-separated)
#        SOS_FLAGS_EXTRA  appended to the preset (ISHMEM_SOS_CONFIGURE_FLAGS_EXTRA)
set -eo pipefail

if [[ -z ${SLURM_JOB_ID:-} ]]; then
    SELF=$(readlink -f "${BASH_SOURCE[0]}")
    exec "$(dirname "$SELF")/srun.sh" "$SELF" "$@"
fi

WORKSPACE_ROOT=${WORKSPACE_ROOT:-"$HOME/shmem-workspace"}
ISHMEM_SRC=${ISHMEM_SRC:-"$WORKSPACE_ROOT/repos/ishmem"}
ISHMEM_BUILD=${ISHMEM_BUILD:-"$WORKSPACE_ROOT/build/ishmem-florence"}
ISHMEM_INSTALL=${ISHMEM_INSTALL:-"$WORKSPACE_ROOT/install/ishmem-florence"}
ISHMEM_AOT_DEVICE_TYPES=${ISHMEM_AOT_DEVICE_TYPES:-"xe-hpc"}
JOBS=${JOBS:-$(nproc)}
BUILD_UNIT_TESTS=${BUILD_UNIT_TESTS:-ON}
RUNTIME=${RUNTIME:-mpi}

if [[ ! -f "$ISHMEM_SRC/CMakeLists.txt" ]]; then
    echo "ERROR: ishmem source not found at $ISHMEM_SRC" >&2
    echo "  git clone https://github.com/intel-innersource/libraries.runtimes.hpc.shmem.ishmem.git $ISHMEM_SRC" >&2
    exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

case "$RUNTIME" in
    mpi) RUNTIME_ARGS=(-DENABLE_MPI=ON -DMPI_DIR="$I_MPI_ROOT" -DISHMEM_DEFAULT_RUNTIME=mpi -DENABLE_OPENSHMEM=OFF) ;;
    pmi) RUNTIME_ARGS=(-DENABLE_PMI=ON -DENABLE_MPI=OFF -DISHMEM_DEFAULT_RUNTIME=PMI -DENABLE_OPENSHMEM=OFF) ;;
    sos)
        if [[ ! -f "$ISHMEM_SRC/third_party/sos/autogen.sh" ]]; then
            echo "ERROR: $ISHMEM_SRC/third_party/sos missing; run" >&2
            echo "  git -C $ISHMEM_SRC submodule update --init third_party/sos" >&2
            exit 1
        fi
        RUNTIME_ARGS=(-DENABLE_OPENSHMEM=ON -DISHMEM_SOS=bundled
                      -DISHMEM_SOS_PROVIDER="${SOS_PROVIDER:-auto}"
                      -DISHMEM_SOS_CONFIGURE_FLAGS="${SOS_FLAGS:-}"
                      -DISHMEM_SOS_CONFIGURE_FLAGS_EXTRA="${SOS_FLAGS_EXTRA:-}")
        if [[ ${SOS_MPI:-ON} == OFF ]]; then
            RUNTIME_ARGS+=(-DENABLE_MPI=OFF)
        else
            RUNTIME_ARGS+=(-DENABLE_MPI=ON -DMPI_DIR="$I_MPI_ROOT")
        fi
        ;;
    *)   echo "ERROR: RUNTIME must be mpi, pmi or sos, got '$RUNTIME'" >&2; exit 1 ;;
esac

mkdir -p "$ISHMEM_BUILD"
cmake -S "$ISHMEM_SRC" -B "$ISHMEM_BUILD" \
    -DCMAKE_C_COMPILER=icx \
    -DCMAKE_CXX_COMPILER=icpx \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX="$ISHMEM_INSTALL" \
    "${RUNTIME_ARGS[@]}" \
    -DBUILD_UNIT_TESTS="$BUILD_UNIT_TESTS" \
    -DBUILD_PERF_TESTS=ON \
    -DBUILD_EXAMPLES=ON \
    -DCTEST_LAUNCHER=mpi \
    -DENABLE_IBGDA=OFF \
    -DISHMEM_AOT_DEVICE_TYPES="$ISHMEM_AOT_DEVICE_TYPES" \
    "$@" 2>&1 | tee "$ISHMEM_BUILD/configure.log"
cmake --build "$ISHMEM_BUILD" -j "$JOBS" 2>&1 | tee "$ISHMEM_BUILD/build.log"
cmake --install "$ISHMEM_BUILD" 2>&1 | tee "$ISHMEM_BUILD/install.log"
