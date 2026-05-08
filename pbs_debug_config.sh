#!/bin/bash
#PBS -N cfg_debug
#PBS -l nodes=1
#PBS -l walltime=00:05:00
#PBS -l filesystems=home
#PBS -j oe
#PBS -A Intel-Punchlist
#PBS -q debug
#
# Debug script for config.sh
# Submit: qsub -l filesystems=home -N cfg_debug -q debug pbs_debug_config.sh

echo "========================================"
echo "PBS environment"
echo "========================================"
echo "PBS_O_HOST     = ${PBS_O_HOST}"
echo "PBS_JOBID      = ${PBS_JOBID}"
echo "PBS_QUEUE      = ${PBS_QUEUE}"
echo "PBS_NODEFILE   = ${PBS_NODEFILE}"
cat "${PBS_NODEFILE}"
echo ""

echo "========================================"
echo "Sourcing config.sh"
echo "========================================"
source ${HOME}/shmem-workspace/config.sh
echo ""

echo "========================================"
echo "Detected values"
echo "========================================"
echo "CLUSTER        = ${CLUSTER}"
echo "PLATFORM       = ${PLATFORM}"
echo ""

echo "========================================"
echo "Key env vars set by config.sh"
echo "========================================"
for var in \
    OFI_INSTALL PALS_PMI \
    FI_CXI_OPTIMIZED_MRS FI_CXI_DEFAULT_CQ_SIZE \
    FI_MR_CACHE_MAX_COUNT FI_MR_CACHE_MAX_SIZE \
    SHMEM_BOUNCE_SIZE \
    I_MPI_OFFLOAD I_MPI_OFFLOAD_RDMA \
    MLX5_SCATTER_TO_CQE FI_VERBS_IFACE \
    ZE_FLAT_DEVICE_HIERARCHY ZE_ENABLE_PCI_ID_DEVICE_MAPPING \
    EnableImplicitScaling NEOReadDebugKeys \
    ISHMEM_RUNTIME \
    RenderCompressedBuffersEnabled ISHMEM_ENABLE_DEVICE_ATOMICS UseKmdMigration
do
    if [[ -v ${var} ]]; then
        echo "  ${var} = ${!var}"
    fi
done
echo ""

echo "========================================"
echo "Sanity checks"
echo "========================================"
_fail=0

if [[ "${CLUSTER}" == "unknown" ]]; then
    echo "FAIL: CLUSTER not recognized (PBS_O_HOST=${PBS_O_HOST})"
    _fail=1
else
    echo "PASS: CLUSTER=${CLUSTER}"
fi

if [[ "${PLATFORM}" == "unknown" ]]; then
    echo "FAIL: PLATFORM not set"
    _fail=1
else
    echo "PASS: PLATFORM=${PLATFORM}"
fi

if [[ "${PLATFORM}" == "cray" ]]; then
    if [[ -d "${OFI_INSTALL}" ]]; then
        echo "PASS: OFI_INSTALL exists (${OFI_INSTALL})"
    else
        echo "FAIL: OFI_INSTALL directory not found (${OFI_INSTALL})"
        _fail=1
    fi
fi

if [[ ${_fail} -eq 0 ]]; then
    echo ""
    echo "All checks passed."
else
    echo ""
    echo "One or more checks FAILED."
    exit 1
fi
