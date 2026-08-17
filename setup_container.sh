#!/bin/bash
alias lt='ls -lrt'
alias pd=pushd
alias po=popd
alias h=history
alias c=clear
alias rm='rm -i'
groupadd -g 993 render 
source /opt/intel/oneapi/setvars.sh
showme="CXX=icpx CC=icx cmake -S . -B build-docker -DENABLE_MPI=ON -DENABLE_OPENSHMEM=OFF -DBUILD_EXAMPLES=ON -DBUILD_UNIT_TESTS=ON -DDCTEST_LAUNCHER=mpi"
