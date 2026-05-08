# shmem-workspace
Setting workspace for the developers and users of Intel SHMEM

## Repository Structure

```
build/                        # Build scripts
  build_sos.sh                    # Builds libfabric (OFI) and SOS
  build_sos_ucx.sh                # Builds SOS with UCX transport
  build_ishmem.sh                 # Builds Intel SHMEM and its tests
  build_osumb.sh                  # Builds OSU Micro-Benchmarks
  config_ofi.sh                   # Configure script for libfabric (OFI)
repos/                        # Source repositories (clone separately)
  osu-micro-benchmarks-7.5.2/     # OSU Micro-Benchmarks source
  ishmem/                         # Intel SHMEM source
  libfabric/                      # libfabric (OFI) source
  SOS/                            # Sandia OpenSHMEM source
results/                      # Benchmark results organized by cluster
# --- config / shared logic ---
config.sh                     # Multi-cluster config: auto-detects cluster, sets platform env vars and CPU binding
config.cray-shmem.sh          # Loads modules for Cray SHMEM runtime
cpu_bind.sh                   # CPU binding env vars for MPI runs (source before running)
test_all.sh                   # Common build-and-test logic sourced by PBS/Slurm job scripts
osu_put_latency.sh            # OSU Put Latency benchmark logic sourced by OSU bench job scripts
osu_pair_bench.sh             # OSU pair (2-rank) benchmark logic sourced by OSU bench job scripts
osu_multi_bench.sh            # OSU multi-node (variable PPN) benchmark logic sourced by OSU bench job scripts
# --- PBS job scripts ---
pbs_test_all.sh               # Build + run all tests
pbs_debug_config.sh           # Validate config.sh on a real node
pbs_debug_sos.sh              # Run SOS debug tests
pbs_fi_debug.sh               # Run libfabric debug benchmarks
pbs_osu_bench.sh              # Run OSU Put Latency benchmarks
pbs_osu_cray_env.sh           # OSU benchmarks with Cray env setup
pbs_cxi_debug.sh              # OSU benchmarks with CXI telemetry capture
pbs_template.sh               # PBS job script template
# --- Slurm job scripts ---
slurm_test_all.sh             # Build + run all tests
slurm_osu_bench.sh            # Run OSU Put Latency benchmarks
# --- utilities ---
collect_telemetry.sh          # Collects CXI NIC telemetry counters from all nodes
cxi_telemetry_snapshot.sh     # CXI NIC telemetry snapshot (call before/after a workload)
cxi_telemetry_diff.py         # Diffs CXI telemetry snapshots; computes per-NIC deltas
debug_sos_shmemx.sh           # Debug script for SOS shmemx atomics
excludes                      # Rsync exclude list for workspace syncing
```

## Getting sources in repos
* libfabric
```
git clone https://github.com/ofiwg/libfabric.git 
```
On Cray systems, the default uses the system module, e.g., libfabric/1.22.0 on Aurora.
* SOS
```
git clone --recurse-submodules https://github.com/Sandia-OpenSHMEM/SOS.git
```
* ishmem
```
git clone https://github.com/oneapi-src/ishmem
```
## Build

Build output is placed under `$BASE` (default: `~/shmem-workspace/build/latest`).

### 1. Build SOS and OFI

```bash
bash build/build_sos.sh
```

- Builds libfabric (OFI) from `repos/libfabric` unless `$OFI_INSTALL` already exists or `SKIP_OFI_BUILD=1`.
- Builds Sandia OpenSHMEM (SOS) from `repos/SOS` against the OFI installation.
- Generates `$BASE/setup_sos_ofi.sh` with the resulting environment variables.

Platform-specific configure flags are selected automatically:
- **Cray (Borealis/Aurora)**: uses `--with-xpmem`, `--enable-ofi-mr=basic`, `--enable-mr-endpoint`, `mpicc`/`mpicxx` compilers, and `--enable-pmi-mpi`. Set `OFI_INSTALL` to the system libfabric:
  ```bash
  export OFI_INSTALL=/opt/cray/libfabric/1.22.0
  bash build/build_sos.sh
  ```
