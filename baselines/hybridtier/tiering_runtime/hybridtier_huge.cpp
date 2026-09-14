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

#include "frequency_sketch_block_huge.hpp"

// Perf related 
//#define PERF_PAGES	(1 + (1 << 7))	// Has to be == 1+2^n, 
#define PERF_PAGES	(1 + (1 << 5))	// Has to be == 1+2^n, 
#define NPROC 16
#define NPBUFTYPES 2
#define LOCAL_DRAM_LOAD 0
#define REMOTE_DRAM_LOAD 1
#define PAGE_MIGRATE_BATCH_SIZE 1024 // how many pages to migrate at once via move_pages()
#define SAMPLE_BATCH_SIZE 100000


#ifdef FAST_MEMORY_SIZE_GB
uint64_t FAST_MEMORY_SIZE = (FAST_MEMORY_SIZE_GB * (1024L * 1024L * 1024L)); // size of fast tier memory in bytes
#else
uint64_t FAST_MEMORY_SIZE = 0;
#endif

uint64_t PAGE_SIZE = 2097152; // huge page
uint64_t NUM_FAST_MEMORY_PAGES = FAST_MEMORY_SIZE/PAGE_SIZE;
// W in the original paper. The formula is W/C=16. 16 is the TinyLFU max counter value hardcoded in the TinyLFU implementation.
uint64_t SAMPLE_SIZE = NUM_FAST_MEMORY_PAGES*16*10*400;
//#define SAMPLE_SIZE NUM_FAST_MEMORY_PAGES*16000
// Calculating the bloom filter size. Source: https://hur.st/bloomfilter/
#define FALSE_POSITIVE_PROB 0.001
#define NUM_HASH_FUNCTIONS 4

// 5% of total memory size
#define DEMOTE_WMARK FAST_MEMORY_SIZE / 20L
// 1.25% of total memory size
#define ALLOC_WMARK  DEMOTE_WMARK / 4L

#define SLOPE_THRESH -0.02

#define PERIODIC_ON_TIME_MS 5000 
#define PERIODIC_OFF_TIME_MS 5000 

uint32_t perf_sample_freq_list[5] = {1001, 1001, 1001, 1001, 100001};
std::deque<float> fast_mem_hit_ratio_window;

//typedef std::tuple<uint64_t,uint64_t> vma_range;

int fd[NPROC][NPBUFTYPES];
static struct perf_event_mmap_page *perf_page[NPROC][NPBUFTYPES];

std::chrono::steady_clock::time_point periodic_start_time;

// Second chance demotion 
std::vector<uint64_t> second_chance_queue;
std::vector<uint32_t> second_chance_oldfreq;


struct perf_sample {
  struct perf_event_header header;
  __u64 addr;        /* if PERF_SAMPLE_ADDR */
};


// Helpers for calculating bloom filter size.
float r_from_pk(float p, int64_t k) {
	return -1 * (float)k / log(1 - exp(log(p) / (float)k));
}

int64_t m_from_knp(int64_t k, int64_t n, float p) {
  float r = r_from_pk(p, k);
  return ceil(n*r);
}

// num_pages_to_demote: requested number of pages to demote from this memory range
// The current memory range (start_address to end_address) might not have num_pages_to_demote
// cold pages. In that case, the return value indicates how many cold pages were detected.
uint64_t handle_virtual_range(int pagemap_fd, uint64_t start_address, uint64_t end_address, 
                              frequency_sketch<uint64_t> &lfu, frequency_sketch<uint64_t> &momentum, 
                              int hot_thresh, std::vector<uint64_t> &cold_page_list, 
                              uint64_t num_pages_to_demote, uint64_t *last_scanned_address) {

  //printf("pagemap addr 0x%-16lx - 0x%-16lx \n", start_address, end_address);
  uint64_t num_cold_pages_found = 0;
  uint64_t last_page_reached;
  uint64_t pagemap_read_batch_size_num_pages = 1; 
  uint64_t num_pages_in_address_range = (end_address - start_address) / PAGE_SIZE;

  //printf("in handle vrange \n");

  if (num_pages_in_address_range < pagemap_read_batch_size_num_pages) {
    // The current address range can also be smaller than 1024. In that case, just read the entire address range.
    pagemap_read_batch_size_num_pages = num_pages_in_address_range;
  }

  //printf("num_pages_in_address_range %d pagemap_read_batch_size_num_pages %d \n", num_pages_in_address_range, pagemap_read_batch_size_num_pages);

  size_t pagemap_buffer_size;
  uint64_t num_pages_to_read;
  for(uint64_t curr_address = start_address & ~(0x1FFFFF); curr_address < end_address; curr_address += pagemap_read_batch_size_num_pages * PAGE_SIZE) {
    if (curr_address + pagemap_read_batch_size_num_pages * PAGE_SIZE > end_address) {
      // Reached the last chunk. Only read until end_address
      num_pages_to_read = (end_address - curr_address) / PAGE_SIZE;
    } else {
      num_pages_to_read = pagemap_read_batch_size_num_pages;
    }
    //printf("reading %ld pages. curr_address %-16lx \n", num_pages_to_read, curr_address);
    pagemap_buffer_size = num_pages_to_read * sizeof(uint64_t);
    uint64_t *pagemap_buffer = new uint64_t[pagemap_buffer_size]; 
    //uint64_t pagemap_index = (curr_address / PAGE_SIZE) * sizeof(pagemap_buffer[0]);
    uint64_t pagemap_index = (curr_address / 4096L) * sizeof(pagemap_buffer[0]); // should this still be 4096? I think this file is indexed by base page
    ssize_t pagemap_read_bytes = pread(pagemap_fd, pagemap_buffer, pagemap_buffer_size, pagemap_index);
    //printf("pagemap_read_bytes %ld \n", pagemap_read_bytes);
    if(pagemap_read_bytes == -1) {
        perror("pread");
        return 1;
    }
    last_page_reached = curr_address + num_pages_to_read * PAGE_SIZE;
  

    // Process a batch of results
    for(uint64_t ii = 0; ii < pagemap_read_bytes/sizeof(uint64_t); ii++) {
      uint64_t virtual_page_addr = curr_address + ii*PAGE_SIZE; // start from the first page in the 1024 chunk
      uint64_t pfn = pagemap_buffer[ii] & 0x7fffffffffffff;
      //printf("vaddr %lx pfn %lx \n", virtual_page_addr, pfn);
      if (pfn > 0 && pfn < 0x8080000) {
        // This virtual page is mapped to a physical page on node 0 (fast tier memory)
        int page_freq = lfu.frequency(virtual_page_addr & ~(0x1FFFFF));
        int page_momentum = momentum.frequency(virtual_page_addr & ~(0x1FFFFF));
        // 4 cases for demotion:
        // low frequency + low momentum -> demote
        // low frequency + high momentum -> do not demote
        // high frequency + low momentum -> second chance
        // high frequency + high momentum -> do not demote
        //printf("demote fast tier page?  vaddr %lx, freq %d, momentum %d \n", virtual_page_addr, page_freq, page_momentum);
        if (page_freq < hot_thresh && page_momentum < 400) { 
          // low frequency + low momentum case
          cold_page_list.push_back(virtual_page_addr);
          num_cold_pages_found++;
          //printf("demote \n");
        } else if (page_freq >= hot_thresh && page_momentum < 20) {
          //printf("[2ndc]   in demotion, found second chance page %lx, page_freq %d\n", virtual_page_addr&~(0xFFF), page_freq);
          // high frequency + low momentum case. 
          if (second_chance_queue.size() < 1000) { // limit second chance demotion
            second_chance_queue.push_back(virtual_page_addr & ~(0x1FFFFF));
            if (page_freq == 65535) {
              // If page already has frequency 15, decrement its frequency by 1. This is used to check 
              // if any accesses will occur to this page (second chance)
              lfu.decrement_frequency(virtual_page_addr & ~(0x1FFFFF));
              second_chance_oldfreq.push_back(65534);
            } else {
              // Record current frequency. 
              second_chance_oldfreq.push_back(page_freq);
            }
          }
          //num_cold_pages_found++;
        }
      }
    }
    delete[] pagemap_buffer;

    //printf("found %ld cold pages so far. target is %ld \n", num_cold_pages_found, num_pages_to_demote);
    if (num_cold_pages_found >= num_pages_to_demote) {
      // The actual number of pages to demote might be smaller or larger than the num_pages_to_demote_requesteed.
      if (last_page_reached > *last_scanned_address) {
        *last_scanned_address = last_page_reached;
      }
      // We have found enough cold pages for demotion. Return early.
      return num_cold_pages_found;
    }
  }
  // We have finished scanning all pages in this address range and could not find the requested number of pages to demote.
  return num_cold_pages_found;

}

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

