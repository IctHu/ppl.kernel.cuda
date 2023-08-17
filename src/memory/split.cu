// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

#include "cudakernel/memory/split.h"
#include "cudakernel/memory/slice.h"
#include "cudakernel/common/divmod_fast.h"
#include "cudakernel/common/common.h"
#include "ppl/common/tensor_shape.h"
#include "ppl/common/retcode.h"
#include <cuda_runtime.h>

#include "cudakernel/common/common.cuh"
#include <cuda_fp16.h>

#define NHWC8_ALIGNED_AXIS (8)

template <typename T1, typename T2>
__global__ void __launch_bounds__(256) ppl_cukernel_split_nhwc_two_inputs(
    int64_t num_elems,
    int inner_dims,
    int pad_inner_dims,
    int axis_width0,
    int pad_axis_width0,
    int axis_width1,
    int pad_axis_width1,
    T1* input,
    T2* output0,
    T2* output1)
{
    for (int64_t i = (int64_t)blockIdx.x * blockDim.x + threadIdx.x;
         i < num_elems;
         i += (int64_t)blockDim.x * gridDim.x) {
        int inner_idx    = i % inner_dims;
        int outer_idx    = i / inner_dims;
        int input_offset = outer_idx * pad_inner_dims + inner_idx;
        if (inner_idx >= axis_width0) {
            int output_offset      = outer_idx * pad_axis_width1 + (inner_idx - axis_width0);
            output1[output_offset] = input[input_offset];
        } else {
            int output_offset      = outer_idx * pad_axis_width0 + inner_idx;
            output0[output_offset] = input[input_offset];
        }
    }
}

template <typename T>
__global__ void __launch_bounds__(256) ppl_cukernel_split_ndarray(
    int64_t num_elems,
    DivModFast inner_dims_fast,
    int in_split_axis_size,
    DivModFast out_split_axis_size_fast,
    int offset_split_axis,
    const T* input,
    T* output)
{
    for (int64_t i = (int64_t)blockIdx.x * blockDim.x + threadIdx.x;
         i < num_elems;
         i += (int64_t)blockDim.x * gridDim.x) {
        int inner_idx, outer_split_idx;
        inner_dims_fast.divmod(i, outer_split_idx, inner_idx);
        int split_idx, outer_idx;
        out_split_axis_size_fast.divmod(outer_split_idx, outer_idx, split_idx);
        int inner_dims   = inner_dims_fast.d_;
        int input_offset = outer_idx * in_split_axis_size * inner_dims +
                           (split_idx + offset_split_axis) * inner_dims + inner_idx;
        output[i] = input[input_offset];
    }
}

