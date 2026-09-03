// hailo_detect: runs a YOLO HEF on the Hailo-8 and returns bounding
// boxes, as a Port binary driven by `RosBridge.Inference.Hailo`.
//
// Why a Port and not a NIF: `InferVStreams::infer` blocks for
// milliseconds. That is a scheduler hazard in a NIF and a non-event
// in a separate OS process. It also buys crash isolation — a Hailo
// fault must never take the depth path down with it.
//
// The HEF is expected to carry its NMS in-graph (the model zoo
// `*_nms_postprocess` variants do), so this binary never decodes
// anchors or runs IoU suppression: it hands over pixels and reads
// back boxes.
//
// ## Wire protocol
//
// Request (stdin), tag 1 = DETECT:
//     u8  tag
//     u32 seq
//     u16 width
//     u16 height
//     u8  channels        (1 = grayscale, 3 = BGR as Evision hands it over)
//     u8  pixels[width * height * channels]
//
// Response (stdout), tag 1 = DETECTIONS:
//     u8  tag
//     u32 seq
//     u16 count
//     count x { u16 class_id; f32 score; f32 x0, y0, x1, y1 }
//
// Boxes come back in the **caller's** pixel coordinates, not the
// model's 640x640 — this binary owns the letterbox transform, so it
// is also the only place that can invert it. Everything is
// little-endian, matching the other records on this transport.
//
// Scalars are little-endian to match `camera_capture`; the 4-byte
// record length prefix is big-endian and handled by ovcs::framing.

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

// YOLO's conventional letterbox fill. Mid-grey keeps the padding
// from reading as a hard edge to the first conv layer.
constexpr uint8_t kPadValue = 114;

// Geometry of the letterbox that maps a caller frame into the
// model's square input, kept so we can invert it on the way out.
struct Letterbox {
  float scale;   // caller px -> model px
  int offset_x;  // left padding, in model px
  int offset_y;  // top padding, in model px
};

Letterbox letterbox_for(int src_w, int src_h, int dst) {
  const float scale =
      std::fmin(static_cast<float>(dst) / static_cast<float>(src_w),
                static_cast<float>(dst) / static_cast<float>(src_h));
  const int scaled_w = static_cast<int>(std::lround(src_w * scale));
  const int scaled_h = static_cast<int>(std::lround(src_h * scale));
  return Letterbox{scale, (dst - scaled_w) / 2, (dst - scaled_h) / 2};
}

