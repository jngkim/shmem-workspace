---
name: florence-default
description: Build Intel SHMEM with the default (non-IBGDA, MPI runtime) configuration against Intel MPI / oneAPI 2026.2 on the Florence Slurm cluster (4x PVC = 8 tiles per node, InfiniBand/mlx5, login node mgt1, compute nodes compute[11-44]), and run tests. Builds and tests run on a compute node through `srun -p debug` (or `-p hdr200`). Covers build.sh, the 1_helloworld smoke test, ctest unit/perf suites, and running a single test binary via ishmrun. Use when asked to build ishmem, rebuild after a source change, or run unit/perf tests on Florence/PVC. For IBGDA builds use the ibgda-test skill instead.
---

# Build Intel SHMEM (default, non-IBGDA) on Florence and run tests

The login node `mgt1` has no GPUs and old glibc (test binaries fail there with `GLIBC_2.38 not found`).
Every build and test runs on a compute node (`compute[11-44]`: 4 PVC = 8 tiles, mlx5 InfiniBand) through Slurm:

- Interactive (for the user): `srun -p debug -N 1 -t 1:00:00 --pty /bin/bash`, then
  `source ~/shmem-workspace/.claude/skills/florence-default/env.sh` and use the commands below directly.
- Non-interactive (for Claude, since the Bash tool has no pty): `srun.sh <command>` runs one command
  on a compute node with `env.sh` loaded. `build.sh` calls `srun.sh` itself when it runs outside a job.

Partitions: `debug` (default, 2-hour limit) and `hdr200` (8-hour limit) can both be used. Select one with
`SLURM_PARTITION=hdr200`. `hdr200` rejects interactive/`srun` allocations ("interactive job rejected"), so for
any partition other than `debug`, `srun.sh` submits `sbatch --wait`, prints the job log when the job ends, and
returns its exit code. Logs are kept in `~/shmem-workspace/results/slurm/` (`SLURM_LOG_DIR`). Output appears only
at the end, so run long jobs in the background. For an interactive shell, use `debug`. Before you submit, run `sinfo -p debug,hdr200` and `squeue -u $USER` to check for idle nodes.

You can run several jobs at once (on separate nodes), so independent work can run in parallel. For example,
run a build variant on one node while tests run on another, or split the unit suite by regex across jobs.

Paths (defaults, overridable via env):

| What | Path |
|---|---|
| Source | `~/shmem-workspace/repos/ishmem` |
| Build tree | `~/shmem-workspace/build/ishmem-florence` |
| Install | `~/shmem-workspace/install/ishmem-florence` |

`build/ishmem` and `install/ishmem` are a separate SOS/OPENSHMEM debug build (`build/ishmem/env_sos.sh`,
`setup.sh`); don't point this skill at them. For a variant build set `I_SHMEM_BUILD`/`I_SHMEM_INSTALL`
to a new `build/<name>` / `install/<name>`.

## 1. Environment

`~/.bashrc` returns early for non-interactive shells, so `env.sh` replicates its module loads:

- `module load gcc/13.2.0 oneapi/2026.2` (override with `GCC_MODULE`, `ONEAPI_MODULE`)
- `module load intel-comp-rt/agama-ci-devel/1250` (GPU runtime; override with `AGAMA_MODULE`, empty to skip)
- `module load cmake`
- `I_MPI_CC=icx I_MPI_CXX=icpx I_MPI_HYDRA_BOOTSTRAP=ssh`, and `repos/ishmem/scripts` on `PATH`.

Runtime settings it exports:

- PVC: `ZE_FLAT_DEVICE_HIERARCHY=FLAT` (8 tiles appear as 8 devices; `ishmrun` pins one per PE),
  `ZE_ENABLE_PCI_ID_DEVICE_MAPPING=1`, `EnableImplicitScaling=0`, `NEOReadDebugKeys=1`.
  PVC supports device atomics, so `ISHMEM_ENABLE_DEVICE_ATOMICS` is left at its default (unlike BMG).