ppl::common::RetCode PPLCUDASplitForwardImp(
    cudaStream_t stream,
    int split_axis,
    const ppl::common::TensorShape* input_shape,
    const void* input,
    int num_outputs,
    const int64_t* out_dims[],
    void* outputs[])
{
    int64_t num_byte_elem = ppl::common::GetSizeOfDataType(input_shape->GetDataType());
    if (input_shape->GetDataFormat() == ppl::common::DATAFORMAT_NDARRAY) {
        int num_dims              = input_shape->GetDimCount();
        int64_t split_size        = 1;
        int64_t split_count       = 1;
        int64_t offset_split_axis = 0;
        int64_t split_axis_length = input_shape->GetDim(split_axis);
        for (int i = 0; i < split_axis; i++)
            split_count *= input_shape->GetDim(i);
        for (int i = split_axis + 1; i < num_dims; i++)
            split_size *= input_shape->GetDim(i);

#define SWITCH_CASE(TYPE)                                                                                                                                                                         \
    case sizeof(TYPE): {                                                                                                                                                                          \
        for (int i = 0; i < num_outputs; i++) {                                                                                                                                                   \
            TYPE* out_ptr             = static_cast<TYPE*>(outputs[i]);                                                                                                                           \
            const TYPE* input_ptr     = static_cast<const TYPE*>(input);                                                                                                                          \
            int out_split_axis_length = out_dims[i][split_axis];                                                                                                                                  \
            int split_size_with_axis  = out_split_axis_length * split_size;                                                                                                                       \
            int memcpy_threshold      = 64;                                                                                                                                                       \
            if (split_count > memcpy_threshold || split_size_with_axis < memcpy_threshold) {                                                                                                                                        \
                int block_size = 128;                                                                                                                                                             \
                int out_elems  = split_size_with_axis * split_count;                                                                                                                              \
                int grid_size  = (out_elems + block_size - 1) / block_size;                                                                                                                       \
                DivModFast split_size_fast(split_size);                                                                                                                                           \
                DivModFast out_split_axis_size_fast(out_split_axis_length);                                                                                                                       \
                ppl_cukernel_split_ndarray<<<grid_size, block_size, 0, stream>>>(out_elems, split_size_fast, split_axis_length, out_split_axis_size_fast, offset_split_axis, input_ptr, out_ptr); \
            } else {                                                                                                                                                                              \
                for (int n = 0; n < split_count; n++) {                                                                                                                                           \
                    int64_t out_offset = n * split_size_with_axis;                                                                                                                                \
                    int64_t in_offset  = (n * split_axis_length + offset_split_axis) * split_size;                                                                                                \
                    cudaMemcpyAsync(out_ptr + out_offset, input_ptr + in_offset, split_size_with_axis * num_byte_elem, cudaMemcpyDeviceToDevice, stream);                                         \
                }                                                                                                                                                                                 \
            }                                                                                                                                                                                     \
            offset_split_axis += out_split_axis_length;                                                                                                                                           \
        }                                                                                                                                                                                         \
        return ppl::common::RC_SUCCESS;                                                                                                                                                           \
    }

        switch (num_byte_elem) {
            SWITCH_CASE(int8_t);
            SWITCH_CASE(int16_t);
            SWITCH_CASE(int32_t);
            SWITCH_CASE(int64_t);
            default:
                return ppl::common::RC_UNSUPPORTED;
        }

#undef SWITCH_CASE
    } else if (input_shape->GetDataFormat() == ppl::common::DATAFORMAT_NHWC8 ||
               input_shape->GetDataFormat() == ppl::common::DATAFORMAT_NHWC16) {
        int num_dims = input_shape->GetDimCount();
        if (num_dims < 2)
            return ppl::common::RC_UNSUPPORTED;
        int input_elems = input_shape->CalcElementsExcludingPadding();
        if (num_outputs == 2 && split_axis == 1) {
            int align_size = NHWC8_ALIGNED_AXIS;
            if (input_shape->GetDataFormat() == ppl::common::DATAFORMAT_NHWC16) {
                align_size = NHWC8_ALIGNED_AXIS * 2;
            }
#define SWITCH_CASE(TYPE)                                                                            \
    case sizeof(TYPE): {                                                                             \
        int block_size      = 256;                                                                   \
        int grid_size       = (input_elems + block_size - 1) / block_size;                           \
        int axis_width0     = out_dims[0][split_axis];                                               \
        int pad_axis_width0 = Align(axis_width0, align_size);                                \
        int axis_width1     = out_dims[1][split_axis];                                               \
        int pad_axis_width1 = Align(axis_width1, align_size);                                \
        int inner_dims      = axis_width0 + axis_width1;                                             \
        int pad_inner_dims  = Align(inner_dims, align_size);                                 \
        ppl_cukernel_split_nhwc_two_inputs<<<grid_size, block_size, 0, stream>>>(input_elems,        \
                                                                                 inner_dims,         \
                                                                                 pad_inner_dims,     \
                                                                                 axis_width0,        \
                                                                                 pad_axis_width0,    \
                                                                                 axis_width1,        \
                                                                                 pad_axis_width1,    \
                                                                                 (const TYPE*)input, \
                                                                                 (TYPE*)outputs[0],  \
                                                                                 (TYPE*)outputs[1]); \
        return ppl::common::RC_SUCCESS;                                                              \
    }

            switch (num_byte_elem) {
                SWITCH_CASE(int8_t);
                SWITCH_CASE(int16_t);
                SWITCH_CASE(int32_t);
                SWITCH_CASE(int64_t);
                default:
                    return ppl::common::RC_UNSUPPORTED;
            }
#undef SWITCH_CASE
        }

        ppl::common::TensorShape output_shape(*input_shape);

        SliceKernelParam param;
        param.axes_num  = 1;
        param.starts[0] = 0;
        param.ends[0]   = input_shape->GetDim(split_axis);
        param.axes[0]   = split_axis;
        param.steps[0]  = 1;

        int64_t offset_split_axis = 0;
        for (int i = 0; i < num_outputs; i++) {
            output_shape.Reshape(out_dims[i], num_dims);
            output_shape.CalcPadding();
            param.starts[0]           = offset_split_axis;
            int out_split_axis_length = out_dims[i][split_axis];
            offset_split_axis += out_split_axis_length;
            param.ends[0] = offset_split_axis;
            PPLCUDASliceForwardImp(stream, param, input_shape, input, &output_shape, outputs[i]);
        }
        return ppl::common::RC_SUCCESS;
    } else {
        return ppl::common::RC_UNSUPPORTED;
    }
}

