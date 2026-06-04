# ISHMEM OMP/SYCL Examples

This repository contains a small CMake project with two Intel SHMEM examples:

- `test_sycl`: SYCL-based data initialization and host-side ISHMEM calls
- `test_omp`: OpenMP target offload initialization and host-side ISHMEM calls

Both examples:

- initialize/finalize ISHMEM
- query PE rank/count
- allocate symmetric memory
- run collective and point-to-point operations
- print per-PE validation output

## Repository layout

- `CMakeLists.txt`: Build configuration and options
- `test_sycl.cpp`: SYCL + ISHMEM example
- `test_omp.cpp`: OpenMP offload + ISHMEM example

## Prerequisites

- CMake 3.20+
- Intel oneAPI C/C++ toolchain (`icx`, `icpx`)
- Intel SHMEM installation with `ISHMEMConfig.cmake`
- Runtime launcher/environment for your SHMEM stack

Optional when enabling OpenSHMEM backend mode:

- `pkg-config`
- Sandia OpenSHMEM package discoverable as `sandia-openshmem`

## Configure

Use Intel compilers and point CMake to your ISHMEM install.

```bash
CC=icx CXX=icpx cmake -S . -B build \
  -DISHMEM_DIR=/path/to/ishmem/install
```

`ISHMEM_DIR` may be either:

- an install prefix containing `lib/cmake/ishmem/ISHMEMConfig.cmake`, or
- the config directory itself (`.../lib/cmake/ishmem`)

Enable OpenSHMEM runtime support (optional):

```bash
CC=icx CXX=icpx cmake -S . -B build \
  -DISHMEM_DIR=/path/to/ishmem/install \
  -DENABLE_OPENSHMEM=ON
```

## Build

```bash
cmake --build build -j
```

Expected binaries:

- `build/test_sycl`
- `build/test_omp`

## Run

Run with your SHMEM launcher (for example `oshrun`) and a selected PE count:

```bash
oshrun -n 2 ./build/test_sycl
oshrun -n 2 ./build/test_omp
```

If your environment requires oneAPI setup first, source it before configure/build/run:

```bash
source /opt/intel/oneapi/setvars.sh
```

## CMake target reuse

The project defines an interface target `ishmem` that links host-side ISHMEM usage requirements.

To reuse in new executables:

```cmake
add_executable(my_app my_app.cpp)
target_link_libraries(my_app PRIVATE ishmem)
```

## Troubleshooting

- `Could not find ISHMEMConfig.cmake`:
  Verify `ISHMEM_DIR` points to either install prefix or `lib/cmake/ishmem`.
- `pkg-config could not find sandia-openshmem`:
  Install/configure Sandia OpenSHMEM or disable `ENABLE_OPENSHMEM`.
- Link/runtime backend mismatch:
  Reconfigure from a clean build directory after changing runtime/backend options.
