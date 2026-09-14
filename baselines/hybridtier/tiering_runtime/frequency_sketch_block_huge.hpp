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
 * to 256 (8-bits).
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

/* Some notes. Need to make them more organized.
element: the data structure used to keep counters. multiple counters share the same element (64 bit here)
counter: the actual thing that keeps count (16 bit here)

table_size = number of 64bit elements 
	lets say 2^10, 1024 = 0x400 = 0b 100 0000 0000

each counter is 16 bits
block size = 128B, so total 64 blocks, each block contains 64 counters or 16 elements

blockMask_ = (table_size_ >> 4) - 1 = 0x3f = 0b 11 1111  
	this mask is used to find the block (0 to 63)
	
block = (blockHash & blockMask_) << 4;
	blockHash is basically a random number. 
	& with mask gives 0 to 63. 
	shift left by 4: leave 4 bit of space for offset within a block -> which 1 out of 16 elements to pick in a block
	
h = counterHash >> (i << 3)
	again, hash is a random number. 
	i correspond to 4 counters, so i << 3 gives 0, 8, 16, 24
	this is just to use different portions of counterhash. Use 8 bits at a time
	
index[i] = (h >> 1) & 3;
	take 2 bits (essentially random) as j, which selects which counter to use within the element (0 to 3)

offset = h & 1; index[i + 4] = block + offset + (i << 1);
	offset is a rand 0 or 1. 
	block gives which block, which contains multiple elements.
	index[i + 4] decides which element to use in a block (0 to 15)
	i << 2 gives 0, 4, 8, 12 respectively, which ensures the elements chosen are spread out. 

in try_increase_counter_at(i, j)
j selects which 8 bit counter in the 64 bit element (0 to 7)

offset = j << 3
	e.g if j is 2 (select the 2nd counter), offset = 2*8 = 16, which is the bit position of the jth counter

mask = (0xffL << offset)
	0xff selects the 8 bit counter
	shift to line up with the jth counter
	
*/

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

    // Count the number of items with a particular frequency in CBF. E.g. frequency_dist[5] = 1000 means
    // there are 1000 items that have frequency = 5 in CBF.
    // Not counting items with frequency = 0, so frequency_dist[0] should always be 0
    uint64_t frequency_dist[65536]= {0};
    
    // Used for testing. 
    uint64_t num_hot_pages = 0;

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
        //std::cout << "[INFO] Creating CBF with capacity = " << table_.size() << " (each 8B), sample size (W) = " << sample_size << std::endl;
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
        printf("Actual LFU table size %ld \n", table_size_);
        size_ = 0;

        blockMask_ = (table_size_ >> 3) - 1;
        printf("block mask %lx \n", blockMask_);
    }

    bool contains(const T& t) const noexcept
    {
        return frequency(t) > 0;
    }

    //TODO return type should be 8 bit unsigned int 
    int frequency(const T& t) const noexcept
    {

      uint32_t *count = new uint32_t[4];
      const uint32_t hash = detail::hash(t);
      uint32_t blockHash = spread(hash);
      uint32_t counterHash = rehash(blockHash);
      // each (64B) block contains 8*uint64_t
      uint32_t block = (blockHash & blockMask_) << 3;
      for (uint32_t i = 0; i < 4; i++) {
          uint32_t h = counterHash >> (i << 3);
          uint32_t index = (h >> 1) & 3;
          uint32_t offset = h & 1;
          count[i] = (uint32_t) ((table_[block + offset + (i << 1)] >> (index << 4)) & 0xffffL);
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
        decrement_index[i] = (h >> 1) & 7;
        uint32_t offset = h & 1;
        decrement_index[i + 4] = block + offset + (i << 1);
      }

      decrement_counter_at(decrement_index[4], decrement_index[0]);
      decrement_counter_at(decrement_index[5], decrement_index[1]);
      decrement_counter_at(decrement_index[6], decrement_index[2]);
      decrement_counter_at(decrement_index[7], decrement_index[3]);

    }

    // Increase the frequency of t by increase_amount
    void increase_frequency(const T& t, uint32_t increase_amount, uint32_t* updated_freq, int print = 0) noexcept
    {
        // 128B blocks, 16 bit counters -> 64 counters per block
        const uint32_t hash = detail::hash(t);
        uint32_t blockHash = spread(hash);
        uint32_t counterHash = rehash(blockHash);
        uint32_t block = (blockHash & blockMask_) << 3;

        // Each key hashes to 4 counters within the same block
        for (int i = 0; i < 4; i++) {
          // use different portions of counterHash. h is effectively another hash
          uint32_t h = counterHash >> (i << 3);
          index_[i] = (h >> 1) & 3;
          uint32_t offset = h & 1;
          index_[i + 4] = block + offset + (i << 1);
        }
      
        bool was_added = false;

        // Try to increase the counters at all 4 positions.
        //if (print) {
        //  printf("orig freq %d \n", frequency(t));
        //}

        uint64_t increased_amount0 = try_increase_counter_at(index_[4], index_[0], increase_amount, &(freqs_[0]), print);
        uint64_t increased_amount1 = try_increase_counter_at(index_[5], index_[1], increase_amount, &(freqs_[1]), print);
        uint64_t increased_amount2 = try_increase_counter_at(index_[6], index_[2], increase_amount, &(freqs_[2]), print);
        uint64_t increased_amount3 = try_increase_counter_at(index_[7], index_[3], increase_amount, &(freqs_[3]), print);

        uint64_t max_increased_amount = std::max(std::max(increased_amount0, increased_amount1), std::max(increased_amount2, increased_amount3));
        
        // The smallest counter out of the 4 is used as the count of this key
        *updated_freq = std::min(std::min(freqs_[0], freqs_[1]), std::min(freqs_[2], freqs_[3]));

        //if (print) {
        //  printf("updated freq %d, max incr amount %d \n", *updated_freq, max_increased_amount);
        //}

        // Received increase_amount samples
        size_ += increase_amount;


        // Update frequency distribution histogram. 
        // E.g. The 4 counters are originally 14, 2, 5, 7
        //      increase_amount = 4
        //      new counters become 15, 6, 9, 11
        //      updated_freq = 6
        //      max_increased_amount = 4
        //      So this key used to have frequency 2. Now it has frequency 6.
        // E.g. If counters are originally 0, 0, 0, 0
        //      updated_freq will equal max_increased_amount 
        //      since the histogram does not track pages with 0 frequency, do not subtract from the 0 bin
        if(max_increased_amount != 0) {
          frequency_dist[*updated_freq]++;
          //if (print) {
          //  printf("bin %d freq++ \n", *updated_freq);
          //}
          if (*updated_freq - max_increased_amount > 0) {
            //if (print) {
            //  printf("bin %d freq-- \n", *updated_freq - max_increased_amount);
            //}
            frequency_dist[*updated_freq - max_increased_amount]--;
          }
        }

        if(max_increased_amount == 0) {
          // No counters are incremented. This occurs when all 4 counters are at max value (15) already.
          // Thus, the filter is not changed and these samples are considered unuseful.
          num_nonuseful_samples_ += increase_amount;
        }

        if(size_ >= sample_size_) {
            age();
            *updated_freq = *updated_freq / 2;
        }

        //if (print) {
        //  printf("updated_freq %x \n", *updated_freq);
        //}
    }

    
    void print_frequency_dist() {
      uint64_t sum1 = 0;
      uint64_t sum2 = 0;
      uint64_t sum3 = 0;
      uint64_t sum4 = 0;
      uint64_t sum5 = 0;
      uint64_t sum6 = 0;
      for (int i = 1; i < 100; i++){
        sum1 += frequency_dist[i];
      }
      for (int i = 100; i < 1000; i++){
        sum2 += frequency_dist[i];
      }
      for (int i = 1000; i < 2000; i++){
        sum3 += frequency_dist[i];
      }
      for (int i = 2000; i < 3000; i++){
        sum4 += frequency_dist[i];
      }
      for (int i = 3000; i < 5000; i++){
        sum5 += frequency_dist[i];
      }
      for (int i = 5000; i < 65535; i++){
        sum6 += frequency_dist[i];
      }
      printf("CBF freq dist: (1) %ld, (1-100) %ld, (100-1000) %ld, (1k-2k) %ld, (2k-3k) %ld, (3k-5k) %ld, (5k-65534) %ld, (65k) %ld \n", 
                                 frequency_dist[1], sum1, sum2, sum3, sum4, sum5, sum6, frequency_dist[65535]);

    }

    // Return the number of pages in the bloom filter that has frequency >= hot_thresh.
    uint64_t get_num_hot_pages(uint32_t hot_thresh) {
      uint64_t sum = 0;
      for (int i = hot_thresh; i < 65536; i++) { 
        sum += frequency_dist[i];
      }
      return sum;
    }

    uint64_t get_size() {
      return size_;
    }

    uint64_t get_num_elements() {
      uint64_t sum = 0;
      for(auto i = 0; i < 65536; ++i) {
        sum += frequency_dist[i];
      }
      return sum;
    }

    /** Halves every counter and adjusts $size_. */
    void age() noexcept
    {
        printf("[DEBUG] Halving CBF counters.\n");
        for(uint32_t i = 0; i < table_size_; i++) {
            // Do a 'bitwise_and' on each (16 bit) counter with 0x7fff so as to
            // eliminate the bit that got shifted over from the counter to the left to
            // the leftmost position of the current counter.
            //printf("table %d before %lx \n", i, table_[i]);
            table_[i] = (table_[i] >> 1) & 0x7fff7fff7fff7fffL;
            //printf("table %d after %lx \n", i, table_[i]);
        }
        size_ /= 2;
        // Also adjust frequency distribution array.
        // E.g. all the items with freq 2 and 3 become freq 1, 4 and 5 become 2 etc.
        for(int i = 1; i < 32768; i++){
          frequency_dist[i] = frequency_dist[i*2] + frequency_dist[i*2+1];
        }
        for(int i = 32768; i < 65536; i++){
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
        uint64_t offset = j << 4;
        long mask = (0xffffL << offset);
        uint64_t orig_freq = (table_[i] & mask) >> offset;
        table_[i] -= (1L << offset);
    }

    // i selects which 64 bit element in the block, j selects which 8 bit counter in the 64 bit element (max 7)
    // Returns 
    uint32_t try_increase_counter_at(const uint32_t i, const uint32_t j, uint32_t increase_amount, uint32_t *updated_freq, int print = 0)
    {
        
        //if (print) {
        //  printf("table i %d \n", i);
        //}
        uint64_t add = increase_amount > 65535 ? 65535 : increase_amount;
        //printf("i %d, j %d, amount %d \n", i, j, increase_amount);
        uint64_t offset = j << 4;
        long mask = (0xffffL << offset);
        uint32_t increased_amount = 0;
        uint64_t orig_freq = (table_[i] & mask) >> offset;
        //if (print) {
        //  printf("counter orig val %lx \n", orig_freq);
        //}
        if (orig_freq + add >= 65535) {
          // Set this counter to the max value (255)
          table_[i] |= (0xffffL << offset); 
          increased_amount = 65535 - orig_freq;
        } else {
          table_[i] += (add << offset);
          increased_amount = increase_amount;
        }
        *updated_freq = (table_[i] & mask) >> offset;
        //if (print) {
        //  printf("counter updated val %lx \n", *updated_freq);
        //}
        return increased_amount;
    }

};

#endif
