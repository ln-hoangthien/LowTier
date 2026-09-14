#include <iostream>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <sys/ioctl.h>
#include <linux/perf_event.h>
#include <asm/unistd.h>
#include <sys/mman.h>
#include <cassert>
#include <pthread.h>
#include <cerrno>
#include <fstream>
#include <iostream>
#include <cstdint>
#include <string>
#include <fstream>
#include <set>
#include <numa.h>
#include <numaif.h>
#include <errno.h>
#include <syscall.h>
#include <chrono>
#include <thread>
#include <cstdint>
#include <iostream>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <math.h> 
// pagemap
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/types.h>
#include <vector>

#include <cstdio>
#include <memory>
#include <stdexcept>
#include <array>
#include <regex>
#include <mutex>
#include <unordered_map>

#include <list>

class ARC {
public:
    // Constructor
    explicit ARC(size_t capacity)
        : c(capacity), p(0) {
        // Lists T1, T2, B1, B2 are empty
        // p is initially 0
        printf("[INFO] ARC cache created with capacity = %ld \n", capacity);
      
        // Used for move_pages() syscall.
        migrate_pages = new int*[1];  // array of pointer, with only 1 element
    }

    int promote_page(uint64_t page_addr) {
      int move_page_ret = 99;
      migrate_nodes[0] = 0; // promote to node 0
      migrate_status[0] = 99;
      uint64_t num_pages_to_migrate = 1;

      migrate_pages[0] = (int*)page_addr;
      move_page_ret = numa_move_pages(0, num_pages_to_migrate, (void **)migrate_pages, migrate_nodes, migrate_status, MPOL_MF_MOVE_ALL);

      return move_page_ret;
    }

    int demote_page(uint64_t page_addr) {
      int move_page_ret = 99;
      migrate_nodes[0] = 1; // demote to node 1
      migrate_status[0] = 99;
      uint64_t num_pages_to_migrate = 1;

      migrate_pages[0] = (int*)page_addr;
      move_page_ret = numa_move_pages(0, num_pages_to_migrate, (void **)migrate_pages, migrate_nodes, migrate_status, MPOL_MF_MOVE_ALL);

      return move_page_ret;
    }

    // Request an item x in the cache
    // Returns true if hit, false if miss
    bool request(uint64_t x) {
        // Case I: x ∈ T1 or T2
        if (inCache(x)) {
            // Cache hit
            if (locationMap[x].second == ListTag::T1) {
                // Move from T1 to front (MRU) of T2
                T1.erase(locationMap[x].first);
                T2.push_front(x);
                locationMap[x] = { T2.begin(), ListTag::T2 };
            } else {
                // x is in T2. Move it to the front of T2 (MRU).
                T2.splice(T2.begin(), T2, locationMap[x].first);
            }
            return true; // hit
        }

        // Case II: x ∈ B1
        if (inB1(x)) {
            // Ghost hit in B1 => miss, but we know x
            size_t sizeB1 = B1.size();
            size_t sizeB2 = B2.size();
            double delta1 = (sizeB1 >= sizeB2)
                                ? 1.0
                                : double(sizeB2) / double(sizeB1 == 0 ? 1 : sizeB1);
            p = std::min(double(p + delta1), double(c));

            replace(x);

            // Move x from B1 to T2
            B1.erase(locationMap[x].first);
            T2.push_front(x);
            locationMap[x] = { T2.begin(), ListTag::T2 };
            // PROMOTE PAGE
            //printf("PROMOTE page case II %lx \n", x);
            int ret = promote_page(x);
            if (!ret) {
              num_promotes++;
            }
            return false;
        }

        // Case III: x ∈ B2
        if (inB2(x)) {
            // Ghost hit in B2 => miss
            size_t sizeB1 = B1.size();
            size_t sizeB2 = B2.size();
            double delta2 = (sizeB2 >= sizeB1)
                                ? 1.0
                                : double(sizeB1) / double(sizeB2 == 0 ? 1 : sizeB2);
            p = std::max(double(p - delta2), 0.0);

            replace(x);

            // Move x from B2 to T2
            B2.erase(locationMap[x].first);
            T2.push_front(x);
            locationMap[x] = { T2.begin(), ListTag::T2 };

            // PROMOTE PAGE
            //printf("PROMOTE page case III %lx \n", x);
            int ret = promote_page(x);
            if (!ret) {
              num_promotes++;
            }
            return false;
        }

        // Case IV: x not in T1, T2, B1, B2 => pure miss
        if (sizeT1() + sizeB1() == c) {
            // If T1 + B1 == c
            if (sizeT1() < c) {
                // Delete LRU in B1
                uint64_t lru = B1.back();
                B1.pop_back();
                locationMap.erase(lru);
                replace(x);
            } else {
                // Delete LRU in T1
                uint64_t lru = T1.back();
                T1.pop_back();
                locationMap.erase(lru);
                // DEMOTE PAGE
                //printf("DEMOTE page case IV 1 %lx \n", lru);
                int ret = demote_page(x);
                if (!ret) {
                  num_demotes++;
                }
            }
        } else if (sizeT1() + sizeB1() < c) {
            if (sizeT1() + sizeT2() + sizeB1() + sizeB2() >= c) {
              if (sizeT1() + sizeT2() + sizeB1() + sizeB2() >= 2 * c) {
                  uint64_t lru = B2.back();
                  B2.pop_back();
                  locationMap.erase(lru);
              }
              replace(x);
            }
        }

        // Finally, bring x into T1 (MRU)
        T1.push_front(x);
        locationMap[x] = { T1.begin(), ListTag::T1 };
        //printf("PROMOTE page case VI %lx \n", x);
        int ret = promote_page(x);
        if (!ret) {
          num_promotes++;
        }

        return false; // miss
    }

