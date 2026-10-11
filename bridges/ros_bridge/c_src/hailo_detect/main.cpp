// hailo_detect: the Port behind `RosBridge.Inference.Hailo`. The HEF carries its
// NMS in-graph, so this binary letterboxes pixels in and reads boxes back out.

// Request (stdin): u8 tag 1, u32 seq, u16 width, u16 height, u8 channels (1 gray, 3 BGR), pixels.
// Response (stdout): u8 tag 1, u32 seq, u16 count, count × {u16 class_id, f32 score, x0, y0, x1, y1}
// in the caller's pixel coordinates. Scalars are little-endian.

#include <arpa/inet.h>
#include <unistd.h>

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "framing.h"
#include "hailo/hailort.hpp"

namespace {

constexpr uint8_t kTagDetect = 1;
constexpr uint8_t kTagDetections = 1;
// tag, seq, width, height, channels
constexpr size_t kDetectHeaderBytes = 1 + 4 + 2 + 2 + 1;
// y_min, x_min, y_max, x_max, score
constexpr size_t kFloatsPerBox = 5;
// class_id, score, x0, y0, x1, y1
constexpr size_t kDetectionBytes = 2 + 5 * 4;

// YOLO's conventional letterbox fill. Mid-grey keeps the padding
// from reading as a hard edge to the first conv layer.
constexpr uint8_t kPadValue = 114;

// Geometry of the letterbox that maps a caller frame into the
// model's square input, kept to invert it on the way out.
struct Letterbox {
  float scale;   // caller px -> model px
  int offset_x;  // left padding, in model px
  int offset_y;  // top padding, in model px
};

Letterbox letterbox_for(int source_width, int source_height, int model_size) {
  const float scale =
      std::fmin(static_cast<float>(model_size) / static_cast<float>(source_width),
                static_cast<float>(model_size) / static_cast<float>(source_height));
  const int scaled_width = static_cast<int>(std::lround(source_width * scale));
  const int scaled_height = static_cast<int>(std::lround(source_height * scale));
  return Letterbox{scale, (model_size - scaled_width) / 2, (model_size - scaled_height) / 2};
}

// Bilinear letterbox into the model's NHWC RGB input (gray replicated, BGR
// swapped). Hand-written: linking OpenCV for one resize is a lot of firmware weight.
void letterbox_into(const uint8_t* source, int source_width, int source_height, int channels,
                    uint8_t* destination, int model_size, const Letterbox& box) {
  std::memset(destination, kPadValue, static_cast<size_t>(model_size) * model_size * 3);

  const int scaled_width = static_cast<int>(std::lround(source_width * box.scale));
  const int scaled_height = static_cast<int>(std::lround(source_height * box.scale));

  for (int y = 0; y < scaled_height; ++y) {
    // Sample at pixel centres, so the image doesn't creep half a pixel up-left.
    const float source_y = (static_cast<float>(y) + 0.5f) / box.scale - 0.5f;
    const int y0 = static_cast<int>(std::floor(source_y));
    const float y_weight = source_y - static_cast<float>(y0);
    const int top_row = std::min(std::max(y0, 0), source_height - 1);
    const int bottom_row = std::min(std::max(y0 + 1, 0), source_height - 1);

    for (int x = 0; x < scaled_width; ++x) {
      const float source_x = (static_cast<float>(x) + 0.5f) / box.scale - 0.5f;
      const int x0 = static_cast<int>(std::floor(source_x));
      const float x_weight = source_x - static_cast<float>(x0);
      const int left_column = std::min(std::max(x0, 0), source_width - 1);
      const int right_column = std::min(std::max(x0 + 1, 0), source_width - 1);

      uint8_t* destination_pixel =
          destination + ((static_cast<size_t>(box.offset_y + y) * model_size +
                          (box.offset_x + x)) *
                         3);

      for (int c = 0; c < channels; ++c) {
        const auto at = [&](int row, int column) {
          return static_cast<float>(
              source[(static_cast<size_t>(row) * source_width + column) * channels + c]);
        };
        const float top = at(top_row, left_column) * (1.0f - x_weight) +
                          at(top_row, right_column) * x_weight;
        const float bottom = at(bottom_row, left_column) * (1.0f - x_weight) +
                             at(bottom_row, right_column) * x_weight;
        const uint8_t sample =
            static_cast<uint8_t>(std::lround(top * (1.0f - y_weight) + bottom * y_weight));

        if (channels == 1) {
          destination_pixel[0] = sample;
          destination_pixel[1] = sample;
          destination_pixel[2] = sample;
        } else {
          destination_pixel[2 - c] = sample;
        }
      }
    }
  }
}

struct Detection {
  uint16_t class_id;
  float score;
  float x0, y0, x1, y1;
};

// HAILO_NMS_BY_CLASS: per class, a float count then that many bboxes ordered
// y_min, x_min, y_max, x_max, score, normalised to the padded model input.
std::vector<Detection> decode_nms_by_class(const float* nms_output, size_t float_count,
                                           size_t class_count,
                                           int source_width, int source_height,
                                           const Letterbox& box,
                                           int model_size,
                                           float score_threshold) {
  std::vector<Detection> detections;
  size_t offset = 0;

  for (size_t class_id = 0; class_id < class_count; ++class_id) {
    if (offset >= float_count) break;
    const size_t count = static_cast<size_t>(nms_output[offset++]);
    if (count == 0) continue;
    if (offset + count * kFloatsPerBox > float_count) break;

    for (size_t i = 0; i < count; ++i) {
      const float* bbox = nms_output + offset + i * kFloatsPerBox;
      const float score = bbox[4];
      if (score < score_threshold) continue;

      // Normalised padded coords -> padded pixels -> caller pixels.
      auto to_source_x = [&](float n) {
        return (n * static_cast<float>(model_size) -
                static_cast<float>(box.offset_x)) / box.scale;
      };
      auto to_source_y = [&](float n) {
        return (n * static_cast<float>(model_size) -
                static_cast<float>(box.offset_y)) / box.scale;
      };

      Detection detection;
      detection.class_id = static_cast<uint16_t>(class_id);
      detection.score = score;
      detection.x0 = to_source_x(bbox[1]);
      detection.y0 = to_source_y(bbox[0]);
      detection.x1 = to_source_x(bbox[3]);
      detection.y1 = to_source_y(bbox[2]);

      // Clamp to the frame: a box may legitimately extend into the
      // padding when an object is cut off at the image edge.
      detection.x0 = std::fmin(std::fmax(detection.x0, 0.0f), static_cast<float>(source_width));
      detection.x1 = std::fmin(std::fmax(detection.x1, 0.0f), static_cast<float>(source_width));
      detection.y0 = std::fmin(std::fmax(detection.y0, 0.0f), static_cast<float>(source_height));
      detection.y1 = std::fmin(std::fmax(detection.y1, 0.0f), static_cast<float>(source_height));

      if (detection.x1 > detection.x0 && detection.y1 > detection.y0) detections.push_back(detection);
    }
    offset += count * kFloatsPerBox;
  }

  return detections;
}

std::vector<uint8_t> build_detections_record(
    uint32_t sequence, const std::vector<Detection>& detections) {
  std::vector<uint8_t> out;
  out.reserve(1 + 4 + 2 + detections.size() * kDetectionBytes);
  out.push_back(kTagDetections);

  auto append = [&](const void* p, size_t n) {
    const uint8_t* b = static_cast<const uint8_t*>(p);
    out.insert(out.end(), b, b + n);
  };

  append(&sequence, sizeof(sequence));
  const uint16_t count = static_cast<uint16_t>(detections.size());
  append(&count, sizeof(count));

  for (const Detection& detection : detections) {
    append(&detection.class_id, sizeof(detection.class_id));
    append(&detection.score, sizeof(detection.score));
    append(&detection.x0, sizeof(detection.x0));
    append(&detection.y0, sizeof(detection.y0));
    append(&detection.x1, sizeof(detection.x1));
    append(&detection.y1, sizeof(detection.y1));
  }

  return out;
}

// HAILO_DEBUG_DUMP=<dir>: the model input as a PPM and the head of the raw NMS
// output, to see a wrong letterbox or a misread output layout.
void dump_debug(const std::string& dir, const uint8_t* rgb, int size,
                const float* nms_output, size_t float_count, size_t class_count) {
  const std::string ppm_path = dir + "/hailo_input.ppm";
  if (FILE* ppm_file = fopen(ppm_path.c_str(), "wb")) {
    fprintf(ppm_file, "P6\n%d %d\n255\n", size, size);
    fwrite(rgb, 1, static_cast<size_t>(size) * size * 3, ppm_file);
    fclose(ppm_file);
  }

  const std::string text_path = dir + "/hailo_output.txt";
  if (FILE* text_file = fopen(text_path.c_str(), "w")) {
    // One line per class that reported any box, so a non-empty
    // result is obvious even when every score is below threshold.
    size_t offset = 0;
    for (size_t class_id = 0; class_id < class_count && offset < float_count; ++class_id) {
      const size_t count = static_cast<size_t>(nms_output[offset++]);
      if (count > 0 && offset + count * kFloatsPerBox <= float_count) {
        fprintf(text_file, "class %zu count %zu:", class_id, count);
        for (size_t i = 0; i < count && i < 4; ++i) {
          const float* bbox = nms_output + offset + i * kFloatsPerBox;
          fprintf(text_file, "  [y0=%.3f x0=%.3f y1=%.3f x1=%.3f s=%.3f]", bbox[0], bbox[1],
                  bbox[2], bbox[3], bbox[4]);
        }
        fprintf(text_file, "\n");
      }
      if (count > 0) offset += count * kFloatsPerBox;
    }
    fclose(text_file);
  }
}

void log(const std::string& message) {
  fprintf(stderr, "[hailo_detect] %s\n", message.c_str());
  fflush(stderr);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    log("usage: hailo_detect <model.hef> [score_threshold]");
    return 2;
  }
  const std::string hef_path = argv[1];
  const float score_threshold = (argc > 2) ? std::stof(argv[2]) : 0.4f;

