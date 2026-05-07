foreach(benchmark
    osu_allgather
    osu_allgatherv
    osu_allreduce
    osu_alltoall
    osu_alltoallv
    osu_alltoallw
    osu_barrier
    osu_bcast
    osu_gather
    osu_gatherv
    osu_reduce
    osu_reduce_scatter
    osu_reduce_scatter_block
    osu_scatter
    osu_scatterv)
    add_mpi_benchmark(${benchmark} ${CMAKE_CURRENT_SOURCE_DIR})
endforeach()
