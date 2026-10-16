#!/bin/bash

# CPU-only single-node build of libfabric + Sandia OpenSHMEM with the OFI shm
# provider as the ONLY on-node transport (no SOS CMA/XPMEM layer on top).
#
# Siblings:
#   build-sos-cpu-cma.sh   same idea, plus SOS's CMA transport (--with-cma),
#                          built with mpicc/mpicxx and --enable-pmi-mpi
#   build-sos-shm-hmem.sh  GPU flavour (FI_HMEM, Level Zero)
#
# Toolchain: oneAPI 2026.1 (icx/icpx; classic icc is not shipped in 2026.1).
#   libfabric: CC=icx CXX=icpx.
#   SOS: --enable-pmi-mpi, so it is compiled with Intel MPI's icx-based
#   wrappers CC=mpiicx CXX=mpiicpx and libsma links libmpi; MPI_Init does the
#   PE bootstrap. Launch with oneAPI's mpiexec.hydra/mpirun or SOS's oshrun.
#   (PMI-simple with plain icx also works: SOS_PMI=--enable-pmi-simple
#   SOS_COMPILERS="CC=icx CXX=icpx".)
#
# Why each SOS flag is there (each one fixes a real failure with shm):
#   --enable-ofi-manual-progress  shm/sm2 only support FI_PROGRESS_MANUAL;
#                                 without it fi_getinfo returns -61.
#   --enable-manual-progress      different flag: SOS drives the target CQ
#                                 while spin-waiting, else barriers deadlock.
#   --enable-ofi-mr=basic --enable-mr-endpoint --enable-hard-polling
#                                 MR mode/polling that shm supports.
#   No --enable-ofi-hmem, so no --disable-ofi-inject and no inject-hint source
#   fix: the non-HMEM shm variant advertises inject_size=4096.
#   No --with-cma: shm does its own single-copy CMA (smr_src_iov) for gets and
#   puts > 4096 B as long as the endpoint has no FI_HMEM cap.
#
# Layout (everything stays inside the workspace):
#   repos/libfabric  -> build/ofi-shm  -> install/ofi-shm
#   repos/SOS        -> build/sos-shm  -> install/sos-shm
#
# Knobs: SKIP_OFI_BUILD=1, CLEAN_BUILD=0, BUILD_TYPE=Debug|RelWithDebInfo|Release,
#        RUN_CHECK=1 (run a 2-PE hello + put/get smoke test after install).

set -e

ONEAPI_ROOT=${ONEAPI_ROOT:-/opt/intel/oneapi/2026.1}
# Keep oneAPI's bundled libfabric off LD_LIBRARY_PATH; ofi-shm/lib has priority.
export I_MPI_OFI_LIBRARY_INTERNAL=0
if ! command -v icx > /dev/null 2>&1; then
    source ${ONEAPI_ROOT}/oneapi-vars.sh > /dev/null 2>&1 \
        || source ${ONEAPI_ROOT}/setvars.sh > /dev/null 2>&1
fi

BASE_DIR=$(dirname $(dirname $(realpath $0)))
REPO_DIR=$(realpath -m ${REPO_DIR:-${BASE_DIR}/repos})
BUILD_DIR=$(realpath -m ${BUILD_DIR:-${BASE_DIR}/build})
INSTALL_DIR=$(realpath -m ${INSTALL_DIR:-${BASE_DIR}/install})

OFI_SRC=$(realpath -m ${OFI_SRC:-${REPO_DIR}/libfabric})
OFI_BUILD=$(realpath -m ${OFI_BUILD:-${BUILD_DIR}/ofi-shm})
OFI_INSTALL=$(realpath -m ${OFI_INSTALL:-${INSTALL_DIR}/ofi-shm})

SOS_SRC=$(realpath -m ${SOS_SRC:-${REPO_DIR}/SOS})
SOS_BUILD=$(realpath -m ${SOS_BUILD:-${BUILD_DIR}/sos-shm})
SOS_INSTALL=$(realpath -m ${SOS_INSTALL:-${INSTALL_DIR}/sos-shm})

OFI_COMPILERS=${OFI_COMPILERS:-"CC=icx CXX=icpx"}
SOS_COMPILERS=${SOS_COMPILERS:-"CC=mpiicx CXX=mpiicpx"}
SOS_PMI=${SOS_PMI:---enable-pmi-mpi}

# Only providers useful on a single node.
OFI_PROVIDER_FLAGS=${OFI_PROVIDER_FLAGS:-"--enable-shm --enable-sm2 --enable-tcp
    --disable-verbs --disable-psm2 --disable-psm3 --disable-opx --disable-efa
    --disable-usnic --disable-ucx --disable-lnx --disable-udp --disable-rxd
    --disable-rxm --disable-sockets"}
OFI_HMEM_FLAGS=${OFI_HMEM_FLAGS:-"--without-ze --without-cuda --without-rocr
    --without-neuron --without-synapseai --without-gdrcopy
    --disable-hook_hmem --disable-dmabuf_peer_mem"}

SKIP_OFI_BUILD=${SKIP_OFI_BUILD:-0}
CLEAN_BUILD=${CLEAN_BUILD:-1}
BUILD_TYPE=${BUILD_TYPE:-Release}
RUN_CHECK=${RUN_CHECK:-1}

SOS_CONFIGURE_FLAGS=""
CFLAGS_ARG=()
case ${BUILD_TYPE} in
Debug)          SOS_CONFIGURE_FLAGS="--enable-debug"; CFLAGS_ARG=(CFLAGS="-g -O0") ;;
RelWithDebInfo) CFLAGS_ARG=(CFLAGS="-g -O2") ;;
Release)        ;;
*) echo "ERROR: unknown BUILD_TYPE '${BUILD_TYPE}'"; exit 1 ;;
esac

