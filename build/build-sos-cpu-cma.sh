#!/bin/bash

#set -e

# CPU-only single-node build of OFI + SOS, with the CMA on-node transport.
#
# Sibling of build-sos-shm-hmem.sh, which builds the GPU/FI_HMEM flavour. Dropping
# FI_HMEM simplifies things considerably:
#   - No Level Zero anywhere: OFI is configured --without-ze (and without the
#     other accelerator backends), so libfabric never touches a GPU runtime.
#   - No --disable-ofi-inject and no SOS source fix needed. The FI_HMEM variant
#     of shm advertises inject_size=0, which is what forces that whole dance;
#     the plain variant advertises 4096, so SOS's unconditional "require at
#     least sizeof(long double)" inject hint is satisfied as-is.
#   - shm keeps its own internal CMA. libfabric turns it off when the endpoint
#     asks for FI_HMEM (prov/shm/src/smr_ep.c, cma_cap_* = SMR_VMA_CAP_OFF), so
#     a CPU-only build gets single-copy transfers at both levels: SOS's CMA
#     transport for small/medium, and shm's own CMA (smr_src_iov) for host gets
#     and for puts above SMR_INJECT_SIZE=4096. What matters is the endpoint
#     caps, not the provider: shm still publishes an FI_HMEM variant here (it
#     handles FI_HMEM_SYSTEM by itself), but SOS never selects it.
#
# Still needed, because the on-node providers have not changed:
#   --enable-ofi-manual-progress: shm/sm2 only support FI_PROGRESS_MANUAL;
#     without it SOS asks for FI_PROGRESS_AUTO and fi_getinfo returns -61.
#   --enable-manual-progress: makes shmem_transport_probe() drive the target CQ
#     while spin-waiting, otherwise a barrier can deadlock. Different flag from
#     the one above; both are needed together.
#
# CMA notes:
#   --with-cma must be passed bare, NOT --with-cma=<path>: config/check_cma.m4
#     only runs the feature test when the value is exactly "yes", while
#     configure.ac defines USE_CMA for any non-empty value, so a path would
#     define USE_CMA without compiling the CMA transport. check_sos_cma below
#     verifies the result rather than trusting the flag.
#   --with-cma is mutually exclusive with --with-xpmem and implies
#     USE_ON_NODE_COMMS + ENABLE_HARD_POLLING.
#   It needs no kernel module and no root, but the PEs must share a uid and
#     kernel.yama.ptrace_scope must be 0 (or the process needs CAP_SYS_PTRACE).
#     Inside a container, add --cap-add=SYS_PTRACE: Docker's default seccomp
#     profile blocks process_vm_readv without it.
#   SOS only uses CMA below a size threshold, tunable at run time with
#     SHMEM_CMA_PUT_MAX (default 8K) and SHMEM_CMA_GET_MAX (default 16K).
#     There is no lower bound; even scalar puts take the CMA path.
#
# Installs alongside the FI_HMEM build rather than on top of it:
#
# repos  (REPO_DIR)         build  (BUILD_DIR)      install (INSTALL_DIR)
#   ofi                       build-sos-cpu-cma.sh    ofi-cpu
#   sos                       ofi-cpu                 sos-cpu
#                             sos-cpu

BASE_DIR=$(dirname $(dirname $(realpath $0)))
REPO_DIR=$(realpath -m ${REPO_DIR:-${BASE_DIR}/repos})
BUILD_DIR=$(realpath -m ${BUILD_DIR:-${BASE_DIR}/build})
INSTALL_DIR=$(realpath -m ${INSTALL_DIR:-${BASE_DIR}/install})

OFI_SRC=$(realpath -m ${OFI_SRC:-${REPO_DIR}/ofi})
OFI_BUILD=$(realpath -m ${OFI_BUILD:-${BUILD_DIR}/ofi-cpu})
OFI_INSTALL=$(realpath -m ${OFI_INSTALL:-${INSTALL_DIR}/ofi-cpu})