- **IB cluster (Florence)**: uses `--disable-bounce-buffers`, `--disable-ofi-inject`, `--enable-hard-polling`, `icx`/`icpx` compilers, and `--enable-pmi-simple`.
- **Stand-alone (tpi\*)**: disables HMEM and OFI-MR flags, and sets `FI_PROVIDER_PATH` to the local OFI install.

### 2. Build Intel SHMEM

```bash
bash build/build_ishmem.sh
```

- Requires a SOS installation at `$SOS_INSTALL` (default: `$BASE/install/sos`).
- Builds Intel SHMEM and its unit tests and examples using `icx`/`icpx` via CMake.
- Generates `$BASE/setup_ishmem.sh` with the resulting environment variables.

## Configuration

`config.sh` is the central runtime configuration script sourced by all job scripts. It auto-detects the cluster from scheduler environment variables (`SLURM_CLUSTER_NAME`, `PBS_O_HOST`, or hostname) and sets platform-specific environment variables.

| Variable | Description |
|---|---|
| `CLUSTER` | Auto-detected: `aurora`, `borealis`, `florence`, `anbmg`. Override by exporting before sourcing. |
| `PLATFORM` | Derived from `CLUSTER`: `cray` (Aurora/Borealis) or `ib` (Florence/anbmg). |

Platform-specific variables set automatically:
- **Cray (Aurora/Borealis)**: `OFI_INSTALL`, `PALS_PMI=pmix`, `FI_CXI_*`, `SHMEM_BOUNCE_SIZE`
- **InfiniBand (Florence/anbmg)**: `USE_I_MPI=1`, `I_MPI_OFFLOAD`, `FI_VERBS_IFACE`, Arc B-Series GPU workarounds

To debug `config.sh` on a real node:

```bash
qsub -l filesystems=home -N cfg_debug -q debug pbs_debug_config.sh
```

After a build, source the generated environment script to set paths for the session:

```bash
source build/latest/setup_sos_ofi.sh    # OFI + SOS paths
source build/latest/setup_ishmem.sh     # Intel SHMEM paths (generated by build_ishmem.sh)
```

## CPU Binding

`cpu_bind.sh` computes CPU binding strings from the live `lscpu` topology and exports them as environment variables for use in `mpirun` / `mpiexec` calls.

```bash
source cpu_bind.sh           # include core 0 of each socket (default)
source cpu_bind.sh exclude   # skip core 0 of each socket (use on Aurora/Borealis)
```

On Aurora/Borealis cores 0 and 52 are reserved for the OS; always use `exclude` there.

### Exported Variables

| Variable | Description |
|---|---|
| `BIND2_C` | 2 ranks pinned to the two halves of socket 0 |
| `BIND2_S` | 2 ranks, one per socket |
| `BIND2_N` | Alias for `BIND2_S` |
| `BIND_ALL` | All usable cores, one contiguous range per socket |
| `BIND1C` | One core per rank (no sharing) |
| `BIND2C` | Two consecutive cores per rank (HT pairs) |
| `BIND64_N` | 64-rank hand-tuned map for Aurora/Borealis (52 cores/socket) |
| `BIND8_N` | 8-rank map for Aurora/Borealis (52 cores/socket) |
| `BIND1C_MAX` | Maximum ranks supported by `BIND1C` on this node |
| `BIND2C_MAX` | Maximum ranks supported by `BIND2C` on this node |

Each `BIND*` variable has a corresponding `IMPI_BIND*` variant formatted for Intel MPI (`-genv I_MPI_PIN ...`). `BIND64_N` and `BIND8_N` are only set when 52 cores/socket are detected.

### Example

