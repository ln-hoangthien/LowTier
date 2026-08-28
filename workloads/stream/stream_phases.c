/*
 * STREAM Micro-Phasing Benchmark for Tiered Memory
 *
 * Designed to evaluate tiered memory migration across distinct phases:
 * 1. Natural Spillover Footprint: Exceeds Fast Node 0, naturally spilling over
 *    into Slow Node 1 without any synthetic memory binding.
 * 2. Phase-Based Working Set Shifts: Cycles through active working sets sequentially
 *    to trigger tiered memory demotion and promotion.
 * 3. Randomized Page Indirection: Shuffles 4KB page access order via Fisher-Yates
 *    to break hardware prefetchers and expose true memory access latency.
 * 4. STREAM Triad Kernel (a = b * scalar + c): Continuous read/write traffic across A, B, and C.
 * 5. Parallel OpenMP Execution: Dynamic scheduling across OpenMP threads.
 * 6. Optional Migration Delay: Configurable microsecond delay between passes.
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <math.h>
#include <float.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <omp.h>

#define DEFAULT_NUM_PHASES          4096
#define DEFAULT_TOTAL_GB            25.0
#define DEFAULT_PASSES_PER_PHASE    50
#define DEFAULT_NTIMES              (DEFAULT_NUM_PHASES * 2)
#define DEFAULT_DELAY_US            500 // Default microsecond delay (0 us = max speed)
#define ELEMENTS_PER_PAGE           512 // 512 * 8 bytes = 4096 bytes (4KB page)
#define SCAN_ELEMENTS               512

typedef double STREAM_TYPE;

void *alloc_anonymous(size_t bytes) {
    void *ptr = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (ptr == MAP_FAILED) return NULL;
    return ptr;
}

double mysecond() {
    struct timeval tp;
    gettimeofday(&tp, NULL);
    return ((double) tp.tv_sec + (double) tp.tv_usec * 1.e-6);
}

int main() {
#ifdef NUM_THREADS
    if (getenv("OMP_NUM_THREADS") == NULL) {
        omp_set_num_threads(NUM_THREADS);
    }
#endif

    int num_phases = DEFAULT_NUM_PHASES;
    double total_target_gb = DEFAULT_TOTAL_GB;
    int passes_per_phase = DEFAULT_PASSES_PER_PHASE;
    int ntimes = DEFAULT_NTIMES;
    int delay_us = DEFAULT_DELAY_US;
    int scan_elements = SCAN_ELEMENTS;

    if (getenv("STREAM_TOTAL_GB") != NULL) {
        total_target_gb = atof(getenv("STREAM_TOTAL_GB"));
        if (total_target_gb <= 0.0) total_target_gb = DEFAULT_TOTAL_GB;
    }
    if (getenv("STREAM_NUM_PHASES") != NULL) {
        num_phases = atoi(getenv("STREAM_NUM_PHASES"));
        if (num_phases <= 0) num_phases = DEFAULT_NUM_PHASES;
    }
    if (getenv("PASSES_PER_PHASE") != NULL) {
        passes_per_phase = atoi(getenv("PASSES_PER_PHASE"));
        if (passes_per_phase <= 0) passes_per_phase = DEFAULT_PASSES_PER_PHASE;
    }
    if (getenv("NTIMES") != NULL) {
        ntimes = atoi(getenv("NTIMES"));
        if (ntimes <= 0) ntimes = DEFAULT_NTIMES;
    }
    if (getenv("STREAM_DELAY_US") != NULL) {
        delay_us = atoi(getenv("STREAM_DELAY_US"));
        if (delay_us < 0) delay_us = 0;
    }
    if (getenv("SCAN_ELEMENTS") != NULL) {
        scan_elements = atoi(getenv("SCAN_ELEMENTS"));
        if (scan_elements < 0) scan_elements = 0;
    }

    int total_delay_us = delay_us;

    double phase_target_gb = total_target_gb / (double)num_phases;
    size_t array_bytes = (size_t)((phase_target_gb / 3.0) * 1024.0 * 1024.0 * 1024.0);
    size_t stream_array_size = (array_bytes / (sizeof(STREAM_TYPE) * ELEMENTS_PER_PAGE)) * ELEMENTS_PER_PAGE;
    size_t num_pages = stream_array_size / ELEMENTS_PER_PAGE;
    array_bytes = stream_array_size * sizeof(STREAM_TYPE);

    double actual_phase_gb = (double)(stream_array_size * sizeof(STREAM_TYPE) * 3) / (1024.0 * 1024.0 * 1024.0);
    double actual_total_gb = actual_phase_gb * num_phases;

    printf("==================================================================================\n");
    printf(" STREAM Micro-Phasing Benchmark (Pure C - NO mbind)\n");
    printf(" OpenMP Threads       : %d (Max Cores - 2 reserved for tiering)\n", omp_get_max_threads());
    printf(" Total Footprint      : %.2f GB (Anonymous heap - Natural Node 1 Spillover)\n", actual_total_gb);
    printf(" Number of Phases     : %d Rotating Working Sets\n", num_phases);
    printf(" Per-Phase Working Set: %.2f GB (%zu 4KB pages per array)\n", actual_phase_gb, num_pages);
    printf(" Phase Pass Density   : %d Passes per Phase Shift\n", passes_per_phase);
    printf(" Total Phase Shifts   : %d Cycles\n", ntimes);
    printf(" Read-Write Gap Delay : %.3f ms (%d us) (Kernel migration determination window)\n", (double)total_delay_us / 1000.0, total_delay_us);
    printf(" Access Pattern       : Randomized Page Indirection (0%% HW Prefetch Efficiency)\n");
    printf(" Kernel Operation     : STREAM Triad a[p] = b[p] * scalar + c[p]\n");
    printf("==================================================================================\n\n");

    STREAM_TYPE **a = (STREAM_TYPE **) malloc(num_phases * sizeof(STREAM_TYPE *));
    STREAM_TYPE **b = (STREAM_TYPE **) malloc(num_phases * sizeof(STREAM_TYPE *));
    STREAM_TYPE **c = (STREAM_TYPE **) malloc(num_phases * sizeof(STREAM_TYPE *));

    if (!a || !b || !c) {
        printf("Error: Failed to allocate array pointer tables!\n");
        return 1;
    }

    for (int p = 0; p < num_phases; p++) {
        a[p] = (STREAM_TYPE *) alloc_anonymous(array_bytes);
        b[p] = (STREAM_TYPE *) alloc_anonymous(array_bytes);
        c[p] = (STREAM_TYPE *) alloc_anonymous(array_bytes);

        if (!a[p] || !b[p] || !c[p]) {
            printf("Error: Memory allocation failed for Phase %d!\n", p);
            return 1;
        }
    }

    // Pre-generate shuffled page permutation table to destroy hardware prefetching
    size_t *page_order = (size_t *) malloc(num_pages * sizeof(size_t));
    if (!page_order) {
        printf("Error: Failed to allocate page permutation table!\n");
        return 1;
    }
    for (size_t i = 0; i < num_pages; i++) page_order[i] = i;

    // Fisher-Yates shuffle with fixed seed for deterministic reproducibility
    srand(42);
    for (size_t i = num_pages - 1; i > 0; i--) {
        size_t j = (size_t)rand() % (i + 1);
        size_t tmp = page_order[i];
        page_order[i] = page_order[j];
        page_order[j] = tmp;
    }

    printf("Initializing %.2f GB Arrays in parallel (Pure C First-Touch Allocation)...\n", actual_total_gb);
    for (int p = 0; p < num_phases; p++) {
        #pragma omp parallel for
        for (size_t i = 0; i < stream_array_size; i++) {
            a[p][i] = 1.0 + (double)p;
            b[p][i] = 2.0 + (double)p;
            c[p][i] = 0.0;
        }
    }

    STREAM_TYPE scalar = 3.0;
    printf("Initialization complete! Starting Phase Shifts...\n\n");
    printf("%-12s | %-20s | %-16s | %-18s\n", "Cycle", "Active Micro-Phase", "Time (sec)", "App Bandwidth (MB/s)");
    printf("-----------------------------------------------------------------------------------------\n");

    for (int k = 0; k < ntimes; k++) {
        int p = k % num_phases;
        double t0 = mysecond();

        // High-stress random page-hopping loop with heavy multi-thread lock contention:
        for (int pass = 0; pass < passes_per_phase; pass++) {
            size_t pass_offset = (pass * 13) % num_pages;

            #pragma omp parallel for schedule(dynamic, 1)
            for (size_t blk = 0; blk < num_pages; blk++) {
                size_t page_idx = page_order[(blk + pass_offset) % num_pages];
                size_t start_idx = page_idx * ELEMENTS_PER_PAGE;
                size_t num_elements = (scan_elements > 0 && scan_elements <= ELEMENTS_PER_PAGE) ? (size_t)scan_elements : ELEMENTS_PER_PAGE;

                for (size_t j = 0; j < num_elements; j++) {
                    a[p][start_idx + j] = b[p][start_idx + j] * scalar + c[p][start_idx + j];
                }
            }

            if (delay_us > 0) {
                usleep(delay_us);
            }
        }

        double t1 = mysecond();
        double elapsed = t1 - t0;
        double bw_mb = (3.0 * (double)array_bytes * passes_per_phase / (1024.0 * 1024.0)) / elapsed;

        printf("Cycle %3d    | Phase %4d (A%4d, B%4d, C%4d)  | %-10.4f | %-10.2f MB/s\n", 
               k, p, p, p, p, elapsed, bw_mb);
    }

    for (int p = 0; p < num_phases; p++) {
        munmap(a[p], array_bytes);
        munmap(b[p], array_bytes);
        munmap(c[p], array_bytes);
    }
    free(a);
    free(b);
    free(c);
    free(page_order);

    printf("-----------------------------------------------------------------------------------------\n");
    printf("Benchmark Complete!\n");
    return 0;
}
