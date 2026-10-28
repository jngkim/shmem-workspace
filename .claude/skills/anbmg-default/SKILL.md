---
name: anbmg-default
description: Build Intel SHMEM with the default (non-IBGDA) configuration against Intel MPI / oneAPI 2026.0 on the anbmg Slurm cluster (Arc B-series GPUs, compute nodes anbmg-c01/c02, login node anbmghdr), and run tests. Builds and tests run on a compute node through srun. Covers build.sh, the 1_helloworld smoke test, ctest unit/perf suites, and running a single test binary via ishmrun. Use when asked to build ishmem, rebuild after a source change, or run unit/perf tests on anbmg/BMG. For IBGDA builds use the ibgda-test skill instead.
---

# Build Intel SHMEM (default, non-IBGDA) on anbmg and run tests

The host `anbmghdr` is a SLES login node with no GPUs. Every build and test runs on a compute node
(`anbmg-c01`/`anbmg-c02`: Ubuntu 24.04, 224 cores, 2 Arc B-series GPUs) through Slurm:

- Interactive (for the user): `srun -N 1 -t 60 --pty /bin/bash`, then use the commands below directly.
- Non-interactive (for Claude, since the Bash tool has no pty): `srun.sh <command>` runs one command
  on a compute node with `env.sh` loaded. `build.sh` calls `srun.sh` itself when it runs outside a job.

Before you submit, run `sinfo` and `squeue -u $USER` to check that a node is idle.

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

Every shell on a compute node that builds or runs tests needs the same environment. `srun.sh` and `build.sh`
load it automatically; inside an interactive `srun --pty` shell, load it yourself:

```bash
source ~/shmem-workspace/.claude/skills/anbmg-default/env.sh
```

- It sources `/opt/intel/oneapi/2026.0/oneapi-vars.sh` (override with `ONEAPI_VARS`) if `icpx` or `I_MPI_ROOT` is missing.
- It then loads the Intel Graphics PPA GPU runtime with
  `source /home/tsantosf/teixeira-setup-scripts/install-intel-graphics-ppa.sh --load`. This must come after
  oneAPI because it prepends its own Level Zero/OpenCL libraries and `ocloc`. Set `AGAMA_SETUP` to another
  setup script, or to empty to skip it. You can ignore its `.iig-version: Permission denied` message: the
  snapshot dir belongs to tsantosf, and the runtime still loads.
- Never set `ISHMEM_ENABLE_DEVICE_ATOMICS=1` on anbmg: BMG does not support peer-to-peer atomics, so
  every AMO, signal, test and wait has to go through the host proxy.
- It exports the BMG runtime settings from `~/setup-env.sh`: `RenderCompressedBuffersEnabled=0`,
  `ISHMEM_ENABLE_DEVICE_ATOMICS=0`, `UseKmdMigration=1`, `ISHMEM_RUNTIME=MPI`, `I_MPI_OFFLOAD=1`, ...

## 2. Build

```bash
~/shmem-workspace/.claude/skills/anbmg-default/build.sh [extra -D cmake args]
```

From the login node this submits `srun -N 1 -t 60`. Use `SLURM_TIME=<minutes>` to change the time limit
and `SRUN_ARGS="-p ishmem-ci -w anbmg-c02"` to pick a partition or node.

The script runs configure, build and install in one go. It uses these options:

```
-DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx -DCMAKE_BUILD_TYPE=RelWithDebInfo
-DENABLE_MPI=ON -DMPI_DIR=$I_MPI_ROOT -DISHMEM_DEFAULT_RUNTIME=mpi
-DBUILD_UNIT_TESTS=$BUILD_UNIT_TESTS -DBUILD_PERF_TESTS=ON -DBUILD_EXAMPLES=ON
-DCTEST_LAUNCHER=mpi -DENABLE_OPENSHMEM=OFF -DISHMEM_AOT_DEVICE_TYPES=$ISHMEM_AOT_DEVICE_TYPES
```

- `ISHMEM_AOT_DEVICE_TYPES` defaults to `xe2`, which matches the B-series GPUs on anbmg.
- The script passes `-DENABLE_IBGDA=OFF` explicitly, because the ibgda-test skill uses the same build tree
  and would otherwise leave `ENABLE_IBGDA=1` in `CMakeCache.txt`.
- Env overrides: `ISHMEM_SRC`, `ISHMEM_BUILD`, `ISHMEM_INSTALL`, `JOBS` (default `nproc`).
- `RUNTIME=mpi` (the default) passes `-DENABLE_MPI=ON -DMPI_DIR=$I_MPI_ROOT -DISHMEM_DEFAULT_RUNTIME=mpi`.
  `RUNTIME=pmi` replaces those with `-DENABLE_PMI=ON -DENABLE_MPI=OFF -DISHMEM_DEFAULT_RUNTIME=PMI`.
  Only branches that contain the PMI runtime support it; see section 4.
- `BUILD_UNIT_TESTS` defaults to `ON`, so the ctest unit tests in section 3 are built.
  The unit tests dominate build time; set `BUILD_UNIT_TESTS=OFF` for a faster build without them.
