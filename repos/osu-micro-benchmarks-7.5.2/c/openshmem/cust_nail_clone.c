#define BENCHMARK "Nail Clone: OpenSHMEM Fetching Atomic + Dependent Put Test"
/*
 * cust_nail_clone — contention-configurable put + AMO benchmark
 *
 * Usage:
 *   cust_nail_clone <heap|global> [put_contention_pct] [amo_contention_pct]
 *                                 [min_bytes] [max_bytes]
 *
 *   put_contention_pct  0-100. Percentage of puts that target slot 0 on PE 0
 *                       (hot/contended). Remaining puts target the fixed ring
 *                       neighbor (default) or rotate all-to-all (#define ALLTOALL).
 *                       Default: 0.
 *
 *   amo_contention_pct  0-100. Percentage of AMOs that target buffer[0] on
 *                       PE 0 (hot/contended). Remaining AMOs target the fixed
 *                       ring neighbor (default) or rotate all-to-all
 *                       (#define ALLTOALL).  Default: 0.
 *
 *   min_bytes           Minimum put size in bytes. Must be a multiple of 8.
 *                       Default: 8.
 *
 *   max_bytes           Maximum put size in bytes. Must be a multiple of 8.
 *                       Sweep doubles from min to max.  Defaults to min_bytes
 *                       (i.e. a single size) when omitted.
 *
 * Examples:
 *   cust_nail_clone heap                    -- 8-byte puts, no contention
 *   cust_nail_clone heap 50 0               -- 50% contended puts, 8-byte
 *   cust_nail_clone heap 100 100            -- fully contended, 8-byte
 *   cust_nail_clone heap 0 0 8 4096         -- size sweep 8..4096, no contention
 *   cust_nail_clone heap 50 0 64 64         -- single 64-byte size, 50% put contention
 *
 * All PEs participate; no pair split.  Contention ratio is exact and
 * deterministic: iteration i is contended when (i % 100) < pct.
 */

#include <shmem.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <limits.h>
#include <stdint.h>
#include <errno.h>
#ifdef SHOW_INFO
#define _GNU_SOURCE
#include <unistd.h>
#include <sched.h>
#endif

#define FIELD_WIDTH     20
#define FLOAT_PRECISION  2
#define HEADER "# " BENCHMARK "\n"
#define OSHM_LOOP_ATOMIC 2000
#define DEFAULT_MIN_BYTES 8
#define DST_SLOTS 1024
#define MAX_BYTES_LIMIT (SIZE_MAX / DST_SLOTS)  /* ensures DST_SLOTS * max_bytes cannot overflow size_t */

static inline double TIME(void)
{
    struct timeval tv;
    if (gettimeofday(&tv, NULL)) { perror("gettimeofday"); abort(); }
    return ((double)tv.tv_sec) * 1e6 + tv.tv_usec;
}

#ifndef MEMORY_SELECTION
#define MEMORY_SELECTION 1
#endif

//#define SHOW_INFO
//#define ALLTOALL

struct pe_vars {
    int me;
    int npes;
    int pairs;
    int nxtpe;
};

union data_types {
    int int_type;
    long long_type;
    long long longlong_type;
    float float_type;
    double double_type;
} global_msg_buffer[OSHM_LOOP_ATOMIC];

#ifdef USE_DEPRECATED_API
double pwrk1[_SHMEM_REDUCE_MIN_WRKDATA_SIZE];
double pwrk2[_SHMEM_REDUCE_MIN_WRKDATA_SIZE];

long psync1[_SHMEM_REDUCE_SYNC_SIZE];
long psync2[_SHMEM_REDUCE_SYNC_SIZE];
#endif

struct pe_vars init_openshmem(void)
{
    struct pe_vars v;

    shmem_init();
    v.me   = shmem_my_pe();
    v.npes = shmem_n_pes();
    v.pairs = v.npes / 2;
    v.nxtpe = v.me < v.pairs ? v.me + v.pairs : v.me - v.pairs;

#ifdef SHOW_INFO
    {
        char hostname[64];
        gethostname(hostname, sizeof(hostname));
        int corenum = sched_getcpu();
        printf("[%s:%d] PE[%d]->PE[%d] \n", hostname, corenum, v.me, v.nxtpe); fflush(stdout);
    }
#endif

    return v;
}

