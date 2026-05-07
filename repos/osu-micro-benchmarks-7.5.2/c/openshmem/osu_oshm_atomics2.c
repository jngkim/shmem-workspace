#define BENCHMARK "OSU OpenSHMEM Int/Long Atomic Operation Rate Test"
/*
 * Copyright (c) 2002-2025 the Network-Based Computing Laboratory
 * (NBCL), The Ohio State University.
 *
 * Contact: Dr. D. K. Panda (panda@cse.ohio-state.edu)
 *
 * For detailed copyright and licensing information, please refer to the
 * copyright file COPYRIGHT in the top level OMB directory.
 */
/*
mpirun -np 2 -ppn 1 ./osu_oshm_atomics2 heap            # all types, all ops
mpirun -np 2 -ppn 1 ./osu_oshm_atomics2 heap int        # int only, all ops
mpirun -np 2 -ppn 1 ./osu_oshm_atomics2 heap int cswap  # int cswap only
mpirun -np 2 -ppn 1 ./osu_oshm_atomics2 heap long fadd  # longlong fadd only
*/
#include <shmem.h>
#include <osu_util_pgas.h>
#include <string.h>

#ifndef MEMORY_SELECTION
#define MEMORY_SELECTION 1
#endif

/* Supported data types */
#define TYPE_ALL  0
#define TYPE_INT  1
#define TYPE_LONG 2

/* Supported operations */
#define OP_ALL    0
#define OP_FADD   1
#define OP_CSWAP  2
#define OP_SET    3

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

double pwrk1[_SHMEM_REDUCE_MIN_WRKDATA_SIZE];
double pwrk2[_SHMEM_REDUCE_MIN_WRKDATA_SIZE];

long psync1[_SHMEM_REDUCE_SYNC_SIZE];
long psync2[_SHMEM_REDUCE_SYNC_SIZE];

struct pe_vars init_openshmem(void)
{
    struct pe_vars v;

#ifdef OSHM_1_3
    shmem_init();
    v.me = shmem_my_pe();
    v.npes = shmem_n_pes();
#else
    start_pes(0);
    v.me = _my_pe();
    v.npes = _num_pes();
#endif

    v.pairs = v.npes / 2;
    v.nxtpe = v.me < v.pairs ? v.me + v.pairs : v.me - v.pairs;

    return v;
}

static void print_usage(int myid)
{
    if (myid == 0) {
        fprintf(stderr,
                "Usage: osu_oshm_atomics_int <heap|global> [type [op]]\n"
                "\n"
                "  type (optional): int, long  (default: all)\n"
                "  op   (optional): fadd, cswap, set  (default: all)\n"
                "\n"
                "  Examples:\n"
                "    osu_oshm_atomics_int heap\n"
                "    osu_oshm_atomics_int heap int\n"
                "    osu_oshm_atomics_int heap int cswap\n"
                "    osu_oshm_atomics_int heap long fadd\n");
    }
}

static int parse_type(const char *name)
{
    if (strncmp(name, "int",  10) == 0) return TYPE_INT;
    if (strncmp(name, "long", 10) == 0) return TYPE_LONG;
    return -1;
}

static int parse_op(const char *name)
{
    if (strncmp(name, "fadd",  10) == 0) return OP_FADD;
    if (strncmp(name, "cswap", 10) == 0) return OP_CSWAP;
    if (strncmp(name, "set",   10) == 0) return OP_SET;
    return -1;
}

