#!/bin/bash
# Smoke test (1_helloworld) + all examples, 2 PEs on GPUs 4,6 (NUMA 1), ENABLE_IBGDA=ON build.
# Env: GPUS (4,6), NICS (mlx5_4,mlx5_6), OUT (results-o262/examples), I_SHMEM_BUILD (build/ishmem-o262)
# Clean env, oneAPI 2026.2 (/usr/local/intel/2026.2/oneapi-vars.sh), ~/setup-env.sh (UseKmdMigration=1).
# Each example is launched directly (not via ctest): ctest's 7_uid uses standalone_wrapper,
# which unsets ZE_AFFINITY_MASK and could land on GPUs 0-3.
# Stops if any new proc of ours is stuck in D state.
[ -z "$CLEAN_ENV" ] && exec env -i HOME=$HOME PATH=/usr/bin:/bin TERM=dumb CLEAN_ENV=1 \
    GPUS="$GPUS" NICS="$NICS" OUT="$OUT" I_SHMEM_BUILD="$I_SHMEM_BUILD" bash "$0" "$@"
source /usr/local/intel/2026.2/oneapi-vars.sh >/dev/null 2>&1
source ~/setup-env.sh
OUT=${OUT:-~/shmem-workspace/results-o262/examples}; mkdir -p $OUT; : > $OUT/status
B=${I_SHMEM_BUILD:-~/shmem-workspace/build/ishmem-o262}
GPUS=${GPUS:-4,6} NICS=${NICS:-mlx5_4,mlx5_6}
export ISHMRUN_GPUS=$GPUS ISHMRUN_NICS=$NICS ISHMRUN_NUMA=1
# IBGDA env as in the PR #868/#888 evals (build has ENABLE_IBGDA=ON)
export ISHMEM_IB_ENABLE_IBGDA=1 I_MPI_FABRICS=shm I_MPI_OFFLOAD_L0_COMMON_ENGINE_TYPE=2
RUN=~/shmem-workspace/build/ishmrun-numa1
T=180

log() { echo "$* $(date -u +%T)" | tee -a $OUT/status; }
stuck_pids() { ps -eLo user,pid,stat | awk '$1=="jeongnim" && $3 ~ /D/ {print $2}' | sort -u; }
OLD_STUCK=$(stuck_pids | tr '\n' ' ')
guard() {
    local p new=
    for p in $(stuck_pids); do [[ " $OLD_STUCK " == *" $p "* ]] || new+="$p "; done
    [ -n "$new" ] && { ps -o pid,stat,wchan:32,etime,comm -p ${new// /,} > $OUT/stuck.txt
                       log "ABORT: new stuck processes after $1"; exit 1; }
    return 0
}
result() {  # name rc
    local r=PASS; [ $2 -eq 124 ] && r=TIMEOUT; [ $2 -ne 0 ] && [ $2 -ne 124 ] && r="FAIL(rc=$2)"
    log "$1: $r"; guard "$1"
}

log "start GPUS=$GPUS NICS=$NICS IBGDA=$ISHMEM_IB_ENABLE_IBGDA FABRICS=$I_MPI_FABRICS CMPLR_ROOT=$CMPLR_ROOT I_MPI_ROOT=$I_MPI_ROOT UseKmdMigration=$UseKmdMigration ignoring stuck: $OLD_STUCK"
cd $B/examples
for ex in 1_helloworld 2_get 3_library_apis 4_pi 5_pi_reduce 6_team_split_strided; do
    timeout -k 10 $T mpiexec -n 2 $RUN ./$ex > $OUT/$ex.log 2>&1
    rc=$?; result $ex $rc
    [ $ex = 1_helloworld ] && [ $rc -ne 0 ] && { log "smoke test failed, stopping"; exit 1; }
done

# 7_uid: no MPI launcher; both ranks see GPUs 4,6 and pick device rank % 2
(
    export ZE_FLAT_DEVICE_HIERARCHY=FLAT ONEAPI_DEVICE_SELECTOR='level_zero:*' ZE_AFFINITY_MASK=$GPUS
    export MASTER_ADDR=localhost WORLD_SIZE=2
    IFS=',' read -r -a nic <<<"$NICS"   # no ishmrun here: pair NIC with the rank's GPU ourselves
    pids=
    for r in 0 1; do
        RANK=$r ISHMEM_IBGDA_NIC=${nic[$r]} ISHMEM_IB_DEV=${nic[$r]} timeout -k 10 $T numactl -N 1 -m 1 ./7_uid > $OUT/7_uid.rank$r.log 2>&1 & pids+="$! "
    done
    rc=0; for p in $pids; do wait $p; e=$?; [ $e -ne 0 ] && rc=$e; done
    exit $rc
)
result 7_uid $?
log done
