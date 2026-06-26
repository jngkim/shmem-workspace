#!/bin/bash

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
    local out_dir="$1"
    local app_tag="$2"
    local app_bin="$3"
    shift 3
    
    for SOS_LIB in "$@"; do
        export CVARS="-genv LD_LIBRARY_PATH=$BASE/install/$SOS_LIB/lib:$LD_LIBRARY_PATH"
        shm_exe="${OSU_BUILD}/openshmem/${app_bin}"
        
        # NIC=8 runs (default CXI mapping, full NICs)
        export NIC_MAPPER=""
        ppn=8
        nranks=$(( nnodes * ppn ))
        put=1
        amo=1
        echo "SOS: N=${nnodes} PPN=${ppn} AMO=${amo} PUT=${put} NIC=8"
        opts="heap ${put} ${amo} ${min_bytes} ${max_bytes}"
        timeout 300 mpirun ${CVARS} -np ${nranks} -ppn ${ppn} ${BINDINGS[$ppn]} ${NIC_MAPPER} ${shm_exe} ${opts} \
          | tee -a "${out_dir}/${SOS_LIB}.nic8.N${nnodes}.p${ppn}.debug.txt"
        
    done
}


# ── Main execution ───────────────────────────────────────────────────────────

app_tag=bucket
app_bin=fadd_put_bucket

declare -ax SOS_LIBS=(sos)
out_dir_top=$out_dir

export SHMEM_DEBUG=1

run_sos_benchmarks "$out_dir_top" "$app_tag" "$app_bin" "${SOS_LIBS[@]}"
