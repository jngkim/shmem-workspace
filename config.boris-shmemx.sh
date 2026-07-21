#!/bin/bash
# node gcc (SUSE Linux) 7.5.0
# Load modules to use Cray SHMEM
# Currently Loaded Modules:
#  1) cray-pals/1.4.0      3) libfabric/1.22.0          5) craype-x86-spr           7) craype/2.7.19      9) net/ofi/1.0/cray-openshmemx/11.5.6
#  2) cray-libpals/1.4.0   4) oneapi/release/2025.3.1   6) perftools-base/22.09.0   8) cray-dsmml/0.2.2  10) comnet/gnu/8.0/ofi/1.0/cray-mpich/8.1.22

export MPICH_CC=gcc
ml load craype/2.7.19
ml load cray-dsmml
ml use -a /opt/cray/pe/lmod/modulefiles
ml load net/ofi/1.0/cray-openshmemx/11.5.6
ml load comnet/gnu/8.0/ofi/1.0/cray-mpich/8.1.22


export SMA_ROOT=/opt/cray/pe/sma/11.5.6/ofi/sma
export DSMML_ROOT=/opt/cray/pe/dsmml/0.2.2/dsmml
export PMI_ROOT=/opt/cray/pe/pmi/6.1.7

export PKG_CONFIG_PATH=${SMA_ROOT}/lib/pkgconfig:${DSMML_ROOT}/lib/pkgconfig:$PKG_CONFIG_PATH
export LD_LIBRARY_PATH=${SMA_ROOT}/lib64:${PMI_ROOT}/lib:${DSMML_ROOT}/lib:$LD_LIBRARY_PATH
export LIBRARY_PATH=${SMA_ROOT}/lib64:${PMI_ROOT}/lib:${DSMML_ROOT}/lib:$LIBRARY_PATH
export CPATH=${SMA_ROOT}/include:${PMI_ROOT}/include:${DSMML_ROOT}/include:$CPATH

export SHMEM_USE_DSMML_SSHEAP=0
export PALS_PMI=pmi

# Force to use only one NIC per socket
# export SHMEM_DEBUG_LEVEL=2
# export SHMEM_DEBUG_CATEGORIES=nic
# export SHMEM_OFI_NIC_POLICY=USER
# export SHMEM_OFI_NIC_MAPPING="0:0-3;4:4-7"