- `ISHMEM_RUNTIME=MPI` (default; respects a caller override), `I_MPI_OFFLOAD=1`, `I_MPI_OFFLOAD_RDMA=1`.
- No IB env is set. `FI_VERBS_IFACE=ib0` and `MLX5_SCATTER_TO_CQE=0` (seen in `build/ishmem/setup.sh`)
  are SOS workarounds; set them only for `ISHMEM_RUNTIME=OPENSHMEM` (SOS) runs, not for this MPI-runtime build.

## 2. Build

```bash
~/shmem-workspace/.claude/skills/florence-default/build.sh [extra -D cmake args]
```

From the login node this submits `srun -p debug -N 1 -t 1:00:00`. Override with `SLURM_PARTITION`,
`SLURM_TIME` (e.g. `2:00:00`), and `SRUN_ARGS="-w compute23"` to pick a node.

The script runs configure, build and install in one go:

```
-DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx -DCMAKE_BUILD_TYPE=RelWithDebInfo
-DENABLE_MPI=ON -DMPI_DIR=$I_MPI_ROOT -DISHMEM_DEFAULT_RUNTIME=mpi
-DBUILD_UNIT_TESTS=$BUILD_UNIT_TESTS -DBUILD_PERF_TESTS=ON -DBUILD_EXAMPLES=ON
-DCTEST_LAUNCHER=mpi -DENABLE_OPENSHMEM=OFF -DENABLE_IBGDA=OFF
-DISHMEM_AOT_DEVICE_TYPES=$I_SHMEM_AOT_DEVICE_TYPES
```

- `I_SHMEM_AOT_DEVICE_TYPES` defaults to `xe-hpc` (PVC).
- Env overrides: `I_SHMEM_SRC`, `I_SHMEM_BUILD`, `I_SHMEM_INSTALL`, `JOBS` (default `nproc`),
  `BUILD_UNIT_TESTS` (default `ON`; `OFF` for a much faster build), `RUNTIME` (`mpi` default; `pmi`
  on branches with the PMI runtime, see the anbmg-default skill section 4; `sos` for the bundled SOS, see section 4).
- To also generate 8-PE ctests: `build.sh -DISHMEM_PE_COUNTS_UNIT_TESTS="2;8"` (default is `2`).
- Logs go to `$I_SHMEM_BUILD/{configure,build,install}.log`. On failure, grep `build.log` for `error:`.
- Run the full build with a long timeout or in the background.
- After a source change, an incremental build is enough:
  `srun.sh cmake --build ~/shmem-workspace/build/ishmem-florence -j`.
  Re-run `build.sh` only when cmake options change.

## 3. Run tests

`B=~/shmem-workspace/build/ishmem-florence`, `S=~/shmem-workspace/repos/ishmem`,
`R=~/shmem-workspace/.claude/skills/florence-default/srun.sh`. Inside an interactive job, source `env.sh` and
drop the `$R` prefix. From the login node run each command as `$R <command>`, and batch a dependent sequence into one
job with `$R bash -c '...'` instead of queueing one allocation per command. Independent runs can go to
separate concurrent jobs, e.g. split the full suite into halves:

```bash
SLURM_PARTITION=debug  $R ctest --test-dir $B/test/unit -I 1,,2 --timeout 120 --output-on-failure &   # odd tests
SLURM_PARTITION=hdr200 $R ctest --test-dir $B/test/unit -I 2,,2 --timeout 120 --output-on-failure &   # even tests
wait
```

Run the smoke test first. If it fails, every unit test will fail too:

```bash
mpiexec -n 2 $S/scripts/ishmrun $B/examples/1_helloworld
mpiexec -n 8 $S/scripts/ishmrun $B/examples/1_helloworld   # all 8 tiles
```

```bash
ctest --test-dir $B/test/unit -N                                   # list
ctest --test-dir $B/test/unit -R put_nbi --output-on-failure       # subset by regex
ctest --test-dir $B/test/unit -R '^put_nbi-device-2$' --output-on-failure   # exact test
ctest --test-dir $B/test/unit --timeout 120 -j1 --output-on-failure # full unit suite
ctest --test-dir $B/test/performance -L perf                       # perf tests
```

