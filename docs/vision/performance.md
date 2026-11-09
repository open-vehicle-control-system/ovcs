---
title: Vision performance
description: How fast the vision unit computes depth, where the time goes, how to read the figures it reports, and the settings that trade rate against range and quality.
---

The figure that matters is the **depth rate**: how many depth images the unit computes a second. It cannot exceed the cameras' frame rate, since each depth image needs a new pair. This guide gives measured rates, where the time goes, and what to change. How the stages run is in [Where depth is computed](./compute.md).

## Reading the figures

| Where | Figure | Meaning |
|---|---|---|
| Dashboard, depth caption | depth rate | Depth images computed in the last second. |
| Dashboard, camera captions | fps | Frames each camera delivered in the last second. |
| Dashboard, bottom bar | CPU | Busy share of all processor cores. |
| Dashboard, bottom bar | Stereo load | Share of each second spent computing the stereo stages, on the GPU or on the CPU cores. Near 100 %, the stages are the bottleneck. |
| Log, `[pipeline]` line | each stage, `total`, `wall` | Every 30 pairs: each stage's time, a pair's latency (`total`) and the interval between pairs (`wall`), as median / 95th percentile / maximum in milliseconds. |
| Log, `[pairer]` line | `pair_delta` | The capture-time gap between a pair's left and right frames: how well the cameras are synchronised. The same line counts the pairs dropped while the pipeline was busy. |

The log goes to the unit's `RingLogger`; read it over SSH with `RingLogger.next`.

When the depth rate is well below the cameras' rate and Stereo load is near 100 %, the stages are the limit. When the depth rate follows the cameras' rate, the cameras are: in a dark room, auto exposure lengthens each frame, and the frame rate drops with it.

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

Median time of each stage in `stereo_match`, at 480 × 270, with a 3 × 3 MedianFilter added after Disparity, which the default stages leave out:

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

On an idle board the same work takes about a third of that: while the unit runs, the cameras' image signal processor, the BEAM and the other Ports share the cores and the memory bandwidth ([Memory and the processor](./compute.md#memory-and-the-processor)).

How the four cores were shared at 480 × 360, with the dashboard open:

| Process | Cores used |
|---|---|
| `stereo_match` | 1.4 to 1.5 |
| the BEAM | about 1.0 |
| `camera_capture`, both cameras | about 0.7 |
| `jpeg_codec`, previews and raw images | about 0.3 |

## Measured on an Arduino VENTUNO Q

The OVCS1 reference vehicle's unit: two Global Shutter Cameras (IMX296) 20 cm apart, matched at 728 × 544 over 128 disparities on the Adreno 623, with YOLOX detecting on the NPU. These are measurements on one unit, not guarantees.

| Figure | Measured |
|---|---|
| One pair, `search: "coarse_to_fine"`, `paths: 8`, `coarse_paths: 3` | 39 ms: depth at 25 Hz |
| One pair, `search: "coarse_to_fine"`, `paths: 3` | 32 ms: depth at the cameras' 30 Hz |
| Each camera | 29.97 frames a second |
| Gap between the left and right frames' starts | within 0.7 ms, median 0.09 ms |
| One detection request, letterbox included | 17 to 22 ms, on nearly every pair at 30 Hz |
| Generating the context binary, first boot only | about 2.4 s |

## What to change

Each setting trades rate against something else. The matching dominates, and its cost grows with **width × height × disparities**.

| Setting | Where | Effect |
|---|---|---|
| Working size | `:width`, `:height`, or `:match_width`, `:match_height` on the `:stereo` component | The strongest lever: half the pixels, about half the matching time. Smaller images measure far points less precisely: the focal length in pixels shrinks with the width. Keep the sensor's aspect ratio, or the image is squeezed and the calibration no longer fits. On a GPU without 8-bit storage, such as the Arduino VENTUNO Q's, the width must be a multiple of 4. |
| `num_disparities` | Disparity, build | 128 measures nearer than 64 (the nearest distance is `f × B / num_disparities`) and costs about twice the matching time. |
| `paths` | Disparity, build | 3 is much faster than 8 on a CPU, and leaves more holes on dark or textureless surfaces. |
| `coarse_paths` | Disparity, build | With `search: "coarse_to_fine"`, the half-size match's paths, `paths` by default. It only places each pixel's band, so 3 costs little: on the 2006 Middlebury pairs about one point more of pixels off by over a pixel. |
| `search: "coarse_to_fine"` | Disparity, build | Matches the pair shrunk 2x over 64 disparities, then each pixel within 16 disparities of that match at full size: a fraction of the full search's cost at the same range and size. It needs 128 disparities and an even working size, and runs on a GPU or Nx, not natively. On the 2006 Middlebury pairs at half size it agreed with the full search within a pixel on 96 to 99.8% of the pixels both matched; a structure too thin for the half-size pair, such as a cable, can take the background's disparity. |
| `format: :grey` | each camera | Avoids encoding every frame to JPEG and decoding it again. Always use it on the Pi 5. |
| `:stereo_match_threads` | `config :vision_core` | One per core by default, which measured fastest; fewer threads leave room for other work at a lower rate. |
| `:raw_image_max_hz`, the preview's `:max_hz` | the ROS 2 exporter's `stereo:` options, `VisionCore.Config` | Fewer JPEG encodes for the raw image topics and the dashboard previews. |
| Camera frame rate | `:fps` | Pairs the stages cannot take are dropped. On the Pi 5, 24 frames a second instead of 30 did not raise the depth rate. |

The kind of each stage setting, live or build, is in [Stereo stages](./stages.md). Change one thing at a time, then compare the depth rate and the `[pipeline]` line over at least a minute: on a busy board, single readings vary by about 15 %.

### Heat

The measurements above ran at 55 to 60 °C. The Raspberry Pi 5 lowers its clock from about 80 °C, which lowers the depth rate: give a vision unit that runs continuously a cooler. `File.read!("/sys/class/thermal/thermal_zone0/temp")` on the unit gives the temperature in thousandths of a degree.

## See also

- [Where depth is computed](./compute.md)
- [Stereo stages](./stages.md)
- [How a pair flows](./data_flow.md)
