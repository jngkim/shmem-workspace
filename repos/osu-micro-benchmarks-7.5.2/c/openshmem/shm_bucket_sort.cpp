/*
 * parallel_bucket_sort.cpp
 * Parallel bucket sort using OpenSHMEM.
 *
 * Algorithm
 * ---------
 *   1. Each PE generates TOTAL_N/npes random integers in [MIN_VAL, MAX_VAL].
 *   2. Each PE scatters its data: for each element, the owning bucket (PE) is
 *      determined by value range, a slot is atomically claimed there, and the
 *      value is written via shmem_long_p.
 *   3. After a barrier, each PE sorts its local bucket with std::sort.
 *   4. PE 0 gathers all sorted buckets and prints the result.
 *
 * Build:  CC -o parallel_bucket_sort parallel_bucket_sort.cpp
 * Run:    oshrun -n 4 ./parallel_bucket_sort [TOTAL_N [MAX_BUCKET [NITER]]]
 *   TOTAL_N    - total number of elements to sort (default 1024)
 *   MAX_BUCKET - symmetric heap slots per PE     (default 8192)
 *   NITER      - number of timed scatter iterations (default 10)
 */

#include <shmem.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <vector>

static const long MIN_VAL = 0;
static const long MAX_VAL = 999;

/* ── Scatter phase ───────────────────────────────────────────────────────
 * Regenerates local data, resets the symmetric counter, then routes every
 * element to its owning bucket PE via atomic fetch-add + shmem_long_p.
 * Bracketed by barriers so callers can time the full collective operation.
 * ─────────────────────────────────────────────────────────────────────── */
static void run_scatter(long *local, int local_n,
                        long *s_bucket, long *s_count,
                        int max_bucket, int npes, int me)
{
    /* Re-generate input data (deterministic per PE, reproducible each iter). */
    srand((unsigned)(me * 2654435761u ^ 0xdeadbeef));
    for (int i = 0; i < local_n; i++)
        local[i] = MIN_VAL + (long)(rand() % (MAX_VAL - MIN_VAL + 1));

    /* Reset destination counter and synchronise before scatter. */
    *s_count = 0;
    shmem_barrier_all();

    const long range = MAX_VAL - MIN_VAL + 1;

    for (int i = 0; i < local_n; i++) {
        long v      = local[i];
        int  target = (int)((double)(v - MIN_VAL) / (double)range * npes);
        if (target >= npes) target = npes - 1;   /* clamp MAX_VAL edge case */

        long slot = shmem_long_atomic_fetch_add(s_count, 1L, target);

        if (slot >= max_bucket) {
            fprintf(stderr,
                    "PE %d: bucket overflow on PE %d (slot %ld >= %d). "
                    "Increase MAX_BUCKET.\n",
                    me, target, slot, max_bucket);
            shmem_global_exit(1);
        }

        shmem_long_p(&s_bucket[slot], v, target);
    }

    /* Ensure all remote writes are visible before the caller proceeds. */
    shmem_barrier_all();
}

/* ────────────────────────────────────────────────────────────────────────── */
int main(int argc, char **argv)
{
    shmem_init();
    int me   = shmem_my_pe();
    int npes = shmem_n_pes();

    /* ── Parse user-settable parameters ─────────────────────────────────── */
    int total_n    = (argc > 1) ? atoi(argv[1]) : 1024;
    int max_bucket = (argc > 2) ? atoi(argv[2]) : 8192;
    int niter      = (argc > 3) ? atoi(argv[3]) : 10;

    if (total_n <= 0 || max_bucket <= 0 || niter <= 0) {
        if (me == 0)
            fprintf(stderr,
                    "Usage: %s [TOTAL_N > 0] [MAX_BUCKET > 0] [NITER > 0]\n",
                    argv[0]);
        shmem_finalize();
        return 1;
    }

    /* ── Allocate symmetric memory via shmem_malloc ──────────────────────── */
    long *s_bucket = (long *)shmem_malloc((size_t)max_bucket * sizeof(long));
    long *s_count  = (long *)shmem_malloc(sizeof(long));

    if (!s_bucket || !s_count) {
        fprintf(stderr, "PE %d: shmem_malloc failed\n", me);
        shmem_global_exit(1);
    }

    /* ── 1. Allocate local data buffer (private heap) ───────────────────── */
    int local_n = total_n / npes + (me < total_n % npes ? 1 : 0);
    std::vector<long> local(local_n);

    if (me == 0)
        printf("Sorting %d elements across %d PEs (range [%ld, %ld]), "
               "max_bucket=%d, niter=%d.\n",
               total_n, npes, MIN_VAL, MAX_VAL, max_bucket, niter);

    /* ── 2. Timed scatter loop ───────────────────────────────────────────── */
    double t_min = 1e30, t_max = 0.0, t_sum = 0.0;

    for (int iter = 0; iter < niter; iter++) {
        double t0 = shmem_wtime();
        run_scatter(local.data(), local_n, s_bucket, s_count,
                    max_bucket, npes, me);
        double elapsed = shmem_wtime() - t0;

        if (elapsed < t_min) t_min = elapsed;
        if (elapsed > t_max) t_max = elapsed;
        t_sum += elapsed;
    }

    /* ── 3. Report scatter timing (PE 0) ─────────────────────────────────── */
    if (me == 0)
        printf("Scatter over %d iters: min=%.6f s  avg=%.6f s  max=%.6f s\n",
               niter, t_min, t_sum / niter, t_max);

    /* ── 4. Sort local bucket (last scatter result) ──────────────────────── */
    std::sort(s_bucket, s_bucket + (size_t)(*s_count));

    /* All buckets are now sorted; PE 0 may safely read them. */
    shmem_barrier_all();

    /* ── 5. PE 0 gathers sorted buckets and verifies/prints ─────────────── */
    if (me == 0) {
        std::vector<long> sorted;
        sorted.reserve((size_t)total_n);

        for (int p = 0; p < npes; p++) {
            long cnt = shmem_long_g(s_count, p);
            if (cnt <= 0) continue;

            size_t prev = sorted.size();
            sorted.resize(prev + (size_t)cnt);
            shmem_long_get(sorted.data() + prev, s_bucket, (size_t)cnt, p);
        }

        /* Verify the concatenated sequence is non-decreasing. */
        bool ok = true;
        for (size_t i = 1; i < sorted.size(); i++) {
            if (sorted[i] < sorted[i - 1]) { ok = false; break; }
        }

        printf("Collected %zu elements. Sort correct: %s\n",
               sorted.size(), ok ? "YES" : "NO");

        /* Print first 64 elements as a sanity check. */
        int show = (int)std::min(sorted.size(), (size_t)64);
        printf("First %d values: ", show);
        for (int i = 0; i < show; i++)
            printf("%ld%c", sorted[i], i + 1 < show ? ' ' : '\n');
    }

    /* Ensure PE 0 finishes all remote gets before others free memory. */
    shmem_barrier_all();

    shmem_free(s_bucket);
    shmem_free(s_count);

    shmem_finalize();
    return 0;
}
