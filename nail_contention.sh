#!/bin/bash
################################################################################
# OpenSHMEM Contention Benchmark Runner
#
# Purpose: Runs contention-based benchmarks (nail) for SHMEM implementations.
#          Can be used standalone or with pbs_node_scaling.sh for scaling studies.
#
# Usage (standalone):
#   qsub -N nail -l nodes=2 -l filesystems=home pbs_contention.sh
#
# Usage (with scaling framework):
#   export SCRIPT_TO_RUN="${HOME}/shmem-workspace/pbs_contention.sh"
#   qsub -N scaling_study -l nodes=2 -l filesystems=home pbs_node_scaling.sh
#
# Environment variables:
#   NNODES          Override detected node count
#   PPN             Processes per node (default: 2)
#   MIN_BYTES       Minimum message size for benchmarks
#   MAX_BYTES       Maximum message size for benchmarks
#   BASE            Path to SHMEM build (default: ~/shmem-workspace/build/latest)
#   OSU_BUILD       Path to OSU benchmark build
#
################################################################################

#set -x

# ── Detect environment ───────────────────────────────────────────────────────
if [[ -n "${PBS_NODEFILE}" ]]; then
    nnodes_avail=$(wc -l "$PBS_NODEFILE" | awk '{print $1}')
    JOBID=${PBS_JOBID%%.*}
    JOB_NAME=${PBS_JOBNAME:-nail}
    NODEFILE=$PBS_NODEFILE
elif [[ -n "${SLURM_NODELIST}" ]]; then
    nnodes_avail=$(sinfo -N --exact -o %N "$SLURM_NODELIST" | wc -l)
    JOBID=${SLURM_JOB_ID}
    JOB_NAME=${SLURM_JOB_NAME:-nail}
    NODEFILE=$(mktemp)
    sinfo -N --exact -o %N "$SLURM_NODELIST" > "$NODEFILE"
else
    echo "ERROR: Not running under PBS or SLURM."
    exit 1
fi

nnodes=${NNODES:-$nnodes_avail}
LOCAL_WORLD_SIZE=${PPN:-2}
WORLD_SIZE=$(( nnodes * LOCAL_WORLD_SIZE ))
echo "WORLD_SIZE=${WORLD_SIZE} LOCAL_WORLD_SIZE=${LOCAL_WORLD_SIZE}"

TIMESTAMP=$(date +%Y%m%d)

source "${HOME}/shmem-workspace/config.sh"
source "${HOME}/shmem-workspace/cpu_bind.sh" exclude
export BASE=${BASE:-${HOME}/shmem-workspace/build/latest}
OSU_BUILD=${OSU_BUILD:-${HOME}/shmem-workspace/build/osu-bench}
min_bytes=${MIN_BYTES:-1024}
max_bytes=${MAX_BYTES:-8192}

# ── Results directory for this run ───────────────────────────────────────────
out_dir="${HOME}/shmem-workspace/results/${CLUSTER}/${JOB_NAME}.${JOBID}"
mkdir -p "${out_dir}"
env | grep CLUSTER >> "${out_dir}/env.txt"
env | grep PLATFORM >> "${out_dir}/env.txt"
env | grep -E "(SLURM|PBS)" >> "${out_dir}/env.txt"
env | grep FI | grep -v LMOD >> "${out_dir}/env.txt"
cat "$NODEFILE" | cut -d '.' -f 1 | tee -a "${out_dir}/hostfile"

# ── Benchmark functions ──────────────────────────────────────────────────────

