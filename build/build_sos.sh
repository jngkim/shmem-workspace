#!/bin/bash

# TIMESTAMP=$(date +%Y%m%d)
# exec > >(tee "ishmem.${TIMESTAMP}.log") 2>&1

export BASE=${BASE:-${HOME}/shmem-workspace/build/latest}

SRC_ROOT=${SRC_ROOT:-${HOME}/shmem-workspace/repos}
SOS_BUILD=${SOS_BUILD:-${BASE}/sos}
SOS_INSTALL=${SOS_INSTALL:-${BASE}/install/sos}
OFI_BUILD=${OFI_BUILD:-${BASE}/ofi}
OFI_INSTALL=${OFI_INSTALL:-${BASE}/install/ofi}

SOS_COMPILERS="CXX=mpicxx CC=mpicc"
SOS_PMI_FLAG="--enable-pmi-mpi"
#SOS_COMPILERS="CXX=icpx CC=icx"
#SOS_PMI_FLAG="--enable-pmi-simple"

extra_options=${1:-""}

build_ofi() {
    local OFI_SRC=${SRC_ROOT}/libfabric
    if [ ! -f ${OFI_SRC}/configure ]; then
        cd ${OFI_SRC} && ./autogen.sh
    fi
    mkdir -p ${OFI_BUILD}
    cd ${OFI_BUILD}
    ${OFI_SRC}/configure --prefix=${OFI_INSTALL} \
      --disable-rxd \
      --disable-rxm \
      --disable-udp \
      --disable-usnic \
      --disable-psm

    make -j
    make install
}

# configure options used for 1.5 release
# https://github.com/oneapi-src/ishmem/issues/15
# export FI_CXI_OPTIMIZED_MRS=0
# Removed 2026-05-29
#      --disable-bounce-buffers
#      --disable-nonfetch-amo
build_sos1.5_cxi() {
    mkdir -p ${SOS_BUILD}
    cd ${SOS_BUILD}

    ${SRC_ROOT}/SOS/configure --prefix=${SOS_INSTALL} --with-ofi=${OFI_INSTALL} \
      --disable-fortran --disable-libtool-wrapper ${extra_options} \
      --enable-ofi-mr=basic --enable-mr-endpoint --enable-ofi-hmem \
      --enable-manual-progress --enable-ofi-manual-progress \
      --disable-ofi-inject \
      ${SOS_PMI_FLAG} ${SOS_COMPILERS}

    make -j
    make install

    head config.log > ${SOS_INSTALL}/config.log
}


build_sos1.6_cxi() {
    mkdir -p ${SOS_BUILD}
    cd ${SOS_BUILD}

    ${SRC_ROOT}/SOS/configure --prefix=${SOS_INSTALL} --with-ofi=${OFI_INSTALL} \
      --disable-fortran --disable-libtool-wrapper ${extra_options} \
      --enable-ofi-mr=basic --enable-mr-endpoint --enable-ofi-manual-progress \
      --enable-ofi-hmem \
      ${SOS_OFI_MR} ${SOS_HMEM_FLAG} ${SOS_COMPILERS}

    make -j
    make install

    head config.log > ${SOS_INSTALL}/config.log
}

build_sos1.6_ib() {
    mkdir -p ${SOS_BUILD}
    cd ${SOS_BUILD}

    ${SRC_ROOT}/SOS/configure --prefix=${SOS_INSTALL} --with-ofi=${OFI_INSTALL} \
      --disable-fortran --disable-libtool-wrapper ${extra_options} \
      --enable-ofi-mr=basic --enable-mr-endpoint --enable-hard-polling \
      --with-cma --enable-ofi-hmem \
      ${SOS_PMI_FLAG} ${SOS_COMPILERS}

    make -j
    make install

    head config.log > ${SOS_INSTALL}/config.log
}

build_sos1.6_mac() {
    mkdir -p ${SOS_BUILD}
    cd ${SOS_BUILD}

    SOS_COMPILERS="CXX=/opt/homebrew/bin/g++-15 CC=/opt/homebrew/bin/gcc-15"
    SOS_PMI_FLAG="--enable-pmi-simple"
    extra_options="--enable-dlopen --disable-cxx" 

    ${SRC_ROOT}/SOS/configure --prefix=${SOS_INSTALL} --with-ofi=${OFI_INSTALL} \
      --disable-fortran --disable-libtool-wrapper ${extra_options} \
      --enable-ofi-mr=basic --with-hwloc=/opt/homebrew \
      ${SOS_PMI_FLAG} ${SOS_COMPILERS}
}

if [[ "${SKIP_OFI_BUILD:-0}" != "1" ]] && [ ! -d ${OFI_INSTALL} ]; then
    build_ofi
fi

if [ ! -f ${SRC_ROOT}/SOS/configure ]; then
  cd ${SRC_ROOT}/SOS && ./autogen.sh
fi

#build_sos_ofi
build_sos1.5_cxi

