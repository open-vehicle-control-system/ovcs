---
id: TASK-94
title: Capture a camera of its own at full resolution and 30 fps
status: In Progress
assignee: []
created_date: '2026-11-11 23:00'
labels:
  - vision
dependencies:
  - TASK-90
ordinal: 73000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`v4l2_capture`'s single mode converts each frame on one core. On the OVCS1 reference vehicle's VENTUNO Q, with the IMX477's 2028 × 1520 mode asked at 35 fps:

| Output | Delivered | Conversion per frame |
|---|---|---|
| `half`, 1014 × 760, denoise on | 34.9 fps | 17.1 ms |
| `full`, 2028 × 1520, denoise on | 16.6 fps | about 60 ms |
| `full`, denoise off | 21.3 fps | about 47 ms |

At 15 fps, before the denoise, `full` took 29.0 ms per frame. The OVCS1 HQ camera therefore runs `half` at 35 fps, which is all its detection and road segmentation use.

Full resolution at the camera's rate needs the conversion spread over several of the A78 cores (a 35 fps frame lasts 28.6 ms) and about 320 MB/s of RGB crossing the Port, which is not measured. Options to weigh in the design: splitting the frame into row bands converted by threads, with the demosaic and denoise rows overlapping at the bands' edges; sending the models' input at `half` and full resolution only as JPEG for viewing and recording; sharing the frames through memory rather than the Port.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A camera of its own delivers `full` 2028 × 1520 colour frames at 30 fps on the VENTUNO Q, denoise on
- [x] #2 The stereo pair's rate and the detection's rate are unchanged while it runs
- [x] #3 The per-frame conversion time and the CPU it uses are recorded in `docs/vision/performance.md`
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Chosen: spread the single mode's conversion over several cores, measure on the unit, and only then decide whether the Port's bandwidth needs work (JPEG for viewing, shared memory).

