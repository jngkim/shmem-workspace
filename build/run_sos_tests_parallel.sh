#!/bin/bash
#
# Run many SOS tests concurrently, each as an independent `mpirun -np NPROCS`
# job.  `make check` runs one binary at a time; this fans them out under a
# concurrency cap so a full suite finishes in a fraction of the wall time.
#
# Each job:
#   - runs in its own TMPDIR so concurrent shm/PMI files never collide
#   - is killed after TIMEOUT seconds (a hung SHMEM job spins forever)
#   - writes its stdout+stderr to LOGDIR/<name>.log
# A PASS/FAIL/TIMEOUT summary is printed at the end; exit code is nonzero if
# any test failed.
#
# Usage:
#   ./run_tests_parallel.sh [test-dir ...]
#
# Env knobs (all optional):
#   NPROCS   ranks per test          (default 2)
#   JOBS     concurrent test jobs    (default: cores / (NPROCS*2), min 1)
#   TIMEOUT  per-test seconds        (default 120)
#   LOGDIR   where per-test logs go  (default $BUILD/test-logs)
#   BUILD    SOS build dir           (default: this script's ../build/sos)
#   FILTER   only run tests whose name matches this grep -E pattern
#
set -u

WS=/mnt/data0/nfs/pdx/home/jeongnim/shmem-workspace
BUILD=${BUILD:-${WS}/build/sos}
NPROCS=${NPROCS:-2}
TIMEOUT=${TIMEOUT:-120}
LOGDIR=${LOGDIR:-${BUILD}/test-logs}

# Runtime env that makes the shm build work (no HMEM; see debug notes).
export SHMEM_OFI_PROVIDER=${SHMEM_OFI_PROVIDER:-shm}
export OSHRUN_LAUNCHER=${OSHRUN_LAUNCHER:-mpirun}

# Default concurrency: leave headroom so the 2 hard-polling ranks per job
# don't oversubscribe. cores / (NPROCS*2).
CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || grep -c ^processor /proc/cpuinfo)
if [ -z "${JOBS:-}" ]; then
    JOBS=$(( CORES / (NPROCS * 2) ))
    [ "${JOBS}" -lt 1 ] && JOBS=1
fi

# Test search roots: args, or the standard unit + shmemx dirs.
if [ "$#" -gt 0 ]; then
    ROOTS=("$@")
else
    ROOTS=("${BUILD}/modules/tests-sos/test/unit"
           "${BUILD}/modules/tests-sos/test/shmemx")
fi

# Collect executable ELF test binaries (skip shell/python wrappers, .o, libs).
mapfile -t TESTS < <(
    find "${ROOTS[@]}" -maxdepth 1 -type f -executable 2>/dev/null \
    | while read -r f; do
        case "$f" in *.sh|*.py|*.o|*.la) continue;; esac
        # keep only ELF executables
        read -r magic < <(head -c 4 "$f" | od -An -tx1 | tr -d ' ')
        [ "$magic" = "7f454c46" ] && echo "$f"
      done | sort
)

if [ -n "${FILTER:-}" ]; then
    mapfile -t TESTS < <(printf '%s\n' "${TESTS[@]}" | grep -E "${FILTER}")
fi

if [ "${#TESTS[@]}" -eq 0 ]; then
    echo "No test binaries found under: ${ROOTS[*]}" >&2
    exit 2
fi

mkdir -p "${LOGDIR}"
echo "SOS parallel test run"
echo "  build   : ${BUILD}"
echo "  tests   : ${#TESTS[@]}"
echo "  ranks   : ${NPROCS}   concurrency: ${JOBS}   (cores: ${CORES})"
echo "  timeout : ${TIMEOUT}s   logs: ${LOGDIR}"
echo "  provider: ${SHMEM_OFI_PROVIDER}"
echo

# Runner for a single test. Invoked in a subshell by xargs; must be exported.
run_one() {
    local bin="$1"
    local name; name=$(basename "$bin")
    local log="${LOGDIR}/${name}.log"
    # Per-job scratch so concurrent shm/PMI files never collide.
    local jobtmp; jobtmp=$(mktemp -d "${TMPDIR:-/tmp}/sostest.${name}.XXXXXX")

    TMPDIR="${jobtmp}" timeout --kill-after=5 "${TIMEOUT}" \
        mpirun -np "${NPROCS}" "${bin}" > "${log}" 2>&1
    local rc=$?

    rm -rf "${jobtmp}"

    if [ "${rc}" -eq 0 ]; then
        echo "PASS ${name}"
    elif [ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ]; then
        echo "TIMEOUT ${name} (${TIMEOUT}s)"
    else
        echo "FAIL ${name} (rc=${rc})  -> ${log}"
    fi
}
export -f run_one
export LOGDIR NPROCS TIMEOUT SHMEM_OFI_PROVIDER OSHRUN_LAUNCHER

# Fan out with a hard concurrency cap. Results stream as jobs finish.
RESULTS=$(printf '%s\n' "${TESTS[@]}" \
    | xargs -P "${JOBS}" -I{} bash -c 'run_one "$@"' _ {})

echo "${RESULTS}"
echo
echo "==================== SUMMARY ===================="
p=$(grep -c '^PASS '    <<<"${RESULTS}")
f=$(grep -c '^FAIL '    <<<"${RESULTS}")
t=$(grep -c '^TIMEOUT ' <<<"${RESULTS}")
echo "PASS=${p}  FAIL=${f}  TIMEOUT=${t}  TOTAL=${#TESTS[@]}"
if [ "${f}" -gt 0 ] || [ "${t}" -gt 0 ]; then
    echo
    echo "Failures/timeouts:"
    grep -E '^(FAIL|TIMEOUT) ' <<<"${RESULTS}"
    exit 1
fi
exit 0
