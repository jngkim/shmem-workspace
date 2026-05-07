#!/bin/bash

# TIMESTAMP=$(date +%Y%m%d)
# exec > >(tee "ishmem.${TIMESTAMP}.log") 2>&1

export BASE=${BASE:-${HOME}/shmem-workspace/build/latest}

SRC_ROOT=${SRC_ROOT:-${HOME}/shmem-workspace/repos}
SOS_BUILD=${SOS_BUILD:-${BASE}/sos}
SOS_INSTALL=${SOS_INSTALL:-${BASE}/install/sos}
OFI_BUILD=${OFI_BUILD:-${BASE}/ofi}
OFI_INSTALL=${OFI_INSTALL:-${BASE}/install/ofi}

extra_options=${1:-""}

build_ofi() {
    local OFI_SRC=${SRC_ROOT}/libfabric
    if [ ! -f ${OFI_SRC}/configure ]; then
        cd ${OFI_SRC} && ./autogen.sh
    fi
    mkdir -p ${OFI_BUILD}
    cd ${OFI_BUILD}
    ${OFI_SRC}/configure --prefix=${OFI_INSTALL} --disable-psm3

    make -j
    make install
}

SOS_COMPILERS="CXX=mpicxx CC=mpicc"
SOS_PMI_FLAG="--enable-pmi-mpi"
SOS_XPMEM_FLAG=""
if [[ "${OFI_INSTALL}" == *"cray"* ]]; then
    # On Cray/CXI systems, XPMEM and CXI can conflict for intra-node transfers 
    # — SOS uses XPMEM for shared-memory transport between ranks on the same
    # node, but when combined with CXI's memory registration model it can
    # deadlock during shmem_init or collectives.
    # with CXI's memory registration model it can deadlock during shmem_init or collectives.
    if [[ "${CLUSTER}" == *"borealis"* ]]; then
      SOS_XPMEM_FLAG="--with-xpmem=/usr/lib"
    fi
    SOS_OFI_MR="--enable-ofi-mr=basic --enable-mr-endpoint --enable-ofi-manual-progress"
else
    # 2026-04-06 on anbmg and florence
    # add --with-cma to improve on-node perf
    # drop --disable-bounce-buffers
    SOS_OFI_MR="--with-cma --enable-ofi-mr=basic --enable-mr-endpoint --enable-hard-polling"
fi

SOS_HMEM_FLAG="--enable-ofi-hmem"

if [[ "${CLUSTER}" == *"anbmg"* ]]; then
    SOS_HMEM_FLAG=""
fi

if [[ "$(hostname)" == *"tpi"* ]]; then
    SOS_HMEM_FLAG=""
    SOS_OFI_MR=""
fi

build_sos_ofi() {

    if [ ! -f ${SRC_ROOT}/SOS/configure ]; then
        cd ${SRC_ROOT}/SOS && ./autogen.sh
    fi

    mkdir -p ${SOS_BUILD}
    cd ${SOS_BUILD}

    ${SRC_ROOT}/SOS/configure --prefix=${SOS_INSTALL} \
      --with-ofi=${OFI_INSTALL} ${SOS_XPMEM_FLAG} ${SOS_PMI_FLAG} \
      --disable-fortran --disable-libtool-wrapper ${extra_options} \
      ${SOS_OFI_MR} ${SOS_HMEM_FLAG} ${SOS_COMPILERS}

    make -j
    make install

    head config.log > ${OSO_INSTALL}/config.log
}

if [[ "${SKIP_OFI_BUILD:-0}" != "1" ]] && [ ! -d ${OFI_INSTALL} ]; then
    build_ofi
fi

build_sos_ofi

cat <<EOF > ${BASE}/setup_sos_ofi.sh
#!/bin/bash
# This script sets up the environment variables for SOS and OFI installations.
export SOS_INSTALL=${SOS_INSTALL}
export OFI_INSTALL=${OFI_INSTALL}

if [[ ":\$LD_LIBRARY_PATH:" != *":\${OFI_INSTALL}/lib:"* ]]; then
    export LD_LIBRARY_PATH=\${OFI_INSTALL}/lib:\$LD_LIBRARY_PATH
    export PATH=\${OFI_INSTALL}/bin:\$PATH
fi

if [[ ":\$LD_LIBRARY_PATH:" != *":\${SOS_INSTALL}/lib:"* ]]; then
    export LD_LIBRARY_PATH=\${SOS_INSTALL}/lib:\$LD_LIBRARY_PATH
    export PATH=\${SOS_INSTALL}/bin:\$PATH
fi
EOF
chmod +x ${BASE}/setup_sos_ofi.sh
echo "Setup script created: ${BASE}/setup_sos_ofi.sh"
