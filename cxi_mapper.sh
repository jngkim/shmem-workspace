#!/bin/bash
# cxi_mapper.sh - Maps each MPI rank to a CXI NIC based on CPU socket affinity.
#
# On a dual-socket node the local ranks are split evenly across the two sockets.
# Ranks on socket 0 are assigned the first NIC group (cxi0), and ranks on
# socket 1 are assigned the second NIC group (cxi<NNICS>). The chosen NIC is
# exported as SHMEM_OFI_DOMAIN so that OpenSHMEM (SOS/ishmem) uses the NIC
# that is closest to the rank's CPU.
#
# Usage: mpirun ... cxi_mapper.sh <program> [args...]
#
# Environment variables:
#   NNICS                                 - number of CXI NICs per node (default: 4)
#   NIC_OFFSET                            - base CXI index offset (default: 0)
#   MPI_LOCALRANKID  / PALS_LOCAL_RANKID  - local rank index within the node
#   MPI_LOCALNRANKS  / PALS_LOCAL_SIZE    - total number of local ranks on the node

# Number of CXI NICs available on this node.
NNICS=${NNICS:-4}

# Optional offset added to the computed CXI index, useful when only a subset
# of NICs should be used (e.g. NIC_OFFSET=2 starts assignment from cxi2).
NIC_OFFSET=${NIC_OFFSET:-0}

# Determine the local rank ID; support both Open MPI (MPI_LOCALRANKID) and
# PALS/Cray MPICH (PALS_LOCAL_RANKID) launchers.
LOCAL_RANK_ID=${MPI_LOCALRANKID:-${PALS_LOCAL_RANKID}}

# Total number of local ranks on this node (used to compute the per-socket split).
LOCAL_WORLD_SIZE=${MPI_LOCALNRANKS:-${PALS_LOCAL_SIZE}}

# Determine which CPU socket owns this rank.
# Assumes ranks are distributed round-robin across 2 sockets, so the first
# half of local ranks belong to socket 0 and the second half to socket 1.
socket_id=$(( LOCAL_RANK_ID / (LOCAL_WORLD_SIZE / 2 ) ))

# Compute the CXI device index: socket 0 -> NIC_OFFSET, socket 1 -> NNICS + NIC_OFFSET.
cxi_id=$(( socket_id * NNICS + NIC_OFFSET ))

# Export the OpenSHMEM OFI domain so the process uses the NIC closest to its socket.
export SHMEM_OFI_DOMAIN=cxi${cxi_id}

# Invoke the main program, passing through all arguments.
exec "$@"
