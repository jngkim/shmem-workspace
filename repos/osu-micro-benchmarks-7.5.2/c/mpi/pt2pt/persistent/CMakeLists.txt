foreach(benchmark
    osu_bibw_persistent
    osu_bw_persistent
    osu_latency_persistent)
    add_mpi_benchmark(${benchmark} ${CMAKE_CURRENT_SOURCE_DIR})
endforeach()
