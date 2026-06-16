#define BENCHMARK "Nail Random: OpenSHMEM Fetching Atomic + Dependent Put Test"
/*
 * cust_nail_random_bucket — bucketed put + optional AMO benchmark
 *
 * The src buffer is divided into npes buckets of send_count = send_bytes /
 * sizeof(long) longs each. The bucket for destination dest_pe is at
 * src[dest_pe * send_count]. The main loop runs OSHM_LOOP_ATOMIC * send_count
 * iterations, packing one element per step into the appropriate src_bucket.
 * When a bucket fills (every send_count steps to the same destination PE), a
 * put is issued.
 *
 * When call_amo=1, a fetching atomic add to a per-destination counter on the
 * remote PE precedes each put. The value returned by the AMO (old_value)
 * selects the remote slot (old_value % DST_SLOTS), creating a true
 * read-after-write (RAW) dependency that serializes the put on the AMO result.
 *
 * When call_amo=0 (baseline), a local counter selects the remote slot,
 * measuring raw bucketed put throughput without AMO overhead.
 *
 * All PEs participate; there is no initiator/target split. After the timed
 * loop each PE contributes its rate and latency to a global sum-reduce.
 * Reported throughput is the aggregate across all PEs; reported latency is the
 * per-PE average.
 *
 * Usage:
 *   cust_nail_random <heap|global> [random_dest] [call_amo]
 *                                  [min_bytes] [max_bytes]
 *
 *   random_dest  0|1. When 1, each put targets a PE chosen uniformly at
 *                random. When 0, the fixed ring neighbor is used. Default: 0.
 *
 *   call_amo     0|1. When 1, a fetching atomic add precedes every put,
 *                creating an AMO->put RAW dependency. Default: 0.
 *
 *   min_bytes    Minimum put size in bytes. Must be a positive multiple of 8.
 *                Default: 8.
 *
 *   max_bytes    Maximum put size in bytes. Must be a positive multiple of 8.
 *                The benchmark sweeps sizes doubling from min_bytes up to
 *                max_bytes. Defaults to min_bytes (single size) when omitted.
 *
 * Examples:
 *   cust_nail_random heap              -- 8-byte puts, ring neighbor, no AMO
 *   cust_nail_random heap 1 0          -- random dest, no AMO
 *   cust_nail_random heap 1 1          -- random dest with AMO dependency
 *   cust_nail_random heap 0 0 8 4096   -- size sweep 8..4096, ring, no AMO
 *   cust_nail_random heap 1 1 64 64    -- single 64-byte size, random + AMO
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

#define FIELD_WIDTH       20
#define FLOAT_PRECISION   2
#define HEADER            "# " BENCHMARK "\n"
#define OSHM_LOOP_ATOMIC  2000
#define DEFAULT_MIN_BYTES 8
#define DST_SLOTS         1024
#define MAX_BYTES_LIMIT                                                        \
    (SIZE_MAX /                                                                \
     DST_SLOTS) /* ensures DST_SLOTS * max_bytes cannot overflow size_t */

static inline double TIME(void)
{
    struct timeval tv;
    if (gettimeofday(&tv, NULL)) {
        perror("gettimeofday");
        abort();
    }
    return ((double)tv.tv_sec) * 1e6 + tv.tv_usec;
}

#ifndef MEMORY_SELECTION
#define MEMORY_SELECTION 1
#endif

// #define SHOW_INFO
// #define ALLTOALL

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

struct pe_vars init_openshmem(void)
{
    struct pe_vars v;

    shmem_init();
    v.me = shmem_my_pe();
    v.npes = shmem_n_pes();
    v.pairs = v.npes / 2;
    v.nxtpe = v.me < v.pairs ? v.me + v.pairs : v.me - v.pairs;

#ifdef SHOW_INFO
    {
        char hostname[64];
        gethostname(hostname, sizeof(hostname));
        int corenum = sched_getcpu();
        printf("[%s:%d] PE[%d]->PE[%d] \n", hostname, corenum, v.me, v.nxtpe);
        fflush(stdout);
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
        if (me == 0)
            fprintf(stderr, "%s: invalid integer '%s'\n", name, s);
        shmem_global_exit(EXIT_FAILURE);
    }
    return v;
}