- Logs go to `$ISHMEM_BUILD/{configure,build,install}.log`. When a build fails, grep `build.log` for `error:`.
- A full build (unit tests included) takes about 4 minutes on a 224-core node. Run it with a long timeout,
  or in the background.
- After a source change, an incremental build is enough:
  `srun.sh cmake --build ~/shmem-workspace/build/ishmem -j 224`.
  Re-run `build.sh` only when cmake options change.

## 3. Run tests

`B=~/shmem-workspace/build/ishmem`, `S=~/shmem-workspace/repos/ishmem`,
`R=~/shmem-workspace/.claude/skills/anbmg-default/srun.sh`. Inside an interactive job, source `env.sh` and drop the `$R` prefix.
The examples below omit it, so from the login node run each one as `$R <command>`, for example
`$R ctest --test-dir $B/test/unit -R put_nbi --output-on-failure`. Batch a sequence into one job with
`$R bash -c '...'` instead of queueing one allocation per command.

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

A node has 2 GPUs, so tests run with at most 2 PEs. A full unit suite (178 tests) takes about 9 minutes on B60
(see `~/shmem-workspace/bmg.20260325.md` for earlier pass/fail baselines), so `SLURM_TIME=60` is enough.


Baseline (2026-10-23, anbmg-c01, B60, oneAPI 2026.0, PPA L0 1.15.39122): 174/178 pass. The known failures are
`amo_compare_swap-2`, `amo_compare_swap_nbi-2`, `int_amos-2` (Failed) and `int_wait_until_all_device-2` (Timeout).
When you report results, compare them against this list.

## 4. PMI runtime (`fork/pmi/runtime` branch)

The `pmi/runtime` branch on the `fork` remote (github.com/jngkim) adds a standalone PMI runtime: a bundled
simple PMI-1 client (`pmi-simple/`) and no MPI library. It is checked out in its own worktree with its own
build tree, so `repos/ishmem` and `build/ishmem` stay untouched:

| What | Path |
|---|---|
| Worktree (local branch `pmi/runtime`, tracking `fork/pmi/runtime`) | `~/shmem-workspace/repos/ishmem-pmi` |
| Build tree | `~/shmem-workspace/build/ishmem-pmi` |
| Install | `~/shmem-workspace/install/ishmem-pmi` |

```bash
# Create the worktree if it is missing, or update it
git -C ~/shmem-workspace/repos/ishmem fetch fork pmi/runtime
git -C ~/shmem-workspace/repos/ishmem worktree add -b pmi/runtime ../ishmem-pmi fork/pmi/runtime
git -C ~/shmem-workspace/repos/ishmem-pmi pull --ff-only

# Build (about 4 minutes)
W=~/shmem-workspace
RUNTIME=pmi ISHMEM_SRC=$W/repos/ishmem-pmi ISHMEM_BUILD=$W/build/ishmem-pmi ISHMEM_INSTALL=$W/install/ishmem-pmi \
    $W/.claude/skills/anbmg-default/build.sh
```

Run with `ISHMEM_RUNTIME=PMI`. `env.sh` defaults `ISHMEM_RUNTIME` to `MPI`, which fails in a binary built
without MPI. srun forwards the caller's environment, so you can set the variable in front of `srun.sh`:

```bash
B=~/shmem-workspace/build/ishmem-pmi S=~/shmem-workspace/repos/ishmem-pmi
ISHMEM_RUNTIME=PMI $R mpiexec -n 2 $S/scripts/ishmrun $B/examples/1_helloworld
ISHMEM_RUNTIME=PMI $R ctest --test-dir $B/test/unit -R put_nbi --output-on-failure
```

- Intel MPI's `mpiexec` (Hydra) is used only as the launcher. It serves PMI-1 through `PMI_FD`, and
  `ishmrun` uses `MPI_LOCALRANKID` from `hydra_pmi_proxy` for GPU binding. ctest goes through
  `scripts/ctest/mpi_wrapper` (`mpirun`), so it works the same way.
- Slurm cannot be the PMI server here: `srun --mpi=list` offers only `none`, `cray_shasta`, `pmi2` and
  `pmix`, not PMI-1. Run `mpiexec` inside the allocation; don't launch PEs directly with `srun -n 2`.
- Check that no MPI library is linked: `ldd $B/examples/1_helloworld | grep -i mpi` prints nothing.
- For debugging, add `ISHMEM_DEBUG=1` to trace init, and `PMI_DEBUG=1` to trace the PMI-1 wire protocol
  in `pmi-simple/simple_pmi.cpp`. Wrap runs in `timeout`, because a PE stuck in a PMI barrier hangs the whole job.

PMI baseline (2026-10-23, `fork/pmi/runtime` at d99f8633, device atomics off): 90/181 pass, 91 fail (5 of
them timeouts). Nearly all failures are `ERROR: unsupported` from the host proxy. `runtime_pmi.cpp` registers no
`proxy_funcs` for most AMOs (only `AMO_FETCH`/`AMO_SET`), `TEST*`, `WAIT*`, `INSCAN`/`EXSCAN`, and it rejects
host-initiated signals without device atomics (`signal_set`, `signal_add`, `put_signal`). Compare
`runtime_mpi.cpp` for the full set of proxy ops.
