foreach(benchmark
    osu_acc_latency
    osu_cas_latency
    osu_fop_latency
    osu_get_acc_latency
    osu_get_bw
    osu_get_latency
    osu_put_bibw
    osu_put_bw
    osu_put_latency)
    add_mpi_benchmark(${benchmark} ${CMAKE_CURRENT_SOURCE_DIR})
endforeach()