```bash
source cpu_bind.sh exclude
mpirun -np 2  -ppn 2  ${BIND2_S}  ./osu_oshm_put    # 1 rank/socket
mpirun -np 64 -ppn 64 ${BIND64_N} ./osu_oshm_put    # Aurora: 64 ranks, fair NIC distribution
mpirun -np ${BIND1C_MAX} -ppn ${BIND1C_MAX} ${BIND1C} ./osu_oshm_put  # max 1-core ranks
```

## Running Tests

### Batch Jobs

Submit a full build-and-test job using the scheduler script for your cluster:

```bash
# PBS (e.g., Aurora/Borealis)
qsub pbs_test_all.sh

# Slurm (e.g., Florence)
sbatch slurm_test_all.sh
```

Both scripts:
1. Optionally build OFI and SOS (set `SKIP_SOS_BUILD=1` to reuse `build/latest/install`).
2. Run `make check` on SOS with OpenSHMEM runtime.
3. Build Intel SHMEM, then run `ctest` for unit tests under both MPI and OpenSHMEM runtimes.

Key overridable environment variables (set before submitting):

| Variable | Default | Description |
|---|---|---|
| `OFI_INSTALL` | `build/latest/install/ofi` | Path to OFI installation |
| `BASE` | `build/<jobname>_<jobid>.<date>` | Build output directory for the job |
| `SKIP_SOS_BUILD` | `0` | Set to `1` to skip OFI/SOS build |

### Manual Test Run (SOS)

```bash
source build/latest/setup_sos_ofi.sh
cd build/latest/sos
make check NPROCS=2 TEST_RUNNER='timeout 60 oshrun -np 2 -ppn 2'
```

## OSU Micro-Benchmarks

OSU Put Latency benchmarks compare MPI one-sided (`osu_put_latency`), MPI point-to-point (`osu_latency`), and OpenSHMEM (`osu_oshm_put`) across three CPU binding modes: core, socket, and node.

### Running

```bash
# PBS (e.g., Borealis)
qsub pbs_osu_bench.sh

# Slurm (e.g., Florence)
sbatch slurm_osu_bench.sh
```

Both scripts source `config.sh` for cluster/platform detection and CPU binding, then source `osu_put_latency.sh` to build and run the benchmarks. Results are written to `results/<cluster>/osumb.put2.<jobid>/`.

### Build Control

| Variable | Default | Description |
|---|---|---|
| `SKIP_OSU_BUILD` | `1` | Set to `0` to force a rebuild of OSU benchmarks |
| `OSU_SRC` | `~/shmem-workspace/repos/osu-micro-benchmarks-7.5.2` | Path to OSU source |
| `OSU_BUILD` | `~/shmem-workspace/build/osu-bench` | Build output directory |

### Affinity Debugging

Set `DEBUG_AFFINITY=1` (default) to run a short debug pass before the benchmark loops. This runs each configuration once with `I_MPI_DEBUG=5` and `SHMEM_DEBUG=1`, writing output to `*.debug.dat` files. If any run produces a `BAD TERMINATION`, the script prints a summary and exits before running the full benchmark.

### Output Files

Each job creates a directory `results/<cluster>/osumb.put2.<jobid>/` containing:

| File | Contents |
|---|---|
| `mpi.core.dat` / `mpi.socket.dat` / `mpi.node.dat` | MPI one-sided put latency (10 runs each binding) |
| `mpi2.core.dat` / `mpi2.socket.dat` / `mpi2.node.dat` | MPI pt2pt latency (10 runs each binding) |
| `sos.core.dat` / `sos.socket.dat` / `sos.node.dat` | OpenSHMEM put latency (10 runs each binding) |
| `*.debug.dat` | Single-run debug output (affinity check, present when `DEBUG_AFFINITY=1`) |
| `env.txt` | Snapshot of key environment variables |
| `hostfile` | Node list from the scheduler |
