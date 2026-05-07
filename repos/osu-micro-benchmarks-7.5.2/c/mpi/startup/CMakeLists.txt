foreach(benchmark osu_hello osu_init)
    add_mpi_benchmark(${benchmark} ${CMAKE_CURRENT_SOURCE_DIR})
endforeach()