void check_usage(int me, int npes, int argc, char *argv[],
                 int *type_sel, int *op_sel)
{
    if (argc < 2 || argc > 4) {
        print_usage(me);
        exit(EXIT_FAILURE);
    }

    if (strncmp(argv[1], "heap", 10) && strncmp(argv[1], "global", 10)) {
        print_usage(me);
        exit(EXIT_FAILURE);
    }

    *type_sel = TYPE_ALL;
    *op_sel   = OP_ALL;

    if (argc >= 3) {
        *type_sel = parse_type(argv[2]);
        if (*type_sel < 0) {
            if (me == 0)
                fprintf(stderr, "Unknown type '%s'\n", argv[2]);
            print_usage(me);
            exit(EXIT_FAILURE);
        }
    }

    if (argc == 4) {
        *op_sel = parse_op(argv[3]);
        if (*op_sel < 0) {
            if (me == 0)
                fprintf(stderr, "Unknown op '%s'\n", argv[3]);
            print_usage(me);
            exit(EXIT_FAILURE);
        }
    }

    if (2 > npes) {
        if (0 == me)
            fprintf(stderr, "This test requires at least two processes\n");
        exit(EXIT_FAILURE);
    }
}

void print_header_local(int myid)
{
    if (myid == 0) {
        fprintf(stdout, HEADER);
        fprintf(stdout, "%-*s%*s%*s\n", 20, "# Operation", FIELD_WIDTH,
                "Million ops/s", FIELD_WIDTH, "Latency (us)");
        fflush(stdout);
    }
}

union data_types *allocate_memory(int me, int use_heap)
{
    union data_types *msg_buffer;

    if (!use_heap) {
        return global_msg_buffer;
    }

#ifdef OSHM_1_3
    msg_buffer = (union data_types *)shmem_malloc(
        sizeof(union data_types[OSHM_LOOP_ATOMIC]));
#else
    msg_buffer = (union data_types *)shmalloc(
        sizeof(union data_types[OSHM_LOOP_ATOMIC]));
#endif

    if (NULL == msg_buffer) {
        fprintf(stderr, "Failed to shmalloc (pe: %d)\n", me);
        exit(EXIT_FAILURE);
    }

    return msg_buffer;
}

void print_operation_rate(int myid, char *operation, double rate, double lat)
{
    if (myid == 0) {
        fprintf(stdout, "%-*s%*.*f%*.*f\n", 20, operation, FIELD_WIDTH,
                FLOAT_PRECISION, rate, FIELD_WIDTH, FLOAT_PRECISION, lat);
        fflush(stdout);
    }
}

double benchmark_fadd(struct pe_vars v, union data_types *buffer,
                      unsigned long iterations)
{
    double begin, end;
    int i;
    static double rate = 0, sum_rate = 0, lat = 0, sum_lat = 0;

    memset(buffer, CHAR_MAX * drand48(),
           sizeof(union data_types[OSHM_LOOP_ATOMIC]));

    shmem_barrier_all();

    if (v.me < v.pairs) {
        int value = 1;
        int old_value;

        begin = TIME();
        for (i = 0; i < iterations; i++) {
            old_value = shmem_int_fadd(&(buffer[i].int_type), value, v.nxtpe);
        }
        end = TIME();

        rate = ((double)iterations * 1e6) / (end - begin);
        lat = (end - begin) / (double)iterations;
    }

    shmem_double_sum_to_all(&sum_rate, &rate, 1, 0, 0, v.npes, pwrk1, psync1);
    shmem_double_sum_to_all(&sum_lat, &lat, 1, 0, 0, v.npes, pwrk2, psync2);
    print_operation_rate(v.me, "shmem_int_fadd", sum_rate / 1e6,
                         sum_lat / v.pairs);
    return 0;
}

