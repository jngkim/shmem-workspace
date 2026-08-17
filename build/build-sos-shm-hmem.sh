#!/bin/bash

#set -e

# Single-node shm + FI_HMEM variant of repos/ishmem/scripts/build-deps.sh.
#
# build-deps.sh targets a multi-node cluster with a NIC (IB/verbs, CXI, ...),
# where the OFI provider that carries FI_HMEM is the NIC provider. This script
# targets ONE Linux node with no fabric at all (e.g. a GPU workstation or cloud
# VM), where the only providers that advertise FI_HMEM are the shared-memory
# ones (shm/sm2). That changes both the OFI and the SOS configuration:
#
# For a build without any GPU support, use the sibling build-sos-cpu-cma.sh
# instead: dropping FI_HMEM removes most of the flags below and lets the CMA
# on-node transport be used at both the SOS and the shm level.
#
# OFI:  only the single-node providers are built, so the build is much smaller.
# SOS:  three extra flags are required on top of the cluster recipe
#   --enable-ofi-manual-progress: shm/sm2 only support FI_PROGRESS_MANUAL;
#     without it SOS asks for FI_PROGRESS_AUTO and fi_getinfo returns -61.
#     (defines ENABLE_FI_MANUAL_PROGRESS -> provider progress mode only)
#   --enable-manual-progress: makes shmem_transport_probe() drive the target CQ
#     while spin-waiting. shm executes atomics/RMA on the target, so without
#     this a barrier deadlocks (completions never arrive). This is a DIFFERENT
#     flag from --enable-ofi-manual-progress (defines ENABLE_MANUAL_PROGRESS);
#     both are needed together.
#   --disable-ofi-inject: the FI_HMEM variant of shm advertises inject_size=0
#     (the non-HMEM variant advertises 4096), so requiring inject support in the
#     fi_getinfo hints rejects the only HMEM-capable provider. Note the flag
#     alone is not sufficient on SOS sources that set the inject_size hint
#     unconditionally; check_sos_inject below rejects such a tree up front.
#
# Run the resulting build with SHMEM_OFI_PROVIDER=shm FI_HMEM=ze.
#
# layout is the same as build-deps.sh, but this script lives in BUILD_DIR
# rather than in the ishmem repo, so BASE_DIR is only one level up.
#
# repos  (REPO_DIR)
#   ishmem
#     scripts/build-deps.sh
#   ofi
#   sos
# build  (BUILD_DIR)
#   build-sos-shm-hmem.sh
#   ofi
#   sos
# install (INSTALL_DIR)
#   ofi
#   sos

BASE_DIR=$(dirname $(dirname $(realpath $0)))
REPO_DIR=$(realpath -m ${REPO_DIR:-${BASE_DIR}/repos})
BUILD_DIR=$(realpath -m ${BUILD_DIR:-${BASE_DIR}/build})
INSTALL_DIR=$(realpath -m ${INSTALL_DIR:-${BASE_DIR}/install})

OFI_SRC=$(realpath -m ${OFI_SRC:-${REPO_DIR}/ofi})
OFI_BUILD=$(realpath -m ${OFI_BUILD:-${BUILD_DIR}/ofi})
OFI_INSTALL=$(realpath -m ${OFI_INSTALL:-${INSTALL_DIR}/ofi})

SOS_SRC=$(realpath -m ${SOS_SRC:-${REPO_DIR}/sos})
SOS_BUILD=$(realpath -m ${SOS_BUILD:-${BUILD_DIR}/sos})
SOS_INSTALL=$(realpath -m ${SOS_INSTALL:-${INSTALL_DIR}/sos})

SOS_COMPILERS=${SOS_COMPILERS:-"CXX=mpicxx CC=mpicc"}
OFI_COMPILERS=${OFI_COMPILERS:-"CXX=icpx CC=icx"}