Test names come from `test/*/CMakeLists.txt`: `<exe>-<mode>-<npes>` for `ishmem_tester` tests,
`<exe>-<npes>` for everything else. Modes are `testmode_t` values in `test/include/ishmem_tester.h`.

Single binary without ctest (one tile per PE, up to 8 PEs on one node):

```bash
mpiexec -n 2 $S/scripts/ishmrun $B/test/unit/put_nbi --test_modes device --csv
```

For debugging inside an existing allocation, `ssh <node>` works (or `srun --jobid=<id> --overlap`);
use `gdb-oneapi` with `INTELGT_AUTO_ATTACH_DISABLE=1`.

Baseline (2026-11-05, compute11, PVC Max 1550, oneAPI 2026.2, agama-ci-devel/1250, repos/ishmem at 6d172163,
2 PEs, `--timeout 120 -j1`): 181/184 pass in ~11 minutes. Failures:
- `int_amos_host_compare_swap-2`: consistent (KILLED BY SIGNAL 9; 3/3 reruns fail).
- `int_wait_until_host-2` (Timeout) and `put_nbi-host_device_device-2` (data mismatch, got 0x81): flaky, both
  passed 3/3 reruns on compute31.
When you report results, compare them against this list.

## 4. Bundled SOS (`fork/sos/bundled`) — debugging and evaluation

The `sos/bundled` branch on the `fork` remote builds Sandia OpenSHMEM from the `third_party/sos` submodule
(innersource SOS mirror, `ishmem/main`: upstream v1.5.3 + 5 ishmem patches, U1-U3/I1-I2 in
`docs/host-runtime-contract.md`) and installs it privately under `<prefix>/lib/ishmem/sos`. It has its own
worktree and build tree, so `repos/ishmem` and `build/ishmem-florence` stay as the MPI baseline:

| What | Path |
|---|---|
| Worktree (local branch `sos/bundled`, tracking `fork/sos/bundled`) | `~/shmem-workspace/repos/ishmem-sos` |
| SOS submodule (source of truth for SOS edits) | `~/shmem-workspace/repos/ishmem-sos/third_party/sos` |
| Build tree | `~/shmem-workspace/build/ishmem-sos` |
| SOS build-tree copy / SOS objects | `build/ishmem-sos/sos-src`, `build/ishmem-sos/sos-build` |
| SOS configure/build logs | `build/ishmem-sos/ishmem-sos-prefix/src/ishmem-sos-stamp/ishmem-sos-*.log` |
| Install (bundled SOS in `lib/ishmem/sos`) | `~/shmem-workspace/install/ishmem-sos` |

Not the same as the older external-SOS setup in `build/ishmem` / `repos/SOS` / `install/sos-scan-fix`
(`env_sos.sh`); don't mix the two.

```bash
# Worktree (once), or update it
git -C ~/shmem-workspace/repos/ishmem fetch fork sos/bundled
git -C ~/shmem-workspace/repos/ishmem worktree add -b sos/bundled ../ishmem-sos fork/sos/bundled
git -C ~/shmem-workspace/repos/ishmem-sos pull --ff-only
git -C ~/shmem-workspace/repos/ishmem-sos submodule update --init third_party/sos

# Build trees (one per provider preset; SOS tuning is compile-time):
#   verbs + ENABLE_MPI=ON  (pmi-mpi, default runtime MPI):        build/ishmem-sos,     install/ishmem-sos
#   shm   + ENABLE_MPI=OFF (pmi-simple, default runtime OPENSHMEM): build/ishmem-sos-shm, install/ishmem-sos-shm
W=~/shmem-workspace
RUNTIME=sos I_SHMEM_SRC=$W/repos/ishmem-sos I_SHMEM_BUILD=$W/build/ishmem-sos I_SHMEM_INSTALL=$W/install/ishmem-sos \
    $W/.claude/skills/florence-default/build.sh
RUNTIME=sos SOS_MPI=OFF SOS_PROVIDER=shm I_SHMEM_SRC=$W/repos/ishmem-sos I_SHMEM_BUILD=$W/build/ishmem-sos-shm \
    I_SHMEM_INSTALL=$W/install/ishmem-sos-shm $W/.claude/skills/florence-default/build.sh
```

