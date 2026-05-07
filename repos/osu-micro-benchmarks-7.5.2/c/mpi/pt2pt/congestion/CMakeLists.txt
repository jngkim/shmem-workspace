set(CONG_UTIL ${CMAKE_CURRENT_SOURCE_DIR}/utils/osu_bw_fan_util.c)

foreach(benchmark osu_bw_fan_in osu_bw_fan_out)
    add_executable(${benchmark}
        ${CMAKE_CURRENT_SOURCE_DIR}/${benchmark}.c
        ${CONG_UTIL}
    )
    target_include_directories(${benchmark} PRIVATE
        ${UTIL_DIR}
        ${CMAKE_CURRENT_SOURCE_DIR}/utils
    )
    target_link_libraries(${benchmark} PRIVATE osu_mpi_util MPI::MPI_C)
endforeach()
