#!/bin/bash

export BASE=${BASE:-${HOME}/shmem-workspace/build/latest}

I_SHMEM_SRC=${I_SHMEM_SRC:-${HOME}/shmem-workspace/repos/ishmem}
I_SHMEM_BUILD=${I_SHMEM_BUILD:-${BASE}/ishmem}
I_SHMEM_INSTALL=${I_SHMEM_INSTALL:-${BASE}/install/ishmem}
SOS_INSTALL=${SOS_INSTALL:-${BASE}/install/sos}
LEVEL_ZERO_DIR=${LEVEL_ZERO_DIR:-}

build_ishmem() {

    if [ ! -d ${I_SHMEM_SRC} ]; then
        echo "ERROR: ishmem source not found at ${I_SHMEM_SRC}"
        exit 1
    fi

    if [ ! -d ${SOS_INSTALL} ]; then
        echo "ERROR: SOS installation not found at ${SOS_INSTALL}"
        echo "Please build SOS first using build_sos.sh"
        exit 1
    fi

    mkdir -p ${I_SHMEM_BUILD}
    cd ${I_SHMEM_BUILD}

    CMAKE_ARGS=(
      -DCMAKE_C_COMPILER=icx
      -DCMAKE_CXX_COMPILER=icpx
      -DENABLE_MPI=ON
      -DCTEST_LAUNCHER=mpi
      -DCMAKE_INSTALL_PREFIX=${I_SHMEM_INSTALL}
    )
  
  if [[ -d ${SOS_INSTALL} ]]; then
      CMAKE_ARGS+=(
        -DENABLE_OPENSHMEM=ON
        -DSHMEM_DIR=${SOS_INSTALL}
      )
  fi

    cmake ${I_SHMEM_SRC} "${CMAKE_ARGS[@]}"
    make -j 32
    make install
}

build_ishmem_tests() {
    cd ${I_SHMEM_BUILD}
    CMAKE_ARGS=(
        -DCTEST_LAUNCHER=mpi
        -DBUILD_APPS=OFF
        -DBUILD_EXAMPLES=ON
        -DBUILD_PERF_TESTS=OFF
        -DBUILD_UNIT_TESTS=ON
        -DISHMEM_HOST_LINK_TYPE=SHARED
    )

    cmake ${I_SHMEM_SRC} "${CMAKE_ARGS[@]}"
    make -j
}

# always build
build_ishmem

build_ishmem_tests
