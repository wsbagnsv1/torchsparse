#pragma once
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

// Use std::unordered_map instead of dense_hash_map for Windows compatibility
#ifdef _WIN32
    #include <unordered_map>
#else
    #include <google/dense_hash_map>
#endif

class HashTableCPU {
 private:
#ifdef _WIN32
  std::unordered_map<int64_t, int64_t> hashmap;
#else
  google::dense_hash_map<int64_t, int64_t> hashmap;
#endif

 public:
  HashTableCPU() {
#ifndef _WIN32
    // Only set empty key for dense_hash_map, not for std::unordered_map
    hashmap.set_empty_key(-1);  // Use -1 as empty key (adjust if needed)
#endif
  }
  
  ~HashTableCPU() {}
  
  void insert_vals(const int64_t* const keys, const int64_t* const vals,
                   const int n);
  void lookup_vals(const int64_t* const keys, int64_t* const results,
                   const int n);
};