    // stats
    void print_stat() { 
      printf("Number of promotes: %ld, demotes: %ld \n", num_promotes, num_demotes);
      printf("T1 %ld, T2 %ld, B1 %ld, B2 %ld \n", sizeT1(), sizeT2(), sizeB1(), sizeB2());
    }

    // Size wrappers
    size_t sizeT1() const { return T1.size(); }
    size_t sizeT2() const { return T2.size(); }
    size_t sizeB1() const { return B1.size(); }
    size_t sizeB2() const { return B2.size(); }

private:
    // REPLACE(x, p)
    void replace(uint64_t x) {
        // If T1 not empty AND (|T1| > p or (x in B2 and |T1| == p))
        // then move LRU from T1 to B1
        // otherwise move LRU from T2 to B2
        if (!T1.empty() &&
            (sizeT1() > size_t(p) || (inB2(x) && sizeT1() == size_t(p)))) {
            uint64_t lru = T1.back();
            T1.pop_back();
            locationMap.erase(lru);

            // DEMOTE PAGE
            //printf("DEMOTE page replace() %lx \n", lru);
            int ret = demote_page(x);
            if (!ret) {
              num_demotes++;
            }

            B1.push_front(lru);
            locationMap[lru] = { B1.begin(), ListTag::B1 };
        } else {
            if (!T2.empty()) {
                uint64_t lru = T2.back();
                T2.pop_back();
                locationMap.erase(lru);

                // DEMOTE PAGE
                //printf("DEMOTE page replace() 2 %lx \n", lru);
                int ret = demote_page(x);
                if (!ret) {
                  num_demotes++;
                }

                B2.push_front(lru);
                locationMap[lru] = { B2.begin(), ListTag::B2 };
            }
        }
    }

    // Helpers to check membership
    bool inCache(uint64_t x) const {
        auto it = locationMap.find(x);
        if (it == locationMap.end()) return false;
        ListTag tag = it->second.second;
        return (tag == ListTag::T1 || tag == ListTag::T2);
    }

    bool inB1(uint64_t x) const {
        auto it = locationMap.find(x);
        return (it != locationMap.end() && it->second.second == ListTag::B1);
    }

    bool inB2(uint64_t x) const {
        auto it = locationMap.find(x);
        return (it != locationMap.end() && it->second.second == ListTag::B2);
    }


private:
    // Cache capacity
    size_t c;
    // Adaptive target for T1
    double p;

    // Lists T1, T2, B1, B2
    std::list<uint64_t> T1;
    std::list<uint64_t> T2;
    std::list<uint64_t> B1;
    std::list<uint64_t> B2;

    // Which list an item resides in
    enum class ListTag { T1, T2, B1, B2 };

    // Key -> (list iterator, which list)
    std::unordered_map<uint64_t, std::pair<std::list<uint64_t>::iterator, ListTag>> locationMap;
    
    // Used for move_pages() syscall.
    int** migrate_pages;
    int migrate_nodes[1] = {-1};
    int migrate_status[1]= {-1};

    // Stats
    uint64_t num_promotes = 0;
    uint64_t num_demotes = 0;
};

//**************************************** 
//********************* Perf related 
//**************************************** 
//#define PERF_PAGES	(1 + (1 << 7))	// Has to be == 1+2^n, 
#define PERF_PAGES	(1 + (1 << 5))	// Has to be == 1+2^n, 
#define NPROC 16
#define NPBUFTYPES 2
#define LOCAL_DRAM_LOAD 0
#define REMOTE_DRAM_LOAD 1