// Put this tiering thread to sleep.
void periodic_off(){
  close_perf(); // Must shutdown perf counters to minimize overhead. Just sleep() will not disable perf sampling
  printf("sleeeping \n");
  std::this_thread::sleep_for(std::chrono::milliseconds(PERIODIC_OFF_TIME_MS));
  // Record wake up time. 
  periodic_start_time = std::chrono::steady_clock::now();
}

// Check whether this tiering thread should sleep. If yes, go to sleep.
bool check_sleep() {
  std::chrono::steady_clock::time_point time_now = std::chrono::steady_clock::now();
  double elapsed_time_ms = (double)std::chrono::duration_cast<std::chrono::milliseconds>(time_now - periodic_start_time).count();
  printf("check sleep elapsed %f \n", elapsed_time_ms);
  if (elapsed_time_ms >= PERIODIC_ON_TIME_MS) {
    periodic_off();
    return true;
  }
  return false;
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

    std::cout << "[INFO] Hybridtier perf sampling freq: " << perf_sample_freq << std::endl;
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
    printf("Perf mmap size %ld, page size %ld \n", mmap_size, sysconf(_SC_PAGESIZE));

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

    //int ret = madvise((void *)p, mmap_size, MADV_NOHUGEPAGE);
    //if (ret) {
    //  printf("madvise return non zero %d \n", ret);
    //} else {
    //  printf("madvise return sucess: %d \n", ret);
    //}

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
  std::cout << "[INFO] 2Starting perf stat monitoring." << std::endl;
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


// Checks the fast memory hit ratio statistics and decide whether we should change the perf sampling frequency.
// fast_mem_hit_ratio_window contains the most recent 5 fast memory hit ratios.
// return > 0: the new perf sampling frequency we should use. Could be equal to the previous sample frequency
// return == 0: not enough data accumulated. No action
uint32_t check_fast_mem_hit_ratio(int cur_sampling_freq) {
  int num_lines = 0;
  std::string line;
  std::ifstream perf_stat_file("perf_stat_file");

  while (std::getline(perf_stat_file, line)) {
    if (!line.empty() && line[0] != '#') {
      ++num_lines;
    }
  }

  // Only process output file when there are new samples (2 lines)
  if (num_lines < 1*2) { // 2 lines each entry (local, remote)
    return 0;
  }

  perf_stat_file.clear();
  perf_stat_file.seekg(0);

  float fast_mem_hit_ratio;
  uint64_t local_dram_loads;
  uint64_t remote_dram_loads;

  std::vector<std::string> lines;

  while (std::getline(perf_stat_file, line) && lines.size() < 2) {
    if (!line.empty() && line[0] != '#') {
      // Ignore empty lines and comments
      lines.push_back(line);
    }
  }
  
  //printf("[INFO] Fast memory hit ratio trend: ");
  // Extract number of local memory accesse
  line = lines[0];
  std::istringstream iss(line);
  std::string token;
  std::getline(iss, token, ',');  // Skip the first number
  std::getline(iss, token, ',');  // Extract the second number
  local_dram_loads = std::stoul(token);

  // Extract number of remote memory accesse
  line = lines[1];
  std::istringstream iss2(line);
  std::string token2;
  std::getline(iss2, token2, ',');  // Skip the first number
  std::getline(iss2, token2, ',');  // Extract the second number
  remote_dram_loads = std::stoul(token2);

  fast_mem_hit_ratio = (float)local_dram_loads / ((float)local_dram_loads + (float)remote_dram_loads );

  //printf("local %ld, remote %ld, hit rate %f \n", local_dram_loads, remote_dram_loads, fast_mem_hit_ratio[i]);

  perf_stat_file.close();

  // Done consuming output file content. Erase it.
  std::ofstream erase_file("perf_stat_file"); // Without append
  erase_file.close();

  fast_mem_hit_ratio_window.push_back(fast_mem_hit_ratio);

  if (fast_mem_hit_ratio_window.size() <= 5) {
    // At the beginning, we have not collected 5 hit ratios yet. 
    return 0;
  }
  // Remove the oldest entry
  fast_mem_hit_ratio_window.pop_front();

  printf("[INFO] Fast memory hit ratio history: %f, %f, %f, %f, %f\n", 
                            fast_mem_hit_ratio_window[0],
                            fast_mem_hit_ratio_window[1],
                            fast_mem_hit_ratio_window[2],
                            fast_mem_hit_ratio_window[3],
                            fast_mem_hit_ratio_window[4]);
  
  // Calculate the line of best fit using linear regression.
  // 5 data points (x, y): (0, fast_mem_hit_ratio_window[0]), (1, fast_mem_hit_ratio_window[1]) etc.
  // The formula for computing the slope of the line of best fit:
  // slope = ( n*sumproduct(x, y) - sum(x)*sum(y) ) / ( n*sum(x^2) - sum(x)^2 )
  // The x array is constant: [0, 1, 2, 3, 4]
  // So sum(x) = 10, sum(x^2) = 30.

  // Compute sumproduct(x,y) and sum(y)
  float sumproduct_x_y = 0;
  float sum_y = 0;
  for (int x = 0; x < 5; x++) {
    sumproduct_x_y += (float)x * fast_mem_hit_ratio_window[x];
    sum_y += fast_mem_hit_ratio_window[x];
  }

  int n = 5;
  float slope = ( (float)n*sumproduct_x_y - 10*sum_y ) / ( (float)n*30 - 100);

  printf("[DEBUG] sumproduct_x_y %f, sum_y %f, slope %f\n", sumproduct_x_y, sum_y, slope);

  // If the slope of the line of best fit is lower than this value (can be negative), we consider the 
  // memory hit ratio as no longer growing. Decrease perf sampling in that case.
  float slope_thresh = SLOPE_THRESH;

  if (slope < slope_thresh) {
    printf("[INFO] Fast memory hit ratio dropped. Increasing perf sampling rate.\n");
    return next_sampling_freq(cur_sampling_freq , true);
  }
  printf("[INFO] Fast memory hit ratio stablized. Decreasing perf sampling rate.\n");
  return next_sampling_freq(cur_sampling_freq , false);
}

// Returns amount of free memory in node 0 in KB
uint64_t get_node0_free_mem() {
  std::string path = "/sys/devices/system/node/node0/meminfo";
  std::ifstream file(path);
  if (!file) {
      std::cerr << "Failed to open " << path << std::endl;
      return -1;
  }
  std::string line;
  std::regex regex(R"(MemFree:\s+(\d+) kB)");
  while (getline(file, line)) {
      std::smatch match;
      if (std::regex_search(line, match, regex)) {
          return std::stoull(match[1].str());
      }
  }
  return -1;
}


void low_overhead_monitor() {
  std::cout << "[INFO] Starting low overhead perf stat monitoring." << std::endl;
  close_perf();
  std::cout << "[INFO] Sleep for 120s for fast memory hit ratio to stablize." << std::endl;
  std::this_thread::sleep_for(std::chrono::seconds(120));
  uint32_t num_times_too_much_free_memory = 0;

  // Reset the fast memory hit ratio history.
  fast_mem_hit_ratio_window.clear();
  while (true) {
    uint32_t ret_freq = check_fast_mem_hit_ratio(perf_sample_freq_list[0]);
    // If returned sampling frequency is larger than minimum frequency, need to turn perf 
    // sampling back on. 
    printf("return freq %d \n", ret_freq);
    if (ret_freq > perf_sample_freq_list[0]) {
      std::cout << "[INFO] Low overhead monitoring detected change in hit ratio. Enable perf sampling." << std::endl;
      return;
    }
    sleep(12); // Check periodically
    
    // If local memory has lots of free memory, resume tiering
    uint64_t node0_free_mem_kB = get_node0_free_mem(); // in kB
    std::cout << "[INFO] node 0 free memory in kB : " << node0_free_mem_kB << std::endl;
    if (node0_free_mem_kB*1000 >= DEMOTE_WMARK * 2) {
      num_times_too_much_free_memory++;
      if (num_times_too_much_free_memory > 20) {
        std::cout << "[INFO] Too much free memory for 20 times consecutively. Resume tiering: " << node0_free_mem_kB << std::endl;
        return;
      }
    } else {
      num_times_too_much_free_memory = 0;
    }
    
  }
}

// Used for demoting cold pages in fast tier memory.
// num_pages_to_demote_requested: the requested number of pages to demote
// demotion_vma_scanned: a vector containing all VMA ranges we have already seen in this demotion round.
// full_sweep_not_enough_cold_pages: indicates whether we have performed a full sweep of the address space 
// Return value: actual number of pages demoted. 
uint64_t scan_for_cold_pages(int pid, int hot_thresh, 
                             frequency_sketch<uint64_t> &lfu, frequency_sketch<uint64_t> &momentum, 
                             uint64_t num_pages_to_demote_requested, uint64_t *last_scanned_address,
                             bool *full_sweep_not_enough_cold_pages) {
  std::cout << "scan_for_cold_pages" << std::endl;

  //std::this_thread::sleep_for(std::chrono::microseconds(2000000));

  std::ifstream input("/proc/"+std::to_string(pid)+"/maps");
  std::regex addr_range_regex("^([0-9a-fA-F]+)-([0-9a-fA-F]+)");
  std::smatch match;
  uint64_t start_addr;
  uint64_t end_addr;
  uint64_t vma_num_pages;
  std::vector<uint64_t> cold_page_list;
  uint64_t num_cold_pages_found = 0;

  uint32_t maps_num_lines = 0;
  std::string line_tmp;
  while (std::getline(input, line_tmp)) {
    maps_num_lines++;
  }

  printf("num lines total %d \n", maps_num_lines);
  // Reset file reader position to top of file
  input.clear();
  input.seekg(0);

  *full_sweep_not_enough_cold_pages = false;

  uint32_t maps_cur_line = 0;
  for(std::string line; getline(input, line);) {
    maps_cur_line++;
    if (std::regex_search(line, match, addr_range_regex)) {
      start_addr = std::stoul(match.str(1), nullptr, 16);
      end_addr = std::stoul(match.str(2), nullptr, 16);
    } else {
      continue;
    }
    vma_num_pages = (end_addr - start_addr)/PAGE_SIZE;
    if (vma_num_pages < 10) {
      // Only worry about memory ranges larger than 20MB. If memory range is
      // larger than 1GB, my custom kernel changes will breakdown the NUMA stats of
      // this memory range into 1GB chunks in the next few lines, so skipping this entry.
      //std::cout << "  mem range too small" << std::endl;
      continue;
    }

    if (*last_scanned_address <= start_addr) {
      // Have not scanne this VMA yet. Scan this VMA from start to end
      //std::cout << "  Have not scann this VMA yet" << std::endl;
      start_addr = start_addr;
      end_addr = end_addr;
      std::cout << std::hex << "  range: " << start_addr << " - " << end_addr << ", size " << std::dec << vma_num_pages << std::endl;
    } else if (*last_scanned_address >= end_addr - 0x200000) {
      // - 0x1000 because the end_addr in /proc/PID/maps is one page after the last page in the VMA
      //std::cout << "  Already scanned this VMA. Skip" << std::endl;
      continue;
    } else if (*last_scanned_address > start_addr && (*last_scanned_address < end_addr - 0x200000)) {
      // The last scan reached the middle of this VMA. Pick up where we left off.
      std::cout << std::hex << "  range: " << start_addr << " - " << end_addr << ", size " << std::dec << vma_num_pages << std::endl;
      start_addr = *last_scanned_address;
      std::cout << std::hex <<"  Scanning from the middle of this VMA: " << start_addr << std::dec << std::endl;
      end_addr = end_addr;
    }


    std::string pagemap_path = "/proc/"+std::to_string(pid)+"/pagemap";
    int pagemap_fd = open(pagemap_path.c_str(), O_RDONLY);
    if(pagemap_fd < 0) {
      std::cout << "[ERROR] pagemap open failed." << std::endl;
      return -1;
    }
    num_cold_pages_found += handle_virtual_range(pagemap_fd, start_addr, end_addr, 
                                                 lfu, momentum, 
                                                 hot_thresh, cold_page_list, 
                                                 num_pages_to_demote_requested - num_cold_pages_found, last_scanned_address);

    std::cout << "  found cold pages: " << num_cold_pages_found << ", last scanned " << std::hex << *last_scanned_address << std::dec  << std::endl;
    if (num_cold_pages_found >= num_pages_to_demote_requested) {
      // Found enough cold pages to demote. Done
      break;
    } else {
      std::cout << "[INFO] Did not find enough pages to demote from memory range." << std::endl;
      // Continue to look for more cold pages to demote
    }
  }

  std::cout << "processed number of lines: " << maps_cur_line << std::endl;

  if (num_cold_pages_found >= num_pages_to_demote_requested) {
    std::cout << "found " << num_cold_pages_found << " cold pages. requested " << num_pages_to_demote_requested << std::endl;
  } else {
    std::cout << "did not find " << num_pages_to_demote_requested << " cold pages in node 0" << std::endl;
    if (maps_cur_line == maps_num_lines) {
      // Sweeped through the entire address space in /proc/pid/maps and did not find enough pages to demote
      std::cout << "Did not find " << num_pages_to_demote_requested << " cold pages in node 0 after a full address space sweep" << std::endl;
      *full_sweep_not_enough_cold_pages = true;
    }
  
  }

  // Demote the cold pages
  // The actual number of pages to demote might be smaller or larger than the num_pages_to_demote_requesteed.
  // TODO: check below. 
  //uint32_t num_pages_to_demote_actual = std::max(num_pages_to_demote_requested, num_cold_pages_found);
  uint64_t num_pages_to_demote_actual = cold_page_list.size();
  int** demote_pages = new int*[num_pages_to_demote_actual];
  int* demote_nodes = new int[num_pages_to_demote_actual];
  int* demote_status = new int[num_pages_to_demote_actual];
  int demote_ret; 

  for (uint64_t i = 0; i < num_pages_to_demote_actual; i++) {
    demote_pages[i] = (int*)(cold_page_list[i]);
    demote_nodes[i] = 1; // Demote to node 1
    demote_status[i] = 99;
  }

  demote_ret = numa_move_pages(0, num_pages_to_demote_actual, (void **)demote_pages, demote_nodes, demote_status, MPOL_MF_MOVE_ALL);

  delete[] demote_pages;
  delete[] demote_nodes;
  delete[] demote_status;

  std::cout << "scan_for_cold_pages done" << std::endl;
  if (demote_ret == 0) {
    return num_pages_to_demote_actual;
  }

  std::perror("Demotion move_pages error");
  return -1;
}



std::vector<void*> check_pages_on_node(const std::vector<void*>& addresses, size_t pages, int check_node) {
    std::vector<int> status(pages, -1);  // Status to hold the current node
    std::vector<void*> pages_to_move;

    // Call numa_move_pages with the NULL target node to only check status
    int err = numa_move_pages(0, pages, const_cast<void**>(addresses.data()), nullptr, status.data(), 0);
    if (err != 0) {
        std::cerr << "numa_move_pages() failed during status check: " << strerror(errno) << std::endl;
        exit(EXIT_FAILURE);
    }

    // Collect pages that are currently on the specified check_node
    for (size_t i = 0; i < pages; ++i) {
        if (status[i] == check_node) {
            pages_to_move.push_back(addresses[i]);
        }
    }

    return pages_to_move;
}


void* perf_func(void*) {
    std::cout << "Hybridtier. huge page" << std::endl;
    uint64_t fast_memory_size = FAST_MEMORY_SIZE;
    if (fast_memory_size == 0) {
      std::cout << "ERROR fast tier memory size not provided."  << std::endl;
      exit(1);
    }
    std::cout << "[DEBUG] fast memory size = " << fast_memory_size  << std::endl;
    std::cout << "[DEBUG] number of pages in fast memory = " << NUM_FAST_MEMORY_PAGES << std::endl;
    std::cout << "[DEBUG] perf_pages = " << NUM_FAST_MEMORY_PAGES << std::endl;
    printf(" perf_pages %d, sample_batch_size %d \n", PERF_PAGES, SAMPLE_BATCH_SIZE);

    pid_t pid = getpid();
    std::cout << "pid: " << pid << std::endl;
  
    uint64_t unknown_cnt = 0;
    uint64_t sample_cnt = 0;
    uint64_t num_sample_batches = 0;
    uint64_t num_perf_record_lost = 0;
    uint64_t num_overflow_samples = 0;

    int initial_hot_thresh = 1000;
    int hot_thresh = initial_hot_thresh;
    int momentum_thresh = 200;
    // m_from_knp returns the number of counters we need. each counter is 4 bits, and each element in the 
    // bloom array is 64 bits. So we need m*4/64 = m/16 array elements.
    std::cout << "==== debug info" <<  std::endl;
    
    #ifdef NUM_CBF_ENTRIES_DEF
    int64_t NUM_CBF_ENTRIES = NUM_CBF_ENTRIES_DEF;
    std::cout << "[INFO] Manually specifying CBF size = " << NUM_CBF_ENTRIES << std::endl;
    #else
    int64_t NUM_CBF_ENTRIES = m_from_knp(NUM_HASH_FUNCTIONS, NUM_FAST_MEMORY_PAGES, FALSE_POSITIVE_PROB)/4;
    std::cout << "[INFO] Calculating CBF size = " << NUM_CBF_ENTRIES  <<  std::endl;
    #endif
    
    assert(NUM_CBF_ENTRIES >= 0);
    frequency_sketch<uint64_t> lfu(NUM_CBF_ENTRIES, SAMPLE_SIZE);
    frequency_sketch<uint64_t> momentum(NUM_CBF_ENTRIES/8, 1100000);
    std::cout << std::dec << "Starting hot threshold = " << hot_thresh << std::endl;
    std::cout << std::dec << "Momentum threshold = " << momentum_thresh << std::endl;
    std::cout << std::dec << "Stable fast mem hit ratio slope threshold = " << SLOPE_THRESH << std::endl;
    std::cout << std::dec << "False positive rate = " << FALSE_POSITIVE_PROB << std::endl;
    std::cout << std::dec << "perf stat period = 60s " << std::endl;

    uint64_t alloc_wmark = ALLOC_WMARK;
    uint64_t demote_wmark = DEMOTE_WMARK;
    std::cout << std::dec << "allocation watermark = " << alloc_wmark << ", demotion watermark = " << demote_wmark << std::endl;

    uint64_t page_addr;
    uint64_t num_local_mem_samples_in_batch = 0;
    uint64_t num_remote_mem_samples_in_batch = 0;
    uint64_t num_local_mem_samples_hot = 0;
    uint64_t num_pages_lfu_demote = 0;

    // Used for move_pages() syscall.
    // Migrate in batches (PAGE_MIGRATE_BATCH_SIZE pages)
    std::vector<void*> migrate_pages(SAMPLE_BATCH_SIZE);
    std::vector<int> migrate_status(SAMPLE_BATCH_SIZE, 99);
    std::vector<int> migrate_nodes(SAMPLE_BATCH_SIZE, 0);

    int cur_page_in_migration_batch = 0; // track how many pages we have collected. migrate the batch when this reaches 100.

    uint64_t pages_migrated = 0;
    uint64_t move_pages_errors = 0;
    //long prev_pages_migrated = 0;
    int move_page_ret = 0;
    int move_page_ret2 = 0;
    //bool migration_done = false;

    //std::vector<vma_range> demotion_vma_scanned;
    uint64_t last_scanned_address = 0;
    __u64 perf_sample_freq = perf_sample_freq_list[4];
    __u64 perf_sample_freq_local = perf_sample_freq;
    
    std::unordered_map<uint64_t, uint32_t> sampled_address_counts[NPBUFTYPES]; // one for fast tier, one for slow tier
    uint64_t num_samples_collected_in_batch = 0;

    // Have we already performed a full demotion sweep and did not find enough cold pages?
    // If two consecutive full demotion sweep does not give enough memory, go into monitor mode
    bool full_sweep_not_enough_cold_pages_once = false;
    uint64_t num_pages_promoted_history = 0;

    // Used to calculate the % of samples that are "unuseful", that is, incrementing
    // frequency counts that are already at the max value.
    uint64_t num_unuseful_samples[NPBUFTYPES];

    start_perf_stat();

    std::cout << "start perf recording." << std::endl;

    //int cpu = sched_getcpu();
    //printf("Tiering thread running on CPU %d\n", cpu);

    float unuseful_sample_fraction_local;
    float unuseful_sample_fraction_remote;

    bool drop_local_sample_freq = false;

    // Used to throttle demotion
    std::chrono::steady_clock::time_point demotion_clock = std::chrono::steady_clock::now();
    uint32_t demotion_throttle_secs = 0;

    // Used for momentum based demotion
    std::chrono::steady_clock::time_point second_chance_clock = std::chrono::steady_clock::now();

    uint16_t demotion_reset_count = 0;

perf_sampling_start:
    sample_cnt = 0;
    cur_page_in_migration_batch = 0;
    perf_setup(perf_sample_freq);
    for(;;){
      for (int i = 0; i < NPROC; i++) {
        for(int j = 0; j < NPBUFTYPES; j++) {
          struct perf_event_mmap_page *p = perf_page[i][j];
          char *pbuf = (char *)p + p->data_offset;
          __sync_synchronize();
          // if data_tail == data_head, then we have read all perf samples in the ring buffer.

          //uint64_t read_offset = p->data_tail;
          //uint64_t write_offset = reinterpret_cast<std::atomic<uint64_t>*>(&p->data_head)->load(std::memory_order_acquire);

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
                    page_addr = ps->addr & ~(0x1FFFFF); // get virtual page address from address
                    
                    sample_cnt = sample_cnt + 1;
                    
                    if (j == REMOTE_DRAM_LOAD) {
                      num_remote_mem_samples_in_batch++;
                    } else if (j == LOCAL_DRAM_LOAD){ 
                      num_local_mem_samples_in_batch++;
                    }

                    sampled_address_counts[j][page_addr]++;

                    num_samples_collected_in_batch++;
                    if (num_samples_collected_in_batch < SAMPLE_BATCH_SIZE) {
                      // Did not collect a batch of samples yet, continue sampling.
                      goto perf_done_one_sample;
                    }
                    //printf("got batch of samples. fast %d, slow %d \n", sampled_address_counts[0].size(), sampled_address_counts[1].size());
                    //printf("total samples fast %d, slow %d \n", num_local_mem_samples_in_batch, num_remote_mem_samples_in_batch);

                    num_samples_collected_in_batch = 0;
                    uint64_t num_pages_to_migrate = 0;

                    
                    // Process batch of samples once total of SAMPLE_BATCH_SIZE samples has been collected (from both local and remote)
                    for(int jj = 0; jj < NPBUFTYPES; jj++) {
                      // go through each address sampled from fast tier and slow tier
                      for (const auto& sample_address_count_pair : sampled_address_counts[jj]) {
                        uint64_t sampled_addr = sample_address_count_pair.first;
                        uint32_t sampled_addr_count = sample_address_count_pair.second;
                        uint32_t updated_freq;
                        uint32_t updated_momentum;
                        // increase the frequency of sampled_addr to sampled_addr_count
                        lfu.increase_frequency(sampled_addr, sampled_addr_count, &updated_freq); 
                        momentum.increase_frequency(sampled_addr, sampled_addr_count, &updated_momentum); 
                        //printf("page %lx, freq %d, momentum %d \n", sampled_addr, lfu.frequency(sampled_addr), momentum.frequency(sampled_addr));

                        // Seems like PEBS is not accurate in terms of which node a page is from.
                        // Try to promote pages sampled from both LOCAL_DRAM and REMOTE_DRAM.
                        if (updated_freq >= hot_thresh || updated_momentum >= momentum_thresh) {
                        //if (updated_freq >= hot_thresh) {
                          migrate_pages[num_pages_to_migrate] = (int*)sampled_addr;
                          migrate_status[num_pages_to_migrate] = 99;
                          num_pages_to_migrate++;
                        }
                      }
                      // Reset hash tables
                      sampled_address_counts[jj].clear();

                      // For both fast tier and slow tier, record how many samples wre nonuseful
                      num_unuseful_samples[jj] = lfu.get_num_nonuseful_samples();
                      lfu.clear_num_nonuseful_samples(); // reset nonuseful counter
                    }

                    printf("collected one batch of samples. pages to migrate = %ld \n", num_pages_to_migrate);

                    unuseful_sample_fraction_local = (float) (num_unuseful_samples[LOCAL_DRAM_LOAD]) / num_local_mem_samples_in_batch;
                    unuseful_sample_fraction_remote = (float) (num_unuseful_samples[REMOTE_DRAM_LOAD]) / num_remote_mem_samples_in_batch;
                    //printf("frac of unuseful samples: %f local, %f remote \n", unuseful_sample_fraction_local, unuseful_sample_fraction_remote);

                    if (unuseful_sample_fraction_local > 0.8) {
                      // Mark this 
                      drop_local_sample_freq = true;
                    }

                    // Reset 
                    num_local_mem_samples_in_batch = 0;
                    num_remote_mem_samples_in_batch = 0;


                    std::vector<void*> pages_on_node_1 = check_pages_on_node(migrate_pages, num_pages_to_migrate, 1);
                    size_t num_pages_in_slow = pages_on_node_1.size();
                    size_t num_pages_in_fast = num_pages_to_migrate - num_pages_in_slow;



                    //delete[] dbg_status;
                    if (num_pages_in_slow == 0) {
                      printf("no slow pages to promote\n");
                    }
                    
                    if (num_pages_in_slow > 0) {
                      printf("start promoting %ld pages\n", num_pages_in_slow);
                      // Migrate the batch of pages
                      //move_page_ret = numa_move_pages(0, num_pages_to_migrate, (void **)migrate_pages, migrate_nodes, migrate_status, MPOL_MF_MOVE_ALL);
                      move_page_ret = numa_move_pages(0, num_pages_in_slow, const_cast<void**>(pages_on_node_1.data()), migrate_nodes.data(), migrate_status.data(), MPOL_MF_MOVE_ALL);
                      if (move_page_ret == 0) { 
                        // Number of pages actually promoted
                        //pages_migrated += num_pages_in_slow - num_pages_remain_in_slow; 
                        pages_migrated += num_pages_in_slow;
                        num_pages_promoted_history += num_pages_in_slow;

                      } else {
                        printf("move page ret %d \n", move_page_ret);
                        std::cout << "move page error: " << errno << '\n';

                        if (errno == ENOMEM) {
                          printf("got ENOMEM. trying against with %ld pages \n", num_pages_in_slow/5);
                          // Fast tier does not have enough memory for migration. 
                          // Try again with 1/4 of pages.
                          move_page_ret = numa_move_pages(0, num_pages_to_migrate/10, const_cast<void**>(pages_on_node_1.data()), migrate_nodes.data(), migrate_status.data(), MPOL_MF_MOVE_ALL);
                          
                          printf("second promote attempt return %d\n", move_page_ret);
                        }

                        // a non zero value is returned.
                        move_pages_errors++;
                        if (move_pages_errors % 1000 == 0) {
                          std::cout << " move_pages_errors " << move_pages_errors << std::endl;
                        }
                      }
                    } 

                    // Check how much free memory we still have on node 0.
                    uint64_t node0_free_mem_kB = get_node0_free_mem(); // in kB
                    std::cout << std::dec << "pages migrated: " << pages_migrated 
                              << ", lfu # items: " << lfu.get_num_elements() 
                              << ", lfu sample size: " << lfu.get_size() 
                              << ", samples: " << sample_cnt 
                              //<< ", local " << num_local_mem_samples 
                              //<< ", remote " << num_remote_mem_samples 
                              << ", node 0 mem " << node0_free_mem_kB
                              //<< ", lfu demote " << num_pages_lfu_demote 
                              << std::endl;
                    lfu.print_frequency_dist();
                    momentum.print_frequency_dist();

                    // Not enough free memory. Trigger demotion
                    if (node0_free_mem_kB*1000 <= alloc_wmark) {
                      // record number of pages to demote here. 
                      uint64_t pages_to_demote = (demote_wmark - node0_free_mem_kB*1000) / PAGE_SIZE;
                      // First check pages that were given second chance
                      if (second_chance_queue.size() != 0) {
                        std::chrono::steady_clock::time_point second_chance_clock_now = std::chrono::steady_clock::now();
                        double second_chance_time_elapsed = (double)std::chrono::duration_cast<std::chrono::milliseconds>
                                                                  (second_chance_clock_now - second_chance_clock).count();
                        //printf("[2ndc] time since last 2nd chance %f. queue size %lu\n", second_chance_time_elapsed * 1000,  second_chance_queue.size());
                        if (second_chance_time_elapsed / 1000 > 60) {
                          // After some time, check second chance pages again.
                          std::vector<uint64_t> demote_page_list;
                          for (uint64_t k = 0; k < std::min(static_cast<uint32_t>(second_chance_queue.size()), (uint32_t)10000); k++) { // demote 10k pages at max
                            uint64_t second_chance_page = second_chance_queue[k];
                            uint32_t second_chance_page_oldfreq = second_chance_oldfreq[k];
                            // The current frequency and momentum
                            int second_chance_page_newfreq = lfu.frequency(second_chance_page);
                            //printf("[2ndc] page %lx, old freq %d, new freq %d\n", second_chance_page,second_chance_page_oldfreq, second_chance_page_newfreq);
                            if (second_chance_page_newfreq - second_chance_page_oldfreq < 100) {
                              // Very few accesses sampled since last visit. Demote this page.
                              //printf("[2ndc] 2nd chanced failed (<100 new accesses). page %lx, new freq %d \n", second_chance_page, second_chance_page_newfreq);
                              demote_page_list.push_back(second_chance_page);
                            }
                          }
                          // Record time now. Perform second chance clean up roughly 10 seconds later
                          second_chance_clock = std::chrono::steady_clock::now();

                          printf("[2ndc] collected %lu second chance pages to demote (%f of all 2nd chances) \n", 
                                  demote_page_list.size(), (float) demote_page_list.size() / (float) second_chance_queue.size());
                          // Actually demote the second chance pages
                          int** demote_pages = new int*[demote_page_list.size()];
                          int* demote_nodes = new int[demote_page_list.size()];
                          int* demote_status = new int[demote_page_list.size()];
                          int demote_ret; 

                          for (uint64_t kk = 0; kk < demote_page_list.size(); kk++) {
                            demote_pages[kk] = (int*)(demote_page_list[kk]);
                            demote_nodes[kk] = 1; // Demote to node 1
                            demote_status[kk] = 99;
                          }

                          demote_ret = numa_move_pages(0, demote_page_list.size(), (void **)demote_pages, demote_nodes, demote_status, MPOL_MF_MOVE_ALL);

                          delete[] demote_pages;
                          delete[] demote_nodes;
                          delete[] demote_status;

                          second_chance_queue.clear(); // reset queue
                          second_chance_oldfreq.clear(); 
                        }
                      }

                      bool full_sweep_not_enough_cold_pages = false;
                      uint64_t pages_demoted = scan_for_cold_pages(pid, hot_thresh, 
                                                                   lfu, momentum, pages_to_demote, 
                                                                   &last_scanned_address, &full_sweep_not_enough_cold_pages);
                      std::cout << "pages_demoted " << pages_demoted  << std::endl;


                      // Potentially throttle demotion
                      std::chrono::steady_clock::time_point demotion_clock_now = std::chrono::steady_clock::now();
                      double time_between_demotions_ms = (double)std::chrono::duration_cast<std::chrono::milliseconds>
                                                                (demotion_clock_now - demotion_clock).count();
                      double bytes_per_sec_demoted = (double)(pages_demoted * PAGE_SIZE) / (time_between_demotions_ms) * 1000;
                      printf("Demotion rate: %f \n", bytes_per_sec_demoted);
                      if (bytes_per_sec_demoted > 100*1024*1024 && demotion_throttle_secs < 1) { 
                        // If larger than 50MB/s, throttle. 
                        demotion_throttle_secs++;
                        printf("demotion rate too high. Increase demotion throttle to %d secs.\n", demotion_throttle_secs);
                      } else if (bytes_per_sec_demoted < 10*1024*1024 && demotion_throttle_secs > 0) {
                        // Demoting too slowly. Decrease throttling
                        demotion_throttle_secs--;
                        printf("demotion rate too low. Decrease demotion throttle to %d secs.\n", demotion_throttle_secs);
                      }
                      // Update time we did the last demotion
                      demotion_clock = std::chrono::steady_clock::now();
                      // Perform throttling
                      if (demotion_throttle_secs > 0){ 
                        std::this_thread::sleep_for(std::chrono::seconds(demotion_throttle_secs));
                      }
                      // Throttling done

                      if (pages_demoted < pages_to_demote) {
                        // Finished one sweep of address space and demoted all cold pages we found.
                        last_scanned_address = 0;
                        std::cout << "[INFO] Finished one sweep of address space. " << std::endl;
                      }
                      if (full_sweep_not_enough_cold_pages_once && full_sweep_not_enough_cold_pages) {
                        std::cout << "[INFO] Finished two demotion sweeps and found no cold pages. Go to monitor mode. " << std::endl;
                        demotion_reset_count = 0;
                        low_overhead_monitor();
                        // Aging here makes sense. At this point, there are likely no more cold pages in node 0 DRAM.
                        // Without aging, it would be pointless to restart sampling since we cannot find more cold pages anyway.
                        //std::cout << "[INFO] Aging frequency CBF twice (divide all counters by 4)" << std::endl;
                        //lfu.age();
                        lfu.age();
                        momentum.age();
                        // Reset 2nd chance queues after aging, since the page frequencies are now lower than before
                        second_chance_queue.clear(); 
                        second_chance_oldfreq.clear(); 
                        printf("Clearing 2nd chance queue \n");
                        // Wake up with less aggressive sampling frequency. Give the workload a chance to settle into 
                        // monitoring mode.
                        // Reset hot threshold since it may have been reduced due to promotion plateau
                        hot_thresh = initial_hot_thresh;
                        printf("Reset hot threshold to %d \n", hot_thresh);
                        //perf_sample_freq = perf_sample_freq_list[3];
                        full_sweep_not_enough_cold_pages_once = false; // Reset
                        goto perf_sampling_start;
                      } else if (!full_sweep_not_enough_cold_pages_once && full_sweep_not_enough_cold_pages)  {
                        // Record the fact that we performed a full demotion sweep and did not find any cold pages.
                        full_sweep_not_enough_cold_pages_once = true;
                        std::cout << "Record 1/2 full sweep with no cold pages " << std::endl;
                      } else if (full_sweep_not_enough_cold_pages_once && !full_sweep_not_enough_cold_pages)  {
                        // If the previous demotion sweep did not find enough cold pages and we were able to find more cold
                        // pages in this sweep, clear flag since we are looking for two consecutive full sweeps. 
                        full_sweep_not_enough_cold_pages_once = false;
                        demotion_reset_count++;
                        std::cout << "Reset. Waiting for two consecutive sweeps. Reset count " << demotion_reset_count << std::endl;
                        if (demotion_reset_count == 10) {
                          std::cout << "sweeped address space 10 times and still cold pages left. Give up for now. Entering monitor mode." << std::endl;
                          low_overhead_monitor();
                          lfu.age();
                          momentum.age();
                          demotion_reset_count = 0;
                          full_sweep_not_enough_cold_pages_once = false; // Reset
                          hot_thresh = initial_hot_thresh;
                          printf("Reset hot threshold to %d \n", hot_thresh);
                          // Reset 2nd chance queues after aging, since the page frequencies are now lower than before
                          second_chance_queue.clear(); 
                          second_chance_oldfreq.clear(); 
                          printf("Clearing 2nd chance queue \n");
                          goto perf_sampling_start;
                        }
                      }
                    }
                    num_sample_batches++;

                    // Check for promotion plateau: if we promoted less than (40MB) in 20 sample batches, 
                    // this is an indicator that there are not much hot pages left to promote. Thus, keeping 
                    // perf sampling ON is likely a waste of resources. 
                    bool promotion_plateau_detected = false;
                    //printf("[DEBUG] new num_pages_promoted_history = %ld \n", num_pages_promoted_history);
                    if (num_sample_batches % 50 == 49){
                      printf("[DEBUG] Number of hot pages promoted in 50 batches = %ld \n", num_pages_promoted_history);
                      if (num_sample_batches > 100) {
                        // dont go to plateau in the first 1000 batches = 10M samples. 
                        if (num_pages_promoted_history <= 100) {
                          promotion_plateau_detected = true;
                        }
                      }
                      num_pages_promoted_history = 0; // reset
                    }
                    
                    if (promotion_plateau_detected) {
                      uint64_t cur_num_hot_pages = lfu.get_num_hot_pages(hot_thresh);
                      uint64_t cur_num_hot_pages_size_bytes = cur_num_hot_pages*PAGE_SIZE;
                      std::cout << "[INFO] Reached promotion plateau. cur hot page size " << cur_num_hot_pages_size_bytes << ", fast mem 80% " << fast_memory_size*8/10 << std::endl;
                      if (cur_num_hot_pages_size_bytes < fast_memory_size*8/10) { 
                        // If there are not enough hot pages to fill 80% of fast tier memory,
                        // decrease hot threshold to allow more pages to be promoted. 
                        // Intuitively, if there are more free space in fast tier memory, try to lower
                        // the promotion requirements and promote more.
                        if (hot_thresh == 600) { 
                          // Not going below hot threshold = 2. Experimentally there seems to be a 
                          // large amount of pages with frequency = 1. Not worth it to promote all of them.
                          printf("[INFO] Hot thresh already at minimum. Not decreasing it. Go to monitor mode\n");
                          low_overhead_monitor();
                          // When waking up from monitoring mode, age counters. If not aging here, then we would
                          // likely still not be able to find more hot pages to promote. 
                          //lfu.age();
                          momentum.age();
                          // Wake up with less aggressive sampling frequency. Give the workload a chance to settle into 
                          // monitoring mode.
                          //perf_sample_freq = perf_sample_freq_list[3];
                          // Reset hot threshold since it may have been reduced due to promotion plateau
                          //hot_thresh = initial_hot_thresh;
                          hot_thresh = hot_thresh + 100;
                          printf("Reset hot threshold to %d \n", hot_thresh);
                          // Reset 2nd chance queues after aging, since the page frequencies are now lower than before
                          second_chance_queue.clear(); 
                          second_chance_oldfreq.clear(); 
                          printf("Clearing 2nd chance queue \n");
                          goto perf_sampling_start;
                        } else { 
                          hot_thresh -= 100;
                          printf("[INFO] Decrease hot thresh to %d.\n", hot_thresh);
                        }
                      } else {
                        // If we hit promotion plateau and there are no more free spaces in fast tier memory,
                        // go to monitor mode since there is not much else we can do.
                        std::cout << "[INFO] Go to monitor mode from promotion plateau." << std::endl;
                        low_overhead_monitor();
                        lfu.age();
                        momentum.age();
                        // Reset hot threshold since it may have been reduced due to promotion plateau
                        hot_thresh = initial_hot_thresh;
                        printf("Reset hot threshold to %d \n", hot_thresh);
                        // Reset 2nd chance queues after aging, since the page frequencies are now lower than before
                        second_chance_queue.clear(); 
                        second_chance_oldfreq.clear(); 
                        printf("Clearing 2nd chance queue \n");
                        //perf_sample_freq = perf_sample_freq_list[3];
                        goto perf_sampling_start;
                      }
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
          
          if (drop_local_sample_freq) {
            // We have marked that we need to drop the sampling frequency on local node.
            if (perf_sample_freq_local > 20000) { // minimum 20kHz
              perf_sample_freq_local = perf_sample_freq_local / 2;
              printf("frac of unuseful samples too high. Dropping fast tier sampling frequency to %llu \n", perf_sample_freq_local);
              for (int ii = 0; ii < NPROC; ii++) {
                change_perf_freq(ii, LOCAL_DRAM_LOAD, perf_sample_freq_local);
              }
              drop_local_sample_freq = false;
            }
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


  
