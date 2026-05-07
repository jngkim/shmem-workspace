foreach(benchmark
    osu_iallgather
    osu_iallgatherv
    osu_iallreduce
    osu_ialltoall
    osu_ialltoallv
    osu_ialltoallw
    osu_ibarrier
    osu_ibcast
    osu_igather
    osu_igatherv
    osu_ireduce
    osu_ireduce_scatter
    osu_ireduce_scatter_block
    osu_iscatter
    osu_iscatterv)
    add_mpi_benchmark(${benchmark} ${CMAKE_CURRENT_SOURCE_DIR})
endforeach()
