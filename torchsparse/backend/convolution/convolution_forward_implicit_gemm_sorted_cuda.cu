#ifdef _MSC_VER // MSVC compiler (used by nvcc on Windows)
#define __asm__ asm
#define __volatile__ volatile
#endif

#include <torch/extension.h>
#include "convolution_forward_implicit_gemm_sorted_cuda.h"
#include "../utils/memory.cuh"
#include <cuda_fp16.h>
#include <stdexcept>

// Pack two half values.
static inline __device__ __host__ unsigned
__pack_half2(const half x, const half y)
{
  unsigned v0 = *((unsigned short *)&x);
  unsigned v1 = *((unsigned short *)&y);
  return (v1 << 16) | v0;
}


// conv_forward_cuda_m128n16k16_m64n16k16_m16n16k16_f16f16f32_sort
template <int K_ld_factor, int N_ld_factor, bool K_ld_check, bool N_ld_check>
__global__ void __launch_bounds__(64) conv_forward_cuda_setting1_mode1_f16f16f32(int M, int K_original, int N, int kernel_volume, int split_mask_len, int reduced_mask_len, int reorder_loc_len, half *__restrict__ A, half *__restrict__ B, int *__restrict__ reduced_mask, int *__restrict__ out_in_map, int *__restrict__ reorder_loc, half *__restrict__ C)
{
  const int K_tile = 16; 
  int K_tile_padded = K_tile * ((K_original + K_tile - 1) / K_tile);
  int K_implicit = K_tile_padded * kernel_volume;

  float C_warp[32];
  __shared__ half A_shared[5120];
  __shared__ half B_shared[640];
  half A_shared_warp[32];
  half B_shared_warp[8];
  for (int i0_0_3_init = 0; i0_0_3_init < 4; ++i0_0_3_init)
  {
    for (int i = 0; i < 8; ++i)
    {
      C_warp[(i0_0_3_init * 8) + i] = 0.0;
    };
  }

  // hoisting shared pointer offsets
  int j_factors1 = (N + 15) / 16 / 1;
  int blockIdx_x = 0;
  int blockIdx_y = blockIdx.x % ((M + 128 - 1) / 128 * j_factors1);
  int blockIdx_z = blockIdx.x / ((M + 128 - 1) / 128 * j_factors1);
  int out_in_map_offset = blockIdx_y / j_factors1 * 128 
      + threadIdx.y * 16 
      + threadIdx.x / 2;
  int* out_in_map_ptr = out_in_map
    + out_in_map_offset * kernel_volume
    + ((threadIdx.y * 256) % 16) / K_tile_padded
    + ((threadIdx.x * 8) % 16) / K_tile_padded;
  int* reduced_mask_ptr = reduced_mask + blockIdx_z * reduced_mask_len;
  int* reorder_loc_ptr = reorder_loc + blockIdx_z * reorder_loc_len;
  half* A_ptr = A 
    + ((threadIdx.y * 256 % 16) % K_tile_padded)
    + ((threadIdx.x * 8 % 16) % K_tile_padded);
  half* B_ptr = B
    + (blockIdx_y % j_factors1) * 16
    + threadIdx.y * 256 / 16 * N 
    + threadIdx.x * 8 / 16 * N 
    + (threadIdx.x * 8) % 16;
  int reorder_loc_offset = blockIdx_x / 1 * 5280 * 16
    + blockIdx_y / j_factors1 * 8 * 16
    + (threadIdx.y % 2) * 4 * 16
    + (threadIdx.x / 4);
  half* C_ptr = C + M * N * blockIdx_z
    + (blockIdx_x % 1) * j_factors1 * 16
    + (blockIdx_y % j_factors1) * 16
    + threadIdx.y / 2 * 16
    + (threadIdx.x % 4) * 2;
  
  int A_ld_start, A_ld_amount, A_ld_bound, A_pred_guard;
  int B_ld_start, B_ld_amount, B_ld_bound, B_pred_guard, B_ld_amount_N, B_ld_K_bound;
  bool B_ld_K;
  if constexpr (N_ld_check || K_ld_check)
  {
    B_ld_start = (blockIdx_y % j_factors1) * 16 + (threadIdx.x * 8) % 16;
    B_ld_amount_N = max(0, min(B_ld_start + 8, N) - B_ld_start);
    B_ld_K_bound = K_original;
  }
  else
    B_pred_guard = 1;

  // Shang: kernel offset for loading B
  int B_kernel_offset =  threadIdx.y * 256 / 16
                        + threadIdx.x * 8 / 16;
  int K_st = blockIdx_z * split_mask_len;
  int K_ed = min(kernel_volume, (blockIdx_z + 1) * split_mask_len);

  for (int i2_0_0 = K_st * K_tile_padded / K_tile; i2_0_0 < K_ed * K_tile_padded / K_tile; ++i2_0_0)

  {

    int kernel_offset = i2_0_0 / ((K_original + K_tile - 1) / K_tile) - K_st;

    bool bit_flag = (bool)(reduced_mask_ptr[blockIdx_y / j_factors1] & (1 << kernel_offset));
    if (bit_flag)
    {
    
      if constexpr (K_ld_check)
      {
        A_ld_start = (i2_0_0 * K_tile % K_tile_padded) + ((threadIdx.x * 8 % 16) % K_tile_padded);
        A_ld_amount = max(0, min(A_ld_start + 8, K_original) - A_ld_start);
        A_ld_bound = A_ld_amount / (K_ld_factor / 2);
        A_pred_guard = 0;
        for (int i = 0; i < A_ld_bound; i++)
          A_pred_guard |= (1 << i);
      }
      else
      {
        A_pred_guard = 1;
      }

      if constexpr (K_ld_check || N_ld_check)
      {
        B_ld_K = ((i2_0_0 * K_tile % K_tile_padded) + threadIdx.x * 8 / 16) < B_ld_K_bound;
        B_ld_amount = B_ld_amount_N * (int)B_ld_K;
        B_ld_bound = B_ld_amount / (N_ld_factor / 2);
        B_pred_guard = 0;
        for (int i = 0; i < B_ld_bound; i++)
          B_pred_guard |= (1 << i);
      }

      int* out_in_map_ptr_local = out_in_map_ptr + i2_0_0 * 16 / K_tile_padded;
      half* A_ptr_local = A_ptr + (i2_0_0 * 16 % K_tile_padded);
      half* B_ptr_local;
      if constexpr (K_ld_check)
        B_ptr_local = B_ptr + (i2_0_0 * K_tile / K_tile_padded * K_original + i2_0_0 * K_tile % K_tile_padded) * N;
      else
        B_ptr_local = B_ptr + i2_0_0 * K_tile * N;

      __syncthreads();
      for (int ax0_ax1_fused_0 = 0; ax0_ax1_fused_0 < 4; ++ax0_ax1_fused_0)
      {
        int input_idx = out_in_map_ptr_local[
          (ax0_ax1_fused_0 * 32) * kernel_volume
          + (ax0_ax1_fused_0 * 512 % 16) / K_tile_padded
        ];

        if (input_idx != -1)
        {
          uint4 A_loaded = make_uint4(0, 0, 0, 0);
          global_load<K_ld_factor>(A_loaded, A_ptr_local + input_idx * K_original + ((ax0_ax1_fused_0 * 512 % 16) % K_tile_padded), A_pred_guard);
          *(uint4 *)(A_shared + ((((ax0_ax1_fused_0 * 1280) + (((int)threadIdx.y) * 640)) + ((((int)threadIdx.x) >> 1) * 40)) + ((((int)threadIdx.x) & 1) * 8))) = A_loaded;
        }
        else
        {
          *(uint4 *)(A_shared + ((((ax0_ax1_fused_0 * 1280) + (((int)threadIdx.y) * 640)) + ((((int)threadIdx.x) >> 1) * 40)) + ((((int)threadIdx.x) & 1) * 8))) = make_uint4(__pack_half2(__float2half_rn(0.000000e+00f), __float2half_rn(0.000000e+00f)), __pack_half2(__float2half_rn(0.000000e+00f), __float2half_rn(0.000000e+00f)), __pack_half2(__float2half_rn(0.000000e+00f), __float2half_rn(0.000000e+00f)), __pack_half2(__float2half_rn(0.000000e+00f), __float2half_rn(0.000000e+00f)));
        }
      }
      
      if (threadIdx.y == 0)
      {
        uint4 B_loaded = make_uint4(0, 0, 0, 0);
        global_load<N_ld_factor>(B_loaded, B_ptr_local, B_pred_guard);
        *(uint4 *)(B_shared + (((((int)threadIdx.y) * 640) + ((((int)threadIdx.x) >> 1) * 40)) + ((((int)threadIdx.x) & 1) * 8))) = B_loaded;
      }
      
      __syncthreads();

      for (int ax0_0 = 0; ax0_0 < 4; ++ax0_0)
      {

        {
          unsigned int addr;
          __asm__ __volatile__(
              "{ .reg .u64 addr; cvta.to.shared.u64 addr, %1; cvt.u32.u64 %0, addr; }"
              : "=r"(addr)
              : "l"((void *)((&(A_shared[((((int)threadIdx.y) * 2560) + (ax0_0 * 640))])) + (((((int)threadIdx.x) & 15) * 40) + ((((int)threadIdx.x) >> 4) * 8)))));
#if __CUDA_ARCH__ >= 750
          __asm__ __volatile__(
              "ldmatrix.sync.aligned.m8n8.x4.shared.b16"
              "{%0, %1, %2, %3}, [%4];"
              : "=r"(((unsigned *)(A_shared_warp + (ax0_0 * 8)))[0]), "=r"(((unsigned *)(A_shared_warp + (ax0_0 * 8)))[1]), "=r"(((unsigned *)(A_shared_warp + (ax0_0 * 8)))[2]), "=r"(((unsigned *)(A_shared_warp + (ax0_0 * 8)))[3])
              : "r"(addr));
#else
  #pragma message("FP16 kernels will not be compiled for SM75-.")
#endif
        }
      }

      {
        unsigned int addr;
        __asm__ __volatile__(
            "{ .reg .u64 addr; cvta.to.shared.u64 addr, %1; cvt.u32.u64 %0, addr; }"
            : "=r"(addr)
            : "l"((void *)((&(B_shared[0])) + (((((int)threadIdx.x) & 15) * 40) + ((((int)threadIdx.x) >> 4) * 8)))));
#if __CUDA_ARCH__ >= 750       
        __asm__ __volatile__(
            "ldmatrix.sync.aligned.m8n8.x4.trans.shared.b16"
            "{%0, %1, %2, %3}, [%4];"
            : "=r"(((unsigned *)(B_shared_warp + 0))[0]), "=r"(((unsigned *)(B_shared_warp + 0))[1]), "=r"(((unsigned *)(B_shared_warp + 0))[2]), "=r"(((unsigned *)(B_shared_warp + 0))[3])
            : "r"(addr));
#else
  #pragma message("FP16 kernels will not be compiled for SM75-.")
#endif
      }
      for (int i0_0_3 = 0; i0_0_3 < 4; ++i0_0_3)
      {
#if __CUDA_ARCH__ >= 800
        {
          __asm__ __volatile__(
              "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32"
              "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
              : "=f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[3])
              : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[2]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[3]), "r"(((unsigned *)(B_shared_warp + 0))[0]), "r"(((unsigned *)(B_shared_warp + 0))[1]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[3]));
        }

        {
          __asm__ __volatile__(
              "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32"
              "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
              : "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3])
              : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[2]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[3]), "r"(((unsigned *)(B_shared_warp + 4))[0]), "r"(((unsigned *)(B_shared_warp + 4))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3]));
        }
#elif __CUDA_ARCH__ >= 750
        {
          __asm__ __volatile__(
              "mma.sync.aligned.m16n8k8.row.col.f32.f16.f16.f32"
              "{%0, %1, %2, %3}, {%4, %5}, {%6}, {%7, %8, %9, %10};"
              : "=f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[3])
              : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(B_shared_warp + 0))[0]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[3]));
        }

        {
          __asm__ __volatile__(
              "mma.sync.aligned.m16n8k8.row.col.f32.f16.f16.f32"
              "{%0, %1, %2, %3}, {%4, %5}, {%6}, {%7, %8, %9, %10};"
              : "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3])
              : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(B_shared_warp + 4))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3]));
        }

        {
          __asm__ __volatile__(
              "mma.sync.aligned.m16n8k8.row.col.f32.f16.f16.f32"
              "{%0, %1, %2, %3}, {%4, %5}, {%6}, {%7, %8, %9, %10};"
              : "=f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[3])
              : "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[0]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[1]), "r"(((unsigned *)(B_shared_warp + 2))[0]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[3]));
        }

        {
          __asm__ __volatile__(
              "mma.sync.aligned.m16n8k8.row.col.f32.f16.f16.f32"
              "{%0, %1, %2, %3}, {%4, %5}, {%6}, {%7, %8, %9, %10};"
              : "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3])
              : "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[0]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[1]), "r"(((unsigned *)(B_shared_warp + 6))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3]));
        }
#else
  #pragma message("FP16 kernels will not be compiled for SM75-.")
#endif
      }
    }
  }

  for (int ax0_0_1 = 0; ax0_0_1 < 4; ++ax0_0_1)
  {

    int reorder_loc_offset_local = reorder_loc_offset + ax0_0_1 * 16;
    for (int local_id = 0; local_id < 8; ++local_id)
    {
      int reorder_location_cur = reorder_loc_offset_local + (((local_id / 2) % 2) * 8);
      if constexpr (N_ld_check)
      {
        bool C_wb_enable = ((blockIdx_y % j_factors1) * 16 + threadIdx.y / 2 * 16 + (threadIdx.x % 4) * 2 + (local_id % 2) + (local_id / 4) * 8) < N;
        if (C_wb_enable && reorder_location_cur < M)
          C_ptr[reorder_loc_ptr[reorder_location_cur] * N
              + (local_id % 2) + (local_id / 4) * 8] = __float2half(C_warp[(ax0_0_1 * 8) + local_id]);
      }
      else
      {
        if (reorder_location_cur < M)
          C_ptr[reorder_loc_ptr[reorder_location_cur] * N
              + (local_id % 2) + (local_id / 4) * 8] = __float2half(C_warp[(ax0_0_1 * 8) + local_id]);
      }
    };
  }
}


