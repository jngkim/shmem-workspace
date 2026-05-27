#!/bin/bash
################################################################################
# cleanup_pbs_files.sh - Move PBS output files to organized result directories
#
# Purpose: After a scaling study completes, move remaining PBS .o/.e files
#          into results/${CLUSTER}/${JOB_NAME}.${JOBID}/ directories.
#
# Usage:
#   ./cleanup_pbs_files.sh [pattern]
#
# Examples:
#   ./cleanup_pbs_files.sh                    # Move all *.o* and *.e* files
#   ./cleanup_pbs_files.sh "debug.scale.*"    # Move only debug.scale.* files
#   ./cleanup_pbs_files.sh "nail.*"           # Move only nail.* files
#
################################################################################

PATTERN="${1:-*}"

if [[ ! -f "${HOME}/shmem-workspace/config.sh" ]]; then
    echo "ERROR: Cannot source config.sh; expected at ${HOME}/shmem-workspace/config.sh"
    exit 1
fi
source "${HOME}/shmem-workspace/config.sh"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "${SCRIPT_DIR}"

echo "INFO: Looking for PBS output files matching: ${PATTERN}.[oe]*"
echo "INFO: Cluster=${CLUSTER}"

moved_count=0

# Process all matching .o and .e files
for ext in o e; do
    for file in ${PATTERN}.${ext}*; do
        # Skip if glob didn't match anything
        [[ -f "${file}" ]] || continue

        # Extract job name and job ID from filename
        # Format: JOBNAME.{o,e}JOBID
        if [[ "${file}" =~ ^(.+)\.${ext}([0-9]+)$ ]]; then
            job_name="${BASH_REMATCH[1]}"
            job_id="${BASH_REMATCH[2]}"

            result_dir="${SCRIPT_DIR}/results/${CLUSTER}/${job_name}.${job_id}"
            mkdir -p "${result_dir}"

            mv "${file}" "${result_dir}/" && {
                echo "INFO: Moved ${file} -> ${result_dir}/"
                ((moved_count++))
            }
        else
            echo "WARN: Skipping file with unexpected format: ${file}"
        fi
    done
done

if [[ ${moved_count} -eq 0 ]]; then
    echo "INFO: No files found to move."
else
    echo "INFO: Moved ${moved_count} file(s)."
fi
