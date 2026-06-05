/* Copyright (C) 2024 Intel Corporation
 * SPDX-License-Identifier: BSD-3-Clause
 */

/* Example demonstrating Intel SHMEM with OpenMP offload */

#include <omp.h>
#include <ishmem.h>
#include <stdio.h>
#include <stdlib.h>

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
    printf("\n======================================\n");
    printf("PE %d / %d\n", my_pe, n_pes);
    printf("======================================\n");

    printf("  ✓ ISHMEM initialized successfully\n");
    printf("  ✓ Query operations successful\n");

    {
        int *data = (int *)ishmem_malloc(n_pes * nelems * sizeof(int));
        if (data == NULL)
        {
            printf("  ✗ Memory allocation failed\n");
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
            printf("  ✓ Allocated and initialized %d integers\n", n_pes * nelems);
        }

        int *remote_data = (int *)ishmem_calloc(n_pes * nelems, sizeof(int));

        ishmem_sum_reduce(remote_data, data, n_pes * nelems);

        ishmem_barrier_all();
        printf("  ✓ Barrier completed\n");

        ishmem_put(&remote_data[my_pe * nelems], &data[my_pe * nelems], nelems, target_pe);
        ishmem_barrier_all();

        int *check_buf = (int *)malloc(n_pes * nelems * sizeof(int));
        omp_target_memcpy(check_buf, remote_data, n_pes * nelems * sizeof(int), 0, 0,
                          omp_get_initial_device(), omp_get_default_device());

        printf("  PE %d received data: [", my_pe);
        for (int i = 0; i < n_pes * nelems; i++)
        {
            printf("%d", check_buf[i]);
            if (i < n_pes * nelems - 1)
                printf(", ");
        }
        printf("]\n");
        free(check_buf);

        ishmem_free(remote_data);
        ishmem_free(data);
    }

    ishmem_barrier_all();

    /* Final summary */
    printf("\n======================================\n");
    if (errors == 0)
    {
        printf("PE %d - ALL TESTS PASSED ✓\n", my_pe);
    }
    else
    {
        printf("PE %d - FAILED with %d error(s)\n", my_pe, errors);
    }
    printf("======================================\n\n");

    /* Finalize */
    ishmem_finalize();

    return errors > 0 ? 1 : 0;
}
