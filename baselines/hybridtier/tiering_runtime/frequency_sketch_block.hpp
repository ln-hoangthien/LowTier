/* Copyright 2017 https://github.com/mandreyel
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of this
 * software and associated documentation files (the "Software"), to deal in the Software
 * without restriction, including without limitation the rights to use, copy, modify,
 * merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be included in all copies
 * or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 * PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 * CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
 * OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#ifndef FREQUENCY_SKETCH_HEADER
#define FREQUENCY_SKETCH_HEADER

#include "detail.hpp"

#include <vector>
#include <cmath>
#include <stdexcept>
#include <limits>
#include <emmintrin.h>
#include <smmintrin.h>

/**
 * A probabilistic set for estimating the popularity (frequency) of an element within an
 * access frequency based time window. The maximum frequency of an element is limited
 * to 15 (4-bits).
 *
 * NOTE: the capacity will be the nearest power of two of the input capacity (for various
 * efficiency and hash distribution gains).
 *
 * This is a slightly altered version of Caffeine's implementation:
 * https://github.com/ben-manes/caffeine
 *
 * The white paper:
 * http://dimacs.rutgers.edu/~graham/pubs/papers/cm-full.pdf
 */

//TODO: nothing here should be int. Everything should be unsigned (e.g. uint64_t)
template<typename T>
class frequency_sketch
{
    // Holds 64 bit blocks, each of which holds sixteen 4 bit counters. For simplicity's
    // sake, the 64 bit blocks are partitioned into four 16 bit sub-blocks, and the four
    // counters corresponding to some T is within a single such sub-block.
    //std::vector<uint64_t> table_;
    uint64_t* table_;
    uint64_t table_size_;

    // Incremented with each call to record_access, if the frequency of the item could
    // be incremented, and halved when sampling size is reached.
    uint64_t size_;

    // Count the number of items with a particular frequency in TinyLFU. E.g. frequency_dist[5] = 1000 means
    // there are 1000 items that have frequency = 5 in TinyLFU.
    // Not counting items with frequency = 0, so frequency_dist[0] should always be 0
    uint64_t frequency_dist[16]= {0};

    // W in the original paper. The age operation is launched when size_ reaches this value.
    uint64_t sample_size_;

    uint64_t blockMask_;

    // Arrays used when modifying CBF
    uint32_t index_[8];
    uint32_t freqs_[4];
    
    // Count the number of address sampled but already have access count of 15 (max),
    // hence not useful. Used for testing only.
    uint64_t num_nonuseful_samples_ = 0;

public:
    explicit frequency_sketch(int capacity, uint64_t sample_size)
    {
        change_capacity(capacity);
        sample_size_ = sample_size;
        printf("Blocked CBF + sample batch. \n");
        printf("vector start %p, \n", &(table_[0]));
        std::cout << "[INFO] Creating CBF with capacity = " << table_size_ << " (each 8B), sample size (W) = " << sample_size << std::endl;
    }

    uint32_t spread(uint32_t x) const {
      x ^= x >> 17;
      x *= 0xed5ad4bb;
      x ^= x >> 11;
      x *= 0xac4c1b51;
      x ^= x >> 15;
      return x;
    }

    uint32_t rehash(uint32_t x) const {
      x *= 0x31848bab;
      x ^= x >> 14;
      return x;
    }

    void change_capacity(const int n)
    {
        //std::cout << "WARNING! Aging is turned off for testing." << std::endl;
        if(n <= 0)
        {
            throw std::invalid_argument("frequency_sketch capacity must be larger than 0");
        }
        //table_.resize(detail::nearest_power_of_two(n));
        table_size_ = detail::nearest_power_of_two(n);
        table_ = (uint64_t*)aligned_alloc(64, sizeof(uint64_t) * table_size_);
        printf("Actual CBF table size %ld \n", table_size_);
        size_ = 0;

        blockMask_ = (table_size_ >> 3) - 1;
        printf("block mask %lx \n", blockMask_);
    }

    bool contains(const T& t) const noexcept
    {
        return frequency(t) > 0;
    }

