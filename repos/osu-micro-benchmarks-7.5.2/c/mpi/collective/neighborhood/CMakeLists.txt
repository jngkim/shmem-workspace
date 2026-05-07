foreach(benchmark
    osu_ineighbor_allgather
    osu_ineighbor_allgatherv
    osu_ineighbor_alltoall
    osu_ineighbor_alltoallv
    osu_ineighbor_alltoallw
    osu_neighbor_allgather
    osu_neighbor_allgatherv
    osu_neighbor_alltoall
    osu_neighbor_alltoallv
    osu_neighbor_alltoallw)
    add_mpi_benchmark(${benchmark} ${CMAKE_CURRENT_SOURCE_DIR})
endforeach()