SOS_SRC=$(realpath -m ${SOS_SRC:-${REPO_DIR}/sos})
SOS_BUILD=$(realpath -m ${SOS_BUILD:-${BUILD_DIR}/sos-cpu})
SOS_INSTALL=$(realpath -m ${SOS_INSTALL:-${INSTALL_DIR}/sos-cpu})

SOS_COMPILERS=${SOS_COMPILERS:-"CXX=mpicxx CC=mpicc"}
OFI_COMPILERS=${OFI_COMPILERS:-"CXX=icpx CC=icx"}

# Only the providers that can serve a single node; override to change the set.
OFI_PROVIDER_FLAGS=${OFI_PROVIDER_FLAGS:-"--disable-psm2 "}

# CPU only: no accelerator backends and no HMEM plumbing at all.
OFI_HMEM_FLAGS=${OFI_HMEM_FLAGS:-"--without-ze --without-cuda --without-rocr
                                  --without-neuron --without-synapseai
                                  --without-gdrcopy
                                  --disable-hook_hmem
                                  --disable-dmabuf_peer_mem"}

# Reuse an existing OFI install instead of building one.
SKIP_OFI_BUILD=${SKIP_OFI_BUILD:-0}

# Reconfigure from scratch by default; the install trees are overwritten by
# "make install". Only the build trees are removed.
CLEAN_BUILD=${CLEAN_BUILD:-1}

# Options are: Debug, Release, RelWithDebInfo
BUILD_TYPE=${BUILD_TYPE:-Release}

SOS_CONFIGURE_FLAGS=""
SOS_CFLAGS=""
case ${BUILD_TYPE} in
Debug)
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

# CMA is a run-time permission, not just a compile-time feature, so warn about
# the things configure cannot see. Not fatal: the build is still valid, it just
# would not be able to attach to a peer.
check_cma_prereqs() {
    local scope_file=/proc/sys/kernel/yama/ptrace_scope
    if [ -r ${scope_file} ]; then
        local scope=$(cat ${scope_file})
        if [ "${scope}" != "0" ]; then
            echo "    WARNING: ${scope_file} is ${scope}, expected 0."
            echo "    CMA needs to ptrace a peer PE; process_vm_readv will fail"
            echo "    with EPERM unless the process has CAP_SYS_PTRACE."
        else
            echo "    yama ptrace_scope is 0"
        fi
    fi
    if [ -f /.dockerenv ] || grep -qE "docker|containerd|kubepods" /proc/1/cgroup 2>/dev/null; then
        echo "    NOTE: running in a container. CMA also needs --cap-add=SYS_PTRACE,"
        echo "    since the default seccomp profile blocks process_vm_readv."
    fi
}

build_ofi() {
    if [ "${SKIP_OFI_BUILD}" == "1" ]; then
        echo "    SKIP_OFI_BUILD=1, using existing OFI at ${OFI_INSTALL}"
        if [ ! -d ${OFI_INSTALL} ]; then
            echo "ERROR: no OFI installation at ${OFI_INSTALL}"
            exit 1
        fi
        return 0
    fi

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

    # --with-dlopen=no keeps the providers built in. It matters much less here
    # than in the GPU build, where dlopening Level Zero breaks FI_HMEM_ZE.
    ${OFI_SRC}/configure \
        --prefix=${OFI_INSTALL} \
        ${OFI_PROVIDER_FLAGS} \
        ${OFI_HMEM_FLAGS} \
        ${OFI_COMPILERS}
    echo "::endgroup::"
    echo "    OFI configure elapsed: $((SECONDS - start_time))s"

    build_and_install OFI
}

# configure accepts --with-cma=<anything>, so confirm the transport was really
# compiled in instead of taking the flag on faith.
check_sos_cma() {
    if ! grep -q "^#define USE_CMA 1" ${SOS_BUILD}/src/config.h; then
        echo "ERROR: USE_CMA is not defined in ${SOS_BUILD}/src/config.h."
        echo "       The CMA transport was not compiled in. Check that"
        echo "       configure printed 'CMA: yes' under On Node Communication,"
        echo "       and that --with-cma was passed bare (no =path)."
        exit 1
    fi
    if grep -q "^#define USE_FI_HMEM 1" ${SOS_BUILD}/src/config.h; then
        echo "ERROR: USE_FI_HMEM is defined; this is meant to be a CPU-only build."
        exit 1
    fi
    echo "    USE_CMA defined, USE_FI_HMEM absent, as intended"
}

