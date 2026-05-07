#!/bin/bash
# Load modules to use Cray SHMEM

ml load cray-pe/25.03
ml load cray-dsmml/0.3.1
ml use -a /opt/cray/pe/lmod/modulefiles
ml load net/ofi/1.0/cray-openshmemx/11.7.4

export SMA_ROOT=/opt/cray/pe/sma/11.7.4/ofi/sma
export DSMML_ROOT=/opt/cray/pe/dsmml/0.3.1/dsmml
export PMI_ROOT=/opt/cray/pe/pmi/6.1.15
export LD_LIBRARY_PATH=${SMA_ROOT}/lib64:${PMI_ROOT}/lib:${DSMML_ROOT}/lib:$LD_LIBRARY_PATH

export SHMEM_USE_DSMML_SSHEAP=0
export PALS_PMI=pmi
