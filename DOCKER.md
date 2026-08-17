# Intel SHMEM (ishmem) development with Docker

Reference for using the prebuilt image
`amr-registry-pre.caas.intel.com/ishmem/ishmem-ubuntu24:latest` as a dev
environment. This is the "run the shipped image as-is" workflow — no custom
image build.

## What's in the image

| Component            | Version / Path                                   |
|----------------------|--------------------------------------------------|
| OS                   | Ubuntu 24.04 LTS (glibc 2.39)                    |
| DPC++/SYCL compiler  | `icpx` 2025.1 — `/opt/intel/oneapi/compiler/2025.1/bin` |
| Intel MPI            | `mpicxx` / `mpiexec.hydra` 2021.15               |
| libfabric            | bundled under Intel MPI                          |
| CMake / Ninja        | `/usr/bin`                                       |
| Level Zero loader    | `libze_loader.so.1`                              |
| ccache               | `CCACHE_DIR=/ccache`                             |
| Default WORKDIR/user | `/work`, root, `/bin/bash`                       |

Non-obvious notes:
- oneAPI toolchain is **not** on `PATH` by default — must `source setvars.sh`.
- Image has **no SOS/OpenSHMEM prebuilt** → the self-contained backend is
  **MPI**. (OpenSHMEM builds would fail to find `shmem.h`.)
- Only oneAPI **2025.1** is inside the image (not 2026.1).

## Docker concepts (quick)

- **Image** = frozen read-only filesystem. **Container** = a running instance.
- Changes inside a container are lost on removal *unless* on a mounted volume.
  → mount source from the host so edits/builds persist.

## Step-by-step

### 1. Confirm the image is present
```bash
docker images | grep ishmem-ubuntu24
```

### 2. Quick throwaway shell
```bash
docker run -it --rm amr-registry-pre.caas.intel.com/ishmem/ishmem-ubuntu24:latest bash
```
- `-it` interactive terminal · `--rm` auto-delete on exit.

### 3. Activate the Intel toolchain (inside container)
```bash
source /opt/intel/oneapi/setvars.sh
icpx --version        # Intel oneAPI DPC++/C++ 2025.1.1
sycl-ls               # list SYCL devices (CPU only without GPU flags)
```

### 4. Mount source so edits/builds persist
Run from the workspace root
(`/mnt/data0/nfs/pdx/home/jeongnim/shmem-workspace`):
```bash
docker run -it --rm \
  -v "$PWD/repos/ishmem":/work/ishmem \
  -w /work/ishmem \
  amr-registry-pre.caas.intel.com/ishmem/ishmem-ubuntu24:latest bash
```

### 5. Add GPU access
Host has Intel GPUs at `/dev/dri`; render group GID is **993**.
```bash
docker run -it --rm \
  --device /dev/dri --group-add 993 --ipc=host \
  -v "$PWD/repos/ishmem":/work/ishmem \
  -w /work/ishmem \
  amr-registry-pre.caas.intel.com/ishmem/ishmem-ubuntu24:latest bash
```
- `--device /dev/dri` GPU render nodes · `--group-add 993` render group ·
  `--ipc=host` shared memory for SHMEM/MPI transports.
- **Warning `groups: cannot find name for group ID 993` is harmless** — the
  GID membership works; the container just has no *name* for it. To silence:
  `groupadd -g 993 render 2>/dev/null` inside, or launch with
  `bash -c 'groupadd -g 993 render 2>/dev/null; exec bash'`.
- Verify: `id` lists 993, `ls -l /dev/dri` shows `renderD128...`, and after
  sourcing setvars `sycl-ls` lists the Level-Zero GPU(s).

### 6. Build ishmem (MPI backend)
```bash
source /opt/intel/oneapi/setvars.sh
cmake -G Ninja -B build-docker -DENABLE_MPI=ON \
  -DCMAKE_CXX_COMPILER=icpx -DCMAKE_BUILD_TYPE=Release
cmake --build build-docker -j $(nproc)
```
Confirm in the configure summary: MPI support ON, Default Runtime MPI,
compiler = icpx 2025.1, AOT device type(s) match your GPU (`xe-hpc`=PVC/Max,
`xe2`=Xe2-class).

Tests/examples are OFF by default → to get runnable binaries, reconfigure with
the appropriate `BUILD_*` option (`cmake -B build-docker -LH | grep -i test`).

### 7. Run tests (single node, in container)
```bash
FI_PROVIDER=shm ctest --test-dir build-docker --output-on-failure
```
- **`FI_PROVIDER=shm`** pins libfabric to the shared-memory provider, avoiding
  network fabrics (verbs/psm3/cxi) that aren't wired up in the container.
- ishmem requires a **1:1 PE-to-GPU mapping**; `scripts/ishmrun` enforces it.
- Manual launch example:
  `ISHMEM_RUNTIME=MPI mpiexec.hydra -n 2 ./scripts/ishmrun ./build-docker/test/...`

## Everyday container commands
```bash
docker ps                       # running containers
docker exec -it <name> bash     # 2nd shell into a running container
docker stop <name>              # stop
docker logs <name>              # output
# Named, reusable container (survives exit):
docker run -it --name ishmem-dev ... bash
docker start -ai ishmem-dev     # re-attach later
docker rm ishmem-dev            # delete when done
```

## The two gotchas not in any README
1. Render-group GID **993** for `/dev/dri` access (+ the harmless name warning).
2. **`FI_PROVIDER=shm`** for single-node runs inside the container.