  // Take stdout away from libhailort before it can log a byte onto
  // it — see `framing::set_output_fd`.
  const int records_fd = dup(STDOUT_FILENO);
  if (records_fd < 0) {
    log("could not dup stdout");
    return 1;
  }
  dup2(STDERR_FILENO, STDOUT_FILENO);
  ovcs::framing::set_output_fd(records_fd);

  using namespace hailort;

  auto vdevice = VDevice::create();
  if (!vdevice) {
    log("VDevice::create failed: " + std::to_string(vdevice.status()));
    return 1;
  }

  auto hef = Hef::create(hef_path);
  if (!hef) {
    log("Hef::create(" + hef_path +
        ") failed: " + std::to_string(hef.status()));
    return 1;
  }

  auto configure_params =
      vdevice.value()->create_configure_params(hef.value());
  if (!configure_params) {
    log("create_configure_params failed");
    return 1;
  }

  auto network_groups =
      vdevice.value()->configure(hef.value(), configure_params.value());
  if (!network_groups || network_groups->empty()) {
    log("configure failed");
    return 1;
  }
  auto network_group = network_groups.value()[0];

  // Quantised UINT8 in (the model's native input format, so HailoRT
  // does no conversion), dequantised FLOAT32 out (the NMS layer
  // emits scores and normalised coordinates).
  auto input_params = network_group->make_input_vstream_params(
      true, HAILO_FORMAT_TYPE_UINT8, HAILO_DEFAULT_VSTREAM_TIMEOUT_MS,
      HAILO_DEFAULT_VSTREAM_QUEUE_SIZE);
  auto output_params = network_group->make_output_vstream_params(
      false, HAILO_FORMAT_TYPE_FLOAT32, HAILO_DEFAULT_VSTREAM_TIMEOUT_MS,
      HAILO_DEFAULT_VSTREAM_QUEUE_SIZE);
  if (!input_params || !output_params) {
    log("make_vstream_params failed");
    return 1;
  }

