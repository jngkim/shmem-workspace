
#!/bin/bash

# Usage: source this script to set CPU binding environment variables for MPI runs.
# source cpu_bind.sh [exclude]
# Use BIND variables in mpirun calls to bind ranks to specific cores/sockets.
# - BIND2_C  : bind two ranks to the two halves of socket 0.
# - BIND2_S  : bind two ranks, one per socket.
# - BIND2_N  : alias for BIND2_S (all sockets, split by socket).
# - BIND_ALL : bind all usable cores, one range per socket.
# - BIND1C   : one core per rank (no sharing).
# - BIND2C   : two consecutive cores per rank (hyperthreading).
# - BIND64_N : custom 64-rank binding for Aurora/Borealis (52 cores/socket).
# - BIND8_N  : custom 8-rank binding for Aurora/Borealis (52 cores/socket).
# Each BIND_* variable has a corresponding IMPI_BIND_* variant for Intel MPI.
#
# On Aurora/Borealis, cores 0 and 52 are reserved for the OS; use "exclude":
#   source cpu_bind.sh exclude
#   mpirun -np 64 -ppn 64 ${BIND64_N} ...  # 64 ranks, fair distribution
#   mpirun -np 50 -ppn 50 ${BIND2C} ...    # two cores per rank
#   mpirun -np 102 -ppn 102 ${BIND1C} ...  # one core per rank


# ─── CPU binding derived from lscpu topology ─────────────────────────────────
# Skip core 0 on each socket (typically reserved for OS).
# Socket 0: cores 1..(cps-1), Socket 1: cores (cps+1)..(2*cps-1)
_cps=$(lscpu | awk '/^Core\(s\) per socket:/ {print $NF}')
_s0_half=$(( _cps / 2 ))
_s0_half_end=$(( _cps / 2 - 1 ))
_s0_end=$(( _cps - 1 ))
_s1_start=$(( _cps + 1 ))
_s1_end=$(( 2 * _cps - 1 ))

export BIND2_C="--cpu-bind list:1-${_s0_half_end}:${_s0_half}-${_s0_end}"
export BIND2_S="--cpu-bind list:1-${_s0_end}:${_s1_start}-${_s1_end}"

# For Intel MPI, use default binding except for two-rank cases
export IMPI_BIND2_C="-genv I_MPI_PIN 1 -genv I_MPI_PIN_PROCESSOR_LIST 1-${_s0_half_end},${_s0_half}-${_s0_end}"
export IMPI_BIND2_S="-genv I_MPI_PIN 1 -genv I_MPI_PIN_PROCESSOR_LIST 1-${_s0_end},${_s1_start}-${_s1_end}"

# ── Helpers ───────────────────────────────────────────────────────────────────

