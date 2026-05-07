foreach(benchmark
    osu_bibw
    osu_bw
    osu_latency
    osu_latency_mp
    osu_mbw_mr
    osu_multi_lat
  )
    add_mpi_benchmark(${benchmark} ${CMAKE_CURRENT_SOURCE_DIR})
endforeach()

# osu_latency_mt requires pthreads
add_executable(osu_latency_mt ${CMAKE_CURRENT_SOURCE_DIR}/osu_latency_mt.c)
target_include_directories(osu_latency_mt PRIVATE ${UTIL_DIR})
target_link_libraries(osu_latency_mt PRIVATE osu_mpi_util MPI::MPI_C Threads::Threads)
