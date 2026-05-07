#!/bin/bash

export BASE=${BASE:-${HOME}/shmem-workspace/build/latest}

SRC_ROOT=${SRC_ROOT:-${HOME}/shmem-workspace/repos}
SOS_BUILD=${SOS_BUILD:-${BASE}/sos-ucx}
SOS_INSTALL=${SOS_INSTALL:-${BASE}/install/sos-ucx}

SOS_PMI_FLAG="--enable-pmi-mpi"
SOS_COMPILERS="CXX=mpicxx CC=mpicc"

build_sos_ucx() {

    if [ ! -f ${SRC_ROOT}/SOS/configure ]; then
        cd ${SRC_ROOT}/SOS && ./autogen.sh
    fi

    mkdir -p ${SOS_BUILD}
    cd ${SOS_BUILD}

    ${SRC_ROOT}/SOS/configure --prefix=${SOS_INSTALL} \
      --with-cma \
      --with-ucx=/usr ${SOS_PMI_FLAG} \
      --disable-fortran --disable-libtool-wrapper \
      ${SOS_COMPILERS}

    make -j
    make install
}

build_sos_ucx

cat <<EOF > ${BASE}/setup_sos_ucx.sh
#!/bin/bash
# This script sets up the environment variables for SOS and OFI installations.
export SOS_INSTALL=${SOS_INSTALL}

if [[ ":\$LD_LIBRARY_PATH:" != *":\${SOS_INSTALL}/lib:"* ]]; then
    export LD_LIBRARY_PATH=\${SOS_INSTALL}/lib:\$LD_LIBRARY_PATH
    export PATH=\${SOS_INSTALL}/bin:\$PATH
fi
EOF
chmod +x ${BASE}/setup_sos_ucx.sh
echo "Setup script created: ${BASE}/setup_sos_ucx.sh"