# _make_bindings <inclusive> <cps> <nsockets>
#   inclusive=1 : include core 0 of each socket
#   inclusive=0 : exclude core 0 of each socket (default)
# Sets: BIND_ALL, BIND1C, BIND2C, BIND4PS, IMPI_BIND_ALL, IMPI_BIND1C, IMPI_BIND2C, IMPI_BIND4PS
#       BIND4PS : 4 ranks per socket, each on cps/4 consecutive cores, first core of each group excluded
_make_bindings() {
    local inclusive=$1 cps=$2 nsockets=$3
    local c0=1; [[ "${inclusive}" == 1 ]] && c0=0   # first usable core offset

    local all_list="" one_list="" two_list="" four_list=""
    local s c base first last lo hi pairs avail g grp_size
    grp_size=$(( cps / 4 ))

    for (( s=0; s<nsockets; s++ )); do
        base=$(( s * cps ))
        first=$(( base + c0 ))
        last=$(( base + cps - 1 ))

        # BIND_ALL: one range per socket
        [[ -n "${all_list}" ]] && all_list+=":"
        all_list+="${first}-${last}"

        # BIND1C: one core per entry
        for (( c=first; c<=last; c++ )); do
            [[ -n "${one_list}" ]] && one_list+=":"
            one_list+="${c}"
        done

        # BIND2C: pairs, drop unpaired remainder
        avail=$(( last - first + 1 ))
        pairs=$(( avail / 2 ))
        for (( p=0; p<pairs; p++ )); do
            lo=$(( first + p * 2 ))
            hi=$(( lo + 1 ))
            [[ -n "${two_list}" ]] && two_list+=":"
            two_list+="${lo}-${hi}"
        done

        # BIND4PS: 4 ranks per socket, cps/4 cores each, skip first core of each group
        for (( g=0; g<4; g++ )); do
            lo=$(( base + g * grp_size + 1 ))
            hi=$(( base + (g + 1) * grp_size - 1 ))
            [[ -n "${four_list}" ]] && four_list+=":"
            four_list+="${lo}-${hi}"
        done
    done

    export BIND_ALL="--cpu-bind list:${all_list}"
    export BIND1C="--cpu-bind list:${one_list}"
    export BIND2C="--cpu-bind list:${two_list}"
    export BIND4PS="--cpu-bind list:${four_list}"
    export IMPI_BIND_ALL="-genv I_MPI_PIN 1 -genv I_MPI_PIN_PROCESSOR_LIST ${all_list}"
    export IMPI_BIND1C="-genv I_MPI_PIN 1 -genv I_MPI_PIN_PROCESSOR_LIST ${one_list}"
    export IMPI_BIND2C="-genv I_MPI_PIN 1 -genv I_MPI_PIN_PROCESSOR_LIST ${two_list}"
    export IMPI_BIND4PS="-genv I_MPI_PIN 1 -genv I_MPI_PIN_PROCESSOR_LIST ${four_list}"

    # Count entries (colon-separated tokens)
    local IFS=':'
    read -ra _arr <<< "${one_list}"; export BIND1C_MAX=${#_arr[@]}
    read -ra _arr <<< "${two_list}"; export BIND2C_MAX=${#_arr[@]}
    read -ra _arr <<< "${four_list}"; export BIND4PS_MAX=${#_arr[@]}
}



# ── Topology ──────────────────────────────────────────────────────────────────
_nsockets=$(lscpu | awk '/^Socket\(s\):/ {print $NF}')

# Default: exclude core 0 of each socket; pass "inclusive" to include it
_inclusive=1
[[ "${1:-}" == "exclude" ]] && _inclusive=0

_make_bindings "${_inclusive}" "${_cps}" "${_nsockets}"

# Custom binding for 52 cores/socket on Aurora/Borealis with 52 cores per socket
if [[ "${PLATFORM}" == "cray" ]]; then
    export BIND64_N="--cpu-bind list:1,105:3,107:5,109:6,110:7,111:9,113:11,115:12,116:14,118:16,120:18,122:19,123:20,124:22,126:24,128:25,129:27,131:29,133:31,135:32,136:33,137:35,139:37,141:38,142:40,144:42,146:44,148:45,149:46,150:48,152:50,154:51,155:53,157:55,159:57,161:58,162:59,163:61,165:63,167:64,168:66,170:68,172:70,174:71,175:72,176:74,178:76,180:77,181:79,183:81,185:83,187:84,188:85,189:87,191:89,193:90,194:92,196:94,198:96,200:97,201:98,202:100,204:102,206:103,207"
    export BIND8_N="--cpu-bind list:1-12:14-25:27-38:40-51:53-64:66-77:79-90:92-103"
fi

# BIND2_N is an alias for BIND_ALL (all allowed cores, 1 PE per node)
export BIND2_N="${BIND2_S}"
export IMPI_BIND2_N="${IMPI_BIND2_S}"

echo "INFO: cores/socket=${_cps}  sockets=${_nsockets}  inclusive=${_inclusive}"
echo "INFO: BIND2_C=${BIND2_C}"
echo "INFO: BIND2_S=${BIND2_S}"
echo "INFO: BIND2_N=${BIND2_N}"
echo "INFO: BIND_ALL=${BIND_ALL}"
echo "INFO: BIND1C=${BIND1C}  (max ranks: ${BIND1C_MAX})"
echo "INFO: BIND2C=${BIND2C}  (max ranks: ${BIND2C_MAX})"
echo "INFO: BIND4PS=${BIND4PS}  (max ranks: ${BIND4PS_MAX})"

declare -ax PPN_LIST=(64 $BIND2C_MAX $BIND1C_MAX)
declare -Ax BINDINGS
BINDINGS[64]=$BIND64_N
BINDINGS[$BIND2C_MAX]=$BIND2C
BINDINGS[$BIND1C_MAX]=$BIND1C