clean_build_dir() {
    local dir=$1
    case "${dir}" in
    ""|"/"|"${HOME}"|"${BASE_DIR}"|"${BUILD_DIR}")
        echo "ERROR: refusing to clean '${dir}'"; exit 1 ;;
    esac
    if [ "${CLEAN_BUILD}" == "1" ] && [ -d "${dir}" ]; then
        echo "    removing stale build directory ${dir}"
        rm -rf "${dir}"
    fi
}

autogen() {
    [ -f configure ] && echo "    configure exists, skipping autogen.sh" || ./autogen.sh
}

build_ofi() {
    if [ "${SKIP_OFI_BUILD}" == "1" ]; then
        [ -d ${OFI_INSTALL} ] || { echo "ERROR: no OFI at ${OFI_INSTALL}"; exit 1; }
        echo "    SKIP_OFI_BUILD=1, using ${OFI_INSTALL}"
        return 0
    fi
    echo "::group::OFI ($(git -C ${OFI_SRC} describe --tags --always))"
    cd ${OFI_SRC}; autogen
    clean_build_dir ${OFI_BUILD}
    mkdir -p ${OFI_BUILD}; cd ${OFI_BUILD}
    ${OFI_SRC}/configure --prefix=${OFI_INSTALL} --with-dlopen=no \
        ${OFI_PROVIDER_FLAGS} ${OFI_HMEM_FLAGS} ${OFI_COMPILERS}
    make -j 32 > make.log 2>&1 || { tail -30 make.log; exit 1; }
    make install > install.log 2>&1
    echo "::endgroup::"
}

build_sos() {
    echo "::group::SOS ($(git -C ${SOS_SRC} rev-parse --abbrev-ref HEAD) $(git -C ${SOS_SRC} rev-parse --short HEAD))"
    [ -f ${SOS_SRC}/modules/tests-sos/configure.ac ] \
        || git -C ${SOS_SRC} submodule update --init --recursive
    cd ${SOS_SRC}; autogen
    clean_build_dir ${SOS_BUILD}
    mkdir -p ${SOS_BUILD}; cd ${SOS_BUILD}
    ${SOS_SRC}/configure --prefix=${SOS_INSTALL} ${SOS_CONFIGURE_FLAGS} \
        --with-ofi=${OFI_INSTALL} \
        ${SOS_PMI} \
        --disable-fortran \
        --disable-libtool-wrapper \
        --enable-ofi-mr=basic \
        --enable-mr-endpoint \
        --enable-hard-polling \
        --enable-manual-progress \
        --enable-ofi-manual-progress \
        ${SOS_COMPILERS} "${CFLAGS_ARG[@]}"
    local cfg=${SOS_BUILD}/src/config.h
    for bad in USE_FI_HMEM USE_CMA USE_XPMEM; do
        if grep -q "^#define ${bad} 1" ${cfg}; then
            echo "ERROR: ${bad} is defined; expected a pure-shm CPU build"; exit 1
        fi
    done
    make -j 32 > make.log 2>&1 || { tail -30 make.log; exit 1; }
    make install > install.log 2>&1
    echo "::endgroup::"
}

check_install() {
    echo "::group::smoke test"
    source ${BUILD_DIR}/env-sos-shm-cpu.sh
    ${OFI_INSTALL}/bin/fi_info -p shm | grep -m1 'provider:'
    local t=${SOS_BUILD}/smoke; mkdir -p $t
    ${SOS_INSTALL}/bin/oshcc -o $t/hello ${SOS_SRC}/modules/tests-sos/test/unit/hello.c
    # ofi-shm/lib must win over oneAPI's bundled libfabric.
    local fab=$(LD_DEBUG=libs timeout 60 mpiexec.hydra -n 1 $t/hello 2>&1 \
        | sed -n 's/.*calling init: \(.*libfabric\.so[^ ]*\).*/\1/p' | sort -u)
    echo "    loaded: ${fab}"
    if [ "$(realpath -m ${fab})" != "$(realpath -m ${OFI_INSTALL}/lib/libfabric.so.1)" ]; then
        echo "ERROR: wrong libfabric loaded; expected ${OFI_INSTALL}/lib first"; exit 1
    fi
    SHMEM_INFO=1 timeout 60 mpiexec.hydra -n 2 $t/hello 2>&1 \
        | grep -E 'Hello|SHMEM_OFI_PROVIDER  ' | sort -u
    echo "::endgroup::"
}

build_ofi
build_sos
[ "${RUN_CHECK}" == "1" ] && check_install

cat <<EOF

Installed:  OFI ${OFI_INSTALL}
            SOS ${SOS_INSTALL}
Run with:
    source ${BUILD_DIR}/env-sos-shm-cpu.sh   # oneAPI + ofi-shm/lib first + SHMEM_OFI_PROVIDER=shm
    oshcc foo.c -o foo
    mpiexec.hydra -n 2 ./foo                 # or oshrun -n 2 ./foo
Test suite (166/168 on 2026-10-12; shmemx gettid_register, perf_counter fail):
    cd ${SOS_BUILD} && make -j 32 check TEST_RUNNER="timeout 180 ${SOS_BUILD}/src/oshrun -n 2"
EOF
