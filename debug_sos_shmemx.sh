SHMEM_DEBUG_LEVEL=5 mpirun -np 64 ${BIND64_N} \
  -outfile-pattern shmemx.fadd.N1.rank%r.out \
  -errfile-pattern shmemx.fadd.N1.rank%r.err \
  shmemx/osu_oshm_atomics2 heap int fadd


# FI_LOG_LEVEL=debug mpirun -np 64 ${BIND64_N} \
# -outfile-pattern sos.fadd.N1.rank%r.out \
# -errfile-pattern sos.fadd.N1.rank%r.err \
# openshmem/osu_oshm_atomics2 heap int fadd