static long parse_long(int me, const char *s, const char *name)
{
    char *end;
    errno = 0;
    long v = strtol(s, &end, 10);
    if (errno != 0 || end == s || *end != '\0') {
        if (me == 0) fprintf(stderr, "%s: invalid integer '%s'\n", name, s);
        shmem_global_exit(EXIT_FAILURE);
    }
    return v;
}

static void print_usage(int myid)
{
    if (myid == 0) {
        if (MEMORY_SELECTION) {
            fprintf(stderr, "Usage: cust_nail_clone <heap|global> [put_contention_pct] [amo_contention_pct] [min_bytes] [max_bytes]\n");
            fprintf(stderr, "  put_contention_pct  0-100, %% of puts targeting the hot PE (default 0)\n");
            fprintf(stderr, "  amo_contention_pct  0-100, %% of AMOs targeting the hot PE (default 0)\n");
            fprintf(stderr, "  min_bytes           minimum put size, multiple of 8 (default %d)\n", DEFAULT_MIN_BYTES);
            fprintf(stderr, "  max_bytes           maximum put size, multiple of 8 (default: same as min_bytes); sweep doubles min to max\n");
        } else {
            fprintf(stderr, "Usage: cust_nail_clone [put_contention_pct] [amo_contention_pct] [min_bytes] [max_bytes]\n");
        }
    }
}

void check_usage(int me, int npes, int argc, char *argv[])
{
#if MEMORY_SELECTION
    if (argc < 2 || argc > 6) {
        print_usage(me);
        shmem_global_exit(EXIT_FAILURE);
    }
    if (strncmp(argv[1], "heap", 10) && strncmp(argv[1], "global", 10)) {
        print_usage(me);
        shmem_global_exit(EXIT_FAILURE);
    }
#else
    if (argc > 5) {
        print_usage(me);
        shmem_global_exit(EXIT_FAILURE);
    }
#endif

    if (2 > npes) {
        if (0 == me)
            fprintf(stderr, "This test requires at least two processes\n");
        shmem_global_exit(EXIT_FAILURE);
    }
    if (npes % 2 != 0) {
        if (0 == me)
            fprintf(stderr, "This test requires an even number of processes\n");
        shmem_global_exit(EXIT_FAILURE);
    }
}

void print_header_local(int myid, int put_contention_pct, int amo_contention_pct)
{
    if (myid == 0) {
        fprintf(stdout, "\n");
        fprintf(stdout, HEADER);
        fprintf(stdout, "# put_contention_pct: %d, amo_contention_pct: %d \n", put_contention_pct, amo_contention_pct);
        fprintf(stdout, "%-*s%*s%*s%*s\n", 20, "# Size (bytes)", FIELD_WIDTH, "Operation",
                FIELD_WIDTH, "Million ops/s", FIELD_WIDTH, "Latency (us)");
        fflush(stdout);
    }
}

union data_types *allocate_memory(int me, int use_heap)
{
    union data_types *msg_buffer;

    if (!use_heap) {
        return global_msg_buffer;
    }

    msg_buffer = (union data_types *)shmem_malloc(
        sizeof(union data_types[OSHM_LOOP_ATOMIC]));

    if (NULL == msg_buffer) {
        fprintf(stderr, "Failed to shmalloc (pe: %d)\n", me);
        shmem_global_exit(EXIT_FAILURE);
    }

    return msg_buffer;
}

void print_operation_rate(int myid, size_t bytes, double rate, double lat)
{
    if (myid == 0) {
        fprintf(stdout, "%-*zu%*s%*.*f%*.*f\n", 20, bytes, FIELD_WIDTH, "benchmark_nail",
                FIELD_WIDTH, FLOAT_PRECISION, rate, FIELD_WIDTH, FLOAT_PRECISION, lat);
        fflush(stdout);
    }
}