# Only the providers that can serve a single node are needed. Everything else
# is turned off to keep the OFI build small; set OFI_PROVIDER_FLAGS to override.
OFI_PROVIDER_FLAGS=${OFI_PROVIDER_FLAGS:-"--enable-shm --enable-sm2 --enable-tcp
                                          --disable-verbs --disable-psm2
                                          --disable-psm3 --disable-opx
                                          --disable-efa --disable-usnic
                                          --disable-ucx --disable-lnx
                                          --disable-udp --disable-rxd
                                          --disable-rxm --disable-sockets"}

# Reconfigure from scratch by default: this script and build-deps.sh share
# ${BUILD_DIR}, and reusing a build tree configured by the other one picks up a
# stale config.status. Only the build trees are removed; the install trees are
# overwritten by "make install".
CLEAN_BUILD=${CLEAN_BUILD:-1}

# Add the CMA on-node transport (single-copy put/get between PEs via
# process_vm_readv/writev). Needs no kernel module and no root, but it does
# need the PEs to share a uid and kernel.yama.ptrace_scope to be 0. Off by
# default because a restrictive ptrace_scope makes it fail at run time.
# --with-cma must be passed bare, NOT --with-cma=<path>: config/check_cma.m4
# only runs the feature test when the value is exactly "yes", while
# configure.ac defines USE_CMA for any non-empty value, so a path would define
# USE_CMA without compiling the CMA transport. It is also mutually exclusive
# with --with-xpmem.
SOS_WITH_CMA=${SOS_WITH_CMA:-0}

# Refuse to build a SOS tree whose fi_getinfo inject_size hint would reject the
# FI_HMEM variant of shm. See check_sos_inject.
SOS_CHECK_INJECT=${SOS_CHECK_INJECT:-1}

# Options are: Debug, Release, RelWithDebInfo
BUILD_TYPE=${BUILD_TYPE:-Release}

SOS_CONFIGURE_FLAGS=""
SOS_CFLAGS=""
case ${BUILD_TYPE} in
Debug)
    # SOS_CONFIGURE_FLAGS="--enable-debug --enable-error-checking"
    SOS_CONFIGURE_FLAGS="--enable-debug"
    SOS_CFLAGS="-g -O0"
    ;;
RelWithDebInfo)
    SOS_CFLAGS="-g -O2"
    ;;
Release)
    ;;
*)
    echo "ERROR: unknown BUILD_TYPE '${BUILD_TYPE}'"
    echo "Options are: Debug, Release, RelWithDebInfo"
    exit 1
    ;;
esac

if [ "${SOS_WITH_CMA}" == "1" ]; then
    SOS_CONFIGURE_FLAGS="${SOS_CONFIGURE_FLAGS} --with-cma"
fi

# CFLAGS must be one word when it reaches configure, so it cannot go in the
# unquoted SOS_CONFIGURE_FLAGS. Left empty for Release so that configure keeps
# its own default optimization flags.
SOS_CFLAGS_ARG=()
if [ -n "${SOS_CFLAGS}" ]; then
    SOS_CFLAGS_ARG=(CFLAGS="${SOS_CFLAGS}")
fi

autogen() {
    if [ -f configure ]; then
        echo "configure exists, skipping autogen.sh"
    else
        ./autogen.sh
    fi
}

clean_build_dir() {
    local dir=$1
    # Refuse to remove anything that is not a plausible build directory.
    case "${dir}" in
    ""|"/"|"${HOME}")
        echo "ERROR: refusing to clean '${dir}'"
        exit 1
        ;;
    esac
    if [ "${CLEAN_BUILD}" == "1" ] && [ -d "${dir}" ]; then
        echo "    removing stale build directory ${dir}"
        rm -rf "${dir}"
    fi
}

build_and_install() {
    local name=$1
    echo "::group::${name} build"
    local start_time=$SECONDS
    make -j
    echo "::endgroup::"
    echo "    ${name} build elapsed: $((SECONDS - start_time))s"

    echo "::group::${name} install"
    start_time=$SECONDS
    make install
    echo "::endgroup::"
    echo "    ${name} install elapsed: $((SECONDS - start_time))s"
}

build_ofi() {
    if [ ! -d ${OFI_SRC} ]; then
        echo "ERROR: OFI source not found at ${OFI_SRC}"
        exit 1
    fi

    echo "::group::OFI configure"
    local start_time=$SECONDS
    cd ${OFI_SRC}
    autogen

    clean_build_dir ${OFI_BUILD}
    mkdir -p ${OFI_BUILD}
    cd ${OFI_BUILD}

    # --with-dlopen=no links Level Zero directly. With --enable-ze-dlopen
    # libfabric reports "Hmem iface FI_HMEM_ZE not supported" at run time even
    # though libze_loader dlopens fine, which leaves no HMEM provider at all.
    ${OFI_SRC}/configure \
        --prefix=${OFI_INSTALL} \
        --with-dlopen=no \
        ${OFI_PROVIDER_FLAGS}  \
        ${OFI_COMPILERS}
    echo "::endgroup::"
    echo "    OFI configure elapsed: $((SECONDS - start_time))s"

    build_and_install OFI
}

