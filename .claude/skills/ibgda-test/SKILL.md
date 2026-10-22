---
name: ibgda-test
description: Build Intel SHMEM with IBGDA enabled (mlx5 NICs; perf tests and examples against Intel MPI) and test IBGDA. Covers the IBGDA quick test (ibgda-quick.sh: 2-PE put_nbi_bw over GPU-initiated InfiniBand with direct doorbell, default GPUs/NICs 4 and 6), running any perf test or example under the same IBGDA environment, and unit tests via ctest or ishmrun. Use when asked to build with IBGDA, run the IBGDA quick test, check an IBGDA fix (e.g. teardown hangs, doorbell/UAR issues), run perf tests or examples over IBGDA, or run a specific unit test (e.g. put_nbi).
---

# Build Intel SHMEM with IBGDA and run IBGDA tests

Paths (defaults, overridable via env):

| What | Path |
|---|---|
| Source | `~/shmem-workspace/repos/ishmem` |
| Build tree | `~/shmem-workspace/build/ishmem` |
| Install | `~/shmem-workspace/install/ishmem` |

Other builds also live under `~/shmem-workspace/build/<name>` and `~/shmem-workspace/install/<name>`;
for a variant build set `ISHMEM_BUILD`/`ISHMEM_INSTALL` to a new `<name>` rather than reusing `ishmem`.

## 0. Source

If `repos/ishmem` is missing:

```bash
git clone https://github.com/intel-innersource/libraries.runtimes.hpc.shmem.ishmem.git ~/shmem-workspace/repos/ishmem
```

The repo forbids in-source builds (`CMAKE_DISABLE_IN_SOURCE_BUILD`).

## 1. Environment

Every shell that builds or runs tests needs:

```bash
source /opt/intel/oneapi/setvars.sh >/dev/null   # icx/icpx, Intel MPI (I_MPI_ROOT), sycl-ls
source ~/setup-env.sh                            # runtime env (needed on xe2): NEOReadDebugKeys,
                                                 # ISHMEM_RUNTIME=MPI, I_MPI_OFFLOAD, device atomics off, ...
```

Check the GPUs with `sycl-ls`.

## 2. Build

```bash
~/shmem-workspace/.claude/skills/ibgda-test/build.sh [extra -D cmake args]
```

The script runs configure, build and install in one go. It uses these options:

```
-DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx -DCMAKE_BUILD_TYPE=RelWithDebInfo
-DENABLE_MPI=ON -DMPI_DIR=$I_MPI_ROOT -DISHMEM_DEFAULT_RUNTIME=mpi
-DBUILD_UNIT_TESTS=$BUILD_UNIT_TESTS -DBUILD_PERF_TESTS=ON -DBUILD_EXAMPLES=ON
-DCTEST_LAUNCHER=mpi -DENABLE_OPENSHMEM=OFF -DISHMEM_AOT_DEVICE_TYPES=$ISHMEM_AOT_DEVICE_TYPES
-DENABLE_IBGDA=1 -DISHMEM_IBGDA_NIC_VENDOR=MLX5
```

- `ISHMEM_AOT_DEVICE_TYPES` defaults to `xe3`, which is correct for this machine (cri-c, GPU 0x674f).
  Use `xe2` on xe2 systems and `xe-hpc` on PVC.
- Env overrides: `ISHMEM_SRC`, `ISHMEM_BUILD`, `ISHMEM_INSTALL`, `JOBS` (default `nproc`).
- `BUILD_UNIT_TESTS` defaults to `OFF` because the unit tests dominate build time.
  Set `BUILD_UNIT_TESTS=ON` before running the ctest unit tests in section 3.
- Logs go to `$ISHMEM_BUILD/{configure,build,install}.log`. When a build fails, grep `build.log` for `error:`.
- A full build takes several minutes because of AOT compilation. Run it with a long timeout,
  or in the background.
- After a source change, an incremental `cmake --build ~/shmem-workspace/build/ishmem -j` is enough.
  Re-run `build.sh` only when cmake options change.

## 3. Run tests

