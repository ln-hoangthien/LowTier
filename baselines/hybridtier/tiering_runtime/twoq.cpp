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

class TwoQCache {
private:
    // Cache size = maxSize
    size_t maxSize, Kin, Kout;
    // Pages in Am and A1in are in fast tier
    std::list<uint64_t> Am, A1in, A1out;
    std::unordered_map<uint64_t, std::list<uint64_t>::iterator> AmMap, A1inMap;
    std::unordered_map<uint64_t, bool> A1outMap;

    // Used for move_pages() syscall.
    int** migrate_pages;
    int migrate_nodes[1] = {-1};
    int migrate_status[1]= {-1};

    // Stats
    uint64_t num_promotes = 0;
    uint64_t num_demotes = 0;

public:
    TwoQCache(size_t B) {
      printf("Created TwoQ cache with size %ld \n", B);
      maxSize = B;
      Kin = B/4; // 25% as per paper
      Kout = B/2; // 50% as per paper

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

      if (!move_page_ret) {
        num_promotes++;
      }

      return move_page_ret;
    }

    int demote_page(uint64_t page_addr) {
      int move_page_ret = 99;
      migrate_nodes[0] = 1; // demote to node 1
      migrate_status[0] = 99;
      uint64_t num_pages_to_migrate = 1;

      migrate_pages[0] = (int*)page_addr;
      move_page_ret = numa_move_pages(0, num_pages_to_migrate, (void **)migrate_pages, migrate_nodes, migrate_status, MPOL_MF_MOVE_ALL);

      if (!move_page_ret) {
        num_demotes++;
      }

      return move_page_ret;
    }

    void reclaim(uint64_t X) {
        if (Am.size() + A1in.size() < maxSize) {
            // If there is space, directly allocate a slot
            //std::cout << "Allocating space for page " << X << "\n";
        } else if (A1in.size() > Kin) {
            //printf("A1in full \n");
            // A1in is full
            // Remove from A1in (FIFO eviction)
            uint64_t Y = A1in.back();
            A1in.pop_back();
            A1inMap.erase(Y);

            // DEMOTE Y
            demote_page(Y);

            A1out.push_front(Y);
            A1outMap[Y] = true;

            // Maintain max size of A1out 
            if (A1out.size() > Kout) {
                uint64_t Z = A1out.back();
                A1out.pop_back();
                A1outMap.erase(Z);
            }
        } else {
          // Am is full
          // Remove from Am (LRU eviction)
          uint64_t Y = Am.back();
          Am.pop_back();
          AmMap.erase(Y);
          // DEMOTE Y
          demote_page(Y);
        }
    }

    void accessPage(uint64_t X) {
        //printf("======== access page %d \n", X);
        if (AmMap.find(X) != AmMap.end()) {
            // Page is in Am -> Move to front
            //std::cout << "Page " << X << " accessed in Am, moved to front.\n";
            Am.erase(AmMap[X]);
            Am.push_front(X);
            AmMap[X] = Am.begin();
        } else if (A1outMap.find(X) != A1outMap.end()) {
            // Page is in A1out -> Bring back to Am
            //std::cout << "Page " << X << " moved from A1out to Am.\n";
            reclaim(X);
            Am.push_front(X);
            AmMap[X] = Am.begin();

            // PROMOTE X
            promote_page(X);

            A1outMap.erase(X);
        } else if (A1inMap.find(X) != A1inMap.end()) {
            // Page is in A1in, do nothing
            //std::cout << "Page " << X << " is in A1in, do nothing.\n";
        } else {
            // New page -> Insert into A1in
            //std::cout << "Page " << X << " added to A1in.\n";
            reclaim(X);
            A1in.push_front(X);
            A1inMap[X] = A1in.begin();
            // PROMOTE X    
            promote_page(X);
            //printf("!!! promote %ld \n", X);
        }
    }

    void displayCache() {
        std::cout << "Am (LRU): ";
        for (uint64_t p : Am) std::cout << p << " ";
        std::cout << "\nA1in (FIFO): ";
        for (uint64_t p : A1in) std::cout << p << " ";
        std::cout << "\nA1out (History): ";
        for (uint64_t p : A1out) std::cout << p << " ";
        std::cout << "\n";
    }

    // Size wrappers
    size_t sizeAm() const { return Am.size(); }
    size_t sizeA1in() const { return A1in.size(); }
    size_t sizeA1out() const { return A1out.size(); }


    void print_stat() {
      printf("Number of promotes: %ld, demotes: %ld \n", num_promotes, num_demotes);
      printf("Am %ld, A1in %ld, A1out %ld \n", sizeAm(), sizeA1in(), sizeA1out());
    }
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


    std::cout << "perf TwoQ tierng." << std::endl;
    uint64_t fast_memory_size = FAST_MEMORY_SIZE;
    std::cout << "[DEBUG] fast memory size = " << fast_memory_size  << std::endl;
    std::cout << "[DEBUG] number of pages in fast memory = " << NUM_FAST_MEMORY_PAGES << std::endl;
    printf(" perf_pages %d\n", PERF_PAGES);

    pid_t pid = getpid();
    std::cout << "pid: " << pid << std::endl;

    TwoQCache mycache(NUM_FAST_MEMORY_PAGES);

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

                    mycache.accessPage(page_addr);

                    sample_cnt++;
                    if (sample_cnt % 100000 == 0) {
                      //printf("Collected %ld samples.\n", sample_cnt);
                      mycache.print_stat();
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


  