# Older SOS query_for_fabric() sets the fi_getinfo hint tx_attr.inject_size to
# sizeof(long double) unconditionally; --disable-ofi-inject only zeroes
# shmem_transport_ofi_max_buffered_send afterwards, once fi_getinfo has already
# run. The shm provider offers a non-HMEM variant with inject_size=4096 and an
# FI_HMEM variant with inject_size=0, so an --enable-ofi-hmem build asks for 16
# bytes of inject, both variants are rejected, and transport init fails with
# -61. This is a source-level bug, so it is fixed in the SOS tree rather than
# here; all this does is refuse to build a tree that would fail at run time.
check_sos_inject() {
    local src=${SOS_SRC}/src/transport_ofi.c
    local hint='tx_attr\.inject_size *= *shmem_transport_ofi_max_buffered_send;'

    if [ "${SOS_CHECK_INJECT}" != "1" ]; then
        echo "    SOS_CHECK_INJECT=0, skipping the inject_size hint check"
        return 0
    fi

    if [ ! -f ${src} ]; then
        echo "ERROR: ${src} not found"
        exit 1
    fi

    # Either the hint is gone (fixed by zeroing max_buffered_send before
    # fi_getinfo) or it is guarded by DISABLE_OFI_INJECT. Both are fine.
    if ! grep -qE "${hint}" ${src} ||
       grep -B3 -E "${hint}" ${src} | grep -q "DISABLE_OFI_INJECT"; then
        echo "    SOS does not over-constrain the inject_size hint, good"
        return 0
    fi

    echo "ERROR: ${SOS_SRC} constrains the fi_getinfo inject_size hint to"
    echo "       sizeof(long double), which rejects the FI_HMEM variant of the"
    echo "       shm provider (inject_size=0). This build would fail at run"
    echo "       time with 'did not find any valid fabric services' (-61)."
    echo "       Check out a SOS revision that fixes it, e.g."
    echo "           git -C ${SOS_SRC} cherry-pick <inject-hint fix>"
    echo "       or set SOS_CHECK_INJECT=0 to build anyway."
    exit 1
}

build_sos() {
    if [ ! -d ${SOS_SRC} ]; then
        echo "ERROR: SOS source not found at ${SOS_SRC}"
        exit 1
    fi

    echo "::group::SOS configure"
    local start_time=$SECONDS
    check_sos_inject
    cd ${SOS_SRC}
    autogen

    clean_build_dir ${SOS_BUILD}
    mkdir -p ${SOS_BUILD}
    cd ${SOS_BUILD}

    ${SOS_SRC}/configure \
        --prefix=${SOS_INSTALL} \
        ${SOS_CONFIGURE_FLAGS} \
        --with-ofi=${OFI_INSTALL} \
        --disable-fortran \
        --disable-libtool-wrapper \
        --enable-hard-polling \
        --enable-mr-endpoint \
        --enable-ofi-hmem \
        --enable-ofi-mr=basic \
        --enable-pmi-mpi \
        --enable-manual-progress \
        --enable-ofi-manual-progress \
        --disable-ofi-inject \
        ${SOS_COMPILERS} \
        "${SOS_CFLAGS_ARG[@]}"
    echo "::endgroup::"
    echo "    SOS configure elapsed: $((SECONDS - start_time))s"

    build_and_install SOS
}

# The whole point of the single-node build is that shm carries FI_HMEM, so
# check that it actually does before anyone tries to run ISHMEM on top.
check_ofi_hmem() {
    echo "::group::OFI FI_HMEM check"
    if LD_LIBRARY_PATH=${OFI_INSTALL}/lib:${LD_LIBRARY_PATH} FI_HMEM=ze \
       ${OFI_INSTALL}/bin/fi_info -p shm -c FI_HMEM > /dev/null 2>&1; then
        echo "    shm advertises FI_HMEM"
    else
        echo "    WARNING: 'fi_info -p shm -c FI_HMEM' found nothing."
        echo "    ISHMEM needs FI_HMEM in the provider. Check that Level Zero"
        echo "    headers and libze_loader were present when OFI was configured."
    fi
    echo "::endgroup::"
}

build_ofi
build_sos
check_ofi_hmem

echo ""
echo "Single-node dependencies installed:"
echo "    OFI: ${OFI_INSTALL}"
echo "    SOS: ${SOS_INSTALL}"
echo "Build ISHMEM against them with:"
echo "    SOS_INSTALL=${SOS_INSTALL} ${REPO_DIR}/ishmem/scripts/build-ishmem.sh"
echo "Run with:"
echo "    export SHMEM_OFI_PROVIDER=shm"
echo "    export FI_HMEM=ze"
# libsma records an rpath to ${OFI_INSTALL}/lib, but Intel MPI ships its own
# libfabric and also pulls it in, so put this OFI first to be sure which one
# gets loaded.
echo "    export LD_LIBRARY_PATH=${OFI_INSTALL}/lib:${SOS_INSTALL}/lib:\${LD_LIBRARY_PATH}"