template<typename T, int TPB, int VPT>
__global__ void ppl_cukernel_aligned_split3_kernel(
    const T* input, int64_t input_dim,
    T* out0, int64_t out0_dim,
    T* out1, int64_t out1_dim,
    T* out2, int64_t out2_dim)
{
    const int64_t idx = (blockIdx.y * TPB + threadIdx.x) * VPT;
    auto cur_input = input + blockIdx.x * input_dim;
    T local[VPT];
    if(idx < out0_dim) {
        const int64_t real_idx = idx;
        auto cur_out0 = out0 + blockIdx.x * out0_dim;
        copy<sizeof(T) * VPT>(&cur_input[idx], local);
        copy<sizeof(T) * VPT>(local, &cur_out0[real_idx]);
    } else if (idx < out0_dim + out1_dim) {
        const int64_t real_idx = idx - out0_dim;
        auto cur_out1 = out1 + blockIdx.x * out1_dim;
        copy<sizeof(T) * VPT>(&cur_input[idx], local);
        copy<sizeof(T) * VPT>(local, &cur_out1[real_idx]);
    } else if (idx < out0_dim + out1_dim + out2_dim) {
        const int64_t real_idx = idx - out0_dim - out1_dim;
        auto cur_out2 = out2 + blockIdx.x * out2_dim;
        copy<sizeof(T) * VPT>(&cur_input[idx], local);
        copy<sizeof(T) * VPT>(local, &cur_out2[real_idx]);
    }
}

ppl::common::RetCode PPLCUDAAlignedSplit3ForwardImp(
    cudaStream_t stream,
    const ppl::common::TensorShape* input_shape,
    const void* input,
    int32_t split_axis,
    const ppl::common::TensorShape* output0_shape,
    void* output0,
    const ppl::common::TensorShape* output1_shape,
    void* output1,
    const ppl::common::TensorShape* output2_shape,
    void* output2)
{

    if (input_shape->GetDataType() != ppl::common::DATATYPE_FLOAT16) {
        return ppl::common::RC_UNSUPPORTED;
    }

    const int64_t VPT = 16 / sizeof(half);
    const int64_t TPB = 256;

    const int64_t outer_dim = input_shape->CalcElementsToDimensionExcludingPadding(split_axis);
    const int64_t inner_dim = input_shape->CalcElementsFromDimensionExcludingPadding(split_axis + 1);
    const int64_t input_dim = input_shape->GetDim(split_axis) * inner_dim;
    const int64_t out0_dim = output0_shape->GetDim(split_axis) * inner_dim;
    const int64_t out1_dim = output1_shape->GetDim(split_axis) * inner_dim;
    const int64_t out2_dim = output2_shape->GetDim(split_axis) * inner_dim;

    const bool out0_aligned = (out0_dim / VPT * VPT == out0_dim);
    const bool out1_aligned = (out1_dim / VPT * VPT == out1_dim);
    const bool out2_aligned = (out2_dim / VPT * VPT == out2_dim);

    if (!out0_aligned || !out1_aligned || !out2_aligned) {
        return ppl::common::RC_UNSUPPORTED;
    }

    const int64_t total_out_dim = out0_dim + out1_dim + out2_dim;
    dim3 grid_size = {(unsigned int)outer_dim, (unsigned int)ceilf(total_out_dim / (VPT * TPB)), 1};

    ppl_cukernel_aligned_split3_kernel<half, TPB, VPT><<<grid_size, TPB, 0, stream>>>(
        (half*)input, input_dim,
        (half*)output0, out0_dim,
        (half*)output1, out1_dim,
        (half*)output2, out2_dim);

    return ppl::common::RC_SUCCESS;
}
