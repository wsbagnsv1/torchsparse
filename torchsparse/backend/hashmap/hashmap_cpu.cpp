#include "hashmap_cpu.hpp"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>

// Fix 1: Use std::unordered_map instead of dense_hash_map for Windows compatibility
#include <unordered_map>

void HashTableCPU::lookup_vals(const int64_t* const keys,
                               int64_t* const results, const int n) {
#pragma omp parallel for
  for (int idx = 0; idx < n; idx++) {
    int64_t key = keys[idx];
    // Change this line - use auto instead of explicit iterator type
    auto iter = hashmap.find(key);
    if (iter != hashmap.end()) {
      results[idx] = iter->second;
    } else {
      results[idx] = 0;
    }
  }
}

void HashTableCPU::insert_vals(const int64_t* const keys,
                               const int64_t* const vals, const int n) {
  // Fix the loop logic and implement the actual insertion
  for (int i = 0; i < n; i++) {  // Changed from i < 10 to i < n
    // Remove debug printf or make it conditional
    #ifdef DEBUG
    printf("Inserting: key=%lld, val=%lld\n", keys[i], vals[i]);
    #endif
    
    // Actually insert the values into the hashmap
    hashmap[keys[i]] = vals[i];
  }
}
