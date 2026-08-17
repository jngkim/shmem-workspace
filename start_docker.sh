docker run -it --rm   --device /dev/dri   --group-add 993  --ipc=host \
    -v "$PWD/repos/ishmem":/work/ishmem   -w /work/ishmem   \
    amr-registry-pre.caas.intel.com/ishmem/ishmem-ubuntu24:latest   bash