// conv_forward_cuda_m128n16k32_m64n16k32_m16n16k16_f16f16f32_sort
__global__ void __launch_bounds__(64) conv_forward_cuda_setting2_mode1_f16f16f32(int M, int K_original, int N, int kernel_volume, int split_mask_len, int reduced_mask_len, int reorder_loc_len, half *__restrict__ A, half *__restrict__ B, int *__restrict__ reduced_mask, int *__restrict__ out_in_map, int *__restrict__ reorder_loc, half *__restrict__ C)
{
  int K_implicit = K_original * kernel_volume;
  float C_warp[32];
  __shared__ half A_shared[5120];
  __shared__ half B_shared[1280];
  half A_shared_warp[32];
  half B_shared_warp[8];
  for (int i0_0_3_init = 0; i0_0_3_init < 4; ++i0_0_3_init) {
    for (int i = 0; i < 8; ++i) {
      C_warp[(i0_0_3_init * 8) + i] = 0.0;
    }
  }

  // hoisting shared pointer offsets
  int j_factors1 = N / 16 / 1;
  int blockIdx_x = 0;
  int blockIdx_y = blockIdx.x % ((M + 128 - 1) / 128 * j_factors1);
  int blockIdx_z = blockIdx.x / ((M + 128 - 1) / 128 * j_factors1);
  int out_in_map_offset = blockIdx_y / j_factors1 * 128 
      + threadIdx.y * 8 
      + threadIdx.x / 4;
  int* out_in_map_ptr = out_in_map
    + out_in_map_offset * kernel_volume
    + ((threadIdx.y * 256) % 32) / K_original
    + ((threadIdx.x * 8) % 32) / K_original;
  int* reduced_mask_ptr = reduced_mask + blockIdx_z * reduced_mask_len;
  int* reorder_loc_ptr = reorder_loc + blockIdx_z * reorder_loc_len;
  half* A_ptr = A 
    + ((threadIdx.y * 256 % 32) % K_original)
    + ((threadIdx.x * 8 % 32) % K_original);
  half* B_ptr = B
    + (blockIdx_y % j_factors1) * 16
    + threadIdx.y * 256 / 16 * N 
    + threadIdx.x * 8 / 16 * N 
    + (threadIdx.x * 8) % 16;
  int reorder_loc_offset = blockIdx_x / 1 * 5280 * 16
    + blockIdx_y / j_factors1 * 8 * 16
    + (threadIdx.y % 2) * 4 * 16
    + (threadIdx.x / 4);
  half* C_ptr = C + M * N * blockIdx_z
    //+ blockIdx_x / 1 * 5280 * N / 16 * 256
    //+ blockIdx_y / j_factors1 * 8 * N / 16 * 256
    //+ (threadIdx.y % 2) * 4 * N / 16 * 256
    + (blockIdx_x % 1) * j_factors1 * 16
    + (blockIdx_y % j_factors1) * 16
    + threadIdx.y / 2 * 16
    + (threadIdx.x % 4) * 2;
    //+ (threadIdx.x / 4) * N;

  // Shang: kernel offset for loading B
  int B_kernel_offset =  threadIdx.y * 256 / 16
                        + threadIdx.x * 8 / 16;
  int K_st = blockIdx_z * split_mask_len;
  int K_ed = min(kernel_volume, (blockIdx_z + 1) * split_mask_len);

  for (int i2_0_0 = K_st * K_original / 32; i2_0_0 < K_ed * K_original / 32; ++i2_0_0)

  {

    int kernel_offset = i2_0_0 / (K_original / 32) - K_st;

    bool bit_flag = (bool)(reduced_mask_ptr[blockIdx_y / j_factors1] & (1 << kernel_offset));
    if (bit_flag)
    {

      int* out_in_map_ptr_local = out_in_map_ptr + i2_0_0 * 32 / K_original;
      half* A_ptr_local = A_ptr + (i2_0_0 * 32 % K_original);
      half* B_ptr_local = B_ptr + i2_0_0 * 32 * N;

      __syncthreads();
      for (int ax0_ax1_fused_0 = 0; ax0_ax1_fused_0 < 8; ++ax0_ax1_fused_0)
      {

        // related to input
        // Haotian: NOTE: what if j_factors[0] != 1?
        // original:
        // int input_idx = out_in_map[(((((((int)blockIdx_y) * 3456) + (ax0_ax1_fused_0 * 864)) + (((int)threadIdx.y) * 216)) + ((((int)threadIdx.x) >> 2) * 27)) + (i2_0_0 >> 1))];
        int input_idx = out_in_map_ptr_local[
          (ax0_ax1_fused_0 * 16) * kernel_volume
          + (ax0_ax1_fused_0 * 512 % 32) / K_original
        ];

        if (input_idx != -1)
        {
          *(uint4*)(A_shared + ((((ax0_ax1_fused_0 * 640) + (((int)threadIdx.y) * 320)) + ((((int)threadIdx.x) >> 2) * 40)) + ((((int)threadIdx.x) & 3) * 8))) =
              // original
              //  *(uint4*)(A + (((input_idx * 64) + ((i2_0_0 & 1) * 32)) + ((((int)threadIdx.x) & 3) * 8)));
              *(uint4*)(
                A_ptr_local
                + input_idx * K_original 
                + ((ax0_ax1_fused_0 * 512 % 32) % K_original)
              );
        }
        else
        {
          *(uint4*)(A_shared + ((((ax0_ax1_fused_0 * 640) + (((int)threadIdx.y) * 320)) + ((((int)threadIdx.x) >> 2) * 40)) + ((((int)threadIdx.x) & 3) * 8))) = make_uint4(__pack_half2(__float2half_rn(0.000000e+00f), __float2half_rn(0.000000e+00f)), __pack_half2(__float2half_rn(0.000000e+00f), __float2half_rn(0.000000e+00f)), __pack_half2(__float2half_rn(0.000000e+00f), __float2half_rn(0.000000e+00f)), __pack_half2(__float2half_rn(0.000000e+00f), __float2half_rn(0.000000e+00f)));
        }
      }
      
      *(uint4*)(B_shared + (((((int)threadIdx.y) * 640) + ((((int)threadIdx.x) >> 1) * 40)) + ((((int)threadIdx.x) & 1) * 8))) = 
        *(uint4*)(B_ptr_local);
        
      
      __syncthreads();

      for (int i2_0_1 = 0; i2_0_1 < 2; ++i2_0_1)
      {
        for (int ax0_0 = 0; ax0_0 < 4; ++ax0_0)
        {

          {
            unsigned int addr;
            __asm__ __volatile__(
                "{ .reg .u64 addr; cvta.to.shared.u64 addr, %1; cvt.u32.u64 %0, addr; }"
                : "=r"(addr)
                : "l"((void *)((&(A_shared[((((((int)threadIdx.y) & 1) * 2560) + (ax0_0 * 640)) + (i2_0_1 * 16))])) + (((((int)threadIdx.x) & 15) * 40) + ((((int)threadIdx.x) >> 4) * 8)))));
#if __CUDA_ARCH__ >= 750
            __asm__ __volatile__(
                "ldmatrix.sync.aligned.m8n8.x4.shared.b16"
                "{%0, %1, %2, %3}, [%4];"
                : "=r"(((unsigned *)(A_shared_warp + (ax0_0 * 8)))[0]), "=r"(((unsigned *)(A_shared_warp + (ax0_0 * 8)))[1]), "=r"(((unsigned *)(A_shared_warp + (ax0_0 * 8)))[2]), "=r"(((unsigned *)(A_shared_warp + (ax0_0 * 8)))[3])
                : "r"(addr));
#else
  #pragma message("FP16 kernels will not be compiled for SM75-.")
#endif
          }
        }

        {
          unsigned int addr;
          __asm__ __volatile__(
              "{ .reg .u64 addr; cvta.to.shared.u64 addr, %1; cvt.u32.u64 %0, addr; }"
              : "=r"(addr)
              : "l"((void *)((&(B_shared[(i2_0_1 * 640)])) + (((((int)threadIdx.x) & 15) * 40) + ((((int)threadIdx.x) >> 4) * 8)))));
#if __CUDA_ARCH__ >= 750
          __asm__ __volatile__(
              "ldmatrix.sync.aligned.m8n8.x4.trans.shared.b16"
              "{%0, %1, %2, %3}, [%4];"
              : "=r"(((unsigned *)(B_shared_warp + 0))[0]), "=r"(((unsigned *)(B_shared_warp + 0))[1]), "=r"(((unsigned *)(B_shared_warp + 0))[2]), "=r"(((unsigned *)(B_shared_warp + 0))[3])
              : "r"(addr));
#else
  #pragma message("FP16 kernels will not be compiled for SM75-.")
#endif
        }
        for (int i0_0_3 = 0; i0_0_3 < 4; ++i0_0_3)
        {

#if __CUDA_ARCH__ >= 800
          {
            __asm__ __volatile__(
                "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32"
                "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
                : "=f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[3])
                : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[2]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[3]), "r"(((unsigned *)(B_shared_warp + 0))[0]), "r"(((unsigned *)(B_shared_warp + 0))[1]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[3]));
          }

          {
            __asm__ __volatile__(
                "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32"
                "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
                : "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3])
                : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[2]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[3]), "r"(((unsigned *)(B_shared_warp + 4))[0]), "r"(((unsigned *)(B_shared_warp + 4))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3]));
          }
#elif __CUDA_ARCH__ >= 750
          {
            __asm__ __volatile__(
                "mma.sync.aligned.m16n8k8.row.col.f32.f16.f16.f32"
                "{%0, %1, %2, %3}, {%4, %5}, {%6}, {%7, %8, %9, %10};"
                : "=f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[3])
                : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(B_shared_warp + 0))[0]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[3]));
          }
          {
            __asm__ __volatile__(
                "mma.sync.aligned.m16n8k8.row.col.f32.f16.f16.f32"
                "{%0, %1, %2, %3}, {%4, %5}, {%6}, {%7, %8, %9, %10};"
                : "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3])
                : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(B_shared_warp + 4))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3]));
          }
          {
            __asm__ __volatile__(
                "mma.sync.aligned.m16n8k8.row.col.f32.f16.f16.f32"
                "{%0, %1, %2, %3}, {%4, %5}, {%6}, {%7, %8, %9, %10};"
                : "=f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[3])
                : "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[0]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[1]), "r"(((unsigned *)(B_shared_warp + 2))[0]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[3]));
          }
          {
            __asm__ __volatile__(
                "mma.sync.aligned.m16n8k8.row.col.f32.f16.f16.f32"
                "{%0, %1, %2, %3}, {%4, %5}, {%6}, {%7, %8, %9, %10};"
                : "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3])
                : "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[0]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[1]), "r"(((unsigned *)(B_shared_warp + 6))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3]));
          }
#else
  #pragma message("FP16 kernels will not be compiled for SM75-.")
#endif
        }
      }
    }
  }
  for (int ax0_0_1 = 0; ax0_0_1 < 4; ++ax0_0_1)
  {

    int reorder_loc_offset_local = reorder_loc_offset + ax0_0_1 * 16;
    for (int local_id = 0; local_id < 8; ++local_id)
    {
      int reorder_location_cur = reorder_loc_offset_local + (((local_id / 2) % 2) * 8);
      if (reorder_location_cur < M)
        C_ptr[reorder_loc_ptr[reorder_location_cur] * N
              + (local_id % 2) + (local_id / 4) * 8] = __float2half(C_warp[(ax0_0_1 * 8) + local_id]);
    };
  }
}


