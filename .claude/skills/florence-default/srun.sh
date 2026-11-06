#!/usr/bin/env bash
# Run a command on a Florence compute node with env.sh loaded.
# Outside a Slurm job it re-launches itself on a compute node:
#   - debug partition (default): `srun -p debug -N 1 -t 1:00:00`
#   - any other partition (e.g. hdr200): `sbatch --wait`, because those partitions reject
#     interactive (srun) allocations. The job log is printed when the job ends and its exit code
#     is returned. Logs go to $SLURM_LOG_DIR (default ~/shmem-workspace/results/slurm).
# Inside a job (e.g. after `srun -p debug -N 1 -t 1:00:00 --pty /bin/bash`) it runs the command directly.
# Usage: srun.sh <command> [args...]
# Env: SLURM_PARTITION (default debug; hdr200 also works, 8h limit),
#      SLURM_TIME (default 1:00:00; debug max is 2:00:00),
#      SRUN_ARGS (extra srun/sbatch options, e.g. "-w compute23")
set -eo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <command> [args...]" >&2
    exit 2
fi

SELF=$(readlink -f "${BASH_SOURCE[0]}")
if [[ -z ${SLURM_JOB_ID:-} ]]; then
    PART=${SLURM_PARTITION:-debug}
    TIME=${SLURM_TIME:-1:00:00}
    if [[ $PART == debug ]]; then
        # shellcheck disable=SC2086
        exec srun -p "$PART" -N 1 -t "$TIME" ${SRUN_ARGS:-} "$SELF" "$@"
    fi
    LOG_DIR=${SLURM_LOG_DIR:-$HOME/shmem-workspace/results/slurm}
    mkdir -p "$LOG_DIR"
    LOG="$LOG_DIR/srun-$PART-$(date +%Y%m%d-%H%M%S)-$$.out"
    CMD=$(printf '%q ' "$SELF" "$@")
    rc=0
    # shellcheck disable=SC2086
    sbatch --wait --parsable -p "$PART" -N 1 -t "$TIME" ${SRUN_ARGS:-} -o "$LOG" \
        --chdir="$PWD" --wrap "$CMD" >/dev/null || rc=$?
    cat "$LOG" 2>/dev/null || echo "srun.sh: no job log at $LOG" >&2
    echo "srun.sh: job log $LOG (exit $rc)" >&2
    exit $rc
fi

source "$(dirname "$SELF")/env.sh"
exec "$@"
