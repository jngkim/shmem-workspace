cmake_minimum_required(VERSION 3.14)
project(osu_openshmem C)

set(UTIL_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../util)

find_package(PkgConfig REQUIRED)

option(ENABLE_OPENSHMEM "Enable OpenSHMEM support" ON)
option(ENABLE_CRAYSHMEMX "Enable Cray SHMEMX support" OFF)
# proceed only one of them is enabled
if(ENABLE_OPENSHMEM AND ENABLE_CRAYSHMEMX)
  message(FATAL_ERROR "Cannot enable both OpenSHMEM and Cray SHMEMX support at the same time")
endif()

add_library(sos INTERFACE)

add_library(osu_openshmem_util OBJECT
    ${UTIL_DIR}/osu_util.c
    ${UTIL_DIR}/osu_util_pgas.c
)
target_include_directories(osu_openshmem_util PUBLIC ${UTIL_DIR})

if(ENABLE_OPENSHMEM)
  pkg_check_modules(SANDIA_SHMEM REQUIRED IMPORTED_TARGET sandia-openshmem)
  # NOTE: Sandia OpenSHMEM's PkgConfig file contains a bunch of linker flags
  #       (e.g. -Wl,...) in its `Libs` declaration.  This trips up CMake, so I
  #       remove these here and then add the include/link flags manually.
  string(REGEX REPLACE "-Wl,[^;]*;" "" SANDIA_SHMEM_LDFLAGS "${SANDIA_SHMEM_LDFLAGS}")

  target_include_directories(sos INTERFACE ${SANDIA_SHMEM_INCLUDE_DIRS})
  target_link_libraries(sos INTERFACE ${SANDIA_SHMEM_LDFLAGS} ${SANDIA_SHMEM_LIBRARIES})
  target_compile_options(sos INTERFACE ${SANDIA_SHMEM_CXXFLAGS})
  target_link_libraries(osu_openshmem_util PUBLIC sos)
endif()

if(ENABLE_CRAYSHMEMX)
  pkg_check_modules(DSMML REQUIRED IMPORTED_TARGET dsmml)
  pkg_check_modules(SMA REQUIRED IMPORTED_TARGET sma)
  target_include_directories(sos INTERFACE ${SMA_INCLUDE_DIRS})
  target_link_libraries(sos INTERFACE ${SMA_LDFLAGS} ${SMA_LIBRARIES} ${DSMML_LDFLAGS} ${DSMML_LIBRARIES})
  target_link_libraries(osu_openshmem_util PUBLIC sos)
endif()

set(OSU_OPENSHMEM_BENCHMARKS
    osu_oshm_get
    osu_oshm_put
    osu_oshm_put_mr
    osu_oshm_atomics
    osu_oshm_barrier
    osu_oshm_broadcast
    osu_oshm_collect
    osu_oshm_fcollect
    osu_oshm_reduce
    osu_oshm_get_nb
    osu_oshm_put_nb
    osu_oshm_put_overlap
    osu_oshm_get_mr_nb
    osu_oshm_put_mr_nb
    osu_oshm_get_bw
    osu_oshm_get_nb_bw
    osu_oshm_put_bw
    osu_oshm_put_nb_bw
    osu_oshm_get_overlap
    osu_oshm_atomics2
    cust_nail_clone
)

foreach(benchmark ${OSU_OPENSHMEM_BENCHMARKS})
    add_executable(${benchmark} ${benchmark}.c)
    target_compile_definitions(${benchmark} PRIVATE OSHM_1_3)
    target_link_libraries(${benchmark} PRIVATE osu_openshmem_util)
endforeach()

add_executable(shm_bucket_sort shm_bucket_sort.cpp)
target_link_libraries(shm_bucket_sort PRIVATE sos)