  auto pipeline = InferVStreams::create(*network_group, input_params.value(),
                                        output_params.value());
  if (!pipeline) {
    log("InferVStreams::create failed: " + std::to_string(pipeline.status()));
    return 1;
  }

  auto& input_vstream = pipeline->get_input_vstreams()[0].get();
  auto& output_vstream = pipeline->get_output_vstreams()[0].get();

  const auto input_shape = input_vstream.get_info().shape;
  const int model_size = static_cast<int>(input_shape.width);
  if (static_cast<int>(input_shape.height) != model_size ||
      input_shape.features != 3) {
    log("expected a square 3-channel input, got " +
        std::to_string(input_shape.width) + "x" +
        std::to_string(input_shape.height) + "x" +
        std::to_string(input_shape.features));
    return 1;
  }

  const size_t class_count =
      output_vstream.get_info().nms_shape.number_of_classes;
  const size_t output_bytes = output_vstream.get_frame_size();

  log("ready: " + hef_path + " " + std::to_string(model_size) + "x" +
      std::to_string(model_size) + ", " + std::to_string(class_count) +
      " classes, threshold " + std::to_string(score_threshold));

  std::vector<uint8_t> model_input(static_cast<size_t>(model_size) *
                                   model_size * 3);
  std::vector<uint8_t> output_buffer(output_bytes);
  std::vector<uint8_t> request;