- `RUNTIME=sos` passes `-DENABLE_OPENSHMEM=ON -DISHMEM_SOS=bundled -DISHMEM_SOS_PROVIDER=${SOS_PROVIDER:-auto}`
  and `-DENABLE_MPI=ON` (or `OFF` with `SOS_MPI=OFF`). The PMI client follows ENABLE_MPI (pmi-mpi / pmi-simple).
- `auto` probes `fi_info -p` cxi -> verbs -> shm on the build node; on Florence it picks verbs, so shm needs
  `SOS_PROVIDER=shm`. The cmake summary prints "SOS provider", "SOS PMI" and "SOS configure".
- SOS builds with autotools on the node against the oneAPI 2026.2 libfabric (2.6, pkg-config). Older oneAPI
  needs `-DISHMEM_SOS_OFI_DIR=<libfabric with headers, >= 2.3>` (Intel MPI's copy has no headers).
- The build bakes the bundled libsma.so path and the preset's SHMEM_OFI_PROVIDER into config.h; no env needed.
- `SOS_FLAGS='--a;--b'` replaces the preset; `SOS_FLAGS_EXTRA` appends to it.
- uid init (examples/7_uid) over OpenSHMEM works only in the ENABLE_MPI=OFF (pmi-simple) build; the pmi-mpi build
  exits with a clear error.
- For an SOS with debug output (`SHMEM_DEBUG=1`), add `--enable-debug` to `SOS_FLAGS` in its own build tree.
- After editing `third_party/sos`, re-run `build.sh`: `configure-sos.sh` copies the submodule into `sos-src`
  on configure, so an incremental `cmake --build` does not see SOS source edits. A new SOS commit, flag set,
  compiler or libfabric re-runs the SOS configure automatically.

### Run

Source `sos-env.sh` inside the job, after `env.sh` (which `srun.sh` loads):

```bash
B=~/shmem-workspace/build/ishmem-sos S=~/shmem-workspace/repos/ishmem-sos F=~/shmem-workspace/.claude/skills/florence-default
$R bash -c "source $F/sos-env.sh; mpiexec -n 2 $S/scripts/ishmrun $B/examples/1_helloworld"
$R bash -c "source $F/sos-env.sh; ctest --test-dir $B/test/unit --timeout 120 -j1 --output-on-failure"
# A/B: same build over Intel MPI
$R bash -c "SOS_RUNTIME=MPI source $F/sos-env.sh; ctest --test-dir $B/test/unit --timeout 120 -j1"
```

`sos-env.sh` sets `ISHMEM_RUNTIME=OPENSHMEM` (`SOS_RUNTIME` overrides), puts the SOS `bin` on `PATH`, and exports the
SOS-only Florence workarounds `FI_VERBS_IFACE=ib0` and `MLX5_SCATTER_TO_CQE=0` (harmless for shm). Set `I_SHMEM_INSTALL`
(not exported) to pick the tree. The provider comes from the build; `SOS_PROVIDER=shm|verbs` forces it.

Debugging knobs: `SHMEM_INFO=1` (prints SOS's env and provider), `FI_LOG_LEVEL=warn` (or `debug`),
`ISHMEM_DEBUG=1`. Check which libraries are loaded with `ldd $B/examples/1_helloworld` (libsma is dlopen()ed, so
it is not listed; confirm the path with `SHMEM_INFO=1`). Use `gdb-oneapi` with `INTELGT_AUTO_ATTACH_DISABLE=1`
inside an allocation (`ssh <node>`), and `source $F/env.sh; source $F/sos-env.sh` first.

The branch must include `origin/main` #888 (`143bf304`, host library not compiled host-only with oneAPI >= 2026.2).
Without it every `*_on_queue` API segfaults in libsycl `handler::setDeviceKernelInfo` under every runtime
(old-base run: 33 failures even over MPI; logs in `results/sos-bundled/old-base/`). The local worktree merges
`origin/main` at `9576c8d3` (unpushed).

Local fixes needed on the branch (committed locally as `32590b60`, unpushed):
- `cmake/sos.cmake`: `ExternalProject_Add(SOURCE_DIR third_party/sos)` fails at configure with "file attempted
  to create a directory ... into a source directory", because the top-level `CMakeLists.txt` sets
  `CMAKE_DISABLE_SOURCE_CHANGES ON` (CMake 3.28.1 here). Fix: `SOURCE_DIR "${_work}"` (the `sos-src` copy).
- `cmake/templates/configure-sos.sh.in`: SOS configure fails with "OFI libfabric support requested ... but not
  found" (`fi_getinfo` link test). oneAPI 2026.2's `libfabric.pc` says `prefix=/usr/local`; `sos.cmake` corrects
  the prefix for `--with-ofi`, but SOS's check still takes `-L/usr/local/lib` from that `.pc`. Fix: pass
  `CPPFLAGS=-I<ofi>/include` and `LDFLAGS=-L<ofi>/lib` (the `$ORIGIN` RUNPATH part stays single-quoted).
- `cmake/sos.cmake`: SOS `make install` fails with `read jobs pipe: Bad file descriptor`. `LOG_BUILD/LOG_INSTALL`
  run the sub-make through a `cmake -P` wrapper that drops the parent make's jobserver fds while `MAKEFLAGS`
  still names them (the build step only survived because its explicit `-jN` disables the jobserver). Fix:
  `${CMAKE_COMMAND} -E env --unset=MAKEFLAGS make ...` for both `BUILD_COMMAND` and `INSTALL_COMMAND`.

With the three fixes, `libsma.so` installs under `install/ishmem-sos/lib/ishmem/sos/lib` with RUNPATH `$ORIGIN`
only and `NEEDED libfabric.so.1`, as `docs/host-runtime-contract.md` C6.1 requires.

SOS baseline (2026-11-05, `sos/bundled` + local `32590b60` + merge of `origin/main` 58e05b72 = `9576c8d3`,
SOS `81c1f98a`, default shm+FI_HMEM SOS flags, 2 PEs, `--timeout 120 -j1`; logs in `results/sos-bundled/`):

| Run (node) | Pass | Time | Failures |
|---|---|---|---|
| `SOS_RUNTIME=MPI` (compute43) | 179/184 | 9 min | `int_amos_host_compare_swap`; `int_wait_until_host` (Timeout); `put-`, `put_nbi-`, `fcollect-host_device_device` (data mismatch, got 0x80/0x81/0x8181) |
| OPENSHMEM, `SOS_PROVIDER=verbs` (compute22) | 177/184 | 18 min | `int_amos_host`, `int_amos_host_compare_swap`; Timeout: `signal_wait_until-`, `wait_until_any-`, `wait_until_any_vector-`, `wait_until_some-`, `wait_until_some_vector-on_queue` |
| OPENSHMEM, `SOS_PROVIDER=shm` (compute31) | 164/184 | 46 min | `int_amos_host`, `int_amos_host_compare_swap`; 18 Timeouts, mostly `wait_until*`/`test_some`/`signal_wait_until` (device, on_queue, host_device_device), plus `amo_fetch_and_nbi`, `amo_fetch_inc_nbi`, `int_put_nbi_device`, `ptr_device`, `reduce_prod-device`, `reduce_prod-on_queue` |

Notes:
- `int_amos_host-2` under verbs segfaults in `ishmem_quiet` -> `shmem_quiet` -> `rxm_ep_progress` -> `rxm_handle_comp`
  -> `ofi_copy_to_hmem_iov` -> CPU `memmove` into device memory: rxm handles a completion for a device buffer as
  system memory (same class as the SOS inject/bounce bug; the bundled SOS already has `shmem_transport_ofi_is_dev_mem`).
- The `host_device_device` data mismatches also show up on `main` over MPI (flaky there); not SOS-specific.
- shm timeouts print no test output before the 120 s kill; start debugging with one test, e.g.
  `wait_until-host_device_device-2`, with `SHMEM_INFO=1 FI_LOG_LEVEL=warn`.
