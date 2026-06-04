cmake_minimum_required(VERSION 3.20)

project(ishmem_omp LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(DEFINED ISHMEM_DIR AND EXISTS "${ISHMEM_DIR}/lib/cmake/ishmem/ISHMEMConfig.cmake")
	set(ISHMEM_DIR "${ISHMEM_DIR}/lib/cmake/ishmem" CACHE PATH "ISHMEM config directory" FORCE)
endif()
find_package(ISHMEM CONFIG REQUIRED)

add_library(ishmem INTERFACE)
target_link_libraries(ishmem INTERFACE ISHMEM::HOST_SHARED)

add_executable(test_sycl test_sycl.cpp)
target_compile_options(test_sycl PRIVATE -fsycl)
target_link_options(test_sycl PRIVATE -fsycl)
target_link_libraries(test_sycl PRIVATE ishmem)

add_executable(test_omp test_omp.cpp)
target_compile_options(test_omp PRIVATE -fiopenmp -fopenmp-targets=spir64)
target_link_options(test_omp PRIVATE -fiopenmp -fopenmp-targets=spir64)
target_link_libraries(test_omp PRIVATE ishmem)