  while (ovcs::framing::read_record(request)) {
    if (request.size() < kDetectHeaderBytes || request[0] != kTagDetect) continue;

    uint32_t sequence;
    uint16_t width, height;
    std::memcpy(&sequence, request.data() + 1, sizeof(sequence));
    std::memcpy(&width, request.data() + 5, sizeof(width));
    std::memcpy(&height, request.data() + 7, sizeof(height));
    const int channels = request[9];

    if (channels != 1 && channels != 3) {
      log("frame " + std::to_string(sequence) + ": unsupported channel count " +
          std::to_string(channels));
      continue;
    }

    const size_t expected_bytes = static_cast<size_t>(width) * height * channels;
    if (request.size() != kDetectHeaderBytes + expected_bytes) {
      log("frame " + std::to_string(sequence) + ": expected " +
          std::to_string(expected_bytes) + " pixel bytes, got " +
          std::to_string(request.size() - kDetectHeaderBytes));
      continue;
    }

    const Letterbox box = letterbox_for(width, height, model_size);
    letterbox_into(request.data() + kDetectHeaderBytes, width, height, channels,
                   model_input.data(), model_size, box);

    std::map<std::string, MemoryView> input_map;
    input_map.emplace(
        input_vstream.name(),
        MemoryView(model_input.data(), model_input.size()));

    std::map<std::string, MemoryView> output_map;
    output_map.emplace(
        output_vstream.name(),
        MemoryView(output_buffer.data(), output_buffer.size()));

    const auto status = pipeline->infer(input_map, output_map, 1);
    if (status != HAILO_SUCCESS) {
      log("infer failed: " + std::to_string(status));
      // Answer anyway: the Elixir side keeps per-seq state and would
      // otherwise hold that frame's depth Mat until it ages out.
      const auto empty = build_detections_record(sequence, {});
      if (!ovcs::framing::write_record(empty.data(), empty.size())) break;
      continue;
    }

    if (const char* dir = getenv("HAILO_DEBUG_DUMP")) {
      dump_debug(dir, model_input.data(), model_size,
                 reinterpret_cast<const float*>(output_buffer.data()),
                 output_bytes / sizeof(float), class_count);
    }

    const auto detections = decode_nms_by_class(
        reinterpret_cast<const float*>(output_buffer.data()),
        output_bytes / sizeof(float), class_count, width, height, box,
        model_size, score_threshold);

    const auto record = build_detections_record(sequence, detections);
    if (!ovcs::framing::write_record(record.data(), record.size())) break;
  }

  return 0;
}
