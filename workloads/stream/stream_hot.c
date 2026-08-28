/*
 * STREAM Hot-Block 4-Phase Tiering Benchmark (Pure Standard C / POSIX - NO mbind)
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <math.h>
#include <float.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <omp.h>

#define DEFAULT_NUM_PHASES 8
#define DEFAULT_TOTAL_GB 18.0
#define DEFAULT_REPEATS_PER_PHASE 35
#define DEFAULT_NTIMES 40
#define ELEMENTS_PER_PAGE 512

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
    int repeats_per_phase = DEFAULT_REPEATS_PER_PHASE;
    int ntimes = DEFAULT_NTIMES;

    if (getenv("STREAM_TOTAL_GB") != NULL) {
        total_target_gb = atof(getenv("STREAM_TOTAL_GB"));
        if (total_target_gb <= 0.0) total_target_gb = DEFAULT_TOTAL_GB;
    }
    if (getenv("REPEATS_PER_PHASE") != NULL) {
        repeats_per_phase = atoi(getenv("REPEATS_PER_PHASE"));
        if (repeats_per_phase <= 0) repeats_per_phase = DEFAULT_REPEATS_PER_PHASE;
    }
    if (getenv("NTIMES") != NULL) {
        ntimes = atoi(getenv("NTIMES"));
        if (ntimes <= 0) ntimes = DEFAULT_NTIMES;
    }

    double phase_target_gb = total_target_gb / (double)num_phases;
    size_t array_bytes = (size_t)((phase_target_gb / 3.0) * 1024.0 * 1024.0 * 1024.0);
    size_t stream_array_size = (array_bytes / (sizeof(STREAM_TYPE) * ELEMENTS_PER_PAGE)) * ELEMENTS_PER_PAGE;
    size_t num_pages = stream_array_size / ELEMENTS_PER_PAGE;
    array_bytes = stream_array_size * sizeof(STREAM_TYPE);

    double actual_phase_gb = (double)(stream_array_size * sizeof(STREAM_TYPE) * 3) / (1024.0 * 1024.0 * 1024.0);
    double actual_total_gb = actual_phase_gb * num_phases;

    printf("==================================================================================\n");
    printf(" STREAM Hot-Block Worsened-Latency Benchmark (Pure C - NO mbind)\n");
    printf(" OpenMP Threads       : %d (Max Cores - 2 reserved for tiering)\n", omp_get_max_threads());
    printf(" Total Footprint      : %.2f GB (Anonymous heap - Natural Spillover)\n", actual_total_gb);
    printf(" Number of Hot Blocks : %d Blocks\n", num_phases);
    printf(" Per-Block Footprint  : %.2f GB (%zu 4KB pages per array)\n", actual_phase_gb, num_pages);
    printf(" Repeats per Phase    : %d Random Passes\n", repeats_per_phase);
    printf(" Total Phase Shifts   : %d Cycles\n", ntimes);
    printf("==================================================================================\n\n");

    STREAM_TYPE *a[DEFAULT_NUM_PHASES];
    STREAM_TYPE *b[DEFAULT_NUM_PHASES];
    STREAM_TYPE *c[DEFAULT_NUM_PHASES];

    for (int p = 0; p < num_phases; p++) {
        a[p] = (STREAM_TYPE *) alloc_anonymous(array_bytes);
        b[p] = (STREAM_TYPE *) alloc_anonymous(array_bytes);
        c[p] = (STREAM_TYPE *) alloc_anonymous(array_bytes);

        if (!a[p] || !b[p] || !c[p]) {
            printf("Error: Memory allocation failed for Block %d!\n", p);
            return 1;
        }
    }

    size_t *page_order = (size_t *) malloc(num_pages * sizeof(size_t));
    for (size_t i = 0; i < num_pages; i++) page_order[i] = i;
    srand(42);
    for (size_t i = num_pages - 1; i > 0; i--) {
        size_t j = (size_t)rand() % (i + 1);
        size_t tmp = page_order[i]; page_order[i] = page_order[j]; page_order[j] = tmp;
    }

    printf("Initializing %.2f GB Arrays (Pure C First-Touch)...\n", actual_total_gb);
    for (int p = 0; p < num_phases; p++) {
        #pragma omp parallel for
        for (size_t i = 0; i < stream_array_size; i++) {
            a[p][i] = 1.0 + (double)p;
            b[p][i] = 2.0 + (double)p;
            c[p][i] = 0.0;
        }
    }

    STREAM_TYPE scalar = 3.0;
    printf("Initialization complete! Starting Worsened Hot-Block Shifts...\n\n");
    printf("%-12s | %-24s | %-16s | %-18s\n", "Cycle", "Active Target Block", "Time (sec)", "App Bandwidth (MB/s)");
    printf("-----------------------------------------------------------------------------------------\n");

    for (int k = 0; k < ntimes; k++) {
        int p = k % num_phases;
        double t0 = mysecond();

        for (int rep = 0; rep < repeats_per_phase; rep++) {
            size_t pass_offset = (rep * 13) % num_pages;
            #pragma omp parallel for schedule(dynamic, 1)
            for (size_t blk = 0; blk < num_pages; blk++) {
                size_t page_idx = page_order[(blk + pass_offset) % num_pages];
                size_t start_idx = page_idx * ELEMENTS_PER_PAGE;

                for (size_t j = 0; j < ELEMENTS_PER_PAGE; j++) {
                    STREAM_TYPE val = a[p][start_idx + j] * 1.00001 + b[p][start_idx + j];
                    a[p][start_idx + j] = val;
                    b[p][start_idx + j] = val * 0.99999;
                    c[p][start_idx + j] += val * scalar;
                }
            }
        }

        double t1 = mysecond();
        double elapsed = t1 - t0;
        double bw_mb = (3.0 * (double)array_bytes * repeats_per_phase / (1024.0 * 1024.0)) / elapsed;

        printf("Cycle %3d     | Hot Block %d (A%d, B%d, C%d)  | %-16.4f | %-18.2f MB/s <--- HIGH STALL OVERHEAD\n", 
               k, p, p, p, p, elapsed, bw_mb);
    }

    for (int p = 0; p < num_phases; p++) {
        munmap(a[p], array_bytes);
        munmap(b[p], array_bytes);
        munmap(c[p], array_bytes);
    }
    free(page_order);

    printf("-----------------------------------------------------------------------------------------\n");
    printf("Hot-Block Benchmark Complete!\n");
    return 0;
}
