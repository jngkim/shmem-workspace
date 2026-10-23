#!/usr/bin/env bash
# Toolchain/runtime environment for building and running Intel SHMEM. Source it:
#   source ~/shmem-workspace/.claude/skills/default-test/env.sh
# Env: AGAMA_SETUP (GPU runtime setup script sourced after oneAPI; set empty to skip)

if ! command -v icpx >/dev/null || [[ -z ${I_MPI_ROOT:-} ]]; then
    source /opt/intel/oneapi/setvars.sh >/dev/null
fi

# tpi-dnp03 runs on the unpacked Agama PPA drop 38308, not the system GPU runtime.
if [[ $(hostname -s) == tpi-dnp03 ]]; then
    AGAMA_SETUP=${AGAMA_SETUP-/mnt/data0/nfs/pdx/home/jeongnim/share/agama-ppa/38308/setup-env.sh}
fi
if [[ -n ${AGAMA_SETUP:-} ]]; then
    source "$AGAMA_SETUP" >/dev/null
fi
