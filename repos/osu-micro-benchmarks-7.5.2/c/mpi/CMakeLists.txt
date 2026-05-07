cmake_minimum_required(VERSION 3.14)
project(osu_mpi C)

set(UTIL_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../util)

find_package(MPI REQUIRED C)
find_package(Threads REQUIRED)

add_library(osu_mpi_util OBJECT
    ${UTIL_DIR}/osu_util.c
    ${UTIL_DIR}/osu_util_mpi.c
    ${UTIL_DIR}/osu_util_graph.c
    ${UTIL_DIR}/osu_util_papi.c
    ${UTIL_DIR}/osu_util_validation.c
)
target_include_directories(osu_mpi_util PUBLIC ${UTIL_DIR})
target_link_libraries(osu_mpi_util PUBLIC MPI::MPI_C)

# Helper macro to build a benchmark executable (available to all subdirectories)
macro(add_mpi_benchmark name src_dir)
    add_executable(${name} ${src_dir}/${name}.c)
    target_include_directories(${name} PRIVATE ${UTIL_DIR})
    target_link_libraries(${name} PRIVATE osu_mpi_util MPI::MPI_C)
endmacro()

add_subdirectory(startup)
add_subdirectory(pt2pt)
add_subdirectory(one-sided)
add_subdirectory(collective)
