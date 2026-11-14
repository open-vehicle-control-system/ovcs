---
title: Vision performance
description: How fast the vision unit computes depth, where the time goes, how to read the figures it reports, and the settings that trade rate against range and quality.
---

The figure that matters is the **depth rate**: how many depth images the unit computes a second. It cannot exceed the cameras' frame rate, since each depth image needs a new pair. How the stages run is in [Where depth is computed](./compute.md).

## Reading the figures

| Where | Figure | Meaning |
|---|---|---|
| Dashboard, depth caption | depth rate | Depth images computed in the last second. |
| Dashboard, camera captions | fps | Frames each camera delivered in the last second. |
| Dashboard, top bar | CPU, Memory | Busy share of all processor cores over half a second at each read, and the share of the memory in use. The 1, 5 and 15 minute load averages are behind the bar's details button. |
| Dashboard, bottom bar | Stereo load | Share of each second spent computing the stereo stages, on the GPU or on the CPU cores. Near 100 %, the stages are the bottleneck. |
| Log, `[pipeline]` line | each stage, `total`, `wall` | Every 30 pairs: each stage's time, a pair's latency (`total`) and the interval between pairs (`wall`), as median / 95th percentile / maximum in milliseconds. |
| Log, `[pairer]` line | `pair_delta` | The capture-time gap between a pair's left and right frames: how well the cameras are synchronised. The same line counts the pairs dropped while the pipeline was busy. |

The log goes to the unit's `RingLogger`; read it over SSH with `RingLogger.next`.

When the depth rate is well below the cameras' rate and Stereo load is near 100 %, the stages are the limit. When the depth rate follows the cameras' rate, the cameras are the limit. In a dark room, auto exposure lengthens each frame, and the frame rate drops with it.

## Measured on a Raspberry Pi 5

Two HQ Cameras (IMX477) with 8 mm lenses 8 cm apart, a Hailo-8 running detection, 64 disparities over 3 paths:

| Configuration | Working size | Depth rate |
|---|---|---|
| Nx compiled by `nx_iree` for the CPU | 480 × 360 | 0.017 Hz |
| Native matching, the other stages in Nx | 480 × 360 | 4.4 Hz |
| All stages native, one pair at a time | 480 × 360 | 8.9 Hz |
| All stages native, two pairs in flight | 480 × 360 | 16 Hz |
| All stages native, two pairs in flight | 480 × 270 | 20 to 21 Hz |

At 480 × 270 the cameras delivered 30 frames a second, CPU stood at 88 to 90 % and about 65 % of the pixels were matched. For comparison, the OKdo Nano C100 computed about 28 depth images a second on its GPU.

### Where the time goes

For this measurement, a 3 × 3 MedianFilter runs after Disparity; the default stages leave it out. Median time of each stage in `stereo_match`, at 480 × 270:

| Stage | Time |
|---|---|
| Disparity | 30.5 ms |
| Rectification | 5.6 ms |
| SpeckleFilter | 3.3 ms |
| MedianFilter (3) | 1.7 ms |
| Depth | 1.7 ms |
| TemporalFilter | 1.6 ms |
| Quality | 1.2 ms |
| RowAlignment, Sharpness, PointCloud | under 0.5 ms each |
| **The whole segment** | **48 ms** |

On an idle board the same work takes about a third of that. While the unit runs, the cameras' image signal processor, the BEAM and the other Ports share the cores and the memory bandwidth ([Memory and the processor](./compute.md#memory-and-the-processor)).

How the four cores were shared at 480 × 360, with the dashboard open:

| Process | Cores used |
|---|---|
| `stereo_match` | 1.4 to 1.5 |
| the BEAM | about 1.0 |
| `camera_capture`, both cameras | about 0.7 |
| `jpeg_codec`, previews and raw images | about 0.3 |

## Measured on an Arduino VENTUNO Q

The unit is the OVCS1 reference vehicle's, at 30 frames a second: two Global Shutter Cameras (IMX296) 20 cm apart. It matches at 728 × 544 over 128 disparities on the Adreno 623. Its Raspberry Pi HQ Camera (IMX477), `:center`, runs in the 2028 × 1520 sensor mode, with four outputs:

- `full`, the full image, kept on the unit (`send: false`);
- `full_h264`, that image as H.264 at 8000 kbps, on the Iris video encoder;
- `half`, that image averaged 2 × 2, for the models;
- `half_jpeg`, the half image as a JPEG.

YOLOX detection (`:objects`) and FFNet-122NS-LowRes road segmentation (`:scene`) run on every frame of `half`, on the Hexagon NPU at the `burst` performance profile, with `rpc_polling_us: 9999`. These are measurements on one unit, not guarantees.

| Figure | Measured |
|---|---|
| One stereo pair, `search: "coarse_to_fine"`, `paths: 8`, `coarse_paths: 3` (OVCS1's setting) | 28 ms |
| Stereo cameras, depth, `:objects`, `:scene` | 30 a second each |
| `:center`'s outputs, over 6 minutes | 30 a second |
| Gap between the left and right frames' starts | within 0.7 ms, median 0.09 ms |
| `:center`'s conversion, the 2 × 2 average and the NV12 for H.264 taken in it, 3 threads | 21.1 to 21.5 ms a frame |
| `:center`'s H.264 encode, 2028 × 1520, from the frame queued to the encoder to its stream dequeued | 5.3 ms a frame |
| `:center`'s H.264 stream at 30 frames a second, a key frame every 30 frames | 8.0 Mbit/s, key frames about 86 KB |
| `:center`'s JPEG encode, 1014 × 760 at quality 80, its own thread | 5 to 6 ms a frame |
| `:center`'s write to the Port, `full_h264`, `half` and `half_jpeg` | 8 to 10 ms a frame |
| `v4l2_capture` for `:center`, all its threads, on the four Cortex-A78 | about 1.9 cores |
| YOLOX on the NPU (`npu.pipelines.objects.inferenceMs`) | 2.1 ms |
| FFNet-122NS-LowRes on the NPU | 5.6 ms |
| The NPU's load, both models on every frame (`npu.loadPercent`) | about 23% |
| One detection request in `qnn_detect`: read, letterbox on 3 threads, `graphExecute` | about 1.4, 4.6 and 4.3 ms |
| One band in `qnn_segment`: read, resize on 3 threads, `graphExecute`, argmax | about 1.1, 5.4, 7.0 and 1.1 ms |
| CPU, all cores, no dashboard open | about 55% |

The QNN Ports' performance profile makes the largest difference. With no power vote and the context binaries built at QNN's default optimisation level, YOLOX took 8.7 ms on the NPU and FFNet 26.9 ms. That is too much for both models on every frame at 30 Hz. Qualcomm AI Hub's figures for the same models on this board, 2.3 and 6.0 ms, are close to the `burst` ones.

On the `:center` camera, sending its 9.2 MB full image to the core at every frame took the writer 24 ms a frame. It slowed the conversion to 34.5 ms, past the 33.3 ms of a frame, and the camera fell to about 27 frames a second.

Before `v4l2_capture` kept a camera's threads off the Cortex-A55 cores, the kernel placed some of each frame's conversion bands on them. With the H.264 output, `:center` held 30 frames a second for 20 to 60 s, then its bands ran on the A55s 40 to 55% of the time instead of about 5%. Its conversion took 33 to 37 ms, and the camera settled at 25 to 28 frames a second, using 2.3 to 2.4 cores.

Averaging the half-size image in a second pass after the conversion cost 4.9 ms more than taking it during the conversion. Above 3 conversion threads, the conversion slows down on this unit.

`jpeg_codec` in the core took 43 to 91 ms to encode a 2028 × 1520 frame with libjpeg-turbo. That includes the frame's 9.2 MB through the Port. The pure-Rust encoder it replaced took 85 to 184 ms, measured the same way. Encoded by `v4l2_capture`, the frame takes 18.2 ms.

### Measuring a change on the board

`mix vision_core.board_bench` measures the default stages on a vision board without its cameras. Run it in `vision/core` on your workstation, with the board on your network:

```shell
mix vision_core.board_bench --host 192.168.1.50 --key ~/.ssh/id_ed25519 --search coarse_to_fine --paths 8 --coarse-paths 3
```

The task:

1. compiles the stages for the board;
2. copies them there with a textured pair of frames;
3. stops the live stereo unit;
4. prints how each output differs from EXLA's, and the time of each pair.

Options:

- `--hot` also loads your `nx_stereo` build on the board, so a shader change is measured without building a firmware. Reboot the board afterwards.
- `--compute native --search full` times the stages in `stereo_match` on the board's CPU instead.

Each stage's time on your workstation's GPU comes from `mix run bench/pipeline.exs` in `nx_stereo`.

## What to change

Each setting trades rate against something else. The matching dominates, and its cost grows with **width × height × disparities**.

| Setting | Where | Effect |
|---|---|---|
| Working size | `:width`, `:height`, or `:match_width`, `:match_height` on the `:stereo` component | The strongest lever: half the pixels, about half the matching time. Smaller images measure far points less precisely: the focal length in pixels shrinks with the width. Keep the sensor's aspect ratio, or the image is squeezed and the calibration no longer fits. On a GPU without 8-bit storage, such as the Arduino VENTUNO Q's, the width must be a multiple of 4. |
| `num_disparities` | Disparity, build | 128 measures nearer than 64 (the nearest distance is `f × B / num_disparities`) and costs about twice the matching time. |
| `paths` | Disparity, build | 3 is much faster than 8 on a CPU, and leaves more holes on dark or textureless surfaces. |
| `coarse_paths` | Disparity, build | With `search: "coarse_to_fine"`, the half-size match's paths, `paths` by default. It only places each pixel's band, so 3 costs little: on the 2006 Middlebury pairs about one point more of pixels off by over a pixel. |
| `search: "coarse_to_fine"` | Disparity, build | Matches the pair shrunk 2x over 64 disparities, then each pixel within 16 disparities of that match at full size. That is a fraction of the full search's cost at the same range and size. It needs 128 disparities and an even working size, and runs on a GPU or Nx, not natively. On the 2006 Middlebury pairs at half size it agreed with the full search within a pixel on 96 to 99.8% of the pixels both matched. A structure too thin for the half-size pair, such as a cable, can take the background's disparity. |
| `format: :grey` | each camera | Avoids encoding every frame to JPEG and decoding it again. Always use it on the Pi 5. |
| `:stereo_match_threads` | `config :vision_core` | One per core by default, which measured fastest; fewer threads leave room for other work at a lower rate. |
| `:raw_image_max_hz`, the preview's `:max_hz` | the ROS 2 exporter's `stereo:` options, `VisionCore.Config` | Fewer JPEG encodes for the raw image topics and the dashboard previews. |
| `jpeg: [ports: n]` | `VisionCore.Config` | How many JPEG encodes for the previews and the exporters run at once, 3 by default. More keep a slow encode from holding the others back, each taking a core while it encodes. |
| A camera's `outputs:` | the `:camera` component | Each output costs its conversion or average and its write to the Port at every frame. Give the models an output at their scale (`from:` an average), and the previews and ROS 2 a `format: :jpeg` output. Keep a large image that no consumer takes off the Port with `send: false`. |
| `performance:` | each QNN backend | `burst`, the default, holds the NPU at its highest voltage corner: the models' fastest times, at more power and heat. `sustained_high_performance` and `balanced` trade time for both. |
| `rpc_polling_us:` | each QNN backend | 0, the default, lets each Port's thread sleep until the NPU signals the end of an inference, up to about a millisecond late. Up to 9999 µs of polling wakes it sooner, but keeps a core busy for each Port through each inference. Keep 0 when the CPU limits the frame rate. |
| Camera frame rate | `:fps` | Pairs the stages cannot take are dropped. On the Pi 5, 24 frames a second instead of 30 did not raise the depth rate. |

The kind of each stage setting, live or build, is in [Stereo stages](./stages.md). Change one thing at a time, then compare the depth rate and the `[pipeline]` line over at least a minute. On a busy board, single readings vary by about 15 %.

### Heat

The measurements above ran at 55 to 60 °C. The Raspberry Pi 5 lowers its clock from about 80 °C, which lowers the depth rate. Give a vision unit that runs continuously a cooler. `File.read!("/sys/class/thermal/thermal_zone0/temp")` on the unit gives the temperature in thousandths of a degree.

## See also

- [Where depth is computed](./compute.md)
- [Stereo stages](./stages.md)
- [How a pair flows](./data_flow.md)