// TinyLFU related
#ifdef FAST_MEMORY_SIZE_GB
uint64_t FAST_MEMORY_SIZE = (FAST_MEMORY_SIZE_GB * (1024L * 1024L * 1024L)); // size of fast tier memory in bytes
#else
uint64_t FAST_MEMORY_SIZE = 0;
#endif

uint64_t PAGE_SIZE = 4096;
uint64_t NUM_FAST_MEMORY_PAGES = FAST_MEMORY_SIZE/PAGE_SIZE;

// 5% of total memory size

uint32_t perf_sample_freq_list[5] = {1001, 1001, 1001, 1001, 100001};

int fd[NPROC][NPBUFTYPES];
static struct perf_event_mmap_page *perf_page[NPROC][NPBUFTYPES];

struct perf_sample {
  struct perf_event_header header;
  __u64 addr;        /* if PERF_SAMPLE_ADDR */
};


void close_perf(){
  std::cout << "closing perf counters" << std::endl;
  for (int i = 0; i < NPROC; i++) {
    for (int j = 0; j < NPBUFTYPES; j++) {
       // disable the event
       if (ioctl(fd[i][j], PERF_EVENT_IOC_DISABLE, 0) == -1) {
           perror("ioctl(PERF_EVENT_IOC_DISABLE)");
       }
       // unmap memory
       if (munmap(perf_page[i][j], sysconf(_SC_PAGESIZE) * PERF_PAGES) == -1) {
           perror("munmap");
       }
       std::cout << "munmap done " << j << std::endl;
       // close the file descriptor
       if (close(fd[i][j]) == -1) {
           perror("close fd");
       }
       std::cout << "close fd done " << j << std::endl;
    }
  }
}

static long
perf_event_open(struct perf_event_attr *hw_event, pid_t pid,
                int cpu, int group_fd, unsigned long flags)
{
    int ret;
    ret = syscall(__NR_perf_event_open, hw_event, pid, cpu,
                   group_fd, flags);
    return ret;
}

 
struct perf_event_mmap_page* perf_setup_one_event(__u64 config, __u64 cpu, __u64 type, __u64 perf_sample_freq) {
    struct perf_event_attr pe;
    memset(&pe, 0, sizeof(pe));

    std::cout << "[INFO] LFU perf sampling freq: " << perf_sample_freq << std::endl;
    //__u64 perf_sample_freq = 400000;

    pe.type = PERF_TYPE_RAW;
    pe.size = sizeof(pe);
    pe.config = config;
    //pe.sample_period = 20;
    pe.sample_type = PERF_SAMPLE_ADDR;
    //pe.disabled = 0;
    pe.disabled = 1;
    //pe.freq = 0;
    pe.freq = 1;
    pe.sample_freq = perf_sample_freq;
    pe.exclude_kernel = 1;
    pe.exclude_hv = 0;
    pe.exclude_callchain_kernel = 1;
    //pe.exclude_callchain_user = 1;
    pe.precise_ip = 1;
    pe.inherit = 1; 
    pe.task = 1; 
    pe.sample_id_all = 1;

    // perf_event_open args: perf_event_attr, pid, cpu, group_fd, flags.
    // pid == 0 && cpu == -1: measures the calling process/thread on any CPU.
    // returns a file descriptor, for use in subsequent system calls.
    // For some reason I cannot configure the perf event to sample from all CPUs.
    //fd = perf_event_open(&pe, 0, -1, -1, 0);
    fd[cpu][type] = perf_event_open(&pe, -1, cpu, -1, 0);
    if (fd[cpu][type] == -1) {
       std::perror("failed");
       fprintf(stderr, "Error opening leader %llx\n", pe.config);
       exit(EXIT_FAILURE);
    }

    size_t mmap_size = sysconf(_SC_PAGESIZE) * PERF_PAGES;

    // mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset)
    // prot: protection. How the page may be used.
    // flags: whether updates to the mapping are visible to other processes mapping the same region.
    // fd: file descriptor.
    // offset: offset into the file.
    struct perf_event_mmap_page *p = (perf_event_mmap_page *)mmap(NULL, mmap_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd[cpu][type], 0);
    if(p == MAP_FAILED) {
      perror("mmap");
      fprintf(stderr, "failed to map memory for cpu %llu, type %llu\n", cpu, type);
      exit(EXIT_FAILURE);  // exit if mmap fails
    }
    assert(p != MAP_FAILED);