#### Task 1: convert a frame in row bands on several threads.
- `v4l2_capture` single mode: the colour path (`colour.rs` `develop_tuned` and the fallback) converts a frame as N horizontal bands on N threads (`std::thread::scope`, no new dependency), each band reading the rows it needs around it (the bilinear demosaic's ±1 row, the chroma denoise's ±2 cell rows) and writing its own output rows; the output is identical to the single-threaded one, byte for byte, for every output mode and rotation.
- The statistics (white balance means, the auto-exposure green) are summed across bands, identical to today's.
- A setting `threads` (default: 3 for `full`, 1 for `half`; 1 keeps today's path), validated `1..=8`; `VisionCore.Camera.V4L2Single` passes it.
- Buffers stay reused across frames: one set per band.
- Tests: byte-identical output for 1, 2, 3 and 4 threads, `full` and `half`, rotated and not, denoise on and off, odd band splits (heights not divisible by the thread count); identical statistics; the host's time per frame for 1 and 3 threads recorded in the report.
- On the unit (when it is powered): `full` at 35 fps asked with 3 threads, delivered rate, conversion time per frame, the stereo pair's and detection's rates alongside; the result recorded in the task's notes. If the rate still falls short with the conversion under 28 ms, the Port's bandwidth is the limit and the next task weighs JPEG for viewing or shared memory.

#### Task 2: write a frame while the next one converts.
Measured on the unit after Task 1, `full` at 35 fps asked, denoise on, nothing else changed:

| Threads | Delivered | Conversion | Write to the Port |
|---|---|---|---|
| 3 | 25.0 fps | 26.5 ms | 12.4 ms |
| 4 | 26.6 fps | 25.0 ms | 12.8 ms |
| 6 | 22.7 fps | 32.3 ms | 10.7 ms |

The conversion fits a frame's 28.6 ms; the loop converts then writes, 39 ms in all. Also, while frames keep arriving the single mode's inner dequeue loop never returns to `poll`, so neither the settings on stdin nor the minute's statistics are served.

Options: write on a thread of its own while the next frame converts (no change to the Port's records); share frames through memory; send `full` only as JPEG. Chosen: the writer thread, the smallest change that removes the serial write; the others stay open if the unit still falls short.

- Single mode: a writer thread sends each converted frame's record while the main thread converts the next, two output buffers alternating so that a frame being written is never overwritten; no extra copy of a frame. When the writer is still busy with the previous frame, the main thread waits for it (no frame dropped silently past the V4L2 queue). Records other than frames (exposure, logs) keep their order relative to the frames they follow as far as the Elixir side depends on it (check `VisionCore.Camera.V4L2Single`).
- The inner loop handles one dequeued frame per `poll` round, so settings and statistics are served while frames keep arriving.
- The minute's statistics add the write's time per frame.
- Tests: the records out for a sequence of frames are identical, in content and order, to the serial path's; settings sent while frames arrive are applied.
- On the unit: `full` at 35 fps with 3 and 4 threads, delivered rate, conversion and write times, CPU; the stereo pair's and detection's rates alongside.

Measured on the unit after Task 2, `full` at 35 fps asked, 3 threads: 35.0 fps, conversion 19.7 ms, write 15 ms beside it, CPU about 50 % of all cores against about 20 % without the camera, depth 32 to 33 Hz against about 34.5. 4 threads: 29.4 fps.

#### Task 3: a camera's outputs, configured.
The models take 640 × 640 (YOLOX) and 1024 × 512 (FFNet), so a `full` frame crosses the pipe to each NPU Port, 9 MB and 6 MB, only to be shrunk there. Options: a resize in the vision core (Nx on the CPU, or the GPU, busy with the stereo pair), a resize Port (one more copy), or more than one output from `v4l2_capture`, made from the full image while it is in cache on the conversion threads. Chosen: outputs configured on the camera, produced by `v4l2_capture`. Every output goes out at every frame, at a constant rate, so each path is exercised all the time, not only when it is viewed.

The outputs are a contract between the camera and its consumers, independent of what produces them: today the software conversion, later the SoC's ISP (TASK-105), which scales in hardware.

- A camera declares named outputs. Each is either made from the sensor's frame by a `processor`, or scaled from another output with `from`:

  ```elixir
  outputs: [
    view: [resolution: {2028, 1520}, processor: :cpu],
    inference: [resolution: {1014, 760}, from: :view]
  ]
  ```

  - `processor: :cpu` is `v4l2_capture`'s software conversion, the only processor of this driver today. An ISP is another processor: the Raspberry Pi 5's, which `camera_capture` already drives through libcamera and which gives a main and a low-resolution stream of one frame, and the VENTUNO Q's (TASK-105). A processor this driver does not have is refused at start.
  - `from: :view` scales an existing output on the CPU, each output pixel the average of the block it covers, in whole fractions of the source (2 × 2 and so on). It is how a second size comes cheaply from any processor: today `inference` from the CPU's `view`, later from an ISP's.
  - The two ways to make a smaller output differ today: from the sensor, `processor: :cpu` converts the raw frame again at that size (17.1 ms for 1014 × 760, one Bayer cell a pixel); `from: :view` averages the image already made (about 1 to 2 ms).
  - At start, refused: an unknown processor or one the driver lacks, a resolution its processor cannot make, a `from` naming an unknown output, a cycle, or a size that is not a whole fraction of its source.
  - `output:` stays as the one-output shorthand. Each consumer names the output it takes: the pipelines on a camera source, the preview, the ROS 2 images, the pose capture; the default is the first output.
- What this design leaves out until a second processor exists on one camera: mixing processors on one camera. Running an ISP beside the raw path the CPU reads depends on the SoC and its driver; an ISP's outputs would also be coloured by its own tuning, so outputs of two processors could differ in colour. Moving frames without the pipe is a change of its own too: each output still crosses it at every frame (9.2 MB and 2.3 MB at 35 Hz, about 400 MB/s, about half a core).
- `resolution` names the size in pixels rather than a ratio, so each consumer reads what it gets; a sensor mode that no longer yields it is refused at start.
- `v4l2_capture`: its arguments take the outputs with their processor or source; each processor is one module behind a trait, and the scaling of `from` outputs one module after it, so an ISP processor slots in without touching the scaling, the framing, the writer or the Elixir side; the writer thread writes one record per output per frame, each tagged with its output's index.
- `VisionCore.Camera.V4L2Single` / `Frame`: a frame carries its outputs by name; subscribers get the output they asked for, with its own size; `camera_info`, the calibration scaled per output (for a 2 × 2 average, `cx' = (cx + ½) / 2 − ½`).
- The pipelines on a camera source use their output's size for boxes, band and reprojection.
- OVCS1's composer: `view` at 2028 × 1520 on the CPU and `inference` at 1014 × 760 from `view`, the detector, the segmenter and the preview on `:inference` (a 2028 × 1520 preview JPEG takes 85 to 184 ms to encode on the unit), ROS 2 on `:view`.
- Tests: the averaged image against a reference; the records per frame, in order, for one and two outputs; the pipelines' geometry on the smaller output; the mapped intrinsics; refused at start: an unknown output name, an unknown or unavailable processor, a resolution its processor cannot make, a `from` cycle or an unknown source, a size not a whole fraction of its source.
- On the unit: rate, conversion and write times, CPU, depth rate, both pipelines' rates, against Task 2's figures.

#### Task 4: one JPEG of the full image, shared by the preview and ROS 2.
The OVCS1 reference vehicle's dashboard and ROS 2 both show the HQ camera's full image at 30 Hz. Encoded in the vision core, each 2028 × 1520 frame crosses a pipe twice (9.2 MB to the core, 9.2 MB again to `jpeg_codec`) and costs 43 to 91 ms there with libjpeg-turbo, once per consumer; the left and right images are already encoded twice, once by the ROS 2 exporter and once by the preview, with the same settings.

Chosen: JPEG is an output format of the camera, encoded once by `v4l2_capture` right after the conversion, with libjpeg-turbo, on a thread of its own; the preview and the ROS 2 exporter take that JPEG as it is. For frames the core still encodes (the stereo cameras), the JPEG pool encodes a frame once for every consumer asking for the same frame at the same quality.

- `outputs:` takes `format: :jpeg` (and `quality:`) on a `from:` output: `view_jpeg: [from: :view, format: :jpeg, quality: 80]`, the same size as its source or a whole fraction of it. Refused at start on a driver or processor that cannot make it.
- `v4l2_capture`: a JPEG output is encoded on an encoder thread from the converted image, beside the writer, so the conversion is not delayed; one JPEG record per frame, tagged with its output index; the minute's statistics add the encode time. Links libjpeg-turbo as `jpeg_codec` does.
- `Frame`: a JPEG output's frame carries `jpeg:` (`Frame.to_jpeg/2` already returns it as is).
- The preview and the ROS 2 exporter's camera image take a JPEG output without encoding; OVCS1: the preview and ROS 2 show `view_jpeg` at 30 Hz.
- `VisionCore.Jpeg`: requests for the same frame (camera, output, capture time) at the same quality share one encode, in flight or just finished (the latest per stream kept).
- Tests: the JPEG output decodes to the full image within a PSNR bound; one record per frame; the preview and the exporter send the camera's JPEG bytes as they are; two consumers of one stereo frame cause one encode.
- On the unit: the HQ camera's rate, the encode time, CPU, the preview's and ROS 2's rates.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
OVCS1 runs every camera at 30 fps: enough for driving, and each stage gains a frame of 33.3 ms.
Decisions: a camera declares named `outputs:`, each made by a processor (`:cpu` today, an ISP later) or `from:` another one, in RGB or `format: :jpeg`, and `send: false` for one that only feeds others; consumers name the output they take. On OVCS1 the full image stays on the unit and goes out as one JPEG shared by the preview and ROS 2.
<!-- SECTION:NOTES:END -->