// conv_forward_cuda_m128n64k32_m64n32k32_m16n16k16_f16f16f32_sort
__global__ void __launch_bounds__(128) conv_forward_cuda_setting3_mode1_f16f16f32(int M, int K_original, int N, int kernel_volume, int split_mask_len, int reduced_mask_len, int reorder_loc_len, half *__restrict__ A, half *__restrict__ B, int *__restrict__ reduced_mask, int *__restrict__ out_in_map, int *__restrict__ reorder_loc, half *__restrict__ C)
{
  int K_implicit = K_original * kernel_volume;
  float C_warp[64];
  __shared__ half A_shared[5120];
  __shared__ half B_shared[2304];
  half A_shared_warp[32];
  half B_shared_warp[16];
  for (int i0_0_3_init = 0; i0_0_3_init < 4; ++i0_0_3_init)
  {
    for (int i1_0_4_init = 0; i1_0_4_init < 2; ++i1_0_4_init)
    {
      for (int i = 0; i < 8; ++i)
      {
        C_warp[((i0_0_3_init * 16) + (i1_0_4_init * 8)) + i] = 0.0;
      };
    }
  }

  // hoisting shared pointer offsets
  int j_factors1 = N / 16 / 4;
  int blockIdx_x = 0;
  int blockIdx_y = blockIdx.x % ((M + 128 - 1) / 128 * j_factors1);
  int blockIdx_z = blockIdx.x / ((M + 128 - 1) / 128 * j_factors1);
  int out_in_map_offset = blockIdx_y / j_factors1 * 128 
      + threadIdx.y * 8 
      + threadIdx.x / 4;
  int* out_in_map_ptr = out_in_map
    + out_in_map_offset * kernel_volume
    + ((threadIdx.y * 256) % 32) / K_original
    + ((threadIdx.x * 8) % 32) / K_original;
  int* reduced_mask_ptr = reduced_mask + blockIdx_z * reduced_mask_len;
  int* reorder_loc_ptr = reorder_loc + blockIdx_z * reorder_loc_len;
  half* A_ptr = A 
    + ((threadIdx.y * 256 % 32) % K_original)
    + ((threadIdx.x * 8 % 32) % K_original);
  half* B_ptr = B
    + (blockIdx_y % j_factors1) * 64
    + threadIdx.y * 256 / 64 * N 
    + threadIdx.x * 8 / 64 * N 
    + (threadIdx.x * 8) % 64;
  int reorder_loc_offset = blockIdx_x / 1 * 5280 * 16
    + blockIdx_y / j_factors1 * 8 * 16
    + (threadIdx.y % 2) * 4 * 16
    + (threadIdx.x / 4);
  half* C_ptr = C + M * N * blockIdx_z
    //+ blockIdx_x / 1 * 5280 * N / 16 * 256
    //+ blockIdx_y / j_factors1 * 8 * N / 16 * 256
    //+ (threadIdx.y % 2) * 4 * N / 16 * 256
    + (blockIdx_x % 1) * j_factors1 * 64
    + (blockIdx_y % j_factors1) * 64
    + threadIdx.y / 2 * 32
    + (threadIdx.x % 4) * 2;
    //+ (threadIdx.x / 4) * N;

  // Shang: kernel offset for loading B
  int B_kernel_offset =  threadIdx.y * 256 / 64
                        + threadIdx.x * 8 / 64;
  int K_st = blockIdx_z * split_mask_len;
  int K_ed = min(kernel_volume, (blockIdx_z + 1) * split_mask_len);

  for (int i2_0_0 = K_st * K_original / 32; i2_0_0 < K_ed * K_original / 32; ++i2_0_0)

  {

    int kernel_offset = i2_0_0 / (K_original / 32) - K_st;

    bool bit_flag = (bool)(reduced_mask_ptr[blockIdx_y / j_factors1] & (1 << kernel_offset));
    if (bit_flag)
    {

      int* out_in_map_ptr_local = out_in_map_ptr + i2_0_0 * 32 / K_original;
      half* A_ptr_local = A_ptr + (i2_0_0 * 32 % K_original);
      half* B_ptr_local = B_ptr + i2_0_0 * 32 * N;

      __syncthreads();
      for (int ax0_ax1_fused_0 = 0; ax0_ax1_fused_0 < 4; ++ax0_ax1_fused_0)
      {

        // related to input
        // Haotian: NOTE: what if j_factors[0] != 1?
        // original:
        // int input_idx = out_in_map[(((((((int)blockIdx_y) * 3456) + (ax0_ax1_fused_0 * 864)) + (((int)threadIdx.y) * 216)) + ((((int)threadIdx.x) >> 2) * 27)) + (i2_0_0 >> 1))];
        int input_idx = out_in_map_ptr_local[
          (ax0_ax1_fused_0 * 32) * kernel_volume
          + (ax0_ax1_fused_0 * 1024 % 32) / K_original
        ];

        if (input_idx != -1)
        {
          *(uint4 *)(A_shared + ((((ax0_ax1_fused_0 * 1280) + (((int)threadIdx.y) * 320)) + ((((int)threadIdx.x) >> 2) * 40)) + ((((int)threadIdx.x) & 3) * 8))) =
              // original
              //  *(uint4*)(A + (((input_idx * 64) + ((i2_0_0 & 1) * 32)) + ((((int)threadIdx.x) & 3) * 8)));
              *(uint4*)(
                A_ptr_local
                + input_idx * K_original 
                + ((ax0_ax1_fused_0 * 1024 % 32) % K_original)
              );
        }
        else
        {
          *(uint4 *)(A_shared + ((((ax0_ax1_fused_0 * 1280) + (((int)threadIdx.y) * 320)) + ((((int)threadIdx.x) >> 2) * 40)) + ((((int)threadIdx.x) & 3) * 8))) = make_uint4(__pack_half2(__float2half_rn(0.000000e+00f), __float2half_rn(0.000000e+00f)), __pack_half2(__float2half_rn(0.000000e+00f), __float2half_rn(0.000000e+00f)), __pack_half2(__float2half_rn(0.000000e+00f), __float2half_rn(0.000000e+00f)), __pack_half2(__float2half_rn(0.000000e+00f), __float2half_rn(0.000000e+00f)));
        }
      }
      for (int ax0_ax1_fused_0_1 = 0; ax0_ax1_fused_0_1 < 2; ++ax0_ax1_fused_0_1)
      {
        *(uint4 *)(B_shared + ((((ax0_ax1_fused_0_1 * 1152) + (((int)threadIdx.y) * 288)) + ((((int)threadIdx.x) >> 3) * 72)) + ((((int)threadIdx.x) & 7) * 8))) =
          // original:
          // *(uint4*)(B + ((((i2_0_0 * 2048) + (ax0_ax1_fused_0_1 * 1024)) + (((int)threadIdx.y) * 256)) + (((int)threadIdx.x) * 8)));
          *(uint4*)(
            B_ptr_local
            + ax0_ax1_fused_0_1 * 1024 * N / 64
          );
        
      }
      __syncthreads();

      for (int i2_0_1 = 0; i2_0_1 < 2; ++i2_0_1)
      {
        for (int ax0_0 = 0; ax0_0 < 4; ++ax0_0)
        {

          {
            unsigned int addr;
            __asm__ __volatile__(
                "{ .reg .u64 addr; cvta.to.shared.u64 addr, %1; cvt.u32.u64 %0, addr; }"
                : "=r"(addr)
                : "l"((void *)((&(A_shared[((((((int)threadIdx.y) & 1) * 2560) + (ax0_0 * 640)) + (i2_0_1 * 16))])) + (((((int)threadIdx.x) & 15) * 40) + ((((int)threadIdx.x) >> 4) * 8)))));
#if __CUDA_ARCH__ >= 750
            __asm__ __volatile__(
                "ldmatrix.sync.aligned.m8n8.x4.shared.b16"
                "{%0, %1, %2, %3}, [%4];"
                : "=r"(((unsigned *)(A_shared_warp + (ax0_0 * 8)))[0]), "=r"(((unsigned *)(A_shared_warp + (ax0_0 * 8)))[1]), "=r"(((unsigned *)(A_shared_warp + (ax0_0 * 8)))[2]), "=r"(((unsigned *)(A_shared_warp + (ax0_0 * 8)))[3])
                : "r"(addr));
#else
  #pragma message("FP16 kernels will not be compiled for SM75-.")
#endif
          }
        }
        for (int ax1_0 = 0; ax1_0 < 2; ++ax1_0)
        {
          {
            unsigned int addr;
            __asm__ __volatile__(
                "{ .reg .u64 addr; cvta.to.shared.u64 addr, %1; cvt.u32.u64 %0, addr; }"
                : "=r"(addr)
                : "l"((void *)((&(B_shared[(((i2_0_1 * 1152) + ((((int)threadIdx.y) >> 1) * 32)) + (ax1_0 * 16))])) + (((((int)threadIdx.x) & 15) * 72) + ((((int)threadIdx.x) >> 4) * 8)))));
#if __CUDA_ARCH__ >= 750
            __asm__ __volatile__(
                "ldmatrix.sync.aligned.m8n8.x4.trans.shared.b16"
                "{%0, %1, %2, %3}, [%4];"
                : "=r"(((unsigned *)(B_shared_warp + (ax1_0 * 8)))[0]), "=r"(((unsigned *)(B_shared_warp + (ax1_0 * 8)))[1]), "=r"(((unsigned *)(B_shared_warp + (ax1_0 * 8)))[2]), "=r"(((unsigned *)(B_shared_warp + (ax1_0 * 8)))[3])
                : "r"(addr));
#else
  #pragma message("FP16 kernels will not be compiled for SM75-.")
#endif
          }
        }
        for (int i0_0_3 = 0; i0_0_3 < 4; ++i0_0_3)
        {
          for (int i1_0_4 = 0; i1_0_4 < 2; ++i1_0_4)
          {
#if __CUDA_ARCH__ >= 800
            {
              __asm__ __volatile__(
                  "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32"
                  "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
                  : "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[0]), "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[1]), "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[2]), "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[3])
                  : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[2]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[3]), "r"(((unsigned *)(B_shared_warp + (i1_0_4 * 8)))[0]), "r"(((unsigned *)(B_shared_warp + (i1_0_4 * 8)))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[2]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[3]));
            }

            {
              __asm__ __volatile__(
                  "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32"
                  "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
                  : "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[0]), "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[1]), "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[2]), "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[3])
                  : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[2]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[3]), "r"(((unsigned *)(B_shared_warp + ((i1_0_4 * 8) + 4)))[0]), "r"(((unsigned *)(B_shared_warp + ((i1_0_4 * 8) + 4)))[1]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[0]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[1]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[2]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[3]));
            }
#elif __CUDA_ARCH__ >= 750
            {
              __asm__ __volatile__(
                  "mma.sync.aligned.m16n8k8.row.col.f32.f16.f16.f32"
                  "{%0, %1, %2, %3}, {%4, %5}, {%6}, {%7, %8, %9, %10};"
                  : "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[0]), "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[1]), "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[2]), "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[3])
                  : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(B_shared_warp + (i1_0_4 * 8)))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[2]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[3]));
            }
            {
              __asm__ __volatile__(
                  "mma.sync.aligned.m16n8k8.row.col.f32.f16.f16.f32"
                  "{%0, %1, %2, %3}, {%4, %5}, {%6}, {%7, %8, %9, %10};"
                  : "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[0]), "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[1]), "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[2]), "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[3])
                  : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(B_shared_warp + ((i1_0_4 * 8) + 4)))[0]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[0]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[1]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[2]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[3]));
            }
            {
              __asm__ __volatile__(
                  "mma.sync.aligned.m16n8k8.row.col.f32.f16.f16.f32"
                  "{%0, %1, %2, %3}, {%4, %5}, {%6}, {%7, %8, %9, %10};"
                  : "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[0]), "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[1]), "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[2]), "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[3])
                  : "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[0]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[1]), "r"(((unsigned *)(B_shared_warp + ((i1_0_4 * 8) + 2)))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[2]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[3]));
            }
            {
              __asm__ __volatile__(
                  "mma.sync.aligned.m16n8k8.row.col.f32.f16.f16.f32"
                  "{%0, %1, %2, %3}, {%4, %5}, {%6}, {%7, %8, %9, %10};"
                  : "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[0]), "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[1]), "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[2]), "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[3])
                  : "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[0]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[1]), "r"(((unsigned *)(B_shared_warp + ((i1_0_4 * 8) + 6)))[0]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[0]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[1]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[2]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[3]));
            }
#else
  #pragma message("FP16 kernels will not be compiled for SM75-.")
#endif
          }
        }
      }
    }
  }
  for (int ax0_0_1 = 0; ax0_0_1 < 4; ++ax0_0_1)
  {

    int reorder_loc_offset_local = reorder_loc_offset + ax0_0_1 * 16;
    for (int ax1_0_1 = 0; ax1_0_1 < 2; ++ax1_0_1)
    {
      for (int local_id = 0; local_id < 8; ++local_id)
      {

        // original:
        // (&(C[(((((((int)blockIdx_y) * 8192) + ((((int)threadIdx.y) & 1) * 4096)) + (ax0_0_1 * 1024)) + ((((int)threadIdx.y) >> 1) * 32)) + (ax1_0_1 * 16))]))[((((((local_id / 2) % 2) * 8) + (threadIdx.x / 4)) * 64) + (((local_id % 2) + ((local_id / 4) * 8)) + ((threadIdx.x % 4) * 2)))]
        int reorder_location_cur = reorder_loc_offset_local + (((local_id / 2) % 2) * 8);
        if (reorder_location_cur < M)
          C_ptr[
            reorder_loc_ptr[reorder_location_cur] * N
            + ax1_0_1 * 16
            + (local_id % 2) 
            + (local_id / 4) * 8
          ] = __float2half(C_warp[((ax0_0_1 * 16) + (ax1_0_1 * 8)) + local_id]);
      };
    }
  }
}


