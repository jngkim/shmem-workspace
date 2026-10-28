#!/usr/bin/env bash
# Run a command on an anbmg compute node with env.sh loaded.
# Outside a Slurm job it re-launches itself with `srun -N 1 -t $SLURM_TIME`; inside a job
# (e.g. after `srun -N 1 -t 60 --pty /bin/bash`) it runs the command directly.
# Usage: srun.sh <command> [args...]
# Env: SLURM_TIME (minutes, default 60), SRUN_ARGS (extra srun options, e.g. "-p ishmem-ci -w anbmg-c02")
set -eo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <command> [args...]" >&2
    exit 2
fi

SELF=$(readlink -f "${BASH_SOURCE[0]}")
if [[ -z ${SLURM_JOB_ID:-} ]]; then
    # shellcheck disable=SC2086
    exec srun -N 1 -t "${SLURM_TIME:-60}" ${SRUN_ARGS:-} "$SELF" "$@"
fi

source "$(dirname "$SELF")/env.sh"
exec "$@"
