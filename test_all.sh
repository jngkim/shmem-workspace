#!/bin/bash
# Expects the following variables to be set by the caller:
#   LOCAL_WORLD_SIZE, WORLD_SIZE, JOBID, JOB_NAME

source ${HOME}/shmem-workspace/config.sh

TIMESTAMP=$(date +%Y%m%d)
BUILD_BASE=${HOME}/shmem-workspace/build
export OFI_INSTALL=${OFI_INSTALL:-${BUILD_BASE}/latest/install/ofi}
export BASE=${BASE:-${BUILD_BASE}/${JOB_NAME}_${JOBID}.${TIMESTAMP}}
SKIP_SOS_BUILD=${SKIP_SOS_BUILD:-0}
SKIP_SOS_UTEST=${SKIP_SOS_UTEST:-0}
SKIP_ISHMEM_BUILD=${SKIP_ISHMEM_BUILD:-0}
SKIP_ISHMEM_UTEST=${SKIP_ISHMEM_UTEST:-0}

echo "INFO: LOCAL_WORLD_SIZE=${LOCAL_WORLD_SIZE}  WORLD_SIZE=${WORLD_SIZE}  JOBID=${JOBID}  JOB_NAME=${JOB_NAME}"
echo "INFO: BASE=${BASE}  OFI_INSTALL=${OFI_INSTALL}"

if [[ "${SKIP_SOS_BUILD}" == "0" ]] || [[ ! -f ${BASE}/setup_sos_ofi.sh ]]; then
  echo "INFO: Building SOS..."
  bash ${BUILD_BASE}/build_sos.sh
fi

[[ -f ${BASE}/setup_sos_ofi.sh ]] || { echo "ERROR: setup_sos_ofi.sh not found"; exit 1; }
source ${BASE}/setup_sos_ofi.sh

if [[ "${SKIP_SOS_UTEST}" == "0" ]]; then
  cd ${BASE}/sos
  echo "INFO: Running SOS unit tests..."
  echo "INFO: Using SOS_LAUNCHER=${SOS_LAUNCHER}"
  BIND2=${BIND2_S}
  [[ "${WORLD_SIZE}" != "${LOCAL_WORLD_SIZE}" ]] && BIND2=${BIND2_N}
  make -j check TESTS=hello NPROCS=${WORLD_SIZE} \
    TEST_RUNNER="timeout 60 ${SOS_LAUNCHER} -np ${WORLD_SIZE} -ppn ${LOCAL_WORLD_SIZE} ${BIND2}" \
  | tee /tmp/sos_check.log

  SOS_MAKE_EXIT=${PIPESTATUS[0]}
  if [[ ${SOS_MAKE_EXIT} -ne 0 ]]; then
    grep -qP '# PASS:\s+[1-9]' /tmp/sos_check.log || { echo "ERROR: SOS make check failed with 0 passing tests"; exit 1; }
  fi

  make check NPROCS=${WORLD_SIZE} \
    TEST_RUNNER="timeout 60 ${SOS_LAUNCHER} -np ${WORLD_SIZE} -ppn ${LOCAL_WORLD_SIZE} ${BIND2}" \
  | tee /tmp/sos_check.log
fi

cd ${BASE}
if [[ "${SKIP_ISHMEM_BUILD}" == "0" ]] || [[ ! -f ${BASE}/setup_ishmem.sh ]]; then
  echo "INFO: Building ISHMEM..."
  bash ${BUILD_BASE}/build_ishmem.sh
fi

[[ -f ${BASE}/setup_ishmem.sh ]] || { echo "ERROR: setup_ishmem.sh not found"; exit 1; }
source ${BASE}/setup_ishmem.sh

if [[ "${SKIP_ISHMEM_UTEST}" == "0" ]]; then
  cd ${BASE}/ishmem
  echo "INFO: Running ISHMEM unit tests with MPI runtime..."
  ISHMEM_RUNTIME=MPI ctest --test-dir test/unit -E scan --timeout 30
  sleep 1

  if [[ "${ENABLE_OPENSHMEM}" -eq 1 ]]; then
    echo "INFO: Running ISHMEM unit tests with OpenSHMEM runtime..."
    ISHMEM_RUNTIME=OPENSHMEM ctest --test-dir test/unit -E scan --timeout 30
  fi
fi