static void print_usage(int myid)
{
    if (myid == 0) {
        if (MEMORY_SELECTION) {
            fprintf(stderr, "Usage: cust_nail_random <heap|global> [call_amo] "
                            "[random_dest] [min_bytes] [max_bytes]\n");
            fprintf(stderr, "  call_amo    0|1, enable fetching AMO before put "
                            "(default 0)\n");
            fprintf(stderr, "  random_dest 0|1, randomize destination PE "
                            "(default 0, uses ring neighbor)\n");
            fprintf(stderr,
                    "  min_bytes   minimum put size, multiple of 8 "
                    "(default %d)\n",
                    DEFAULT_MIN_BYTES);
            fprintf(stderr,
                    "  max_bytes   maximum put size, multiple of 8 "
                    "(default: same as min_bytes); sweep doubles min to max\n");
        } else {
            fprintf(stderr, "Usage: cust_nail_random [call_amo] "
                            "[random_dest] [min_bytes] [max_bytes]\n");
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

void print_header_local(int myid, int call_amo, int random_dest)
{
    if (myid == 0) {
        fprintf(stdout, "\n");
        fprintf(stdout, HEADER);
        fprintf(stdout, "# random_dest: %d, amo: %d\n", random_dest, call_amo);
        fprintf(stdout, "%-*s%*s%*s%*s\n", 20, "# Size (bytes)", FIELD_WIDTH,
                "Operation", FIELD_WIDTH, "Million ops/s", FIELD_WIDTH,
                "Latency (us)");
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
        fprintf(stdout, "%-*zu%*s%*.*f%*.*f\n", 20, bytes, FIELD_WIDTH,
                "benchmark_nail", FIELD_WIDTH, FLOAT_PRECISION, rate,
                FIELD_WIDTH, FLOAT_PRECISION, lat);
        fflush(stdout);
    }
}

void print_statistics(int me, int *dest_count, int npes)
{
    if (me == 0) {
        fprintf(stdout, "\nDestination PE distribution:\n");
        for (int i = 0; i < npes; i++) {
            fprintf(stdout, "PE %d: %d\n", i, dest_count[i]);
        }
        fflush(stdout);
    }
}

void benchmark_nail(struct pe_vars v, unsigned long iterations, int call_amo,
                    int random_dest, size_t send_bytes, long *src, long *dst,
                    long *buffer, int print_stats)
{
    double begin, end;
    int i;

    /* shmem_double_sum_reduce requires symmetric addresses; stack variables are
     * not symmetric */
    double *rate = shmem_malloc(sizeof(double));
    double *sum_rate = shmem_malloc(sizeof(double));
    double *lat = shmem_malloc(sizeof(double));
    double *sum_lat = shmem_malloc(sizeof(double));
    int *dest_count = shmem_calloc(v.npes, sizeof(int));

    if (!rate || !sum_rate || !lat || !sum_lat || !dest_count) {
        fprintf(stderr, "shmem_malloc failed for reduce buffers (pe: %d)\n",
                v.me);
        shmem_global_exit(EXIT_FAILURE);
    }
    *rate = *sum_rate = *lat = *sum_lat = 0.0;

    size_t send_count = send_bytes / sizeof(long);

    shmem_barrier_all();

    {
        long value = 1;
        long old_value = 0;

        begin = TIME();
        for (i = 0; i < iterations * send_count; i++) {
            int dest_pe = (random_dest) ? (int)(rand() % v.npes) : v.nxtpe;
            int local_count = dest_count[dest_pe] % send_count;
            long *src_bucket = &src[dest_pe * send_count];

            if (local_count < send_count) {
                src_bucket[local_count] = v.me; // pack src to send
                local_count++;
            }

            if (local_count == send_count) { // bucket is full
                if (call_amo) {
                    old_value = shmem_atomic_fetch_add(&(buffer[dest_pe]),
                                                       value, dest_pe);
                } else {
                    old_value = dest_count[dest_pe];
                }
                size_t put_slot = old_value % DST_SLOTS;
                shmem_long_put(&dst[put_slot * send_count], src_bucket,
                               send_count, dest_pe);
            }
            dest_count[dest_pe]++;
        }
        end = TIME();

        *rate = ((double)iterations * 1e6) / (end - begin);
        *lat = (end - begin) / (double)iterations;
    }

    shmem_double_sum_reduce(SHMEM_TEAM_WORLD, sum_rate, rate, 1);
    shmem_double_sum_reduce(SHMEM_TEAM_WORLD, sum_lat, lat, 1);
    if (print_stats)
        print_operation_rate(v.me, send_bytes, *sum_rate / 1e6,
                             *sum_lat / v.npes);

    shmem_free(dest_count);
    shmem_free(rate);
    shmem_free(sum_rate);
    shmem_free(lat);
    shmem_free(sum_lat);
}

void benchmark(struct pe_vars v, union data_types *msg_buffer, int call_amo,
               int random_dest, size_t min_bytes, size_t max_bytes)
{
    srand(v.me);

    if (max_bytes > SIZE_MAX / DST_SLOTS) {
        if (v.me == 0)
            fprintf(stderr,
                    "max_bytes %zu would overflow DST_SLOTS * max_bytes\n",
                    max_bytes);
        shmem_global_exit(EXIT_FAILURE);
    }

    long max_slots = DST_SLOTS;

    long *src = (long *)shmem_malloc(max_bytes * v.npes);
    long *dst = (long *)shmem_malloc(max_slots * max_bytes);
    long *buffer = (long *)shmem_malloc(v.npes * sizeof(long));

    if (!src || !dst || !buffer) {
        fprintf(stderr, "allocation failed (pe: %d)\n", v.me);
        shmem_global_exit(EXIT_FAILURE);
    }

    //warmup
    memset(dst, 0, max_slots * max_bytes);
    memset(buffer, 0, v.npes * sizeof(long));
    benchmark_nail(v, OSHM_LOOP_ATOMIC, call_amo, random_dest, max_bytes, src,
                   dst, buffer, 0);

    for (size_t bytes = min_bytes; bytes < max_bytes; bytes *= 2) {
        memset(buffer, 0, v.npes * sizeof(long));
        memset((void *)dst, 0, max_slots * bytes);
        benchmark_nail(v, OSHM_LOOP_ATOMIC, call_amo, random_dest, bytes, src,
                       dst, buffer, 1);
        if (bytes > SIZE_MAX / 2)
            break;
    }
    /* always run max_bytes: covers min==max, exact power-of-two multiples, and
     * non-power-of-two ranges */
    memset(buffer, 0, v.npes * sizeof(long));
    memset((void *)dst, 0, max_slots * max_bytes);
    benchmark_nail(v, OSHM_LOOP_ATOMIC, call_amo, random_dest, max_bytes, src,
                   dst, buffer, 1);

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

    long raw_random_dest =
        (argc >= 2 + arg_off) ?
            parse_long(v.me, argv[1 + arg_off], "random_dest") :
            0;
    long raw_amo = (argc >= 3 + arg_off) ?
                       parse_long(v.me, argv[2 + arg_off], "call_amo") :
                       0;
    long raw_min = (argc >= 4 + arg_off) ?
                       parse_long(v.me, argv[3 + arg_off], "min_bytes") :
                       DEFAULT_MIN_BYTES;
    long raw_max = (argc >= 5 + arg_off) ?
                       parse_long(v.me, argv[4 + arg_off], "max_bytes") :
                       raw_min;

    if (raw_min <= 0 || raw_min % 8 != 0) {
        if (v.me == 0)
            fprintf(stderr, "min_bytes must be a positive multiple of 8\n");
        shmem_global_exit(EXIT_FAILURE);
    }
    if (raw_max <= 0 || raw_max % 8 != 0) {
        if (v.me == 0)
            fprintf(stderr, "max_bytes must be a positive multiple of 8\n");
        shmem_global_exit(EXIT_FAILURE);
    }
    if (raw_max < raw_min) {
        if (v.me == 0)
            fprintf(stderr, "max_bytes must be >= min_bytes\n");
        shmem_global_exit(EXIT_FAILURE);
    }
    if (raw_max > MAX_BYTES_LIMIT) {
        if (v.me == 0)
            fprintf(stderr,
                    "max_bytes must be <= %zu (would overflow DST_SLOTS * "
                    "max_bytes)\n",
                    MAX_BYTES_LIMIT);
        shmem_global_exit(EXIT_FAILURE);
    }

    int call_amo = (int)raw_amo;
    int random_dest = (int)raw_random_dest;
    size_t min_bytes = (size_t)raw_min;
    size_t max_bytes = (size_t)raw_max;

    print_header_local(v.me, call_amo, random_dest);

    benchmark(v, msg_buffer, call_amo, random_dest, min_bytes, max_bytes);

    if (use_heap)
        shmem_free(msg_buffer);

    shmem_finalize();
    return EXIT_SUCCESS;
}