// put_contention_pct: 0-100. Contended puts go to slot 0 on PE 0 (hot). Spread puts go to
// dst[old_value % dst_slots] on the fixed ring neighbor, or all-to-all if #define ALLTOALL.
// amo_contention_pct: 0-100. Contended AMOs hit buffer[0] on PE 0. Spread AMOs hit
// buffer[i % npes] on the fixed ring neighbor, or all-to-all if #define ALLTOALL.
void benchmark_nail(struct pe_vars v, unsigned long iterations,
                    int put_contention_pct, int amo_contention_pct,
                    size_t send_bytes, long *src, long *dst, long *buffer)
{
    double begin, end;
    int i;

    /* shmem_double_sum_reduce requires symmetric addresses; stack variables are not symmetric */
    double *rate     = shmem_malloc(sizeof(double));
    double *sum_rate = shmem_malloc(sizeof(double));
    double *lat      = shmem_malloc(sizeof(double));
    double *sum_lat  = shmem_malloc(sizeof(double));
    if (!rate || !sum_rate || !lat || !sum_lat) {
        fprintf(stderr, "shmem_malloc failed for reduce buffers (pe: %d)\n", v.me);
        shmem_global_exit(EXIT_FAILURE);
    }
    *rate = *sum_rate = *lat = *sum_lat = 0.0;

    size_t send_count = send_bytes / sizeof(long);

    shmem_barrier_all();

    {
        long value = 1;
        long old_value = 0;

        begin = TIME();
        for (i = 0; i < iterations; i++) {
#ifdef ALLTOALL
            int spread_pe = (v.me + 1 + (i % (v.npes - 1))) % v.npes;
#else
            int spread_pe = v.nxtpe;
#endif

            int hot_amo = ((i % 100) < amo_contention_pct);
            int hot_put = ((i % 100) < put_contention_pct);

            int amo_pe   = hot_amo ? 0 : spread_pe;
            int amo_slot = hot_amo ? 0 : (i % v.npes);

            int put_pe = hot_put ? 0 : spread_pe;

            /* fetch-add first; put_slot derived from the returned value */
#ifdef USE_DEPRECATED_API
            old_value = shmem_long_fadd(&(buffer[amo_slot]), value, amo_pe);
#else
            old_value = shmem_atomic_fetch_add(&(buffer[amo_slot]), value, amo_pe);
#endif
            size_t put_slot = hot_put ? 0 : ((size_t)old_value % DST_SLOTS);
            shmem_long_put(&dst[put_slot * send_count], src, send_count, put_pe);
        }
        end = TIME();

        *rate = ((double)iterations * 1e6) / (end - begin);
        *lat  = (end - begin) / (double)iterations;
    }

#ifdef USE_DEPRECATED_API
    shmem_double_sum_to_all(sum_rate, rate, 1, 0, 0, v.npes, pwrk1, psync1);
    shmem_double_sum_to_all(sum_lat,  lat,  1, 0, 0, v.npes, pwrk2, psync2);
#else
    shmem_double_sum_reduce(SHMEM_TEAM_WORLD, sum_rate, rate, 1);
    shmem_double_sum_reduce(SHMEM_TEAM_WORLD, sum_lat,  lat,  1);
#endif

    print_operation_rate(v.me, send_bytes, *sum_rate / 1e6, *sum_lat / v.npes);

    shmem_free(rate);
    shmem_free(sum_rate);
    shmem_free(lat);
    shmem_free(sum_lat);
}

void benchmark(struct pe_vars v, union data_types *msg_buffer,
               int put_contention_pct, int amo_contention_pct,
               size_t min_bytes, size_t max_bytes)
{
    srand(v.me);

    if (max_bytes > SIZE_MAX / DST_SLOTS) {
        if (v.me == 0)
            fprintf(stderr, "max_bytes %zu would overflow DST_SLOTS * max_bytes\n", max_bytes);
        shmem_global_exit(EXIT_FAILURE);
    }

    long *src    = (long *)shmem_malloc(max_bytes);
    long *dst    = (long *)shmem_malloc(DST_SLOTS * max_bytes);
    long *buffer = (long *)shmem_malloc(v.npes * sizeof(long));

    if (!src || !dst || !buffer) {
        fprintf(stderr, "allocation failed (pe: %d)\n", v.me);
        shmem_global_exit(EXIT_FAILURE);
    }

    memset(src, 0, max_bytes);
    memset((void *)dst, 0, DST_SLOTS * max_bytes);
    memset(buffer, 0, v.npes * sizeof(long));

    /* warmup */
    for (unsigned long i = 0; i < OSHM_LOOP_ATOMIC; i++)
        shmem_putmem(&msg_buffer[i].int_type, &msg_buffer[i].int_type,
                     sizeof(int), v.nxtpe);

    for (size_t bytes = min_bytes; bytes < max_bytes; bytes *= 2) {
        memset(buffer, 0, v.npes * sizeof(long));
        memset((void *)dst, 0, DST_SLOTS * bytes);
        benchmark_nail(v, OSHM_LOOP_ATOMIC, put_contention_pct, amo_contention_pct,
                       bytes, src, dst, buffer);
        if (bytes > SIZE_MAX / 2)
            break;
    }
    /* always run max_bytes: covers min==max, exact power-of-two multiples, and non-power-of-two ranges */
    memset(buffer, 0, v.npes * sizeof(long));
    memset((void *)dst, 0, DST_SLOTS * max_bytes);
    benchmark_nail(v, OSHM_LOOP_ATOMIC, put_contention_pct, amo_contention_pct,
                   max_bytes, src, dst, buffer);

    shmem_free(src);
    shmem_free(dst);
    shmem_free(buffer);
}