    //TODO return type should be 4 bit unsigned int (uint8_t also works)
    int frequency(const T& t) const noexcept
    {

      uint32_t *count = new uint32_t[4];
      const uint32_t hash = detail::hash(t);
      uint32_t blockHash = spread(hash);
      uint32_t counterHash = rehash(blockHash);
      uint32_t block = (blockHash & blockMask_) << 3;
      for (uint32_t i = 0; i < 4; i++) {
          uint32_t h = counterHash >> (i << 3);
          uint32_t index = (h >> 1) & 15;
          uint32_t offset = h & 1;
          count[i] = (uint32_t) ((table_[block + offset + (i << 1)] >> (index << 2)) & 0xfL);
      }
      int ret = std::min(std::min(count[0], count[1]), std::min(count[2], count[3]));
      delete[] count;
      return ret;
    }

    // Decrement the frequency of t. Used by demotion second chance
    void decrement_frequency(const T& t) noexcept
    {
      const uint32_t hash = detail::hash(t);
      uint32_t blockHash = spread(hash);
      uint32_t counterHash = rehash(blockHash);
      uint32_t block = (blockHash & blockMask_) << 3;

      uint32_t decrement_index[8];

      for (int i = 0; i < 4; i++) {
        uint32_t h = counterHash >> (i << 3);
        decrement_index[i] = (h >> 1) & 15;
        uint32_t offset = h & 1;
        decrement_index[i + 4] = block + offset + (i << 1);
      }

      decrement_counter_at(decrement_index[4], decrement_index[0]);
      decrement_counter_at(decrement_index[5], decrement_index[1]);
      decrement_counter_at(decrement_index[6], decrement_index[2]);
      decrement_counter_at(decrement_index[7], decrement_index[3]);

    }

    // Increase the frequency of t by increase_amount
    void increase_frequency(const T& t, uint32_t increase_amount, uint32_t* updated_freq) noexcept
    {
        const uint32_t hash = detail::hash(t);
        uint32_t blockHash = spread(hash);
        uint32_t counterHash = rehash(blockHash);
        uint32_t block = (blockHash & blockMask_) << 3;

        for (int i = 0; i < 4; i++) {
          uint32_t h = counterHash >> (i << 3);
          index_[i] = (h >> 1) & 15;
          uint32_t offset = h & 1;
          index_[i + 4] = block + offset + (i << 1);
        }
      
        bool was_added = false;

        // The actual counter increased.
        // TODO: merge these 4 calls into 1? 
        uint64_t increased_amount0 = try_increase_counter_at(index_[4], index_[0], increase_amount, &(freqs_[0]));
        uint64_t increased_amount1 = try_increase_counter_at(index_[5], index_[1], increase_amount, &(freqs_[1]));
        uint64_t increased_amount2 = try_increase_counter_at(index_[6], index_[2], increase_amount, &(freqs_[2]));
        uint64_t increased_amount3 = try_increase_counter_at(index_[7], index_[3], increase_amount, &(freqs_[3]));

        uint64_t max_increased_amount = std::max(std::max(increased_amount0, increased_amount1), std::max(increased_amount2, increased_amount3));
        
        *updated_freq = std::min(std::min(freqs_[0], freqs_[1]), std::min(freqs_[2], freqs_[3]));

        // Received increase_amount samples
        size_ += increase_amount;

        if(size_ >= sample_size_) {
            age();
            *updated_freq = *updated_freq / 2;
        }

        if(max_increased_amount != 0) {
          // frequency of item T was incremented by 1.
          frequency_dist[*updated_freq]++;
          if (*updated_freq - max_increased_amount > 0) {
            frequency_dist[*updated_freq - max_increased_amount]--;
          }
        }
        if(max_increased_amount == 0) {
          // No counters are incremented. This occurs when all 4 counters are at max value (15) already.
          // Thus, the filter is not changed and these samples are considered unuseful.
          num_nonuseful_samples_ += increase_amount;
        }
    }