// Bilinear resize straight into the centre of the model's NHWC RGB
// buffer. A 1-channel source is replicated across R/G/B; a
// 3-channel source is taken as BGR (what Evision hands over) and
// swapped to the RGB the model was trained on.
//
// Done by hand rather than via OpenCV: this is the only image
// operation the binary needs, and linking OpenCV into a Port that
// otherwise only talks to libhailort is a lot of firmware weight
// for one resize.
void letterbox_into(const uint8_t* src, int src_w, int src_h, int channels,
                    uint8_t* dst, int dst_size, const Letterbox& box) {
  std::memset(dst, kPadValue, static_cast<size_t>(dst_size) * dst_size * 3);

  const int scaled_w = static_cast<int>(std::lround(src_w * box.scale));
  const int scaled_h = static_cast<int>(std::lround(src_h * box.scale));

  for (int y = 0; y < scaled_h; ++y) {
    // Sample at pixel centres, so the mapping stays symmetric and
    // the image doesn't creep half a pixel up-left as it scales.
    const float sy = (static_cast<float>(y) + 0.5f) / box.scale - 0.5f;
    const int y0 = static_cast<int>(std::floor(sy));
    const float wy = sy - static_cast<float>(y0);
    const int y0c = std::min(std::max(y0, 0), src_h - 1);
    const int y1c = std::min(std::max(y0 + 1, 0), src_h - 1);

    for (int x = 0; x < scaled_w; ++x) {
      const float sx = (static_cast<float>(x) + 0.5f) / box.scale - 0.5f;
      const int x0 = static_cast<int>(std::floor(sx));
      const float wx = sx - static_cast<float>(x0);
      const int x0c = std::min(std::max(x0, 0), src_w - 1);
      const int x1c = std::min(std::max(x0 + 1, 0), src_w - 1);

      uint8_t* p = dst + ((static_cast<size_t>(box.offset_y + y) * dst_size +
                           (box.offset_x + x)) *
                          3);

      for (int c = 0; c < channels; ++c) {
        const auto at = [&](int yy, int xx) {
          return static_cast<float>(
              src[(static_cast<size_t>(yy) * src_w + xx) * channels + c]);
        };
        const float top = at(y0c, x0c) * (1.0f - wx) + at(y0c, x1c) * wx;
        const float bot = at(y1c, x0c) * (1.0f - wx) + at(y1c, x1c) * wx;
        const uint8_t v =
            static_cast<uint8_t>(std::lround(top * (1.0f - wy) + bot * wy));

        // channels == 1 fills all three; channels == 3 reverses BGR
        // into RGB as it goes.
        if (channels == 1) {
          p[0] = v;
          p[1] = v;
          p[2] = v;
        } else {
          p[2 - c] = v;
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

// Decode HAILO_FORMAT_ORDER_HAILO_NMS_BY_CLASS: for each class in
// turn, a float32 count followed by that many
// `hailo_bbox_float32_t`. The bbox field order is
// **y_min, x_min, y_max, x_max, score** — not the (x, y) order the
// name "bbox" suggests — and the values are normalised to the
// padded model input, so undoing the letterbox is part of decoding.
std::vector<Detection> decode_nms_by_class(const float* data, size_t floats,
                                           size_t num_classes,
                                           int src_w, int src_h,
                                           const Letterbox& box,
                                           int model_size,
                                           float score_threshold) {
  std::vector<Detection> out;
  size_t at = 0;

  for (size_t class_id = 0; class_id < num_classes; ++class_id) {
    if (at >= floats) break;
    const size_t count = static_cast<size_t>(data[at++]);
    if (count == 0) continue;
    if (at + count * 5 > floats) break;

    for (size_t i = 0; i < count; ++i) {
      const float* b = data + at + i * 5;
      const float score = b[4];
      if (score < score_threshold) continue;

      // Normalised padded coords -> padded pixels -> caller pixels.
      auto to_src_x = [&](float n) {
        return (n * static_cast<float>(model_size) -
                static_cast<float>(box.offset_x)) / box.scale;
      };
      auto to_src_y = [&](float n) {
        return (n * static_cast<float>(model_size) -
                static_cast<float>(box.offset_y)) / box.scale;
      };

      Detection d;
      d.class_id = static_cast<uint16_t>(class_id);
      d.score = score;
      d.x0 = to_src_x(b[1]);
      d.y0 = to_src_y(b[0]);
      d.x1 = to_src_x(b[3]);
      d.y1 = to_src_y(b[2]);

      // Clamp to the frame: a box may legitimately extend into the
      // padding when an object is cut off at the image edge.
      d.x0 = std::fmin(std::fmax(d.x0, 0.0f), static_cast<float>(src_w));
      d.x1 = std::fmin(std::fmax(d.x1, 0.0f), static_cast<float>(src_w));
      d.y0 = std::fmin(std::fmax(d.y0, 0.0f), static_cast<float>(src_h));
      d.y1 = std::fmin(std::fmax(d.y1, 0.0f), static_cast<float>(src_h));

      if (d.x1 > d.x0 && d.y1 > d.y0) out.push_back(d);
    }
    at += count * 5;
  }

  return out;
}

std::vector<uint8_t> build_detections_record(
    uint32_t seq, const std::vector<Detection>& detections) {
  std::vector<uint8_t> out;
  out.reserve(1 + 4 + 2 + detections.size() * 22);
  out.push_back(kTagDetections);

  auto append = [&](const void* p, size_t n) {
    const uint8_t* b = static_cast<const uint8_t*>(p);
    out.insert(out.end(), b, b + n);
  };

  append(&seq, sizeof(seq));
  const uint16_t count = static_cast<uint16_t>(detections.size());
  append(&count, sizeof(count));

  for (const Detection& d : detections) {
    append(&d.class_id, sizeof(d.class_id));
    append(&d.score, sizeof(d.score));
    append(&d.x0, sizeof(d.x0));
    append(&d.y0, sizeof(d.y0));
    append(&d.x1, sizeof(d.x1));
    append(&d.y1, sizeof(d.y1));
  }

  return out;
}

// Debug aid, enabled with HAILO_DEBUG_DUMP=<dir>: dump the exact
// buffer handed to the accelerator as a PPM, plus the head of the
// raw NMS output. Lets a wrong letterbox or a misread output layout
// be seen rather than inferred.
void dump_debug(const std::string& dir, const uint8_t* rgb, int size,
                const float* out, size_t floats) {
  const std::string ppm_path = dir + "/hailo_input.ppm";
  if (FILE* f = fopen(ppm_path.c_str(), "wb")) {
    fprintf(f, "P6\n%d %d\n255\n", size, size);
    fwrite(rgb, 1, static_cast<size_t>(size) * size * 3, f);
    fclose(f);
  }

  const std::string txt_path = dir + "/hailo_output.txt";
  if (FILE* f = fopen(txt_path.c_str(), "w")) {
    // One line per class that reported any box, so a non-empty
    // result is obvious even when every score is below threshold.
    size_t at = 0;
    for (size_t c = 0; c < 80 && at < floats; ++c) {
      const size_t count = static_cast<size_t>(out[at++]);
      if (count > 0 && at + count * 5 <= floats) {
        fprintf(f, "class %zu count %zu:", c, count);
        for (size_t i = 0; i < count && i < 4; ++i) {
          const float* b = out + at + i * 5;
          fprintf(f, "  [y0=%.3f x0=%.3f y1=%.3f x1=%.3f s=%.3f]", b[0], b[1],
                  b[2], b[3], b[4]);
        }
        fprintf(f, "\n");
      }
      if (count > 0) at += count * 5;
    }
    fclose(f);
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
  const int records = dup(STDOUT_FILENO);
  if (records < 0) {
    log("could not dup stdout");
    return 1;
  }
  dup2(STDERR_FILENO, STDOUT_FILENO);
  ovcs::framing::set_output_fd(records);

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

  const size_t num_classes =
      output_vstream.get_info().nms_shape.number_of_classes;
  const size_t output_bytes = output_vstream.get_frame_size();

  log("ready: " + hef_path + " " + std::to_string(model_size) + "x" +
      std::to_string(model_size) + ", " + std::to_string(num_classes) +
      " classes, threshold " + std::to_string(score_threshold));

  std::vector<uint8_t> model_input(static_cast<size_t>(model_size) *
                                   model_size * 3);
  std::vector<uint8_t> output_buffer(output_bytes);
  std::vector<uint8_t> request;

  while (ovcs::framing::read_record(request)) {
    // 1 tag + 4 seq + 2 width + 2 height + 1 channels
    if (request.size() < 10 || request[0] != kTagDetect) continue;

    uint32_t seq;
    uint16_t width, height;
    std::memcpy(&seq, request.data() + 1, sizeof(seq));
    std::memcpy(&width, request.data() + 5, sizeof(width));
    std::memcpy(&height, request.data() + 7, sizeof(height));
    const int channels = request[9];

    if (channels != 1 && channels != 3) {
      log("frame " + std::to_string(seq) + ": unsupported channel count " +
          std::to_string(channels));
      continue;
    }

    const size_t expected = static_cast<size_t>(width) * height * channels;
    if (request.size() != 10 + expected) {
      log("frame " + std::to_string(seq) + ": expected " +
          std::to_string(expected) + " pixel bytes, got " +
          std::to_string(request.size() - 10));
      continue;
    }

    const Letterbox box = letterbox_for(width, height, model_size);
    letterbox_into(request.data() + 10, width, height, channels,
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
      const auto empty = build_detections_record(seq, {});
      if (!ovcs::framing::write_record(empty.data(), empty.size())) break;
      continue;
    }

    if (const char* dir = getenv("HAILO_DEBUG_DUMP")) {
      dump_debug(dir, model_input.data(), model_size,
                 reinterpret_cast<const float*>(output_buffer.data()),
                 output_bytes / sizeof(float));
    }

    const auto detections = decode_nms_by_class(
        reinterpret_cast<const float*>(output_buffer.data()),
        output_bytes / sizeof(float), num_classes, width, height, box,
        model_size, score_threshold);

    const auto record = build_detections_record(seq, detections);
    if (!ovcs::framing::write_record(record.data(), record.size())) break;
  }

  return 0;
}