run_sos_benchmarks() {
    local out_dir_base="$1"
    local app_tag="$2"
    local app_bin="$3"
    local -n sos_libs_ref="$4"
    
    local out_dir="${out_dir_base}/${app_tag}"
    mkdir -p "${out_dir}"
    
    for SOS_LIB in "${sos_libs_ref[@]}"; do
        export CVARS="-genv LD_LIBRARY_PATH=$BASE/install/$SOS_LIB/lib:$LD_LIBRARY_PATH"
        shm_exe="${OSU_BUILD}/openshmem/${app_bin}"
        
        # NIC=8 runs (default CXI mapping, full NICs)
        export NIC_MAPPER=""
        for ppn in 64 $BIND1C_MAX; do
            nranks=$(( nnodes * ppn ))
            for put in 0 1; do
                for amo in 0 1; do
                    echo "SOS: N=${nnodes} PPN=${ppn} AMO=${amo} PUT=${put} NIC=8"
                    opts="heap ${put} ${amo} ${min_bytes} ${max_bytes}"
                    timeout 300 mpirun ${CVARS} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${NIC_MAPPER} ${shm_exe} ${opts} \
                        | tee -a "${out_dir}/${SOS_LIB}.nic8.N${nnodes}.p${ppn}.dat"
                done
            done
        done
        
        # NIC=2 runs (restricted CXI mapping via cxi_mapper.sh)
        export NIC_MAPPER="${HOME}/shmem-workspace/cxi_mapper.sh"
        for ppn in 64 $BIND1C_MAX; do
            nranks=$(( nnodes * ppn ))
            for put in 0 1; do
                for amo in 0 1; do
                    echo "SOS: N=${nnodes} PPN=${ppn} AMO=${amo} PUT=${put} NIC=2"
                    opts="heap ${put} ${amo} ${min_bytes} ${max_bytes}"
                    timeout 300 mpirun ${CVARS} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${NIC_MAPPER} ${shm_exe} ${opts} \
                        | tee -a "${out_dir}/${SOS_LIB}.nic2.N${nnodes}.p${ppn}.dat"
                done
            done
        done
    done
}

run_shmemx_benchmarks() {
    local out_dir_base="$1"
    local app_tag="$2"
    local app_bin="$3"
    
    local out_dir="${out_dir_base}/${app_tag}"
    mkdir -p "${out_dir}"
    
    source "${HOME}/shmem-workspace/config.cray-shmem.sh"
    shm_exe="${OSU_BUILD}/shmemx/${app_bin}"
    
    # NIC=8 runs (default SHMEMX mapping)
    unset SHMEM_OFI_NIC_POLICY
    for ppn in 64 $BIND1C_MAX; do
        nranks=$(( nnodes * ppn ))
        NVAR=""
        for put in 0 1; do
            for amo in 0 1; do
                echo "SHMEMX: N=${nnodes} PPN=${ppn} AMO=${amo} PUT=${put} NIC=8"
                opts="heap ${put} ${amo} ${min_bytes} ${max_bytes}"
                timeout 300 mpirun ${NVAR} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} ${opts} \
                    | tee -a "${out_dir}/shmemx.nic8.N${nnodes}.p${ppn}.dat"
            done
        done
    done
    
    # NIC=2 runs (restricted SHMEMX mapping)
    export SHMEM_OFI_NIC_POLICY=USER
    for ppn in 64 $BIND1C_MAX; do
        nranks=$(( nnodes * ppn ))
        NVAR="-genv SHMEM_OFI_NIC_MAPPING=0:0-$((ppn/2-1));4:$((ppn/2))-$((ppn-1))"
        for put in 0 1; do
            for amo in 0 1; do
                echo "SHMEMX: N=${nnodes} PPN=${ppn} AMO=${amo} PUT=${put} NIC=2"
                opts="heap ${put} ${amo} ${min_bytes} ${max_bytes}"
                timeout 300 mpirun ${NVAR} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${shm_exe} ${opts} \
                    | tee -a "${out_dir}/shmemx.nic2.N${nnodes}.p${ppn}.dat"
            done
        done
    done
}

# ── Main execution ───────────────────────────────────────────────────────────

declare -ax APP_LIST=(random bucket)
declare -Ax APP_BIN
APP_BIN["random"]=cust_nail_random
APP_BIN["bucket"]=cust_nail_random_bucket

declare -ax SOS_LIBS=(sos sos-xpmem)
out_dir_top=$out_dir

# Application-specific runs
for app_tag in "${APP_LIST[@]}"; do
    app_bin=${APP_BIN[$app_tag]}
    run_sos_benchmarks "$out_dir_top" "$app_tag" "$app_bin" SOS_LIBS
done

# SHMEMX runs (if available)
if [[ "${HAVE_SHMEMX:-0}" -eq 1 ]]; then
    for app_tag in "${APP_LIST[@]}"; do
        app_bin=${APP_BIN[$app_tag]}
        run_shmemx_benchmarks "$out_dir_top" "$app_tag" "$app_bin"
    done
fi
