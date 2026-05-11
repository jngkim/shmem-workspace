#!/bin/bash                                                                                                                                      

NNICS=${NNICS:-4}
LOCAL_RANK_ID=${MPI_LOCALRANKID:-${PALS_LOCAL_RANKID}}
LOCAL_WORLD_SIZE=${MPI_LOCALNRANKS:-${PALS_LOCAL_SIZE}}
socket_id=$(( LOCAL_RANK_ID / (LOCAL_WORLD_SIZE / 2 ) ))
cxi_id=$(( socket_id * NNICS ))
export SHMEM_OFI_DOMAIN=cxi${cxi_id}
# Invoke the main program
exec "$@"
