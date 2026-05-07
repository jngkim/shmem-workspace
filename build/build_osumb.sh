#!/bin/bash
OSU_SRC=${OSU_SRC:-${HOME}/shmem-workspace/repos/osu-micro-benchmarks-7.5.2}
OSU_BUILD=${OSU_BUILD:-${HOME}/shmem-workspace/build/osu-bench}

mkdir -p ${OSU_BUILD}
_pkg_config_path_old=$PKG_CONFIG_PATH

cmake -S ${OSU_SRC}/c/mpi -B ${OSU_BUILD}/mpi \
  -DCMAKE_CXX_COMPILER=mpicxx -DCMAKE_C_COMPILER=mpicc
cmake --build ${OSU_BUILD}/mpi --parallel

export PKG_CONFIG_PATH=${SOS_INSTALL}/lib/pkgconfig:$_pkg_config_path_old
cmake -S ${OSU_SRC}/c/openshmem -B ${OSU_BUILD}/openshmem \
  -DCMAKE_CXX_COMPILER=mpicxx -DCMAKE_C_COMPILER=mpicc
cmake --build ${OSU_BUILD}/openshmem --parallel

if [[ "${CLUSTER}" == "aurora" ]]; then
  export PKG_CONFIG_PATH=${SMA_ROOT}/lib64/pkgconfig:${DSMML_ROOT}/lib/pkgconfig:$_pkg_config_path_old
  export LIBRARY_PATH=/opt/cray/pe/pmi/6.1.15/lib:$LIBRARY_PATH
  cmake -S ${OSU_SRC}/c/openshmem -B ${OSU_BUILD}/shmemx \
    -DCMAKE_C_COMPILER=mpicc \
    -DENABLE_OPENSHMEM=OFF \
    -DENABLE_CRAYSHMEMX=ON -DSMA_DIR=${SMA_ROOT} -DDMML_DIR=${DMML_ROOT}

  cmake --build ${OSU_BUILD}/shmemx --parallel
fi