build_sos() {
    if [ ! -d ${SOS_SRC} ]; then
        echo "ERROR: SOS source not found at ${SOS_SRC}"
        exit 1
    fi

    echo "::group::SOS configure"
    local start_time=$SECONDS
    check_cma_prereqs
    cd ${SOS_SRC}
    autogen

    clean_build_dir ${SOS_BUILD}
    mkdir -p ${SOS_BUILD}
    cd ${SOS_BUILD}

    ${SOS_SRC}/configure \
        --prefix=${SOS_INSTALL} \
        ${SOS_CONFIGURE_FLAGS} \
        --with-ofi=${OFI_INSTALL} \
        --with-cma \
        --disable-fortran \
        --disable-libtool-wrapper \
        --enable-hard-polling \
        --enable-mr-endpoint \
        --enable-ofi-mr=basic \
        --enable-pmi-mpi \
        --enable-manual-progress \
        --enable-ofi-manual-progress \
        ${SOS_COMPILERS} \
        "${SOS_CFLAGS_ARG[@]}"
    echo "::endgroup::"
    echo "    SOS configure elapsed: $((SECONDS - start_time))s"

    check_sos_cma
    build_and_install SOS
}

# Confirm no accelerator backend crept into OFI. Note that this cannot be done
# with "fi_info -p shm -c FI_HMEM": shm publishes a second FI_HMEM variant
# (inject_size=0) even with every backend compiled out, because it supports
# FI_HMEM_SYSTEM and dmabuf registration on its own. That variant is harmless
# here only because SOS is built without --enable-ofi-hmem and so never asks for
# FI_HMEM; if it did, the endpoint caps would include FI_HMEM and libfabric
# would switch shm's internal CMA off.
check_ofi_cpu_only() {
    echo "::group::OFI CPU-only check"
    local cfg=${OFI_BUILD}/config.h
    if [ ! -f ${cfg} ]; then
        echo "    skipping: ${cfg} not found (SKIP_OFI_BUILD?)"
        echo "::endgroup::"
        return 0
    fi
    local backend found=0
    for backend in ZE CUDA ROCR NEURON SYNAPSEAI GDRCOPY; do
        if grep -q "^#define HAVE_${backend} 1" ${cfg}; then
            echo "    WARNING: HAVE_${backend} is set; OFI was built with an"
            echo "    accelerator backend after all."
            found=1
        fi
    done
    if [ ${found} == 0 ]; then
        echo "    no accelerator backend compiled into OFI, CPU-only as intended"
    fi

    if LD_LIBRARY_PATH=${OFI_INSTALL}/lib:${LD_LIBRARY_PATH} \
       ${OFI_INSTALL}/bin/fi_info -p shm > /dev/null 2>&1; then
        echo "    shm provider present"
    else
        echo "    WARNING: 'fi_info -p shm' found nothing."
    fi
    echo "::endgroup::"
}

build_ofi
build_sos
check_ofi_cpu_only

echo ""
echo "CPU-only CMA dependencies installed:"
echo "    OFI: ${OFI_INSTALL}"
echo "    SOS: ${SOS_INSTALL}"
echo "Run with:"
echo "    export SHMEM_OFI_PROVIDER=shm"
echo "    export LD_LIBRARY_PATH=${OFI_INSTALL}/lib:${SOS_INSTALL}/lib:\${LD_LIBRARY_PATH}"
echo "    # no FI_HMEM: this build has no GPU support"
echo "On-node tuning:"
echo "    SHMEM_CMA_PUT_MAX / SHMEM_CMA_GET_MAX  (SOS CMA thresholds, 8K/16K)"
echo "    FI_SHM_DISABLE_CMA=1                   (to compare against shm's own CMA)"
