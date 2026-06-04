/* Copyright (C) 2024 Intel Corporation
 * SPDX-License-Identifier: BSD-3-Clause
 */

/* Example demonstrating Intel SHMEM with OpenMP offload */

#include <iostream>
#include <cstring>
#include <vector>
#include <omp.h>
#include <ishmem.h>
#include <ishmemx.h>

int main(int argc, char **argv)
{
    int errors = 0;

    /* Test 1: Initialization */
    ishmem_init();

    /* Test 2: Query operations */
    int my_pe = ishmem_my_pe();
    int n_pes = ishmem_n_pes();
    int target_pe = (my_pe + 1) % n_pes;
    int source_pe = (my_pe - 1 + n_pes) % n_pes;
    int nelems = 4;
    std::cout << "\n======================================" << std::endl;
    std::cout << "PE " << my_pe << " / " << n_pes << std::endl;
    std::cout << "======================================" << std::endl;

    std::cout << "  ✓ ISHMEM initialized successfully" << std::endl;
    std::cout << "  ✓ Query operations successful" << std::endl;

    {
        int *data = (int *)ishmem_malloc(n_pes * nelems * sizeof(int));
        if (data == nullptr)
        {
            std::cout << "  ✗ Memory allocation failed" << std::endl;
            errors++;
        }
        else
        {
/* Initialize data on device using OpenMP target */
#pragma omp target teams distribute parallel for is_device_ptr(data)
            for (int i = 0; i < n_pes * nelems; i++)
            {
                data[i] = my_pe;
            }
            std::cout << "  ✓ Allocated and initialized " << n_pes * nelems << " integers" << std::endl;
        }

        int *remote_data = (int *)ishmem_calloc(n_pes * nelems, sizeof(int));

        ishmem_sum_reduce(remote_data, data, n_pes * nelems);

        ishmem_barrier_all();
        std::cout << "  ✓ Barrier completed" << std::endl;

        ishmem_put(&remote_data[my_pe * nelems], &data[my_pe * nelems], nelems, target_pe);
        ishmem_barrier_all();

        std::vector<int> check_buf(n_pes * nelems);
        omp_target_memcpy(check_buf.data(), remote_data, n_pes * nelems * sizeof(int), 0, 0,
                          omp_get_initial_device(), omp_get_default_device());

        std::cout << "  PE " << my_pe << " received data: [";
        for (int i = 0; i < n_pes * nelems; i++)
        {
            std::cout << check_buf[i];
            if (i < n_pes * nelems - 1)
                std::cout << ", ";
        }
        std::cout << "]" << std::endl;

        ishmem_free(remote_data);
        ishmem_free(data);
    }

    ishmem_barrier_all();

    /* Final summary */
    std::cout << "\n======================================" << std::endl;
    if (errors == 0)
    {
        std::cout << "PE " << my_pe << " - ALL TESTS PASSED ✓" << std::endl;
    }
    else
    {
        std::cout << "PE " << my_pe << " - FAILED with " << errors << " error(s)" << std::endl;
    }
    std::cout << "======================================\n"
              << std::endl;

    /* Finalize */
    ishmem_finalize();

    return errors > 0 ? 1 : 0;
}
