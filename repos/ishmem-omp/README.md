# Intel SHMEM CMake Example

This repository contains a minimal CMake project that builds a SYCL-based Intel SHMEM example.

## Files

- `CMakeLists.txt`: Project configuration using `find_package(ISHMEM CONFIG REQUIRED)`.
- `test_sycl.cpp`: Example program using Intel SHMEM host APIs.

## Prerequisites

- Intel oneAPI compiler toolchain (`icx`, `icpx`)
- Intel SHMEM installation with CMake package config (`ISHMEMConfig.cmake`)
- CMake 3.20+

## Configure

Use Intel compilers and pass your Intel SHMEM install prefix as `ISHMEM_DIR`:

```bash
CC=icx CXX=icpx cmake -S . -B build -DISHMEM_DIR=/nfs/site/home/jeongnim/shmem-workspace/build/latest/ishmem-bb/_install
```

Notes:

- This project always uses `find_package(ISHMEM CONFIG REQUIRED)`.
- `ISHMEM_DIR` can be either:
  - the install prefix, or
  - the config directory containing `ISHMEMConfig.cmake`

## Build

```bash
cmake --build build -j
```

## Reuse the ISHMEM interface target

The project defines an interface library target named `ishmem`.

To add another executable and reuse the same host-side ISHMEM link setup:

```cmake
add_executable(my_app my_app.cpp)
target_link_libraries(my_app PRIVATE ishmem)
```

## Current link behavior

- The `ishmem` interface target is configured to link host-side Intel SHMEM targets/libraries only.