// conv_forward_cuda_m128n16k16_m64n16k16_m16n16k16_tf32tf32f32_sort
template <int K_ld_factor, int N_ld_factor, bool K_ld_check, bool N_ld_check>
__global__ void __launch_bounds__(64) conv_forward_cuda_setting1_mode1_tf32tf32f32(int M, int K_original, int N, int kernel_volume, int split_mask_len, int reduced_mask_len, int reorder_loc_len, float *__restrict__ A, float *__restrict__ B, int *__restrict__ reduced_mask, int *__restrict__ out_in_map, int *__restrict__ reorder_loc, float *__restrict__ C)
{
  const int K_tile = 16; 
  int K_tile_padded = K_tile * ((K_original + K_tile - 1) / K_tile);
  int K_implicit = K_tile_padded * kernel_volume;

  float C_warp[32];
  __shared__ float A_shared[5120];
  __shared__ float B_shared[640];
  float A_shared_warp[32];
  float B_shared_warp[8];
  for (int i0_0_3_init = 0; i0_0_3_init < 4; ++i0_0_3_init)
  {
    for (int i = 0; i < 8; ++i)
    {
      C_warp[(i0_0_3_init * 8) + i] = 0.0;
    };
  }

  // hoisting shared pointer offsets
  int j_factors1 = (N + 15) / 16 / 1;
  int blockIdx_x = 0;
  int blockIdx_y = blockIdx.x % ((M + 128 - 1) / 128 * j_factors1);
  int blockIdx_z = blockIdx.x / ((M + 128 - 1) / 128 * j_factors1);
  int out_in_map_offset = blockIdx_y / j_factors1 * 128 
      + threadIdx.y * 16 
      + threadIdx.x / 2;
  int* out_in_map_ptr = out_in_map
    + out_in_map_offset * kernel_volume
    + ((threadIdx.y * 256) % 16) / K_tile_padded
    + ((threadIdx.x * 8) % 16) / K_tile_padded;
  int* reduced_mask_ptr = reduced_mask + blockIdx_z * reduced_mask_len;
  int* reorder_loc_ptr = reorder_loc + blockIdx_z * reorder_loc_len;
  float* A_ptr = A 
    + ((threadIdx.y * 256 % 16) % K_tile_padded)
    + ((threadIdx.x * 8 % 16) % K_tile_padded);
  float* B_ptr = B
    + (blockIdx_y % j_factors1) * 16
    + threadIdx.y * 256 / 16 * N 
    + threadIdx.x * 8 / 16 * N 
    + (threadIdx.x * 8) % 16;
  int reorder_loc_offset = blockIdx_x / 1 * 5280 * 16
    + blockIdx_y / j_factors1 * 8 * 16
    + (threadIdx.y % 2) * 4 * 16
    + (threadIdx.x / 4);
  float* C_ptr = C + M * N * blockIdx_z
    + (blockIdx_x % 1) * j_factors1 * 16
    + (blockIdx_y % j_factors1) * 16
    + threadIdx.y / 2 * 16
    + (threadIdx.x % 4) * 2;
  
  int A_ld_start, A_ld_amount, A_ld_bound, A_pred_guard;
  int B_ld_start, B_ld_amount, B_ld_bound, B_pred_guard, B_ld_amount_N, B_ld_K_bound;
  bool B_ld_K;
  if constexpr (N_ld_check || K_ld_check)
  {
    B_ld_start = (blockIdx_y % j_factors1) * 16 + (threadIdx.x * 8) % 16;
    B_ld_amount_N = max(0, min(B_ld_start + 8, N) - B_ld_start);
    B_ld_K_bound = K_original;
  }
  else
    B_pred_guard = 3;

  // Shang: kernel offset for loading B
  int B_kernel_offset =  threadIdx.y * 256 / 16
                        + threadIdx.x * 8 / 16;
  int K_st = blockIdx_z * split_mask_len;
  int K_ed = min(kernel_volume, (blockIdx_z + 1) * split_mask_len);

  for (int i2_0_0 = K_st * K_tile_padded / K_tile; i2_0_0 < K_ed * K_tile_padded / K_tile; ++i2_0_0)

  {

    int kernel_offset = i2_0_0 / ((K_original + K_tile - 1) / K_tile) - K_st;

    bool bit_flag = (bool)(reduced_mask_ptr[blockIdx_y / j_factors1] & (1 << kernel_offset));
    if (bit_flag)
    {
    
      if constexpr (K_ld_check)
      {
        A_ld_start = (i2_0_0 * K_tile % K_tile_padded) + ((threadIdx.x * 8 % 16) % K_tile_padded);
        A_ld_amount = max(0, min(A_ld_start + 8, K_original) - A_ld_start);
        A_ld_bound = A_ld_amount / (K_ld_factor / 4);
        A_pred_guard = 0;
        for (int i = 0; i < A_ld_bound; i++)
          A_pred_guard |= (1 << i);
      }
      else
      {
        A_pred_guard = 3;
      }

      if constexpr (K_ld_check || N_ld_check)
      {
        B_ld_K = ((i2_0_0 * K_tile % K_tile_padded) + threadIdx.x * 8 / 16) < B_ld_K_bound;
        B_ld_amount = B_ld_amount_N * (int)B_ld_K;
        B_ld_bound = B_ld_amount / (N_ld_factor / 4);
        B_pred_guard = 0;
        for (int i = 0; i < B_ld_bound; i++)
          B_pred_guard |= (1 << i);
      }

      int* out_in_map_ptr_local = out_in_map_ptr + i2_0_0 * 16 / K_tile_padded;
      float* A_ptr_local = A_ptr + (i2_0_0 * 16 % K_tile_padded);
      float* B_ptr_local;
      if constexpr (K_ld_check)
        B_ptr_local = B_ptr + (i2_0_0 * K_tile / K_tile_padded * K_original + i2_0_0 * K_tile % K_tile_padded) * N;
      else
        B_ptr_local = B_ptr + i2_0_0 * K_tile * N;

      __syncthreads();
      for (int ax0_ax1_fused_0 = 0; ax0_ax1_fused_0 < 4; ++ax0_ax1_fused_0)
      {
        int input_idx = out_in_map_ptr_local[
          (ax0_ax1_fused_0 * 32) * kernel_volume
          + (ax0_ax1_fused_0 * 512 % 16) / K_tile_padded
        ];

        if (input_idx != -1)
        {
          uint4 A_loaded[2] = {make_uint4(0, 0, 0, 0)};
          global_load<K_ld_factor>(A_loaded[0], A_ptr_local + input_idx * K_original + ((ax0_ax1_fused_0 * 512 % 16) % K_tile_padded), A_pred_guard);
          global_load<K_ld_factor>(A_loaded[1], A_ptr_local + input_idx * K_original + ((ax0_ax1_fused_0 * 512 % 16) % K_tile_padded) + 4, A_pred_guard >> (4 * 4 / K_ld_factor));
          *(ulonglong4 *)(A_shared + ((((ax0_ax1_fused_0 * 1280) + (((int)threadIdx.y) * 640)) + ((((int)threadIdx.x) >> 1) * 40)) + ((((int)threadIdx.x) & 1) * 8))) = *reinterpret_cast<ulonglong4 *>(A_loaded);
        }
        else
        {
          *(ulonglong4 *)(A_shared + ((((ax0_ax1_fused_0 * 1280) + (((int)threadIdx.y) * 640)) + ((((int)threadIdx.x) >> 1) * 40)) + ((((int)threadIdx.x) & 1) * 8))) = make_ulonglong4(0ULL, 0ULL, 0ULL, 0ULL);
        }
      }
      
      if (threadIdx.y == 0)
      {
        uint4 B_loaded[2] = {make_uint4(0, 0, 0, 0)};
        global_load<N_ld_factor>(B_loaded[0], B_ptr_local, B_pred_guard);
        global_load<N_ld_factor>(B_loaded[1], B_ptr_local + 4, B_pred_guard >> (4 * 4 / N_ld_factor));
        *(ulonglong4 *)(B_shared + (((((int)threadIdx.y) * 640) + ((((int)threadIdx.x) >> 1) * 40)) + ((((int)threadIdx.x) & 1) * 8))) = *reinterpret_cast<ulonglong4 *>(B_loaded);
      }
      
      __syncthreads();

      for (int ax0_0 = 0; ax0_0 < 4; ++ax0_0)
      {
        for (int local_size = 0; local_size < 8; ++local_size)
        {
          A_shared_warp[((ax0_0 * 8) + local_size)] = A_shared[((((((((int)threadIdx.y) * 2560) + (ax0_0 * 640)) + ((local_size & 1) * 320)) + ((((int)threadIdx.x) >> 2) * 40)) + ((local_size >> 1) * 4)) + (((int)threadIdx.x) & 3))];
        }
      }
      for (int local_size_1 = 0; local_size_1 < 8; ++local_size_1)
      {
        B_shared_warp[local_size_1] = B_shared[(((((local_size_1 & 3) * 160) + ((((int)threadIdx.x) & 3) * 40)) + ((local_size_1 >> 2) * 8)) + (((int)threadIdx.x) >> 2))];
      }

      for (int i0_0_3 = 0; i0_0_3 < 4; ++i0_0_3)
      {
#if __CUDA_ARCH__ >= 800
        {
          __asm__ __volatile__(
              "mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32"
              "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
              : "=f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[3])
              : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[2]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[3]), "r"(((unsigned *)(B_shared_warp + 0))[0]), "r"(((unsigned *)(B_shared_warp + 0))[1]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[3]));
        }

        {
          __asm__ __volatile__(
              "mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32"
              "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
              : "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3])
              : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[2]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[3]), "r"(((unsigned *)(B_shared_warp + 4))[0]), "r"(((unsigned *)(B_shared_warp + 4))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3]));
        }

        {
          __asm__ __volatile__(
              "mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32"
              "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
              : "=f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[3])
              : "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[0]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[1]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[2]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[3]), "r"(((unsigned *)(B_shared_warp + 2))[0]), "r"(((unsigned *)(B_shared_warp + 2))[1]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[3]));
        }

        {
          __asm__ __volatile__(
              "mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32"
              "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
              : "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3])
              : "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[0]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[1]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[2]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[3]), "r"(((unsigned *)(B_shared_warp + 6))[0]), "r"(((unsigned *)(B_shared_warp + 6))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3]));
        }
#else
  #pragma message("TF32 kernels will not be compiled.")
#endif  
      }
    }
  }

  for (int ax0_0_1 = 0; ax0_0_1 < 4; ++ax0_0_1)
  {

    int reorder_loc_offset_local = reorder_loc_offset + ax0_0_1 * 16;
    for (int local_id = 0; local_id < 8; ++local_id)
    {
      int reorder_location_cur = reorder_loc_offset_local + (((local_id / 2) % 2) * 8);
      if constexpr (N_ld_check)
      {
        bool C_wb_enable = ((blockIdx_y % j_factors1) * 16 + threadIdx.y / 2 * 16 + (threadIdx.x % 4) * 2 + (local_id % 2) + (local_id / 4) * 8) < N;
        if (C_wb_enable && reorder_location_cur < M)
          C_ptr[reorder_loc_ptr[reorder_location_cur] * N
              + (local_id % 2) + (local_id / 4) * 8] = C_warp[(ax0_0_1 * 8) + local_id];
      }
      else
      {
        if (reorder_location_cur < M)
          C_ptr[reorder_loc_ptr[reorder_location_cur] * N
              + (local_id % 2) + (local_id / 4) * 8] = C_warp[(ax0_0_1 * 8) + local_id];
      }
    };
  }
}


