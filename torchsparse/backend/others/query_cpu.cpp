#include "query_cpu.h"
#include <torch/torch.h>
#include <cmath>
#ifdef _WIN32
    #include <unordered_map>
#else
    #include <google/dense_hash_map>
#endif
#include <iostream>
#include <vector>
#include "../hashmap/hashmap_cpu.hpp"

at::Tensor hash_query_cpu(const at::Tensor hash_query,
                          const at::Tensor hash_target,
                          const at::Tensor idx_target) {
  int n = hash_target.size(0);
  int n1 = hash_query.size(0);
  
#ifdef _WIN32
  std::unordered_map<int64_t, int64_t> hashmap;
#else
  google::dense_hash_map<int64_t, int64_t> hashmap;
  hashmap.set_empty_key(0);
#endif

  at::Tensor out = torch::zeros(
      {n1}, at::device(hash_query.device()).dtype(at::ScalarType::Long));
      
  // Build hashmap
  for (int idx = 0; idx < n; idx++) {
    int64_t key = *(hash_target.data_ptr<int64_t>() + idx);
    int64_t val = *(idx_target.data_ptr<int64_t>() + idx) + 1;
    hashmap[key] = val;
  }
  
  // Query hashmap
#pragma omp parallel for
  for (int idx = 0; idx < n1; idx++) {
    int64_t key = *(hash_query.data_ptr<int64_t>() + idx);
    auto iter = hashmap.find(key);
    if (iter != hashmap.end()) {
      *(out.data_ptr<int64_t>() + idx) = iter->second;
    }
  }
  return out;
}
