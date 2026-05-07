foreach(benchmark
    osu_allgather_persistent
    osu_allgatherv_persistent
    osu_allreduce_persistent
    osu_alltoall_persistent
    osu_alltoallv_persistent
    osu_alltoallw_persistent
    osu_barrier_persistent
    osu_bcast_persistent
    osu_gather_persistent
    osu_gatherv_persistent
    osu_reduce_persistent
    osu_reduce_scatter_persistent
    osu_scatter_persistent
    osu_scatterv_persistent)
    add_mpi_benchmark(${benchmark} ${CMAKE_CURRENT_SOURCE_DIR})
endforeach()