// conv_forward_cuda_m128n16k32_m64n16k32_m16n16k16_tf32tf32f32_sort
__global__ void __launch_bounds__(64) conv_forward_cuda_setting2_mode1_tf32tf32f32(int M, int K_original, int N, int kernel_volume, int split_mask_len, int reduced_mask_len, int reorder_loc_len, float *__restrict__ A, float *__restrict__ B, int *__restrict__ reduced_mask, int *__restrict__ out_in_map, int *__restrict__ reorder_loc, float *__restrict__ C)
{
  int K_implicit = K_original * kernel_volume;
  float C_warp[32];
  __shared__ float A_shared[5120];
  __shared__ float B_shared[1280];
  float A_shared_warp[32];
  float B_shared_warp[8];
  for (int i0_0_3_init = 0; i0_0_3_init < 4; ++i0_0_3_init) {
    for (int i = 0; i < 8; ++i) {
      C_warp[(i0_0_3_init * 8) + i] = 0.0;
    }
  }

  // hoisting shared pointer offsets
  int j_factors1 = N / 16 / 1;
  int blockIdx_x = 0;
  int blockIdx_y = blockIdx.x % ((M + 128 - 1) / 128 * j_factors1);
  int blockIdx_z = blockIdx.x / ((M + 128 - 1) / 128 * j_factors1);
  int out_in_map_offset = blockIdx_y / j_factors1 * 128 
      + threadIdx.y * 8 
      + threadIdx.x / 4;
  int* out_in_map_ptr = out_in_map
    + out_in_map_offset * kernel_volume
    + ((threadIdx.y * 256) % 32) / K_original
    + ((threadIdx.x * 8) % 32) / K_original;
  int* reduced_mask_ptr = reduced_mask + blockIdx_z * reduced_mask_len;
  int* reorder_loc_ptr = reorder_loc + blockIdx_z * reorder_loc_len;
  float* A_ptr = A 
    + ((threadIdx.y * 256 % 32) % K_original)
    + ((threadIdx.x * 8 % 32) % K_original);
  float* B_ptr = B
    + (blockIdx_y % j_factors1) * 16
    + threadIdx.y * 256 / 16 * N 
    + threadIdx.x * 8 / 16 * N 
    + (threadIdx.x * 8) % 16;
  int reorder_loc_offset = blockIdx_x / 1 * 5280 * 16
    + blockIdx_y / j_factors1 * 8 * 16
    + (threadIdx.y % 2) * 4 * 16
    + (threadIdx.x / 4);
  float* C_ptr = C + M * N * blockIdx_z
    //+ blockIdx_x / 1 * 5280 * N / 16 * 256
    //+ blockIdx_y / j_factors1 * 8 * N / 16 * 256
    //+ (threadIdx.y % 2) * 4 * N / 16 * 256
    + (blockIdx_x % 1) * j_factors1 * 16
    + (blockIdx_y % j_factors1) * 16
    + threadIdx.y / 2 * 16
    + (threadIdx.x % 4) * 2;
    //+ (threadIdx.x / 4) * N;

  // Shang: kernel offset for loading B
  int B_kernel_offset =  threadIdx.y * 256 / 16
                        + threadIdx.x * 8 / 16;
  int K_st = blockIdx_z * split_mask_len;
  int K_ed = min(kernel_volume, (blockIdx_z + 1) * split_mask_len);

  for (int i2_0_0 = K_st * K_original / 32; i2_0_0 < K_ed * K_original / 32; ++i2_0_0)

  {

    int kernel_offset = i2_0_0 / (K_original / 32) - K_st;

    bool bit_flag = (bool)(reduced_mask_ptr[blockIdx_y / j_factors1] & (1 << kernel_offset));
    if (bit_flag)
    {

      int* out_in_map_ptr_local = out_in_map_ptr + i2_0_0 * 32 / K_original;
      float* A_ptr_local = A_ptr + (i2_0_0 * 32 % K_original);
      float* B_ptr_local = B_ptr + i2_0_0 * 32 * N;

      __syncthreads();
      for (int ax0_ax1_fused_0 = 0; ax0_ax1_fused_0 < 8; ++ax0_ax1_fused_0)
      {

        // related to input
        // Haotian: NOTE: what if j_factors[0] != 1?
        // original:
        // int input_idx = out_in_map[(((((((int)blockIdx_y) * 3456) + (ax0_ax1_fused_0 * 864)) + (((int)threadIdx.y) * 216)) + ((((int)threadIdx.x) >> 2) * 27)) + (i2_0_0 >> 1))];
        int input_idx = out_in_map_ptr_local[
          (ax0_ax1_fused_0 * 16) * kernel_volume
          + (ax0_ax1_fused_0 * 512 % 32) / K_original
        ];

        if (input_idx != -1)
        {
          *(ulonglong4*)(A_shared + ((((ax0_ax1_fused_0 * 640) + (((int)threadIdx.y) * 320)) + ((((int)threadIdx.x) >> 2) * 40)) + ((((int)threadIdx.x) & 3) * 8))) =
              // original
              //  *(ulonglong4*)(A + (((input_idx * 64) + ((i2_0_0 & 1) * 32)) + ((((int)threadIdx.x) & 3) * 8)));
              *(ulonglong4*)(
                A_ptr_local
                + input_idx * K_original 
                + ((ax0_ax1_fused_0 * 512 % 32) % K_original)
              );
        }
        else
        {
          *(ulonglong4*)(A_shared + ((((ax0_ax1_fused_0 * 640) + (((int)threadIdx.y) * 320)) + ((((int)threadIdx.x) >> 2) * 40)) + ((((int)threadIdx.x) & 3) * 8))) = make_ulonglong4(0ULL, 0ULL, 0ULL, 0ULL);
        }
      }
      
      *(ulonglong4*)(B_shared + (((((int)threadIdx.y) * 640) + ((((int)threadIdx.x) >> 1) * 40)) + ((((int)threadIdx.x) & 1) * 8))) = 
        *(ulonglong4*)(B_ptr_local);
        
      
      __syncthreads();

      for (int i2_0_1 = 0; i2_0_1 < 2; ++i2_0_1)
      {
        for (int ax0_0 = 0; ax0_0 < 4; ++ax0_0)
        {
          for (int local_size = 0; local_size < 8; ++local_size)
          {
            A_shared_warp[((ax0_0 * 8) + local_size)] = A_shared[(((((((((int)threadIdx.y) * 2560) + (ax0_0 * 640)) + ((local_size & 1) * 320)) + ((((int)threadIdx.x) >> 2) * 40)) + (i2_0_1 * 16)) + ((local_size >> 1) * 4)) + (((int)threadIdx.x) & 3))];
          }
        }

        for (int local_size_1 = 0; local_size_1 < 8; ++local_size_1)
        {
          B_shared_warp[local_size_1] = B_shared[(((((i2_0_1 * 640) + ((local_size_1 & 3) * 160)) + ((((int)threadIdx.x) & 3) * 40)) + ((local_size_1 >> 2) * 8)) + (((int)threadIdx.x) >> 2))];
        }
        for (int i0_0_3 = 0; i0_0_3 < 4; ++i0_0_3)
        {
#if __CUDA_ARCH__ >= 800
          {
            __asm__ __volatile__(
                "mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32"
                "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
                : "=f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[3])
                : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[2]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[3]), "r"(((unsigned *)(B_shared_warp + 0))[0]), "r"(((unsigned *)(B_shared_warp + 0))[1]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[3]));
          }

          {
            __asm__ __volatile__(
                "mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32"
                "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
                : "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3])
                : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[2]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[3]), "r"(((unsigned *)(B_shared_warp + 4))[0]), "r"(((unsigned *)(B_shared_warp + 4))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3]));
          }

          {
            __asm__ __volatile__(
                "mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32"
                "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
                : "=f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "=f"(((float *)(C_warp + (i0_0_3 * 8)))[3])
                : "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[0]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[1]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[2]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[3]), "r"(((unsigned *)(B_shared_warp + 2))[0]), "r"(((unsigned *)(B_shared_warp + 2))[1]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[0]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[1]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[2]), "f"(((float *)(C_warp + (i0_0_3 * 8)))[3]));
          }

          {
            __asm__ __volatile__(
                "mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32"
                "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
                : "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "=f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3])
                : "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[0]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[1]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[2]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[3]), "r"(((unsigned *)(B_shared_warp + 6))[0]), "r"(((unsigned *)(B_shared_warp + 6))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[2]), "f"(((float *)(C_warp + ((i0_0_3 * 8) + 4)))[3]));
          }
#else
  #pragma message("TF32 kernels will not be compiled.")
#endif
        }
      }
    }
  }
  for (int ax0_0_1 = 0; ax0_0_1 < 4; ++ax0_0_1)
  {

    int reorder_loc_offset_local = reorder_loc_offset + ax0_0_1 * 16;
    for (int local_id = 0; local_id < 8; ++local_id)
    {
      int reorder_location_cur = reorder_loc_offset_local + (((local_id / 2) % 2) * 8);
      if (reorder_location_cur < M)
        C_ptr[reorder_loc_ptr[reorder_location_cur] * N
              + (local_id % 2) + (local_id / 4) * 8] = C_warp[(ax0_0_1 * 8) + local_id];
    };
  }
}


// conv_forward_cuda_m128n64k32_m64n32k32_m16n16k16_tf32tf32f32_sort
__global__ void __launch_bounds__(128) conv_forward_cuda_setting3_mode1_tf32tf32f32(int M, int K_original, int N, int kernel_volume, int split_mask_len, int reduced_mask_len, int reorder_loc_len, float *__restrict__ A, float *__restrict__ B, int *__restrict__ reduced_mask, int *__restrict__ out_in_map, int *__restrict__ reorder_loc, float *__restrict__ C)
{
  int K_implicit = K_original * kernel_volume;
  float C_warp[64];
  __shared__ float A_shared[5120];
  __shared__ float B_shared[2304];
  float A_shared_warp[32];
  float B_shared_warp[16];
  for (int i0_0_3_init = 0; i0_0_3_init < 4; ++i0_0_3_init)
  {
    for (int i1_0_4_init = 0; i1_0_4_init < 2; ++i1_0_4_init)
    {
      for (int i = 0; i < 8; ++i)
      {
        C_warp[((i0_0_3_init * 16) + (i1_0_4_init * 8)) + i] = 0.0;
      };
    }
  }

  // hoisting shared pointer offsets
  int j_factors1 = N / 16 / 4;
  int blockIdx_x = 0;
  int blockIdx_y = blockIdx.x % ((M + 128 - 1) / 128 * j_factors1);
  int blockIdx_z = blockIdx.x / ((M + 128 - 1) / 128 * j_factors1);
  int out_in_map_offset = blockIdx_y / j_factors1 * 128 
      + threadIdx.y * 8 
      + threadIdx.x / 4;
  int* out_in_map_ptr = out_in_map
    + out_in_map_offset * kernel_volume
    + ((threadIdx.y * 256) % 32) / K_original
    + ((threadIdx.x * 8) % 32) / K_original;
  int* reduced_mask_ptr = reduced_mask + blockIdx_z * reduced_mask_len;
  int* reorder_loc_ptr = reorder_loc + blockIdx_z * reorder_loc_len;
  float* A_ptr = A 
    + ((threadIdx.y * 256 % 32) % K_original)
    + ((threadIdx.x * 8 % 32) % K_original);
  float* B_ptr = B
    + (blockIdx_y % j_factors1) * 64
    + threadIdx.y * 256 / 64 * N 
    + threadIdx.x * 8 / 64 * N 
    + (threadIdx.x * 8) % 64;
  int reorder_loc_offset = blockIdx_x / 1 * 5280 * 16
    + blockIdx_y / j_factors1 * 8 * 16
    + (threadIdx.y % 2) * 4 * 16
    + (threadIdx.x / 4);
  float* C_ptr = C + M * N * blockIdx_z
    //+ blockIdx_x / 1 * 5280 * N / 16 * 256
    //+ blockIdx_y / j_factors1 * 8 * N / 16 * 256
    //+ (threadIdx.y % 2) * 4 * N / 16 * 256
    + (blockIdx_x % 1) * j_factors1 * 64
    + (blockIdx_y % j_factors1) * 64
    + threadIdx.y / 2 * 32
    + (threadIdx.x % 4) * 2;
    //+ (threadIdx.x / 4) * N;

  // Shang: kernel offset for loading B
  int B_kernel_offset =  threadIdx.y * 256 / 64
                        + threadIdx.x * 8 / 64;
  int K_st = blockIdx_z * split_mask_len;
  int K_ed = min(kernel_volume, (blockIdx_z + 1) * split_mask_len);

  for (int i2_0_0 = K_st * K_original / 32; i2_0_0 < K_ed * K_original / 32; ++i2_0_0)

  {

    int kernel_offset = i2_0_0 / (K_original / 32) - K_st;

    bool bit_flag = (bool)(reduced_mask_ptr[blockIdx_y / j_factors1] & (1 << kernel_offset));
    if (bit_flag)
    {

      int* out_in_map_ptr_local = out_in_map_ptr + i2_0_0 * 32 / K_original;
      float* A_ptr_local = A_ptr + (i2_0_0 * 32 % K_original);
      float* B_ptr_local = B_ptr + i2_0_0 * 32 * N;

      __syncthreads();
      for (int ax0_ax1_fused_0 = 0; ax0_ax1_fused_0 < 4; ++ax0_ax1_fused_0)
      {

        // related to input
        // Haotian: NOTE: what if j_factors[0] != 1?
        // original:
        // int input_idx = out_in_map[(((((((int)blockIdx_y) * 3456) + (ax0_ax1_fused_0 * 864)) + (((int)threadIdx.y) * 216)) + ((((int)threadIdx.x) >> 2) * 27)) + (i2_0_0 >> 1))];
        int input_idx = out_in_map_ptr_local[
          (ax0_ax1_fused_0 * 32) * kernel_volume
          + (ax0_ax1_fused_0 * 1024 % 32) / K_original
        ];

        if (input_idx != -1)
        {
          *(ulonglong4 *)(A_shared + ((((ax0_ax1_fused_0 * 1280) + (((int)threadIdx.y) * 320)) + ((((int)threadIdx.x) >> 2) * 40)) + ((((int)threadIdx.x) & 3) * 8))) =
              // original
              //  *(ulonglong4*)(A + (((input_idx * 64) + ((i2_0_0 & 1) * 32)) + ((((int)threadIdx.x) & 3) * 8)));
              *(ulonglong4*)(
                A_ptr_local
                + input_idx * K_original 
                + ((ax0_ax1_fused_0 * 1024 % 32) % K_original)
              );
        }
        else
        {
          *(ulonglong4 *)(A_shared + ((((ax0_ax1_fused_0 * 1280) + (((int)threadIdx.y) * 320)) + ((((int)threadIdx.x) >> 2) * 40)) + ((((int)threadIdx.x) & 3) * 8))) = make_ulonglong4(0ULL, 0ULL, 0ULL, 0ULL);
        }
      }
      for (int ax0_ax1_fused_0_1 = 0; ax0_ax1_fused_0_1 < 2; ++ax0_ax1_fused_0_1)
      {
        *(ulonglong4 *)(B_shared + ((((ax0_ax1_fused_0_1 * 1152) + (((int)threadIdx.y) * 288)) + ((((int)threadIdx.x) >> 3) * 72)) + ((((int)threadIdx.x) & 7) * 8))) =
          // original:
          // *(ulonglong4*)(B + ((((i2_0_0 * 2048) + (ax0_ax1_fused_0_1 * 1024)) + (((int)threadIdx.y) * 256)) + (((int)threadIdx.x) * 8)));
          *(ulonglong4*)(
            B_ptr_local
            + ax0_ax1_fused_0_1 * 1024 * N / 64
          );
        
      }
      __syncthreads();

      for (int i2_0_1 = 0; i2_0_1 < 2; ++i2_0_1)
      {
        for (int ax0_0 = 0; ax0_0 < 4; ++ax0_0)
        {
          for (int local_size = 0; local_size < 8; ++local_size)
          {
            A_shared_warp[((ax0_0 * 8) + local_size)] = A_shared[((((((((((int)threadIdx.y) & 1) * 2560) + (ax0_0 * 640)) + ((local_size & 1) * 320)) + ((((int)threadIdx.x) >> 2) * 40)) + (i2_0_1 * 16)) + ((local_size >> 1) * 4)) + (((int)threadIdx.x) & 3))];
          }
        }
        for (int ax1_0 = 0; ax1_0 < 2; ++ax1_0)
        {
          for (int local_size_1 = 0; local_size_1 < 8; ++local_size_1)
          {
            B_shared_warp[((ax1_0 * 8) + local_size_1)] = B_shared[(((((((i2_0_1 * 1152) + ((local_size_1 & 3) * 288)) + ((((int)threadIdx.x) & 3) * 72)) + ((((int)threadIdx.y) >> 1) * 32)) + (ax1_0 * 16)) + ((local_size_1 >> 2) * 8)) + (((int)threadIdx.x) >> 2))];
          }
        }
        for (int i0_0_3 = 0; i0_0_3 < 4; ++i0_0_3)
        {
          for (int i1_0_4 = 0; i1_0_4 < 2; ++i1_0_4)
          {
#if __CUDA_ARCH__ >= 800
            {
              __asm__ __volatile__(
                  "mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32"
                  "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
                  : "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[0]), "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[1]), "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[2]), "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[3])
                  : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[2]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[3]), "r"(((unsigned *)(B_shared_warp + (i1_0_4 * 8)))[0]), "r"(((unsigned *)(B_shared_warp + (i1_0_4 * 8)))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[2]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[3]));
            }
            {
              __asm__ __volatile__(
                  "mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32"
                  "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
                  : "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[0]), "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[1]), "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[2]), "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[3])
                  : "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[0]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[1]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[2]), "r"(((unsigned *)(A_shared_warp + (i0_0_3 * 8)))[3]), "r"(((unsigned *)(B_shared_warp + ((i1_0_4 * 8) + 4)))[0]), "r"(((unsigned *)(B_shared_warp + ((i1_0_4 * 8) + 4)))[1]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[0]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[1]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[2]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[3]));
            }
            {
              __asm__ __volatile__(
                  "mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32"
                  "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
                  : "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[0]), "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[1]), "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[2]), "=f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[3])
                  : "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[0]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[1]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[2]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[3]), "r"(((unsigned *)(B_shared_warp + ((i1_0_4 * 8) + 2)))[0]), "r"(((unsigned *)(B_shared_warp + ((i1_0_4 * 8) + 2)))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[0]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[1]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[2]), "f"(((float *)(C_warp + ((i0_0_3 * 16) + (i1_0_4 * 8))))[3]));
            }
            {
              __asm__ __volatile__(
                  "mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32"
                  "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
                  : "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[0]), "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[1]), "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[2]), "=f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[3])
                  : "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[0]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[1]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[2]), "r"(((unsigned *)(A_shared_warp + ((i0_0_3 * 8) + 4)))[3]), "r"(((unsigned *)(B_shared_warp + ((i1_0_4 * 8) + 6)))[0]), "r"(((unsigned *)(B_shared_warp + ((i1_0_4 * 8) + 6)))[1]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[0]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[1]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[2]), "f"(((float *)(C_warp + (((i0_0_3 * 16) + (i1_0_4 * 8)) + 4)))[3]));
            }