    void record_access(const T& t, uint32_t* updated_freq) noexcept
    {
        const uint32_t hash = detail::hash(t);
        uint32_t blockHash = spread(hash);
        uint32_t counterHash = rehash(blockHash);
        uint32_t block = (blockHash & blockMask_) << 3;

        uint32_t *index = new uint32_t[8];
        uint32_t *freqs = new uint32_t[4];

        for (int i = 0; i < 4; i++) {
          uint32_t h = counterHash >> (i << 3);
          index[i] = (h >> 1) & 15;
          uint32_t offset = h & 1;
          index[i + 4] = block + offset + (i << 1);
        }
      
        bool was_added = false;

        was_added = 
                try_increment_counter_at(index[4], index[0], &(freqs[0]))
              | try_increment_counter_at(index[5], index[1], &(freqs[1]))
              | try_increment_counter_at(index[6], index[2], &(freqs[2]))
              | try_increment_counter_at(index[7], index[3], &(freqs[3]));
        
        *updated_freq = std::min(std::min(freqs[0], freqs[1]), std::min(freqs[2], freqs[3]));

        if(was_added && (++size_ >= sample_size_))
        {
            age();
            *updated_freq = *updated_freq / 2;
        }

        //int incremented_freq = frequency(t);
        //printf("record_access: incremented_freq %d \n", incremented_freq);
        if(was_added) {
          // frequency of item T was incremented by 1.
          frequency_dist[*updated_freq]++;
          if (*updated_freq > 1) {
            // no need to decrement count of frequency=0.
            frequency_dist[*updated_freq-1]--;
          }
        }

        delete[] index;
        delete[] freqs;
    }

    
    void reset_freq(const T& t) noexcept
    {
        const uint32_t hash = detail::hash(t);
        uint32_t blockHash = spread(hash);
        uint32_t counterHash = rehash(blockHash);
        uint32_t block = (blockHash & blockMask_) << 3;

        uint32_t *index = new uint32_t[8];
        uint32_t *freqs = new uint32_t[4];

        for (int i = 0; i < 4; i++) {
          uint32_t h = counterHash >> (i << 3);
          index[i] = (h >> 1) & 15;
          uint32_t offset = h & 1;
          index[i + 4] = block + offset + (i << 1);
        }
      
        reset_counter_at(index[4], index[0], &(freqs[0]));
        reset_counter_at(index[5], index[1], &(freqs[1]));
        reset_counter_at(index[6], index[2], &(freqs[2]));
        reset_counter_at(index[7], index[3], &(freqs[3]));
        int orig_freq = std::min(std::min(freqs[0], freqs[1]), std::min(freqs[2], freqs[3]));
        if (orig_freq > 0) { 
          frequency_dist[orig_freq]--;
        }

        delete[] index;
        delete[] freqs;
    }
        

    void print_frequency_dist() {
      printf("CBF freq dist: %ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld \n", 
                                 frequency_dist[0], frequency_dist[1], frequency_dist[2], frequency_dist[3],
                                 frequency_dist[4], frequency_dist[5], frequency_dist[6], frequency_dist[7],
                                 frequency_dist[8], frequency_dist[9], frequency_dist[10], frequency_dist[11],
                                 frequency_dist[12], frequency_dist[13], frequency_dist[14], frequency_dist[15]);
    }

    // Return the number of pages in the bloom filter that has frequency >= hot_thresh.
    uint64_t get_num_hot_pages(uint32_t hot_thresh) {
      if (hot_thresh > 15 || hot_thresh < 1) {
        return 0;
      }
      uint64_t sum = 0;
      for (int i = hot_thresh; i < 16; i++) { 
        sum += frequency_dist[i];
      }
      return sum;
    }

    uint64_t get_size() {
      return size_;
    }

    uint64_t get_num_elements() {
      uint64_t sum = 0;
      for(auto i = 0; i < 16; ++i) {
        sum += frequency_dist[i];
      }
      return sum;
    }

    uint32_t find_hot_thresh(uint64_t num_fast_memory_pages) {
      // Return the appropriate hot item threshold.
      // Given the current frequency distribution, the hot threshold is the highest frequency
      // such that all pages with frequency >= this hot threshold exceeds the fast memory capacity.
      // E.g. currently the TinyLFU contains 100 items with frequency 15, 50 with freq 14, 30 with freq 13.
      // If the fast memory can contain 120 pages max, then hot threshold = 14. 
      // The minimum hot threshold is 2. Having hot threshold = 1 does not make much sense at this moment,
      // since no locality is guaranteed.
      uint64_t sum = 0;
      for (uint32_t i = 15; i > 1; i--){
        sum += frequency_dist[i];
        if (sum > num_fast_memory_pages) {
          return i;
        }
      }
      // If the total number of page items in TinyLFU is smaller than the fast memory
      // size (they all fit), promote pages with freq >= 2.
      // This would happen e.g. when the TinyLFU is first initialized.
      // 
      return 2;
    }

