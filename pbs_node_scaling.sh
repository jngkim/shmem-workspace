#!/bin/bash
################################################################################
# Generic Node-Scaling Study Framework
#
# Purpose: Orchestrate scaling studies by submitting a PBS job across a sweep
#          of node counts. Each job in the chain calls a user-specified script
#          with a fixed number of nodes, then automatically submits the next job.
#
# Usage:
#   pbs_node_scaling.sh [--help] [--no-chain] [--cleanup-only]
#
# Environment variables:
#   SCRIPT_TO_RUN        Path to the benchmark script to run (required)
#   NODE_COUNTS          Space/comma-separated list of node counts to sweep
#                        Default: "2 4 8 16 32 64"
#   CLEANUP_ONLY         Set to 1 to run cleanup mode (moves PBS output files)
#   PREV_JOBID           ID of the previous job (set by chain logic)
#   PREV_JOB_NAME        Name of the previous job (set by chain logic)
#   NO_CHAIN             Set to 1 to suppress automatic job chaining
#
# Example (in a PBS script or manually):
#   export SCRIPT_TO_RUN="${HOME}/shmem-workspace/nail_contention.sh"
#   export NODE_COUNTS="2 4 8"
#   qsub -N my_study -l nodes=2 -l filesystems=home pbs_node_scaling.sh
#
# The framework will:
#   1. Source config and detect the current node count
#   2. Run SCRIPT_TO_RUN with the allocated nodes
#   3. Automatically submit the next job in the node count sequence
#   4. Move the previous job's PBS output files to results/${CLUSTER}/${JOBNAME}.${JOBID}/
#   5. After the last job, files remain in workspace (run cleanup_pbs_files.sh to move them)
#
################################################################################

#set -x

# ── Configuration ────────────────────────────────────────────────────────────

# Allow user to override these before calling this script
SCRIPT_TO_RUN=${SCRIPT_TO_RUN:-}
NODE_COUNTS_STR=${NODE_COUNTS:-"2 4 8 16 32 64"}
NO_CHAIN=${NO_CHAIN:-0}
CLEANUP_ONLY=${CLEANUP_ONLY:-0}