#else
  #pragma message("TF32 kernels will not be compiled.")
#endif 
          }
        }
      }
    }
  }
  for (int ax0_0_1 = 0; ax0_0_1 < 4; ++ax0_0_1)
  {

    int reorder_loc_offset_local = reorder_loc_offset + ax0_0_1 * 16;
    for (int ax1_0_1 = 0; ax1_0_1 < 2; ++ax1_0_1)
    {
      for (int local_id = 0; local_id < 8; ++local_id)
      {

        // original:
        // (&(C[(((((((int)blockIdx_y) * 8192) + ((((int)threadIdx.y) & 1) * 4096)) + (ax0_0_1 * 1024)) + ((((int)threadIdx.y) >> 1) * 32)) + (ax1_0_1 * 16))]))[((((((local_id / 2) % 2) * 8) + (threadIdx.x / 4)) * 64) + (((local_id % 2) + ((local_id / 4) * 8)) + ((threadIdx.x % 4) * 2)))]
        int reorder_location_cur = reorder_loc_offset_local + (((local_id / 2) % 2) * 8);
        if (reorder_location_cur < M)
          C_ptr[
            reorder_loc_ptr[reorder_location_cur] * N
            + ax1_0_1 * 16
            + (local_id % 2) 
            + (local_id / 4) * 8
          ] = C_warp[((ax0_0_1 * 16) + (ax1_0_1 * 8)) + local_id];
      };
    }
  }
}


// conv_forward_cuda_m128n16k16_f32f32f32_sort
template <int K_ld_factor, int N_ld_factor, bool K_ld_check, bool N_ld_check>
__global__ void __launch_bounds__(64) conv_forward_cuda_setting1_mode1_f32f32f32(int M, int K_original, int N, int kernel_volume, int split_mask_len, int reduced_mask_len, int reorder_loc_len, float *__restrict__ A, float *__restrict__ B, int *__restrict__ reduced_mask, int *__restrict__ out_in_map, int *__restrict__ reorder_loc, float *__restrict__ C)
{

  int j_factors1 = (N - 1) / 16 + 1; 
  int blockIdx_x = 0;
  int blockIdx_y = blockIdx.x % ((M + 127) / 128 * j_factors1);
  int blockIdx_z = blockIdx.x / ((M + 127) / 128 * j_factors1);

  const int K_tile = 16;
  int K_tile_padded = K_tile * ((K_original + K_tile - 1) / K_tile);
  int K_implicit = K_tile_padded * kernel_volume;

  float C_local[32];
  __shared__ float A_shared[2048];
  __shared__ float B_shared[256];

  #pragma unroll
  for (int i = 0; i < 32; ++i)   
  {
    C_local[i] = 0.0;
  }
  
  int K_loops_all = K_implicit / 16;

  int block_k_iter_start = blockIdx_z * split_mask_len * (K_tile_padded / 16);
  int block_k_iter_end = min(block_k_iter_start + split_mask_len * (K_tile_padded / 16), K_loops_all);

  int blockIdx_m = blockIdx_y / j_factors1;
  int blockIdx_n = blockIdx_y % j_factors1;
  int threadIdx_x = (int)threadIdx.x;

  // hoisting shared pointer offsets
  int * reorder_loc_block = reorder_loc + blockIdx_z * reorder_loc_len;
  int * reduced_mask_block = reduced_mask + blockIdx_z * reduced_mask_len;

  int * out_in_map_ptr = out_in_map 
                         + (blockIdx_m * 128 + (threadIdx_x / (16/4)))* kernel_volume;

  float * B_ptr = B 
                  + (threadIdx_x / (16/4)) * N 
                  + (blockIdx_n * 16) + ((threadIdx_x * 4) % 16); 

  float * A_shared_ptr = A_shared + (threadIdx_x * 4);
  float * A_shared_reduce_ptr =  A_shared + ((threadIdx_x / 4) * 16); 
  float * B_shared_ptr = B_shared + (threadIdx_x * 4);
  float * B_shared_reduce_ptr = B_shared + (threadIdx_x % 4);

  // float * C_ptr = C 
                      // // + (blockIdx_m * 128 + (threadIdx_x / 4)) * N
                      // + blockIdx_n * 16 + (threadIdx_x % 4);
  int location_offset = blockIdx_m * 128 + (threadIdx_x / 4);  // C_m_offset
  int C_n_offset = blockIdx_n * 16  + (threadIdx_x % 4);
  float * C_block = C + blockIdx_z * M * N;
  int channel_offset_A = ((threadIdx_x * 4) % 16);

  // const int K_ld_factor = (8 * !(K_original % 8)) + (4 * !(K_original % 4)) + (2 * !(K_original % 2)) + 1;
  // TODO: A_ld_start related to k_0
  int A_ld_start, A_ld_amount, A_ld_bound, A_pred_guard;
  int B_ld_start, B_ld_amount, B_ld_bound, B_pred_guard, B_ld_amount_N, B_ld_K_bound;
  bool B_ld_K;
  if constexpr (N_ld_check || K_ld_check)
  {
    B_ld_start = (blockIdx_n * 16) + ((threadIdx_x * 4) % 16);
    B_ld_amount_N = max(0, min(B_ld_start + 4, N) - B_ld_start);
    // B_ld_K_bound = (K_original % 16) ? (K_original % 16) : 16;
    B_ld_K_bound = K_original;
  }
  else
    B_pred_guard = 1;

  #pragma unroll
  for (int k_0 = block_k_iter_start; k_0 < block_k_iter_end; ++k_0) 
  {
    int kernel_offset = k_0 / (K_tile_padded / K_tile);
    int bitmask_shift = kernel_offset - blockIdx_z * split_mask_len;
    bool bit_flag = (bool)(reduced_mask_block[blockIdx_m] & (1 << bitmask_shift));
    if (bit_flag)
    {
      if constexpr (K_ld_check)
      {
        A_ld_start = (k_0 * K_tile % K_tile_padded) + ((threadIdx.x * 4) % 16); // Channel_offset
        A_ld_amount = max(0, min(A_ld_start + 4, K_original) - A_ld_start);
        A_ld_bound = A_ld_amount / (K_ld_factor / 4);
        A_pred_guard = 0;
        for (int i = 0; i < A_ld_bound; i++)
          A_pred_guard |= (1 << i);
      }
      else
      {
        A_pred_guard = 1;
      }

      if constexpr (K_ld_check || N_ld_check)
      {
        B_ld_K = ((k_0 * K_tile % K_tile_padded) + threadIdx.x * 4 / 16) < B_ld_K_bound;
        B_ld_amount = B_ld_amount_N * (int)B_ld_K;
        B_ld_bound = B_ld_amount / (N_ld_factor / 4);
        B_pred_guard = 0;
        for (int i = 0; i < B_ld_bound; i++)
          B_pred_guard |= (1 << i);
      }

      int* out_in_map_ptr_local = out_in_map_ptr + k_0 * 16 / K_tile_padded;
      float* A_ptr_local = A  + (k_0 * 16 % K_tile_padded) + channel_offset_A;  

      // float *B_ptr_local = B_ptr + i2_0_0 * K_tile * N;
      float* B_ptr_local;
      if constexpr (K_ld_check)
        B_ptr_local = B_ptr + (k_0 * K_tile / K_tile_padded * K_original + k_0 * K_tile % K_tile_padded) * N;
      else
        B_ptr_local = B_ptr + k_0 * K_tile * N;

      __syncthreads();
      #pragma unroll
      for (int ax0_ax1_fused_0 = 0; ax0_ax1_fused_0 < 8; ++ax0_ax1_fused_0)
      {

        int input_idx = *(out_in_map_ptr_local + (ax0_ax1_fused_0 *16) * kernel_volume); 
        if (input_idx != -1)
        {
          // *(float4*)(A_shared_ptr + (ax0_ax1_fused_0 * 256)) =  // ax0_ax1_fused_0 * elements loaded in each loop
          //     *(float4*)(A + (input_idx * K_original) + channel_offset);
          uint4 A_loaded = make_uint4(0, 0, 0, 0);
          global_load<K_ld_factor>(A_loaded, A_ptr_local + (input_idx * K_original) , A_pred_guard);
          *(uint4 *)(A_shared_ptr + (ax0_ax1_fused_0 * 256)) = A_loaded;
        }
        else 
        {
          // *(float4*)(A_shared_ptr + (ax0_ax1_fused_0 * 256)) = make_float4(0.0, 0.0, 0.0, 0.0);
          *(uint4*)(A_shared_ptr + (ax0_ax1_fused_0 * 256)) = make_uint4(0, 0, 0, 0);
        }
      }

      #pragma unroll
      for (int ax0_ax1_fused_0_1 = 0; ax0_ax1_fused_0_1 < 1; ++ax0_ax1_fused_0_1)
      {
        // *(float4*)(B_shared_ptr + (ax0_ax1_fused_0_1 * 256)) =                 // ax0_ax1_fused_0_1 * elements loaded in each loop
        //       *(float4*)(B_ptr_local + (ax0_ax1_fused_0_1 * 16) * N);
        uint4 B_loaded = make_uint4(0, 0, 0, 0);
        global_load<N_ld_factor>(B_loaded, B_ptr_local + (ax0_ax1_fused_0_1 * 16) * N, B_pred_guard); 
        *(uint4 *)(B_shared_ptr + (ax0_ax1_fused_0_1 * 256)) = B_loaded;
      }

      __syncthreads();
      #pragma unroll
      for (int k_1 = 0; k_1 < ( 16 / 4); ++k_1) 
      {
        #pragma unroll
        for (int k_2 = 0; k_2 < 4; ++k_2) 
        {
          int vk_in_block = (k_1 << 2) + k_2;
          #pragma unroll
          for (int i = 0; i < 32; ++i) 
          {
            C_local[i] = C_local[i] + 
                            A_shared_reduce_ptr[((i / 4) * 16) * 16 + vk_in_block] 
                            * B_shared_reduce_ptr[(vk_in_block * 16) + ((i % 4) * 4)];

          }
        }
      }
    }
  }

  #pragma unroll
  for (int i = 0; i < 32; ++i)
  {
      int location_cur = location_offset + ((i / 4) * 16);
      int vn = C_n_offset + ((i % 4) * 4); 

      if constexpr (N_ld_check)
      {
        if (vn < N && location_cur < M)
          C_block[reorder_loc_block[location_cur] * N + vn] = C_local[i];
      }
      else
      {
        if (location_cur < M)
          C_block[reorder_loc_block[location_cur] * N + vn] = C_local[i];
      }
  }
}