    void reset() noexcept
    {
        printf("[DEBUG] Resetting CBF counters.\n");
        for(uint32_t i = 0; i < table_size_; i++) {
            table_[i] = 0;
        }
        size_ = 0;
        // Also adjust frequency distribution array.
        // E.g. all the items with freq 2 and 3 become freq 1, 4 and 5 become 2 etc.
        for(int i = 1; i < 16; i++){
          frequency_dist[i] = 0;
        }
    }

    /** Halves every counter and adjusts $size_. */
    void age() noexcept
    {
        printf("[DEBUG] Halving CBF counters.\n");
        for(uint32_t i = 0; i < table_size_; i++) {
            // Do a 'bitwise_and' on each (4 bit) counter with 0111 (7) so as to
            // eliminate the bit that got shifted over from the counter to the left to
            // the leftmost position of the current counter.
            table_[i] = (table_[i] >> 1) & 0x7777777777777777L;
        }
        size_ /= 2;
        // Also adjust frequency distribution array.
        // E.g. all the items with freq 2 and 3 become freq 1, 4 and 5 become 2 etc.
        for(int i = 1; i < 8; i++){
          frequency_dist[i] = frequency_dist[i*2] + frequency_dist[i*2+1];
        }
        for(int i = 8; i < 16; i++){
          frequency_dist[i] = 0;
        }
    }

    uint64_t get_num_nonuseful_samples() {
      return num_nonuseful_samples_;
    }

    void clear_num_nonuseful_samples() {
      num_nonuseful_samples_ = 0;
    }

private:
    void decrement_counter_at(const uint32_t i, const uint32_t j)
    {
        uint64_t offset = j << 2;
        long mask = (0xfL << offset);
        uint64_t orig_freq = (table_[i] & mask) >> offset;
        table_[i] -= (1L << offset);
    }

    uint32_t try_increase_counter_at(const uint32_t i, const uint32_t j, uint32_t increase_amount, uint32_t *updated_freq)
    {
        uint64_t add = increase_amount > 15 ? 15 : increase_amount;
        uint64_t offset = j << 2;
        long mask = (0xfL << offset);
        uint32_t increased_amount = 0;
        uint64_t orig_freq = (table_[i] & mask) >> offset;
        if (orig_freq >= 15) {
          // Already maxed out. Nothing to increase
          *updated_freq = 15;
          return 0;
        }
        if (orig_freq + add >= 15) {
          // Set this counter to 15
          table_[i] |= (0xfL << offset); 
          increased_amount = 15 - orig_freq;
        } else {
          table_[i] += (add << offset);
          increased_amount = increase_amount;
        }
        *updated_freq = (table_[i] & mask) >> offset;
        return increased_amount;
    }

    void reset_counter_at(const uint32_t i, const uint32_t j, uint32_t *orig_freq)
    {
        uint32_t offset = j << 2;
        long mask = (0xfL << offset);
        *orig_freq = (table_[i] & mask) >> offset;
        table_[i] = table_[i] & (~mask);
    }

    bool try_increment_counter_at(const uint32_t i, const uint32_t j, uint32_t *updated_freq)
    {
        uint32_t offset = j << 2;
        long mask = (0xfL << offset);
        //printf("i: %d j: %d, mask: %x \n", i, j, mask);
        if ((table_[i] & mask) != mask) {
          //printf("try incr: %d \n", (table_[i] & mask) >> offset);
          table_[i] += (1L << offset);
          //printf("try incr2: %d \n", (table_[i] & mask) >> offset);
          *updated_freq = (table_[i] & mask) >> offset;
          return true;
        }
        *updated_freq = (table_[i] & mask) >> offset;
        return false;
    }

};

#endif
