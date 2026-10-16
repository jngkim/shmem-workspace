#!/usr/bin/env bash
set -o pipefail

source /opt/intel/oneapi/compiler/latest/env/vars.sh &&
source /opt/intel/oneapi/umf/latest/env/vars.sh &&
source /opt/intel/oneapi/tcm/latest/env/vars.sh &&
source "$HOME/intel/oneapi/libfabric/latest/env/vars.sh" &&
source "$HOME/share/agama-ppa/38308/setup-env.sh" || exit 1

set -e

WORKSPACE_ROOT=${WORKSPACE_ROOT:-"$HOME/shmem-workspace"}
MPICH_SRC=${MPICH_SRC:-"$WORKSPACE_ROOT/repos/mpich"}
MPICH_BUILD=${MPICH_BUILD:-"$WORKSPACE_ROOT/build/mpich-pvc"}
MPICH_INSTALL=${MPICH_INSTALL:-"$WORKSPACE_ROOT/install/mpich"}
JOBS=${JOBS:-32}
ZE_LIBDIR=$(pkg-config --variable=libdir level-zero)

command -v icx icpx ifx
icx --version
icpx --version
ifx --version
test -f "$MPICH_SRC/configure.ac"
test -f "$LIBFABRIC_ROOT/include/rdma/fabric.h"
test -f "$ZE_LIBDIR/libze_loader.so"
mkdir -p "$MPICH_BUILD"

if [[ ! -x "$MPICH_SRC/configure" ]]; then
    pushd "$MPICH_SRC"
    git submodule update --init modules/hwloc modules/json-c modules/mydef_boot
    ./autogen.sh --without-ofi --without-ucx 2>&1 | tee "$MPICH_BUILD/autogen.log"
    popd
fi

cd "$MPICH_BUILD"
"$MPICH_SRC/configure" \
    --prefix="$MPICH_INSTALL" \
    --with-device=ch4:ofi \
    --with-libfabric="$LIBFABRIC_ROOT" \
    --with-ze=yes \
    --with-ze-include=/usr/include \
    --with-ze-lib="$ZE_LIBDIR" \
    --without-cuda \
    --without-hip \
    --enable-ze-native=pvc \
    --enable-ze-revision-id=47 \
    CC=icx CXX=icpx FC=ifx F77=ifx \
    "$@" 2>&1 | tee configure-output.log
make -j "$JOBS" 2>&1 | tee build.log
make install 2>&1 | tee install.log
"$MPICH_INSTALL/bin/mpichversion"
printf '\nMPICH installed in %s\n' "$MPICH_INSTALL"