// conv_forward_cuda_m128n16k32_f32f32f32_sort
__global__ void __launch_bounds__(64) conv_forward_cuda_setting2_mode1_f32f32f32(int M, int K_original, int N, int kernel_volume, int split_mask_len, int reduced_mask_len, int reorder_loc_len, float *__restrict__ A, float *__restrict__ B, int *__restrict__ reduced_mask, int *__restrict__ out_in_map, int *__restrict__ reorder_loc, float *__restrict__ C)
{

  int j_factors1 = (N - 1) / 16 + 1; 
  int blockIdx_x = 0;
  int blockIdx_y = blockIdx.x % ((M + 127) / 128 * j_factors1);
  int blockIdx_z = blockIdx.x / ((M + 127) / 128 * j_factors1);

  float C_local[32];
  __shared__ float A_shared[4096];
  __shared__ float B_shared[512];

  #pragma unroll
  for (int i = 0; i < 32; ++i)   
  {
    C_local[i] = 0.0;
  }
  
  int K_loops_all = (K_original * kernel_volume - 1) / 32 + 1;
  int block_k_iter_start = blockIdx_z * split_mask_len * (K_original / 32);
  int block_k_iter_end = min(block_k_iter_start + split_mask_len * (K_original / 32), K_loops_all);

  int blockIdx_m = blockIdx_y / j_factors1;
  int blockIdx_n = blockIdx_y % j_factors1;
  int threadIdx_x = (int)threadIdx.x;
  
  // hoisting shared pointer offsets
  int * reorder_loc_block = reorder_loc + blockIdx_z * reorder_loc_len;
  int * reduced_mask_block = reduced_mask + blockIdx_z * reduced_mask_len;

  int * out_in_map_ptr = out_in_map 
                         + (blockIdx_m * 128 + (threadIdx_x / (32/4)))* kernel_volume;  

  float * B_ptr = B 
                  + (threadIdx_x / (16/4)) * N 
                  + (blockIdx_n * 16) + ((threadIdx_x * 4) % 16); 

  float * A_shared_ptr = A_shared + (threadIdx_x * 4);
  float * A_shared_reduce_ptr =  A_shared + ((threadIdx_x / 4) * 32); 
  float * B_shared_ptr = B_shared + (threadIdx_x * 4);
  float * B_shared_reduce_ptr = B_shared + (threadIdx_x % 4);

  // float * C_ptr = C 
                      // // + (blockIdx_m * 128 + (threadIdx_x / 4)) * N
                      // + blockIdx_n * 16 + (threadIdx_x % 4);
  int location_offset = blockIdx_m * 128 + (threadIdx_x / 4);  // C_m_offset
  int C_n_offset = blockIdx_n * 16  + (threadIdx_x % 4);
  float * C_block = C + blockIdx_z * M * N;

  int channel_offset_A = ((threadIdx_x * 4) % 32); // mod K_tile=32

  #pragma unroll
  for (int k_0 = block_k_iter_start; k_0 < block_k_iter_end; ++k_0) 
  {
    int channel_offset = k_0 % (K_original / 32) * 32 + channel_offset_A; 
    int kernel_offset = k_0 / (K_original / 32);
    int bitmask_shift = kernel_offset - blockIdx_z * split_mask_len;
    int *out_in_map_ptr_k = out_in_map_ptr + kernel_offset;

    bool bit_flag = (bool)(reduced_mask_block[blockIdx_m] & (1 << bitmask_shift));
    if (bit_flag)
    {
      __syncthreads();
      #pragma unroll
      for (int ax0_ax1_fused_0 = 0; ax0_ax1_fused_0 < 16; ++ax0_ax1_fused_0)
      {
        int input_idx = *(out_in_map_ptr_k + (ax0_ax1_fused_0 *8) * kernel_volume); 
        if (input_idx != -1) 
        {
          *(float4*)(A_shared_ptr + (ax0_ax1_fused_0 * 256)) =  // ax0_ax1_fused_0 * elements loaded in each loop
              *(float4*)(A + (input_idx * K_original) + channel_offset);
        }
        else {
          *(float4*)(A_shared_ptr + (ax0_ax1_fused_0 * 256)) = make_float4(0.0, 0.0, 0.0, 0.0);
        }
      }

      #pragma unroll
      for (int ax0_ax1_fused_0_1 = 0; ax0_ax1_fused_0_1 < 2; ++ax0_ax1_fused_0_1)    
      {
        *(float4*)(B_shared_ptr + (ax0_ax1_fused_0_1 * 256)) =                 // ax0_ax1_fused_0_1 * elements loaded in each loop
              *(float4*)(B_ptr + ((k_0 * 32) + (ax0_ax1_fused_0_1 * 16)) * N); 
      }

      __syncthreads();
      #pragma unroll
      for (int k_1 = 0; k_1 < ( 32 / 4); ++k_1) 
      {
        #pragma unroll
        for (int k_2 = 0; k_2 < 4; ++k_2) 
        {
          int vk_in_block = (k_1 << 2) + k_2;
          #pragma unroll
          for (int i = 0; i < 32; ++i) 
          {
            C_local[i] = C_local[i] + 
                          A_shared_reduce_ptr[((i / 4) * 16) * 32 + vk_in_block] 
                          * B_shared_reduce_ptr[(vk_in_block * 16) + ((i % 4) * 4)];

          }
        }
      }
    }
  }

  #pragma unroll
  for (int i = 0; i < 32; ++i) 
  {
      int location_cur = location_offset + ((i / 4) * 16);
      int vn = C_n_offset + ((i % 4) * 4); 

      if (location_cur < M)
        C_block[reorder_loc_block[location_cur] * N + vn] = C_local[i];
  }
}

// conv_forward_cuda_m128n64k32_f32f32f32_sort
__global__ void __launch_bounds__(128) conv_forward_cuda_setting3_mode1_f32f32f32(int M, int K_original, int N, int kernel_volume, int split_mask_len, int reduced_mask_len, int reorder_loc_len, float *__restrict__ A, float *__restrict__ B, int *__restrict__ reduced_mask, int *__restrict__ out_in_map, int *__restrict__ reorder_loc, float *__restrict__ C)
{

  int j_factors1 = (N - 1) / 64 + 1; 
  int blockIdx_x = 0;
  int blockIdx_y = blockIdx.x % ((M + 127) / 128 * j_factors1);
  int blockIdx_z = blockIdx.x / ((M + 127) / 128 * j_factors1);

  float C_local[64];
  __shared__ float A_shared[4096];
  __shared__ float B_shared[2048];

  #pragma unroll
  for (int i = 0; i < 64; ++i)   
  {
    C_local[i] = 0.0;
  }
  
  int K_loops_all = (K_original * kernel_volume - 1) / 32 + 1;
  int block_k_iter_start = blockIdx_z * split_mask_len * (K_original / 32);
  int block_k_iter_end = min(block_k_iter_start + split_mask_len * (K_original / 32), K_loops_all);

  int blockIdx_m = blockIdx_y / j_factors1;
  int blockIdx_n = blockIdx_y % j_factors1;
  int threadIdx_x = (int)threadIdx.x;
  
  // hoisting shared pointer offsets
  int * reorder_loc_block = reorder_loc + blockIdx_z * reorder_loc_len;
  int * reduced_mask_block = reduced_mask + blockIdx_z * reduced_mask_len;

  int * out_in_map_ptr = out_in_map 
                         + (blockIdx_m * 128 + (threadIdx_x / (32/4)))* kernel_volume;  


  float * B_ptr = B 
                  + (threadIdx_x / (64/4)) * N 
                  + (blockIdx_n * 64) + ((threadIdx_x * 4) % 64); 

  float * A_shared_ptr = A_shared + (threadIdx_x * 4);
  float * A_shared_reduce_ptr =  A_shared + ((threadIdx_x / 16) * 32); 
  float * B_shared_ptr = B_shared + (threadIdx_x * 4);
  float * B_shared_reduce_ptr = B_shared + (threadIdx_x % 16);

  // float * C_ptr = C 
                      // // + (blockIdx_m * 128 + (threadIdx_x / 16)) * N
                      // + blockIdx_n * 64 + (threadIdx_x % 16);
  int location_offset = blockIdx_m * 128 + (threadIdx_x / 16);  // C_m_offset
  int C_n_offset = blockIdx_n * 64  + (threadIdx_x % 16);
  float * C_block = C + blockIdx_z * M * N;

  int channel_offset_A = ((threadIdx_x * 4) % 32); // mod K_tile=32

  #pragma unroll
  for (int k_0 = block_k_iter_start; k_0 < block_k_iter_end; ++k_0) 
  {
    int channel_offset = k_0 % (K_original / 32) * 32 + channel_offset_A; 
    int kernel_offset = k_0 / (K_original / 32);
    int bitmask_shift = kernel_offset - blockIdx_z * split_mask_len;
    int *out_in_map_ptr_k = out_in_map_ptr + kernel_offset;

    bool bit_flag = (bool)(reduced_mask_block[blockIdx_m] & (1 << bitmask_shift));
    if (bit_flag)
    {
      __syncthreads();
      #pragma unroll
      for (int ax0_ax1_fused_0 = 0; ax0_ax1_fused_0 < 8; ++ax0_ax1_fused_0)
      {
        int input_idx = *(out_in_map_ptr_k + (ax0_ax1_fused_0 *16) * kernel_volume); 
        if (input_idx != -1) 
        {
          *(float4*)(A_shared_ptr + (ax0_ax1_fused_0 * 512)) =  // ax0_ax1_fused_0 * elements loaded in each loop
              *(float4*)(A + (input_idx * K_original) + channel_offset);
        }
        else {
          *(float4*)(A_shared_ptr + (ax0_ax1_fused_0 * 512)) = make_float4(0.0, 0.0, 0.0, 0.0);
        }
      }

      #pragma unroll
      for (int ax0_ax1_fused_0_1 = 0; ax0_ax1_fused_0_1 < 4; ++ax0_ax1_fused_0_1)    
      {
        *(float4*)(B_shared_ptr + (ax0_ax1_fused_0_1 * 512)) =                 // ax0_ax1_fused_0_1 * elements loaded in each loop
              *(float4*)(B_ptr + ((k_0 * 32) + (ax0_ax1_fused_0_1 * 8)) * N); 
      }

      __syncthreads();
      #pragma unroll
      for (int k_1 = 0; k_1 < ( 32 / 4); ++k_1) 
      {
        #pragma unroll
        for (int k_2 = 0; k_2 < 4; ++k_2) 
        {
          int vk_in_block = (k_1 << 2) + k_2;
          #pragma unroll
          for (int i = 0; i < 64; ++i) 
          {
            C_local[i] = C_local[i] + 
                          A_shared_reduce_ptr[((i / 4) * 8) * 32 + vk_in_block] 
                          * B_shared_reduce_ptr[(vk_in_block * 64) + ((i % 4) * 16)];

          }
        }
      }
    }
  }

  #pragma unroll
  for (int i = 0; i < 64; ++i) 
  {
      int location_cur = location_offset + ((i / 4) * 8);
      int vn = C_n_offset + ((i % 4) * 16); 

      if (location_cur < M)
        C_block[reorder_loc_block[location_cur] * N + vn] = C_local[i];
  }
}