    // Enable the event
    if (ioctl(fd[cpu][type], PERF_EVENT_IOC_ENABLE, 0) == -1) {
      perror("ioctl(PERF_EVENT_IOC_ENABLE)");
      exit(EXIT_FAILURE);
    }
    return p;
}


void perf_setup(__u64 perf_sample_freq) {
  for (int i = 0; i < NPROC; i++) {
    perf_page[i][LOCAL_DRAM_LOAD]  = perf_setup_one_event(0x1d3, i, LOCAL_DRAM_LOAD, perf_sample_freq); // MEM_LOAD_L3_MISS_RETIRED.LOCAL_DRAM
    perf_page[i][REMOTE_DRAM_LOAD] = perf_setup_one_event(0x2d3, i, REMOTE_DRAM_LOAD, perf_sample_freq); // MEM_LOAD_L3_MISS_RETIRED.REMOTE_DRAM
  }
}


void close_perf_one_counter(int i, int j){
  std::cout << "closing perf counter " << i << ", " << j << std::endl;
  if (ioctl(fd[i][j], PERF_EVENT_IOC_DISABLE, 0) == -1) {
      perror("ioctl(PERF_EVENT_IOC_DISABLE)");
  }
  if (munmap(perf_page[i][j], sysconf(_SC_PAGESIZE) * PERF_PAGES) == -1) {
      perror("munmap");
  }
  if (close(fd[i][j]) == -1) {
      perror("close fd");
  }
}

void change_perf_freq(int i, int j, __u64 new_sample_freq) {
  close_perf_one_counter(i, j);
  if (j == LOCAL_DRAM_LOAD) {
    perf_page[i][j] = perf_setup_one_event(0x1d3, i, LOCAL_DRAM_LOAD, new_sample_freq);
  } else if (j == REMOTE_DRAM_LOAD) {
    perf_page[i][j] = perf_setup_one_event(0x2d3, i, REMOTE_DRAM_LOAD, new_sample_freq); // MEM_LOAD_L3_MISS_RETIRED.LOCAL_DRAM
  }
}

void start_perf_stat() {
  std::cout << "[INFO] Starting perf stat monitoring." << std::endl;
  // I am using the perf executable instead of perf_event_open to monitor hardware counters
  // because there is no need to use perf_event_open, since the performance overhead of using the perf executable 
  // is negligible. 
  const char* perf_stat_cmd = "/ssd1/songxin8/thesis/autonuma/linux-6.1-rc6/tools/perf/perf stat -I 60000 -e mem_load_l3_miss_retired.local_dram -e mem_load_l3_miss_retired.remote_dram -x , --output perf_stat_file &";
  std::cout << "/ssd1/songxin8/thesis/autonuma/linux-6.1-rc6/tools/perf/perf stat -I 60000 -e mem_load_l3_miss_retired.local_dram -e mem_load_l3_miss_retired.remote_dram -x , --output perf_stat_file &" << std::endl;
  // Launch perf stat in the command line. 
  int ret_code = system(perf_stat_cmd);
  std::cout << "[INFO] perf stat command return code: " << ret_code << std::endl;
}

// Actually no place to call this. Just terminate in experiment script
//void kill_perf_stat() {
//  std::cout << "[INFO] Terminating perf stat." << std::endl;
//  const char* perf_stat_kill_cmd = "kill $(pidof perf)";
//  ret_code = system(perf_stat_kill_cmd);
//  std::cout << "[INFO] perf stat kill command return code: " << ret_code << std::endl;
//}


// higher_or_lower == true: return the next higher sampling frequency
// higher_or_lower == false: return the next lower sampling frequency
uint32_t next_sampling_freq(uint32_t cur_sampling_freq, bool higher_or_lower) {
  uint32_t cur_sampling_freq_index = 0;
  uint32_t perf_sample_freq_list_size = sizeof(perf_sample_freq_list) / sizeof(uint32_t);
  // Find the index of the current sampling frequency
  for (uint32_t i = 0; i < perf_sample_freq_list_size; i++){
    if (perf_sample_freq_list[i] == cur_sampling_freq) {
      cur_sampling_freq_index = i;
    }
  }
  printf("debug: curent index is %d \n", cur_sampling_freq_index);

  //if (cur_sampling_freq_index == -1) {
  //  printf("[ERROR] unknown sampling frequency: %d \n", cur_sampling_freq);
  //}
  if (higher_or_lower == 1){
    // Go up one frequency. If we are at max already, stay at max.
    return (cur_sampling_freq_index == perf_sample_freq_list_size - 1) 
          ? perf_sample_freq_list[cur_sampling_freq_index] 
          : perf_sample_freq_list[cur_sampling_freq_index+1];
  } else {
    // Go down one frequency. If we are at min already, stay at min.
    return (cur_sampling_freq_index == 0) 
          ? perf_sample_freq_list[cur_sampling_freq_index] 
          : perf_sample_freq_list[cur_sampling_freq_index-1];
  }
}