double benchmark_cswap(struct pe_vars v, union data_types *buffer,
                       unsigned long iterations)
{
    double begin, end;
    int i;
    static double rate = 0, sum_rate = 0, lat = 0, sum_lat = 0;

    for (i = 0; i < OSHM_LOOP_ATOMIC; i++) {
        buffer[i].int_type = v.me;
    }

    shmem_barrier_all();

    if (v.me < v.pairs) {
        int cond = v.nxtpe;
        int value = INT_MAX * drand48();
        int old_value;

        begin = TIME();
        for (i = 0; i < iterations; i++) {
            old_value =
                shmem_int_cswap(&(buffer[i].int_type), cond, value, v.nxtpe);
        }
        end = TIME();

        rate = ((double)iterations * 1e6) / (end - begin);
        lat = (end - begin) / (double)iterations;
    }

    shmem_double_sum_to_all(&sum_rate, &rate, 1, 0, 0, v.npes, pwrk1, psync1);
    shmem_double_sum_to_all(&sum_lat, &lat, 1, 0, 0, v.npes, pwrk2, psync2);
    print_operation_rate(v.me, "shmem_int_cswap", sum_rate / 1e6,
                         sum_lat / v.pairs);
    return 0;
}

double benchmark_set(struct pe_vars v, union data_types *buffer,
                     unsigned long iterations)
{
    double begin, end;
    int i;
    static double rate = 0, sum_rate = 0, lat = 0, sum_lat = 0;

    memset(buffer, CHAR_MAX * drand48(),
           sizeof(union data_types[OSHM_LOOP_ATOMIC]));

    shmem_barrier_all();

    if (v.me < v.pairs) {
        int value = 1;

        begin = TIME();
        for (i = 0; i < iterations; i++) {
            shmem_int_set(&(buffer[i].int_type), value, v.nxtpe);
        }
        end = TIME();

        rate = ((double)iterations * 1e6) / (end - begin);
        lat = (end - begin) / (double)iterations;
    }

    shmem_double_sum_to_all(&sum_rate, &rate, 1, 0, 0, v.npes, pwrk1, psync1);
    shmem_double_sum_to_all(&sum_lat, &lat, 1, 0, 0, v.npes, pwrk2, psync2);
    print_operation_rate(v.me, "shmem_int_set", sum_rate / 1e6,
                         sum_lat / v.pairs);
    return 0;
}

double benchmark_fadd_long(struct pe_vars v, union data_types *buffer,
                           unsigned long iterations)
{
    double begin, end;
    int i;
    static double rate = 0, sum_rate = 0, lat = 0, sum_lat = 0;

    memset(buffer, CHAR_MAX * drand48(),
           sizeof(union data_types[OSHM_LOOP_ATOMIC]));

    shmem_barrier_all();

    if (v.me < v.pairs) {
        long long value = 1;
        long long old_value;

        begin = TIME();
        for (i = 0; i < iterations; i++) {
            old_value = shmem_longlong_fadd(&(buffer[i].longlong_type), value, v.nxtpe);
        }
        end = TIME();

        rate = ((double)iterations * 1e6) / (end - begin);
        lat = (end - begin) / (double)iterations;
    }

    shmem_double_sum_to_all(&sum_rate, &rate, 1, 0, 0, v.npes, pwrk1, psync1);
    shmem_double_sum_to_all(&sum_lat, &lat, 1, 0, 0, v.npes, pwrk2, psync2);
    print_operation_rate(v.me, "shmem_longlong_fadd", sum_rate / 1e6,
                         sum_lat / v.pairs);
    return 0;
}

double benchmark_cswap_long(struct pe_vars v, union data_types *buffer,
                            unsigned long iterations)
{
    double begin, end;
    int i;
    static double rate = 0, sum_rate = 0, lat = 0, sum_lat = 0;

    for (i = 0; i < OSHM_LOOP_ATOMIC; i++) {
        buffer[i].longlong_type = v.me;
    }

    shmem_barrier_all();

    if (v.me < v.pairs) {
        long long cond = v.nxtpe;
        long long value = (long long)INT_MAX * drand48();
        long long old_value;

        begin = TIME();
        for (i = 0; i < iterations; i++) {
            old_value = shmem_longlong_cswap(&(buffer[i].longlong_type), cond,
                                             value, v.nxtpe);
        }
        end = TIME();

        rate = ((double)iterations * 1e6) / (end - begin);
        lat = (end - begin) / (double)iterations;
    }

    shmem_double_sum_to_all(&sum_rate, &rate, 1, 0, 0, v.npes, pwrk1, psync1);
    shmem_double_sum_to_all(&sum_lat, &lat, 1, 0, 0, v.npes, pwrk2, psync2);
    print_operation_rate(v.me, "shmem_longlong_cswap", sum_rate / 1e6,
                         sum_lat / v.pairs);
    return 0;
}