at::Tensor conv_forward_implicit_gemm_sorted_cuda(
    torch::Tensor _in_feats, torch::Tensor _kernel,
    torch::Tensor _out_in_map, torch::Tensor _reduced_mask,
    torch::Tensor _reorder_loc,
    int num_out_feats, int num_out_channels,
    bool allow_tf32, bool allow_fp16)
{
  bool is_tf = allow_tf32;
  int num_in_feats = _in_feats.size(0);
  int num_in_channels = _in_feats.size(1);
  int kernel_volume = _out_in_map.size(1);

  int split_mask_num = _reduced_mask.size(0);
  int split_mask_len = (kernel_volume + split_mask_num - 1) / split_mask_num;
  int reduced_mask_len = _reduced_mask.size(1);
  int reorder_loc_len = _reorder_loc.size(1);

  auto options =
      torch::TensorOptions().dtype(_in_feats.dtype()).device(_in_feats.device());
  at::Tensor _out_feats;
  if (split_mask_num != 1)
    _out_feats = torch::empty({split_mask_num, num_out_feats, num_out_channels}, options);
  else
    _out_feats = torch::empty({num_out_feats, num_out_channels}, options);
  auto reduced_mask = _reduced_mask.data_ptr<int>();
  auto out_in_map = _out_in_map.data_ptr<int>();
  auto reorder_loc = _reorder_loc.data_ptr<int>();
  bool is_half = _in_feats.scalar_type() == at::ScalarType::Half;

  if (is_half)
  {
    // throw std::runtime_error("FP16 kernels have not been updated for split mask implimentation.");
    if (!allow_fp16)
    {
      throw std::runtime_error("FP16 kernels are not supported for implicit GEMM now for SM75-.");
    }
    auto in_feats = reinterpret_cast<half *>(_in_feats.data_ptr<at::Half>());
    auto kernel = reinterpret_cast<half *>(_kernel.data_ptr<at::Half>());
    auto out_feats = reinterpret_cast<half *>(_out_feats.data_ptr<at::Half>());

    if (num_out_channels % 64 == 0 && num_in_channels % 32 == 0)
    {
      int j_factors1 = num_out_channels / 16 / 4;
      dim3 num_blocks(1 * (num_out_feats + 127) / 128 * j_factors1 * split_mask_num);
      // threadIdx.x: 32
      // threadIdx.y: i_factors[2] * j_factors[2]
      dim3 threads_per_block(32, 4);
      conv_forward_cuda_setting3_mode1_f16f16f32<<<num_blocks, threads_per_block>>>(
        num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
    }
    else if (num_in_channels % 32 == 0 && num_out_channels % 16 == 0)
    {
      int j_factors1 = num_out_channels / 16 / 1;
      dim3 num_blocks(1 * (num_out_feats + 127) / 128 * j_factors1 * split_mask_num);
      // threadIdx.x: 32
      // threadIdx.y: i_factors[2] * j_factors[2]
      dim3 threads_per_block(32, 2);
      conv_forward_cuda_setting2_mode1_f16f16f32<<<num_blocks, threads_per_block>>>(
        num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
    }
    else
    {
      // throw std::invalid_argument("IC is too small for this kernel");
      int j_factors1 = (num_out_channels + 15) / 16 / 1;
      dim3 num_blocks(1 * (num_out_feats + 127) / 128 * j_factors1 * split_mask_num);
      // threadIdx.x: 32
      // threadIdx.y: i_factors[2] * j_factors[2]
      dim3 threads_per_block(32, 2);
      // conv_forward_cuda_setting1_mode1_f16f16f32<<<num_blocks, threads_per_block>>>(
      //     _out_feats.size(0), num_in_channels, num_out_channels, kernel_volume, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
      if (num_in_channels % 16 == 0)
      {
        if (num_out_channels % 16 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<16, 16, false, false><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 8 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<16, 16, false, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 4 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<16, 8, false, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 2 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<16, 4, false, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<16, 2, false, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
      }
      else if (num_in_channels % 8 == 0)
      {
        if (num_out_channels % 16 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<16, 16, true, false><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 8 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<16, 16, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 4 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<16, 8, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 2 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<16, 4, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<16, 2, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
      }
      else if (num_in_channels % 4 == 0)
      {
        if (num_out_channels % 16 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<8, 16, true, false><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 8 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<8, 16, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 4 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<8, 8, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 2 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<8, 4, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<8, 2, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
      }
      else if (num_in_channels % 2 == 0)
      {
        if (num_out_channels % 16 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<4, 16, true, false><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 8 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<4, 16, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 4 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<4, 8, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 2 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<4, 4, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<4, 2, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
      }
      else
      {
        if (num_out_channels % 16 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<2, 16, true, false><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 8 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<2, 16, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 4 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<2, 8, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 2 == 0)
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<2, 4, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else
        {
          conv_forward_cuda_setting1_mode1_f16f16f32<2, 2, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
      }
    }
  }
  else if (is_tf)
  {
    //throw std::runtime_error("TF32 kernels have not been updated for split mask implimentation.");
    auto in_feats = _in_feats.data_ptr<float>();
    auto kernel = _kernel.data_ptr<float>();
    auto out_feats = _out_feats.data_ptr<float>();

    if (num_out_channels % 64 == 0 && num_in_channels % 32 == 0)
    {
      int j_factors1 = num_out_channels / 16 / 4;
      dim3 num_blocks(1 * (num_out_feats + 127) / 128 * j_factors1 * split_mask_num);
      // threadIdx.x: 32
      // threadIdx.y: i_factors[2] * j_factors[2]
      dim3 threads_per_block(32, 4);
      conv_forward_cuda_setting3_mode1_tf32tf32f32<<<num_blocks, threads_per_block>>>(
        num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
    }
    else if (num_in_channels % 32 == 0 && num_out_channels % 16 == 0)
    {
      int j_factors1 = num_out_channels / 16 / 1;
      dim3 num_blocks(1 * (num_out_feats + 127) / 128 * j_factors1 * split_mask_num);
      // threadIdx.x: 32
      // threadIdx.y: i_factors[2] * j_factors[2]
      dim3 threads_per_block(32, 2);
      conv_forward_cuda_setting2_mode1_tf32tf32f32<<<num_blocks, threads_per_block>>>(
        num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
    }
    else
    {
      // throw std::invalid_argument("IC is too small for this kernel");
      int j_factors1 = (num_out_channels + 15) / 16 / 1;
      dim3 num_blocks(1 * (num_out_feats + 127) / 128 * j_factors1 * split_mask_num);
      // threadIdx.x: 32
      // threadIdx.y: i_factors[2] * j_factors[2]
      dim3 threads_per_block(32, 2);
      // conv_forward_cuda_setting1_mode1_tf32tf32f32<<<num_blocks, threads_per_block>>>(
      //     _out_feats.size(0), num_in_channels, num_out_channels, kernel_volume, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
      if (num_in_channels % 16 == 0)
      {
        if (num_out_channels % 16 == 0)
        {
          conv_forward_cuda_setting1_mode1_tf32tf32f32<16, 16, false, false><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 4 == 0)
        {
          conv_forward_cuda_setting1_mode1_tf32tf32f32<16, 16, false, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 2 == 0)
        {
          conv_forward_cuda_setting1_mode1_tf32tf32f32<16, 8, false, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else
        {
          conv_forward_cuda_setting1_mode1_tf32tf32f32<16, 4, false, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
      }
      else if (num_in_channels % 4 == 0)
      {
        if (num_out_channels % 16 == 0)
        {
          conv_forward_cuda_setting1_mode1_tf32tf32f32<16, 16, true, false><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 4 == 0)
        {
          conv_forward_cuda_setting1_mode1_tf32tf32f32<16, 16, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 2 == 0)
        {
          conv_forward_cuda_setting1_mode1_tf32tf32f32<16, 8, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else
        {
          conv_forward_cuda_setting1_mode1_tf32tf32f32<16, 4, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
      }
      else if (num_in_channels % 2 == 0)
      {
        if (num_out_channels % 16 == 0)
        {
          conv_forward_cuda_setting1_mode1_tf32tf32f32<8, 16, true, false><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 4 == 0)
        {
          conv_forward_cuda_setting1_mode1_tf32tf32f32<8, 16, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 2 == 0)
        {
          conv_forward_cuda_setting1_mode1_tf32tf32f32<8, 8, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else
        {
          conv_forward_cuda_setting1_mode1_tf32tf32f32<8, 4, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
      }
      else
      {
        if (num_out_channels % 16 == 0)
        {
          conv_forward_cuda_setting1_mode1_tf32tf32f32<4, 16, true, false><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 4 == 0)
        {
          conv_forward_cuda_setting1_mode1_tf32tf32f32<4, 16, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 2 == 0)
        {
          conv_forward_cuda_setting1_mode1_tf32tf32f32<4, 8, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else
        {
          conv_forward_cuda_setting1_mode1_tf32tf32f32<4, 4, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, _reduced_mask.size(1), _reorder_loc.size(1), in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
      }
    }
  }
  else //fp32fp32fp32
  {
    // printf("\n Run sorted FP32 kernel! \n"); 
    auto in_feats = _in_feats.data_ptr<float>();
    auto kernel = _kernel.data_ptr<float>();
    auto out_feats = _out_feats.data_ptr<float>();

    if (num_out_channels % 64 == 0 && num_in_channels % 32 == 0)
    {
      int block_num_M = (num_out_feats + 127) / 128;
      int block_num_N = num_out_channels / 64;  //j_factors1
      dim3 num_blocks(block_num_M * block_num_N * split_mask_num); 
      dim3 threads_per_block(128);
      conv_forward_cuda_setting3_mode1_f32f32f32<<<num_blocks, threads_per_block>>>(
          num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
    }
    else if (num_in_channels % 32 == 0 && num_out_channels % 16 == 0)
    {
      int block_num_M = (num_out_feats + 127) / 128;
      int block_num_N = num_out_channels / 16;  //j_factors1
      dim3 num_blocks(block_num_M * block_num_N * split_mask_num); 
      dim3 threads_per_block(64);
      conv_forward_cuda_setting2_mode1_f32f32f32<<<num_blocks, threads_per_block>>>(
          num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
    }
    else
    {
      int block_num_M = (num_out_feats + 127) / 128;
      int block_num_N = (num_out_channels + 15) / 16;  //j_factors1
      dim3 num_blocks(block_num_M * block_num_N * split_mask_num); 
      dim3 threads_per_block(64);
      // conv_forward_cuda_setting1_mode1_tf32tf32f32<<<num_blocks, threads_per_block>>>(
      //     num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
      
      if (num_in_channels % 16 == 0)
      {
        if (num_out_channels % 16 == 0)
        {
          conv_forward_cuda_setting1_mode1_f32f32f32<16, 16, false, false><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 4 == 0)
        {
          conv_forward_cuda_setting1_mode1_f32f32f32<16, 16, false, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 2 == 0)
        {
          conv_forward_cuda_setting1_mode1_f32f32f32<16, 8, false, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else
        {
          conv_forward_cuda_setting1_mode1_f32f32f32<16, 4, false, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
      }
      else if (num_in_channels % 4 == 0)
      {
        if (num_out_channels % 16 == 0)
        {
          conv_forward_cuda_setting1_mode1_f32f32f32<16, 16, true, false><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 4 == 0)
        {
          conv_forward_cuda_setting1_mode1_f32f32f32<16, 16, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 2 == 0)
        {
          conv_forward_cuda_setting1_mode1_f32f32f32<16, 8, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else
        {
          conv_forward_cuda_setting1_mode1_f32f32f32<16, 4, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
      }
      else if (num_in_channels % 2 == 0)
      {
        if (num_out_channels % 16 == 0)
        {
          conv_forward_cuda_setting1_mode1_f32f32f32<8, 16, true, false><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 4 == 0)
        {
          conv_forward_cuda_setting1_mode1_f32f32f32<8, 16, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 2 == 0)
        {
          conv_forward_cuda_setting1_mode1_f32f32f32<8, 8, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else
        {
          conv_forward_cuda_setting1_mode1_f32f32f32<8, 4, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
      }
      else
      {
        if (num_out_channels % 16 == 0)
        {
          conv_forward_cuda_setting1_mode1_f32f32f32<4, 16, true, false><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 4 == 0)
        {
          conv_forward_cuda_setting1_mode1_f32f32f32<4, 16, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else if (num_out_channels % 2 == 0)
        {
          conv_forward_cuda_setting1_mode1_f32f32f32<4, 8, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
        else
        {
          conv_forward_cuda_setting1_mode1_f32f32f32<4, 4, true, true><<<num_blocks, threads_per_block>>>(
              num_out_feats, num_in_channels, num_out_channels, kernel_volume, split_mask_len, reduced_mask_len, reorder_loc_len, in_feats, kernel, reduced_mask, out_in_map, reorder_loc, out_feats);
        }
      }
    }
  }
  if (split_mask_num != 1)
    return _out_feats.sum(0);
  else 
    return _out_feats;
}
