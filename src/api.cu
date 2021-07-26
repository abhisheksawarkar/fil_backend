/*
 * Copyright (c) 2021, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cuml/fil/fil.h>
#include <treelite/c_api.h>
#include <raft/handle.hpp>

#include <chrono>
#include <cstddef>
#include <limits>
#include <memory>
#include <string>
#include <thread>

#include "triton/backend/backend_common.h"
#include "triton/backend/backend_model.h"
#include "triton/backend/backend_model_instance.h"

#include <triton_fil/config.h>
#include <triton_fil/enum_conversions.h>
#include <triton_fil/exceptions.h>
#include <triton_fil/model_state.h>
#include <triton_fil/triton_utils.h>
#include <triton_fil/model_instance_state.cuh>
#include <triton_fil/triton_tensor.cuh>
#include <triton_fil/triton_tensor_utils.cuh>

namespace triton { namespace backend { namespace fil {

extern "C" {

TRITONSERVER_Error*
TRITONBACKEND_Initialize(TRITONBACKEND_Backend* backend)
{
  try {
    std::string name = get_backend_name(*backend);

    log_info(
        __FILE__, __LINE__,
        (std::string("TRITONBACKEND_Initialize: ") + name).c_str());

    if (!check_backend_version(*backend)) {
      return TRITONSERVER_ErrorNew(
          TRITONSERVER_ERROR_UNSUPPORTED,
          "triton backend API version does not support this backend");
    }
  }
  catch (TritonException& err) {
    return err.error();
  }
  return nullptr;  // success
}

TRITONSERVER_Error*
TRITONBACKEND_ModelInitialize(TRITONBACKEND_Model* model)
{
  try {
    std::string name = get_model_name(*model);

    uint64_t version = get_model_version(*model);

    log_info(
        __FILE__, __LINE__,
        (std::string("TRITONBACKEND_ModelInitialize: ") + name + " (version " +
         std::to_string(version) + ")")
            .c_str());

    set_model_state(*model, ModelState::Create(*model));
  }
  catch (TritonException& err) {
    return err.error();
  }

  return nullptr;  // success
}

TRITONSERVER_Error*
TRITONBACKEND_ModelFinalize(TRITONBACKEND_Model* model)
{
  try {
    auto model_state = get_model_state<ModelState>(*model);
    if (model_state != nullptr) {
      model_state->UnloadModel();
    }

    log_info(
        __FILE__, __LINE__, "TRITONBACKEND_ModelFinalize: delete model state");

    delete model_state;
  }
  catch (TritonException& err) {
    return err.error();
  }

  return nullptr;  // success
}

TRITONSERVER_Error*
TRITONBACKEND_ModelInstanceInitialize(TRITONBACKEND_ModelInstance* instance)
{
  try {
    std::string name = get_model_instance_name(*instance);
    int32_t device_id = get_device_id(*instance);
    TRITONSERVER_InstanceGroupKind kind = get_instance_kind(*instance);

    log_info(
        __FILE__, __LINE__,
        (std::string("TRITONBACKEND_ModelInstanceInitialize: ") + name + " (" +
         TRITONSERVER_InstanceGroupKindString(kind) + " device " +
         std::to_string(device_id) + ")")
            .c_str());

    ModelState* model_state = get_model_state<ModelState>(*instance);

    set_instance_state<ModelInstanceState>(
        *instance, ModelInstanceState::Create(model_state, instance));
  }
  catch (TritonException& err) {
    return err.error();
  }
  return nullptr;  // success
}

TRITONSERVER_Error*
TRITONBACKEND_ModelInstanceFinalize(TRITONBACKEND_ModelInstance* instance)
{
  try {
    void* vstate;
    triton_check(TRITONBACKEND_ModelInstanceState(instance, &vstate));
    ModelInstanceState* instance_state =
        reinterpret_cast<ModelInstanceState*>(vstate);

    if (instance_state != nullptr) {
      instance_state->UnloadFILModel();

      log_info(
          __FILE__, __LINE__,
          "TRITONBACKEND_ModelInstanceFinalize: delete instance state");

      delete instance_state;
    }
  }
  catch (TritonException& err) {
    return err.error();
  }

  return nullptr;  // success
}

TRITONSERVER_Error*
TRITONBACKEND_ModelInstanceExecute(
    TRITONBACKEND_ModelInstance* instance, TRITONBACKEND_Request** raw_requests,
    const uint32_t request_count)
{
  uint64_t all_start_time =
      std::chrono::steady_clock::now().time_since_epoch().count();
  std::size_t total_inference_count = 0;
  std::vector<TRITONBACKEND_Response*> responses;
  try {
    auto instance_state = get_instance_state<ModelInstanceState>(*instance);
    ModelState* model_state = instance_state->StateForModel();
    auto target_memory = get_native_memory_for_instance(instance_state->Kind());

    std::vector<TRITONBACKEND_Request*> requests(
        raw_requests, raw_requests + request_count);

    // One past index of last request that was successfully processed
    size_t end_request = 0;
    try {
      auto input_batches = get_input_batches<float>(
          static_cast<uint32_t>(0), requests, target_memory,
          instance_state->get_raft_handle());
      for (auto& batch : input_batches) {
        uint64_t batch_start_time =
            std::chrono::steady_clock::now().time_since_epoch().count();

        std::vector<std::vector<int64_t>> output_shapes;
        output_shapes.reserve(batch.shapes.size());
        for (auto& input_shape : batch.shapes) {
          total_inference_count += input_shape[0];
          std::vector<int64_t> output_shape{input_shape[0]};
          if (model_state->predict_proba) {
            output_shape.push_back(model_state->num_class());
          }
          output_shapes.push_back(std::move(output_shape));
        }


        // TODO: Adjust function interfaces to allow passing iterators instead
        std::vector<TRITONBACKEND_Request*> batch_requests(
            requests.begin() + batch.extent.first,
            requests.begin() + batch.extent.second);
        responses = construct_responses(batch_requests);
        try {
          auto output_batch = get_output_batch<float>(
              static_cast<uint32_t>(0), batch_requests, responses,
              target_memory, output_shapes, instance_state->get_raft_handle());

          uint64_t batch_compute_start_time =
              std::chrono::steady_clock::now().time_since_epoch().count();
          instance_state->predict(
              batch.data, output_batch, model_state->predict_proba);
          uint64_t batch_compute_end_time =
              std::chrono::steady_clock::now().time_since_epoch().count();

          output_batch.sync();
          send_responses(responses);
          responses.clear();
          end_request = batch.extent.second;

          try {
            report_statistics(
                *instance, batch_requests, true, batch_start_time,
                batch_compute_start_time, batch_compute_end_time,
                std::chrono::steady_clock::now().time_since_epoch().count());
          }
          catch (TritonException& stat_err) {
            log_error(__FILE__, __LINE__, stat_err.what());
          }

          release_requests(batch_requests);
        }
        catch (TritonException& request_err) {
          send_responses(responses, request_err.error());
          responses.clear();
          end_request = batch.extent.second;
          try {
            report_statistics(
                *instance, batch_requests, false, batch_start_time,
                batch_start_time,
                std::chrono::steady_clock::now().time_since_epoch().count(),
                std::chrono::steady_clock::now().time_since_epoch().count());
          }
          catch (TritonException& stat_err) {
            log_error(__FILE__, __LINE__, stat_err.what());
          }
          release_requests(batch_requests);
        }
      }
    }
    catch (TritonException& request_err) {
      // If any responses have already been constructed for this batch, send an
      // error response
      send_responses(responses, request_err.error());
      responses.clear();

      // Return errors for all unprocessed requests
      std::vector<TRITONBACKEND_Request*> requests(
          raw_requests + end_request, raw_requests + request_count);
      send_error_responses(requests, request_err.error());
      uint64_t all_end_time =
          std::chrono::steady_clock::now().time_since_epoch().count();
      try {
        report_statistics(
            *instance, requests, false, all_start_time, all_start_time,
            all_end_time, all_end_time);
      }
      catch (TritonException& stat_err) {
        log_error(__FILE__, __LINE__, stat_err.what());
      }
      release_requests(requests);
      return request_err.error();
    }

    uint64_t all_end_time =
        std::chrono::steady_clock::now().time_since_epoch().count();
    try {
      report_statistics(
          *instance, total_inference_count, all_start_time, all_start_time,
          all_end_time, all_end_time);
    }
    catch (TritonException& stat_err) {
      log_error(__FILE__, __LINE__, stat_err.what());
    }
  }
  catch (TritonException& err) {
    return err.error();
  }

  return nullptr;  // success
}

}  // extern "C"

}}}  // namespace triton::backend::fil