int main(int argc, char *argv[])
{
    struct pe_vars v;
    union data_types *msg_buffer;
    int use_heap;

    v = init_openshmem();
    check_usage(v.me, v.npes, argc, argv);

#ifdef USE_DEPRECATED_API
    for (int i = 0; i < _SHMEM_REDUCE_SYNC_SIZE; i++) {
        psync1[i] = _SHMEM_SYNC_VALUE;
        psync2[i] = _SHMEM_SYNC_VALUE;
    }
#endif
    shmem_barrier_all();

#if MEMORY_SELECTION
    use_heap = !strncmp(argv[1], "heap", 10);
    int arg_off = 1;
#else
    use_heap = 0;
    int arg_off = 0;
#endif
    msg_buffer = allocate_memory(v.me, use_heap);
    memset(msg_buffer, 0, sizeof(union data_types[OSHM_LOOP_ATOMIC]));

    long raw_put_pct  = (argc >= 2 + arg_off) ? parse_long(v.me, argv[1 + arg_off], "put_contention_pct") : 0;
    long raw_amo_pct  = (argc >= 3 + arg_off) ? parse_long(v.me, argv[2 + arg_off], "amo_contention_pct") : 0;
    long raw_min      = (argc >= 4 + arg_off) ? parse_long(v.me, argv[3 + arg_off], "min_bytes") : DEFAULT_MIN_BYTES;
    long raw_max      = (argc >= 5 + arg_off) ? parse_long(v.me, argv[4 + arg_off], "max_bytes") : raw_min;

    if (raw_put_pct < 0 || raw_put_pct > 100) {
        if (v.me == 0) fprintf(stderr, "put_contention_pct must be 0-100\n");
        shmem_global_exit(EXIT_FAILURE);
    }
    if (raw_amo_pct < 0 || raw_amo_pct > 100) {
        if (v.me == 0) fprintf(stderr, "amo_contention_pct must be 0-100\n");
        shmem_global_exit(EXIT_FAILURE);
    }
    if (raw_min <= 0 || raw_min % 8 != 0) {
        if (v.me == 0) fprintf(stderr, "min_bytes must be a positive multiple of 8\n");
        shmem_global_exit(EXIT_FAILURE);
    }
    if (raw_max <= 0 || raw_max % 8 != 0) {
        if (v.me == 0) fprintf(stderr, "max_bytes must be a positive multiple of 8\n");
        shmem_global_exit(EXIT_FAILURE);
    }
    if (raw_max < raw_min) {
        if (v.me == 0) fprintf(stderr, "max_bytes must be >= min_bytes\n");
        shmem_global_exit(EXIT_FAILURE);
    }
    if (raw_max > MAX_BYTES_LIMIT) {
        if (v.me == 0) fprintf(stderr, "max_bytes must be <= %zu (would overflow DST_SLOTS * max_bytes)\n", MAX_BYTES_LIMIT);
        shmem_global_exit(EXIT_FAILURE);
    }

    int put_contention_pct = (int)raw_put_pct;
    int amo_contention_pct = (int)raw_amo_pct;
    size_t min_bytes       = (size_t)raw_min;
    size_t max_bytes       = (size_t)raw_max;

    print_header_local(v.me, put_contention_pct, amo_contention_pct);

    benchmark(v, msg_buffer, put_contention_pct, amo_contention_pct,
              min_bytes, max_bytes);

    if (use_heap)
        shmem_free(msg_buffer);

    shmem_finalize();
    return EXIT_SUCCESS;
}