double benchmark_set_long(struct pe_vars v, union data_types *buffer,
                          unsigned long iterations)
{
    double begin, end;
    int i;
    static double rate = 0, sum_rate = 0, lat = 0, sum_lat = 0;

    memset(buffer, CHAR_MAX * drand48(),
           sizeof(union data_types[OSHM_LOOP_ATOMIC]));

    shmem_barrier_all();

    if (v.me < v.pairs) {
        long long value = 1;

        begin = TIME();
        for (i = 0; i < iterations; i++) {
            shmem_longlong_set(&(buffer[i].longlong_type), value, v.nxtpe);
        }
        end = TIME();

        rate = ((double)iterations * 1e6) / (end - begin);
        lat = (end - begin) / (double)iterations;
    }

    shmem_double_sum_to_all(&sum_rate, &rate, 1, 0, 0, v.npes, pwrk1, psync1);
    shmem_double_sum_to_all(&sum_lat, &lat, 1, 0, 0, v.npes, pwrk2, psync2);
    print_operation_rate(v.me, "shmem_longlong_set", sum_rate / 1e6,
                         sum_lat / v.pairs);
    return 0;
}

void benchmark(struct pe_vars v, union data_types *msg_buffer,
               int type_sel, int op_sel)
{
    srand(v.me);

    /* Warmup with puts */
    if (v.me < v.pairs) {
        unsigned long i;
        for (i = 0; i < OSHM_LOOP_ATOMIC; i++) {
            shmem_putmem(&msg_buffer[i].int_type, &msg_buffer[i].int_type,
                         sizeof(int), v.nxtpe);
        }
    }

#define RUN(type, op, fn) \
    if ((type_sel == (type) || type_sel == TYPE_ALL) && \
        (op_sel   == (op)   || op_sel   == OP_ALL))  \
        fn(v, msg_buffer, OSHM_LOOP_ATOMIC)

    RUN(TYPE_INT,  OP_FADD,  benchmark_fadd);
    RUN(TYPE_INT,  OP_CSWAP, benchmark_cswap);
    RUN(TYPE_INT,  OP_SET,   benchmark_set);
    RUN(TYPE_LONG, OP_FADD,  benchmark_fadd_long);
    RUN(TYPE_LONG, OP_CSWAP, benchmark_cswap_long);
    RUN(TYPE_LONG, OP_SET,   benchmark_set_long);

#undef RUN
}

int main(int argc, char *argv[])
{
    int i;
    struct pe_vars v;
    union data_types *msg_buffer;
    int use_heap;
    int type_sel, op_sel;

    v = init_openshmem();
    check_usage(v.me, v.npes, argc, argv, &type_sel, &op_sel);

    for (i = 0; i < _SHMEM_REDUCE_SYNC_SIZE; i += 1) {
        psync1[i] = _SHMEM_SYNC_VALUE;
        psync2[i] = _SHMEM_SYNC_VALUE;
    }
    shmem_barrier_all();

    print_header_local(v.me);

    use_heap = !strncmp(argv[1], "heap", 10);
    msg_buffer = allocate_memory(v.me, use_heap);
    memset(msg_buffer, 0, sizeof(union data_types[OSHM_LOOP_ATOMIC]));

    benchmark(v, msg_buffer, type_sel, op_sel);

    if (use_heap) {
#ifdef OSHM_1_3
        shmem_free(msg_buffer);
#else
        shfree(msg_buffer);
#endif
    }

#ifdef OSHM_1_3
    shmem_finalize();
#endif

    return EXIT_SUCCESS;
}
