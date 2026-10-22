---
name: default-test
description: Build Intel SHMEM 
---

# Build Intel SHMEM 

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

## 2. Build

```bash
~/shmem-workspace/.claude/skills/default-test/build.sh [extra -D cmake args]
```

The script runs configure, build and install in one go. It uses these options:

```
-DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx -DCMAKE_BUILD_TYPE=RelWithDebInfo
-DENABLE_MPI=ON -DMPI_DIR=$I_MPI_ROOT -DISHMEM_DEFAULT_RUNTIME=mpi
-DBUILD_UNIT_TESTS=$BUILD_UNIT_TESTS -DBUILD_PERF_TESTS=ON -DBUILD_EXAMPLES=ON
-DCTEST_LAUNCHER=mpi -DENABLE_OPENSHMEM=OFF -DISHMEM_AOT_DEVICE_TYPES=$ISHMEM_AOT_DEVICE_TYPES
```

- `ISHMEM_AOT_DEVICE_TYPES` defaults to `xe-hpc,xe2` 
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