void* perf_func(void*) {


    std::cout << "perf ARC tierng." << std::endl;
    uint64_t fast_memory_size = FAST_MEMORY_SIZE;
    std::cout << "[DEBUG] fast memory size = " << fast_memory_size  << std::endl;
    std::cout << "[DEBUG] number of pages in fast memory = " << NUM_FAST_MEMORY_PAGES << std::endl;
    printf(" perf_pages %d\n", PERF_PAGES);

    pid_t pid = getpid();
    std::cout << "pid: " << pid << std::endl;

    ARC arcCache(NUM_FAST_MEMORY_PAGES); // the cache is the fast tier memory
  
    uint64_t unknown_cnt = 0;
    uint64_t sample_cnt = 0;
    uint64_t num_perf_record_lost = 0;
    uint64_t num_overflow_samples = 0;
    
    uint64_t page_addr;

    __u64 perf_sample_freq = perf_sample_freq_list[4];
    __u64 perf_sample_freq_local = perf_sample_freq;
    
    start_perf_stat();

    std::cout << "start perf recording." << std::endl;

perf_sampling_start:
    sample_cnt = 0;
    perf_setup(perf_sample_freq);
    for(;;){
      for (int i = 0; i < NPROC; i++) {
        for(int j = 0; j < NPBUFTYPES; j++) {
          struct perf_event_mmap_page *p = perf_page[i][j];
          char *pbuf = (char *)p + p->data_offset;
          __sync_synchronize();

          while (p->data_tail != p->data_head) {
            struct perf_event_header *ph = (perf_event_header *)((void *)(pbuf + (p->data_tail % p->data_size)));


            struct perf_sample* ps;
            if ( (char*)(__u64(ph) + sizeof(struct perf_sample)) > (char*)(__u64(p) + p->data_offset + p->data_size)) {
              // this sample overflowed/exceeded the mmap region. reading this sample would cause
              // segfault. Skipping this sample. After the next p->data_tail += ph->size, the overflow
              // should be resolved, as we are back to the head of the circular buffer.
              // Ideally we should reconstruct this overflowed sample. If we want to do that, check Google perfetto.
              //std::cout << "[INFO] skipping overflow sample. sample start: " << ph << ", size of sample: " << sizeof(ps) << std::endl;
              num_overflow_samples++;
              if (num_overflow_samples % 10000 == 0) {
                std::cout << "num_overflow_samples count " << num_overflow_samples << std::endl;
              }
            } else {
              switch(ph->type) {
                case PERF_RECORD_SAMPLE:
                  ps = (struct perf_sample*)ph;
                  if (ps->addr != 0) { // sometimes the sample address is 0. Not sure why
                    page_addr = ps->addr & ~(0xFFF); // get virtual page address from address

                    arcCache.request(page_addr);

                    sample_cnt++;
                    if (sample_cnt % 100000 == 0) {
                      printf("Collected %ld samples.\n", sample_cnt);
                      arcCache.print_stat();
                    }
                    

                  }
                  break;
                case PERF_RECORD_LOST:
                  num_perf_record_lost++;
                  if (num_perf_record_lost % 100 == 0) {
                    std::cout << "num_perf_record_lost count " << num_perf_record_lost << std::endl;
                  }
                  break;
                default:
                  unknown_cnt++;
                  if (unknown_cnt % 100000 == 0) {
                    std::cout << "unknown perf sample count " << unknown_cnt << std::endl;
                  }
                  break;
              }
            }
perf_done_one_sample:
            //__sync_synchronize();
            // Proceed to the next perf sample
            p->data_tail += ph->size;
            //uint64_t updated_tail = p->data_tail + ph->size;
            //reinterpret_cast<std::atomic<uint64_t>*>(&p->data_tail)->store(updated_tail, std::memory_order_release);
            //read_offset = updated_tail;
          }
          // Throttle tiering thread
          // Try sleeping more, since we are not getting that many samples from each counter
          std::this_thread::sleep_for(std::chrono::microseconds(2000));
        } // for(int j = 0; j < NPBUFTYPES; j++)
      } // for (int i = 0; i < NPROC; i++)
    }

  //outfile.close();
  return NULL;
}


  
