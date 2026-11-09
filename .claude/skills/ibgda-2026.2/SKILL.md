---
name: ibgda-2026.2
description: Build Intel SHMEM (IBGDA on) with oneAPI 2026.2 from /usr/local/intel/2026.2/oneapi-vars.sh and test it on GPUs 4,6 (NUMA 1) — smoke test, examples, unit/perf tests. Use when asked to build or test with 2026.2, the 2026.2 toolchain, or compare 2026.1 vs 2026.2.
---

# Intel SHMEM with oneAPI 2026.2

| What | Path |
|---|---|
| Toolchain | `/usr/local/intel/2026.2/oneapi-vars.sh` (compiler 2026.2, its Intel MPI) |
| Source | `~/shmem-workspace/repos/ishmem` |
| Build tree | `~/shmem-workspace/build/ishmem-o262` |
| Install | `~/shmem-workspace/install/ishmem-o262` |

The 2026.1 build (`/opt/intel/oneapi`, skills `default-test` / `ibgda-test`) lives in `build/ishmem`.
Keep the two toolchains in separate build trees.

## 0. Before anything

- Check that the node is free (`ps -eo user,etime,pcpu,args --sort=-pcpu`). If other users' jobs are running, stop and ask.
- Use only GPUs 4,6 (or 5,7) with NICs mlx5_4,mlx5_6 (or mlx5_5,mlx5_7), pinned to NUMA 1. Never use GPUs 0-3.
- Both scripts re-exec themselves in a clean env (`env -i`). That way an already-sourced 2026.1
  (or 2026.2 `setvars.sh`) in the calling shell can't leak in. `build.sh` aborts if `CMPLR_ROOT` isn't under `/usr/local/intel`.

## 1. Build

```bash
~/shmem-workspace/.claude/skills/ibgda-2026.2/build.sh [extra -D cmake args]
```

- Options: same as `ibgda-test`. `-DENABLE_IBGDA=ON` (this node always builds with IBGDA),
  `-DISHMEM_IBGDA_NIC_VENDOR=MLX5`, AOT `0x674f` (= `cri`), RelWithDebInfo, MPI runtime, perf tests + examples.
- `BUILD_UNIT_TESTS` defaults to **ON** here. Set `BUILD_UNIT_TESTS=OFF` for a faster build without unit tests.
- Env overrides: `I_SHMEM_SRC`, `I_SHMEM_BUILD`, `I_SHMEM_INSTALL`, `I_SHMEM_AOT_DEVICE_TYPES`, `JOBS` (default `nproc`;
  use `JOBS=64` when the node is shared).
- Logs: `$I_SHMEM_BUILD/{configure,build,install}.log`. Check `grep -c 'error:' build.log`
  and `grep 'Enable IBGDA' configure.log` (must say ON).
- A full build takes several minutes. Run it in the background.

## 2. Smoke test + examples

```bash
~/shmem-workspace/.claude/skills/ibgda-2026.2/run-examples.sh
```

- Runs `1_helloworld` first and stops if it fails. Then runs `2_get` … `6_team_split_strided` via
  `mpiexec -n 2 ~/shmem-workspace/build/ishmrun-numa1`, and `7_uid` with two hand-launched ranks.
- Runtime env: `~/setup-env.sh` (`UseKmdMigration=1`, the user's default; don't unset it),
  `ISHMEM_IB_ENABLE_IBGDA=1`, `I_MPI_FABRICS=shm`, `I_MPI_OFFLOAD_L0_COMMON_ENGINE_TYPE=2`,
  `ISHMRUN_GPUS=4,6`, `ISHMRUN_NICS=mlx5_4,mlx5_6`.
- Examples are launched directly rather than through ctest. ctest's `7_uid` uses `standalone_wrapper`,
  which unsets `ZE_AFFINITY_MASK` and could land on GPUs 0-3. For 7_uid both ranks see `ZE_AFFINITY_MASK=4,6`
  and pick device `rank % 2`. The script pairs `ISHMEM_IBGDA_NIC` per rank.
- Per-test timeout 180 s. The script aborts if any new process of ours gets stuck in D state (see `stuck.txt`).
- Env: `GPUS`, `NICS`, `OUT` (default `~/shmem-workspace/results-o262/examples`), `I_SHMEM_BUILD`.
- Output: `$OUT/status` (one PASS/FAIL/TIMEOUT line per example) plus one log per example.
  The log warning "Disabling IPC - it is unsupported when IBGDA is enabled" is expected.

## 3. Unit / perf tests

Use the same clean 2026.2 + IBGDA env as `run-examples.sh` (see `pr888-results/run_eval.sh` for a full-suite driver):

```bash
env -i HOME=$HOME PATH=/usr/bin:/bin bash -c '
  source /usr/local/intel/2026.2/oneapi-vars.sh >/dev/null 2>&1; source ~/setup-env.sh
  export ISHMEM_IB_ENABLE_IBGDA=1 I_MPI_FABRICS=shm I_MPI_OFFLOAD_L0_COMMON_ENGINE_TYPE=2
  export ISHMRUN_GPUS=4,6 ISHMRUN_NICS=mlx5_4,mlx5_6
  B=~/shmem-workspace/build/ishmem-o262
  ctest --test-dir $B/test/unit -R put_nbi -j1 --timeout 180 --output-on-failure'
```

- Skip `ibgda_nbi_put_get-2` (known doorbell race, aborts and can leave D-state procs).
- After every run, check for stuck procs: `ps -eo user,stat,args | awk '$1=="jeongnim" && $2 ~ /D/'`.