`B=~/shmem-workspace/build/ishmem`, `S=~/shmem-workspace/repos/ishmem`.

```bash
ctest --test-dir $B/test/unit -N                                   # list (~180 tests)
ctest --test-dir $B/test/unit -R put_nbi --output-on-failure       # subset by regex
ctest --test-dir $B/test/unit -R '^put_nbi-device-2$' --output-on-failure   # exact test
ctest --test-dir $B/test/unit --timeout 60 -j1 --output-on-failure # full unit suite
ctest --test-dir $B/test/performance -L perf                       # perf tests
```

Test names come from `test/*/CMakeLists.txt`:
- `<exe>-<mode>-<npes>` for tests based on `ishmem_tester`
- `<exe>-<npes>` for everything else

Modes are the values of `testmode_t` in `test/include/ishmem_tester.h`: `host_*`, `on_queue`,
`device`, `device_subgroup`, `device_grp1..3`, `device_multi_wg`.

To run one binary without ctest, use the launcher wrapper. It pins one GPU per PE:

```bash
mpiexec -n 2 $S/scripts/ishmrun $B/test/unit/put_nbi --test_modes device --csv
```

Run the smoke test before a large suite. If it fails, every unit test will fail too:

```bash
mpiexec -n 2 $S/scripts/ishmrun $B/examples/1_helloworld
```

### IBGDA quick test

This is a 2-PE `put_nbi_bw` run in device mode with IBGDA over mlx5. Coworkers recommend it as a quick test:

```bash
~/shmem-workspace/.claude/skills/ibgda-test/ibgda-quick.sh [GPU_INDEX1=4] [GPU_INDEX2=6]
```

- PE 0 uses `ZE_AFFINITY_MASK=GPU_INDEX1` with `ISHMEM_IBGDA_NIC=mlx5_<NIC_DEVICE1>`. PE 1 does the same with the `2` variables.
- NIC indices default to the GPU indices. Override them with `NIC_DEVICE1`/`NIC_DEVICE2`.
- Env: `ISHMEM_BUILD`, `I_MPI_FABRICS` (default `shm`), `TIMEOUT` (default 120 s).
- Output is CSV.
- To run another binary (perf test or example) with the same IBGDA env and GPU/NIC binding, pass it after `--`:
  ```bash
  ibgda-quick.sh 4 6 -- "$ISHMEM_BUILD/examples/2_get"
  ibgda-quick.sh -- env ISHMEM_IBGDA_DIRECT_DOORBELL=0 "$ISHMEM_BUILD/test/performance/get_bw"
  ```

## 4. Debugging failures

- Add `ISHMEM_DEBUG=1` for init tracing, and `I_MPI_DEBUG=5` for MPI placement.
- For a backtrace, run single-process (no mpiexec needed for 1 PE):
  `gdb-oneapi -batch -ex run -ex bt --args $B/examples/1_helloworld`
- Wrap runs in `timeout` so a hang can't stall the session.
- Report results as pass/fail counts plus the names of failing tests, with the relevant output.

### Known issue (2026-10-21, cri-c / xe3): ishmem bug, every program segfaults in `ishmem_init`

The segfault is in `libze_intel_gpu.so.1`, but the driver isn't at fault: `src/accelerator.cpp` passes it a null queue.
- xe3 reports queue groups `ordinal 0: flags 0x7 (compute), numQueues 1` and `ordinal 1: flags 0x2 (copy), numQueues 2`.
  There is no main copy engine (copy group with `numQueues == 1`), so `copy_queue` stays null.
- `ishmemi_level_zero_sync()` → `sync_cq(copy_queue, ...)` calls `zeCommandQueueSynchronize(nullptr)`,
  reached from `ishmemi_ipc_init` → `node_barrier`.
- `link_queue_count` is never assigned (missing since `c5dc488d`, 2025-07-29), so LINK_QUEUE always falls
  back to `copy_queue`. PVC has a main copy engine, which hides this bug.

Runtime env vars don't help. A fix has to change `src/accelerator.cpp`.