# Parse NODE_COUNTS (handle both space and comma-separated)
NODE_COUNTS=()
for item in ${NODE_COUNTS_STR//,/ }; do
    NODE_COUNTS+=($item)
done


# ── Validate inputs ──────────────────────────────────────────────────────────
if [[ -z "${SCRIPT_TO_RUN}" ]]; then
    echo "ERROR: SCRIPT_TO_RUN not set. Set it before invoking this script."
    echo "Example: export SCRIPT_TO_RUN=\${HOME}/shmem-workspace/nail_contention.sh"
    exit 1
fi

if [[ ! -f "${SCRIPT_TO_RUN}" ]]; then
    echo "ERROR: SCRIPT_TO_RUN='${SCRIPT_TO_RUN}' does not exist."
    exit 1
fi

if [[ ${#NODE_COUNTS[@]} -eq 0 ]]; then
    echo "ERROR: NODE_COUNTS is empty or invalid. Provide a list of node counts."
    exit 1
fi

# ── PBS/SLURM environment detection ──────────────────────────────────────────
if [[ -n "${PBS_NODEFILE}" ]]; then
    # PBS environment
    nnodes_avail=$(wc -l "$PBS_NODEFILE" | awk '{print $1}')
    nnodes=${NNODES:-$nnodes_avail}
    JOBID=${PBS_JOBID%%.*}
    JOB_NAME=${PBS_JOBNAME:-scaling_study}
    WORKDIR=${PBS_O_WORKDIR}
elif [[ -n "${SLURM_NODELIST}" ]]; then
    # SLURM environment
    nnodes=$(sinfo -N --exact -o %N "$SLURM_NODELIST" | wc -l)
    JOBID=${SLURM_JOB_ID}
    JOB_NAME=${SLURM_JOB_NAME:-scaling_study}
    WORKDIR=${SLURM_SUBMIT_DIR}
else
    echo "ERROR: Not running under PBS or SLURM. Cannot determine job environment."
    exit 1
fi

LOCAL_WORLD_SIZE=${PPN:-2}
WORLD_SIZE=$(( nnodes * LOCAL_WORLD_SIZE ))
echo "WORLD_SIZE=${WORLD_SIZE} LOCAL_WORLD_SIZE=${LOCAL_WORLD_SIZE}"

# ── Move previous job's PBS output (if applicable) ────────────────────────────
echo "DEBUG: PREV_JOBID='${PREV_JOBID:-}' PREV_JOB_NAME='${PREV_JOB_NAME:-}'"
if [[ -n "${PREV_JOBID:-}" ]]; then
    if [[ ! -f "${HOME}/shmem-workspace/config.sh" ]]; then
        echo "ERROR: Cannot source config.sh; expected at ${HOME}/shmem-workspace/config.sh"
        exit 1
    fi
    source "${HOME}/shmem-workspace/config.sh"

    prev_out_dir="${HOME}/shmem-workspace/results/${CLUSTER}/${PREV_JOB_NAME}.${PREV_JOBID}"
    mkdir -p "${prev_out_dir}"
    echo "DEBUG: Looking for files: ${WORKDIR}/${PREV_JOB_NAME}.{o,e}${PREV_JOBID}"

    for ext in o e; do
        f="${WORKDIR}/${PREV_JOB_NAME}.${ext}${PREV_JOBID}"
        if [[ -f "${f}" ]]; then
            mv "${f}" "${prev_out_dir}/" && \
                echo "INFO: Moved ${PREV_JOB_NAME}.${ext}${PREV_JOBID} -> ${prev_out_dir}/"
        else
            echo "DEBUG: File not found: ${f}"
        fi
    done
else
    echo "DEBUG: No PREV_JOBID set, skipping file movement"
fi

# ── Run the user-specified benchmark script ──────────────────────────────────
echo "INFO: Running benchmark script: ${SCRIPT_TO_RUN} with ${nnodes} nodes"
source "${SCRIPT_TO_RUN}"
BENCH_EXIT=$?

if [[ ${BENCH_EXIT} -ne 0 ]]; then
    echo "WARN: Benchmark script exited with code ${BENCH_EXIT}"
fi

# ── Chain: submit next job in the scaling sequence ────────────────────────────
if [[ "${NO_CHAIN}" == "1" ]]; then
    echo "INFO: Chaining disabled (NO_CHAIN=1); not submitting next job."
    exit 0
fi

CURRENT_IDX=-1
for i in "${!NODE_COUNTS[@]}"; do
    if [[ "${NODE_COUNTS[$i]}" -eq "${nnodes}" ]]; then
        CURRENT_IDX=$i
        break
    fi
done

NEXT_IDX=$(( CURRENT_IDX + 1 ))

if [[ ${CURRENT_IDX} -ge 0 && ${NEXT_IDX} -lt ${#NODE_COUNTS[@]} ]]; then
    NEXT_NODES=${NODE_COUNTS[$NEXT_IDX]}
    echo "INFO: Scaling sweep: ${nnodes} -> ${NEXT_NODES} nodes. Submitting next job."

    # Get the script's directory to ensure consistent PBS_O_WORKDIR across chained jobs
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

    if [[ -n "${PBS_NODEFILE}" ]]; then
        # PBS submission - cd to script directory so PBS_O_WORKDIR is consistent
        (cd "${SCRIPT_DIR}" && qsub -N "${JOB_NAME}" \
             -A Intel-Punchlist \
             -l "nodes=${NEXT_NODES}" \
             -l walltime=00:30:00 \
             -l filesystems=home \
             -v "PREV_JOBID=${JOBID},PREV_JOB_NAME=${JOB_NAME},SCRIPT_TO_RUN=${SCRIPT_TO_RUN},NODE_COUNTS=${NODE_COUNTS_STR},NO_CHAIN=${NO_CHAIN}" \
             "$0")
    elif [[ -n "${SLURM_NODELIST}" ]]; then
        # SLURM submission
        sbatch --nodes="${NEXT_NODES}" \
               --job-name="${JOB_NAME}" \
               --export="PREV_JOBID=${JOBID},PREV_JOB_NAME=${JOB_NAME},SCRIPT_TO_RUN=${SCRIPT_TO_RUN},NODE_COUNTS=${NODE_COUNTS_STR},NO_CHAIN=${NO_CHAIN}" \
               "$0"
    fi
elif [[ ${CURRENT_IDX} -ge 0 ]]; then
    # Last node count in sweep — no more jobs to submit
    echo "INFO: Scaling sweep complete at ${nnodes} nodes."
    echo "INFO: Output files for this final job will remain in ${WORKDIR}/"
    echo "INFO: Run cleanup_pbs_files.sh manually to move them if needed."
else
    echo "WARN: nnodes=${nnodes} not in NODE_COUNTS=(${NODE_COUNTS[*]}); no chain submitted."
fi
