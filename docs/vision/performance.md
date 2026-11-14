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
| Dashboard, bottom bar | Stereo load | Share of each second the pairs spent at the stereo device, from a pair's hand-over to the device's reply. Near 100 %, the stages are the bottleneck. See [Stereo load](#stereo-load). |
| Dashboard, Cameras and Pipelines menus | each step's time, each pipeline's total, the stereo cameras' and Pairing's latencies | Mean time of each step over the last second's pairs or frames, and their sum. Steps computed in one pass have no time of their own: they share one time, which the total counts. The latencies are waits, which the total leaves out. See [Step times](#step-times) and [Latencies](#latencies). |
| Log, `[pipeline]` line | each stage, `total`, `wall` | Every 30 pairs: each stage's time, a pair's latency (`total`) and the interval between pairs (`wall`), as median / 95th percentile / maximum in milliseconds. |
| Log, `[pairer]` line | `pair_delta` | The capture-time gap between a pair's left and right frames: how well the cameras are synchronised. The same line counts the pairs dropped while the pipeline was busy. |

The log goes to the unit's `RingLogger`; read it over SSH with `RingLogger.next`.

When the depth rate is well below the cameras' rate and Stereo load is near 100 %, the stages are the limit. When the depth rate follows the cameras' rate, the cameras are the limit. In a dark room, auto exposure lengthens each frame, and the frame rate drops with it.

## Stereo load

The `status` channel's `stereoLoadPercent` is the share of the last second the pairs spent at the stereo pipeline's device ([Status](./channels.md#status)). A pair's time runs from its hand-over to the device's reply. On a GPU, it includes the upload of the frames and the submission of the work. The download of the pair's outputs is left out: it runs during the next pair's device work.

A compiled segment takes one pair at a time. At 100 %, a pair takes a whole frame period, and the cameras' pairs that come faster are dropped. The dashboard warns from 97 %: at 30 frames a second, that leaves about one pair's time a second.

The stereo load is above the GPU's own busy share, by the upload and the submission of each pair. `mix vision_core.board_bench` gives the GPU's own time per pair ([Measuring a change on the board](#measuring-a-change-on-the-board)).

## Step times

The `status` channel's `pipelines` gives each pipeline's times, averaged over the last second ([Status](./channels.md#status)). They are the work one pair or frame takes: no time spent waiting is counted.

| Pipeline | Step | What its time covers |
|---|---|---|
| Stereo | a stage on the BEAM | Its `run` on the pair. |
| Stereo | the stages of a native segment | Each stage's time in `stereo_match`. The pipeline's total counts the segment once, with its transfer through the pipes. |
| Stereo | the stages of a compiled segment | One time for the whole run: from the pair's hand-over to the device's reply, plus the download of its outputs. The next pair's time leaves out the device work that ran beside that download, so each download counts once. |
| Detection, segmentation | `input` | Preparing the image and handing it to the backend. |
| Detection, segmentation | `inference` | From the image handed over to the backend's reply: the Port's read of the image, its resize, the model and the decoding. |
| Detection | `filtering`, `placement` | Keeping the detections to pass on, then placing and outlining them. |
| Segmentation | `classes` | Sorting the stereo points into road and off-road. |

A compiled segment runs its stages as one function on the device, so they cannot be timed apart ([Nx: the stages as tensor programs](./compute.md#nx-the-stages-as-tensor-programs)): its time counts in the pipeline's total, and no stage of it has one of its own. The Pipelines menu shows that time once for all its stages, with where they run. `npu.pipelines.<name>.inferenceMs` is the accelerator's share of the `inference` step ([Accelerator load](./detection.md#accelerator-load)).

A pipeline on a camera of its own waits for the stereo pair captured closest to its frame. That wait is in no step's time. The stereo total leaves out the time a pair waits for the device, and the decoding of its frames before a segment. A pair's latency, `total` in the log's `[pipeline]` line, counts them.

## Latencies

The stereo cameras' capture and the Pairing step do no work on a pair, so they have no step time. The `status` channel's `latencies.stereo` gives what they add to a pair's latency instead, averaged over the last second ([Status](./channels.md#status)). The stereo pipeline's total leaves them out: it stays the work one pair takes.

| Part | Latency | What it covers |
|---|---|---|
| Stereo cameras | `cameras` | From the capture time a frame's driver stamps (`Frame.capture_ns`) to the frame's arrival in the pairer, the mean over both cameras' frames: the readout, the driver and its hand-over to the unit. |
| Pairing | `pairing` | From the arrival of a pair's earlier frame to the pair going to the stereo pipeline, the mean over the pairs: the wait for the other camera's frame, and for the pipeline to finish the previous pair. |

A high `cameras` latency points at the camera or its driver. A `pairing` latency near a frame period means the cameras capture out of step ([Status](./channels.md#status), `sync`).

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

With `paths: 8`, the upload and the submission added about 4.3 ms to each pair's 26.7 ms on the GPU, which left almost no room in a frame period. On 20 of the unit's pairs, `paths: 3` matched the same share of pixels with the same jitter, and the nearest distance measured did not change.

| Figure | Measured |
|---|---|
| One stereo pair, `search: "coarse_to_fine"`, `paths: 8`, `coarse_paths: 3` | 28 ms |
| The GPU's busy time for one pair at 877 MHz, `paths: 8` (`gpu_ms`) | 26.7 ms, about 23 ms of it Disparity |
| The same with `paths: 3`, OVCS1's setting | 21.5 ms |
| Live, `paths: 8`: a pair's hand-over to the GPU's reply | 31.5 to 32 ms of the 33.37 ms frame period |
| Live, `paths: 8`: the GPU's busy share, the pairs dropped | 82 to 84 %, about 2 % |
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

`mix vision_core.board_bench` measures your vehicle's stereo stages on a vision board without its cameras. Run it in your vehicle's project on your workstation, with the board on your network. The OVCS1 reference vehicle is the example; use your vehicle's directory and composer:

```shell
cd vehicles/ovcs1
mix vision_core.board_bench --host 192.168.1.50 --key ~/.ssh/id_ed25519 --composer Ovcs1.Vision.Composer
```

The task:

1. compiles the composer's stereo stages, with their options and at its sizes, for the board;
2. copies them there with a textured pair of frames;
3. stops the live stereo unit;
4. prints how each output differs from EXLA's, the time of each pair in µs, and a `BENCH` line of medians.

The `BENCH` line gives, in milliseconds:

- `total_ms`, a pair's hand-over, wait and download;
- `dispatch_ms`, from its hand-over to the GPU's reply;
- `collect_ms`, the download of its outputs;
- `gpu_ms`, the GPU's busy time per pair, from the DRM driver's `drm-engine-gpu` counter, or `n/a` where the driver does not report it.

Options:

- `--paths`, `--coarse-paths`, `--search` and `--disparities` change the Disparity options.
- `--set stage.setting=value` changes any setting of a stage, by the names `GET /api/stages` lists: `--set disparity.p2=79`.
- `--drop speckle_filter,quality` leaves those stages out.
- `--hot` also loads your `nx_stereo` build on the board, so a shader change is measured without building a firmware. Reboot the board afterwards.
- `--compute native --search full` times the stages in `stereo_match` on the board's CPU instead.

Without `--composer`, in `vision/core`, the task times the default stages at 728 × 544, Disparity over 128 disparities, coarse to fine, along 8 paths.

Each stage's time on your workstation's GPU comes from `mix run bench/pipeline.exs` in `nx_stereo`.

## What to change

Each setting trades rate against something else. The matching dominates, and its cost grows with **width × height × disparities**.

| Setting | Where | Effect |
|---|---|---|
| Working size | `:width`, `:height`, or `:match_width`, `:match_height` on the `:stereo` component | The strongest lever: half the pixels, about half the matching time. Smaller images measure far points less precisely: the focal length in pixels shrinks with the width. Keep the sensor's aspect ratio, or the image is squeezed and the calibration no longer fits. On a GPU without 8-bit storage, such as the Arduino VENTUNO Q's, the width must be a multiple of 4. |
| `num_disparities` | Disparity, build | 128 measures nearer than 64 (the nearest distance is `f × B / num_disparities`) and costs about twice the matching time. |
| `paths` | Disparity, build | 3 is much faster than 8 on a CPU, and leaves more holes on dark or textureless surfaces. On the VENTUNO Q's GPU, coarse to fine at 728 × 544, 3 took 21.5 ms of GPU time a pair instead of 26.7. |
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
