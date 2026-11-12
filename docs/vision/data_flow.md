---
title: How a pair flows
description: The processes a pair of camera frames goes through on the vision unit, from capture to the ROS 2 topics, detection and the dashboard, and how the unit keeps up.
---

This guide follows one pair of frames through the vision unit. Related guides:

- [Stereo vision basics](./basics.md): what disparity and rectification are.
- [Stereo stages](./stages.md): the stages themselves.
- [Where depth is computed](./compute.md): where the stages run.

## The processes

Each box below is a process on the BEAM, or a Port: a separate program the BEAM drives over pipes. A Port that crashes cannot take the BEAM down.

The diagram shows the Pi 5. The other boards differ:

- On the C100 and the VENTUNO Q, one `v4l2_capture` Port captures both cameras and sends their frames as pairs.
- A camera of its own has a `v4l2_capture` Port of its own, sending single frames.
- On the VENTUNO Q, detection runs in the `qnn_detect` Port, on the NPU.

A unit runs one detection pipeline per detector its vehicle lists, each with its own supervisor, backend and model. The diagram shows one. A pipeline on a camera of its own subscribes to that camera's frames and to the pairs. It projects the pairs' depth into the camera's image. A segmentation pipeline does the same, one per segmenter, with its band of each frame segmented in the `qnn_segment` Port.

```text
 left camera Port ──► LibCamera / V4L2 driver ─┐
                                                ├─► Pairer ──► Pipeline ──► subscribers
 right camera Port ─► LibCamera / V4L2 driver ─┘                │
                                                                 ├─ stereo_match Port (Pi 5)
                                                                 └─ GPU through nx_iree (C100, VENTUNO Q)

 subscribers:  ROS 2 exporter ── Zenoh ──► the vehicle's ROS 2 graph
               Detection pipeline ──► hailo_detect Port (Hailo-8)
               Status (rates, load, alignment, sharpness)
               Preview ──► jpeg_codec Ports ──► dashboard channels
```

A Port's row below names the process that owns it.

| Box | Process | Started by |
|---|---|---|
| LibCamera / V4L2 driver | [`VisionCore.Camera.LibCamera`](../../vision/core/lib/vision_core/camera/lib_camera.ex) on the Pi 5, [`VisionCore.Camera.V4L2`](../../vision/core/lib/vision_core/camera/v4l2.ex) on the C100 and the VENTUNO Q, one per side | `VisionCore.Stereo.Supervisor` |
| Camera of its own | [`VisionCore.Camera.V4L2Single`](../../vision/core/lib/vision_core/camera/v4l2_single.ex), with its `v4l2_capture` Port, for a `:camera` component | `VisionCore.Camera.Unit` |
| Pairer | [`VisionCore.Stereo.Pairer`](../../vision/core/lib/vision_core/stereo/pairer.ex), which also measures how far apart the cameras capture, for the Status | `VisionCore.Stereo.Supervisor` |
| Pipeline | [`VisionCore.Stereo.Pipeline`](../../vision/core/lib/vision_core/stereo/pipeline.ex) | `VisionCore.Stereo.Supervisor` |
| `stereo_match` Port | [`VisionCore.Stereo.Matcher`](../../vision/core/lib/vision_core/stereo/matcher.ex) | `VisionCore.Supervisor` |
| ROS 2 exporter | [`VisionCore.Ros2.Exporter`](../../vision/core/lib/vision_core/ros2/exporter.ex), with [`VisionCore.Ros2.Exporter.Diagnostics`](../../vision/core/lib/vision_core/ros2/exporter/diagnostics.ex) publishing what the cameras do and their sync, and a [`VisionCore.Ros2.Services.SetCameraInfoServer`](../../vision/core/lib/vision_core/ros2/services/set_camera_info_server.ex) per camera answering `cameracalibrator`'s commit | `VisionCore.Exporters` |
| Detection pipeline, one per detector | [`VisionCore.Detection.Pipeline`](../../vision/core/lib/vision_core/detection/pipeline.ex), with [`VisionCore.Detection.Live`](../../vision/core/lib/vision_core/detection/live.ex) passing its results to the dashboard | `VisionCore.Detection.Supervisor`, one per pipeline |
| `hailo_detect` Port | [`VisionCore.Detection.Backend.Hailo`](../../vision/core/lib/vision_core/detection/backend/hailo.ex) | `VisionCore.Detection.Supervisor` |
| `qnn_detect` Port | [`VisionCore.Detection.Backend.Qnn`](../../vision/core/lib/vision_core/detection/backend/qnn.ex) | `VisionCore.Detection.Supervisor` |
| Segmentation pipeline, one per segmenter | [`VisionCore.Segmentation.Pipeline`](../../vision/core/lib/vision_core/segmentation/pipeline.ex), with [`VisionCore.Segmentation.Live`](../../vision/core/lib/vision_core/segmentation/live.ex) passing its label grids to the dashboard | `VisionCore.Segmentation.Supervisor`, one per pipeline |
| `qnn_segment` Port | [`VisionCore.Segmentation.Backend.Qnn`](../../vision/core/lib/vision_core/segmentation/backend/qnn.ex) | `VisionCore.Segmentation.Supervisor` |
| Status | [`VisionCore.Status`](../../vision/core/lib/vision_core/status.ex) | `VisionCore.Supervisor` |
| Preview | [`VisionCore.Preview`](../../vision/core/lib/vision_core/preview.ex) | `VisionCore.Supervisor` |
| `jpeg_codec` Ports | [`VisionCore.Jpeg`](../../vision/core/lib/vision_core/jpeg.ex), twice: the Pipeline decodes JPEG camera frames on `VisionCore.Jpeg`, one Port; the Preview and the exporters encode on `VisionCore.Jpeg.Export`, a pool of Ports | `VisionCore.Supervisor` |

The drivers, the Pipeline and the detection and segmentation pipelines publish their frames, pairs, detections and label grids through [`VisionCore.Outputs`](../../vision/core/lib/vision_core/outputs.ex). It is a registry of subscriptions that `VisionCore.Supervisor` starts before the components. A process subscribes to the outputs it reads, under the name of the process that produces them. Its subscription holds while that process restarts.

`VisionCore.Stereo.Supervisor` is one stereo unit. It starts its children in order and restarts everything after a child that fails (`:rest_for_one`):

- The Pairer waits on the Pipeline.
- The process that declares the unit's parameters applies their values to the drivers and the Pipeline when it starts.

The unit has its own restart budget. A camera that keeps failing stops the unit and leaves the rest of the vision core running.

## One pair, step by step

1. **Capture.** Each camera Port reads its sensor and writes frames on its stdout. On the Pi 5, libcamera's image signal processor debayers and scales the sensor's output to the configured size in hardware. With `format: :grey`, `camera_capture` sends the luma plane as it is, one byte per pixel. With `sync: :server` on the left camera and `sync: :client` on the right one, the right camera follows the left one's frame timing through libcamera's software sync. The sensor's tuning file must support that sync. On the C100, `v4l2_capture` locks the right sensor's frame starts to the left one's and sends the two frames as one pair.
2. **Pairing.** The Pairer pairs a left and a right frame by their capture times, and submits a pair only when the Pipeline says it can take one. Pairs that are ready while the Pipeline is busy are dropped, not queued: a queue would only make the depth older.
3. **Stages.** The Pipeline runs the stages in order. Consecutive stages that run on the same device form one segment, so a pair crosses to the GPU, or to the `stereo_match` Port, once and comes back once. The [stages guide](./stages.md) describes each one.
4. **Subscribers.** The finished `Pair` goes to every subscriber as a message. On the BEAM, a large binary such as an image is shared between processes by reference, not copied, so five subscribers cost no more memory than one.
5. **Publishing.** The ROS 2 exporter sends the disparity, depth and point cloud of every pair. It sends the raw camera images as frames arrive, at most `:raw_image_max_hz` a second per side (its `stereo:` options). Detection runs on every `:detect_every_n`-th pair. The dashboard's previews are encoded only when a dashboard is open.

## Two pairs in flight

When the first segment is native, as on the Pi 5, the Pipeline keeps two pairs at the `stereo_match` Port. While the Port computes one pair, it reads the next pair's frames and writes the previous pair's outputs on two other threads. The pipe transfers then overlap the computation, and the rate depends on the computation alone. Pairs still come out in the order they went in.

Two figures in the Pipeline's log line describe this:

| Figure | Meaning |
|---|---|
| `total` | A pair's latency, from submission to the subscribers: about two segment times. |
| `wall` | The interval between finished pairs: one segment time when the Port is the bottleneck. |

A live setting, such as the matcher's `p1`, applies from the second pair submitted after the change, since one pair is already at the Port.

With a compiled segment first, as on the C100, the Pipeline overlaps differently. While the next pair's GPU work runs, it collects one pair's outputs and runs the stages after the segment.

## What leaves the unit

The exporters take the unit's outputs out of it; see [Exporters](#exporters). The ROS 2 exporter publishes them over Zenoh as ROS 2 messages, under its `:topic_prefix`. By default that is the stereo unit's `:prefix`, `stereo`:

| Topic | Content |
|---|---|
| `<prefix>/<side>/image_raw/compressed` | Each camera's frames as JPEG. Grey frames are encoded by `jpeg_codec`, at most `:raw_image_max_hz` a second per side; JPEG frames go out as they arrive. |
| `<prefix>/<side>/camera_info` | Each camera's calibration. |
| `<prefix>/disparity` | `stereo_msgs/DisparityImage`, the disparity in 32-bit float pixels. |
| `<prefix>/depth/image_rect` | The depth as a 16UC1 image of millimetres, 0 where there is no measurement: the ROS depth-image convention, at half the bytes of 32-bit metres. |
| `<prefix>/depth/camera_info` | The left camera's rectified intrinsics, next to the depth image so viewers can project it. |
| `<prefix>/points` | The decimated point cloud, organized, NaN where nothing was measured. |
| `<prefix>/detections`, `<prefix>/detections/markers`, `<prefix>/left/detections` | Detected objects with their position in metres, markers for RViz or Foxglove, and the 2D overlay on the left image. |
| `<prefix>/<name>/detections`, `<prefix>/<name>/detections/markers`, `<prefix>/<name>/annotations` | The same for the named detection pipeline `<name>`, with its markers in the namespace `<name>`; its 2D overlay on the left image is `<prefix>/<name>/annotations`. A pipeline on a camera of its own publishes those with a distance there, in the camera's frame, and its overlay over the camera's image. |
| `<prefix>/<name>/detections_2d` | A pipeline on a camera of its own: `vision_msgs/Detection2DArray` of the objects it has no distance for, boxes in the camera's pixels. |
| `<prefix>/<name>/labels` | The segmentation pipeline `<name>`'s label image, a `mono8` `sensor_msgs/Image` of class ids. Each pixel is a cell of the model's output grid, over the band of the camera's image the model sees. It is in the camera's frame, stamped with the frame's capture time. |
| `<prefix>/<name>/camera_info` | Sent with each label image, under its header: the camera's calibration mapped onto the label grid. A point projected through it lands on the label pixel of its cell. Empty but for its size when the camera has no calibration of the frame's aspect ratio. |
| `<prefix>/<name>/road/points`, `<prefix>/<name>/off_road/points` | The segmentation pipeline `<name>`'s stereo points in a road cell and in any other cell, as `sensor_msgs/PointCloud2` in the stereo left optical frame. They are stamped with their stereo pair's capture time, as `<prefix>/points` is, so syncing them with the label image takes an approximate-time policy. None is published for a frame without a matched stereo pair. None is published either when the camera's calibration or pose is missing, or its calibration cannot be projected at the frame's size. |

A named pipeline is published only when the exporter's `detections:` lists it in `pipelines:` (`[:detection]` by default, the unnamed pipeline). Segmentation pipelines are published only with the exporter's `segmentation:` option: those its `pipelines:` lists, or without `pipelines:` every one on a camera. Clouds whose pair carries no frame id, the stereo unit's left camera having been given none, are in `<prefix>_left`.

`VisionCore.Ros2.Exporter.Stereo`'s documentation lists the topics that are off unless you turn them on, such as the rectified images. `GET /api/ros2-node` on the unit lists every topic it has published, with its live rate ([Vision unit](./README.md#dashboard-and-api)).

Each message is stamped with the frame id of what it comes from:

- The stereo component's sides set each camera's frame id (`left: [frame_id: "stereo_left_optical"]`, `<prefix>_left` without one).
- Every frame carries its camera's frame id.
- A pair's outputs and its detections are in the left camera's frame.
- A camera of its own's detections are in that camera's frame.

One setting therefore reaches every exporter.

## Exporters

An exporter takes the unit's outputs out of it, to a network or to storage. It is a module of plain functions implementing [`VisionCore.Exporter`](../../vision/core/lib/vision_core/exporter.ex). It names the outputs it reads (the stereo pairs, a camera's frames, the detections) and takes each value it is handed.

[`VisionCore.Exporter.Runner`](../../vision/core/lib/vision_core/exporter/runner.ex) subscribes to those outputs and hands the exporter the newest value of each, at most the output's `:max_hz` times a second. A value that arrives while the exporter is busy replaces the one before it, so a slow exporter skips values instead of falling behind. An exporter whose transport answers later says it is busy with an output. It is handed that output's newest value once it says it is ready.

Your vehicle's composer lists the exporters in its `VisionCore.Config`, next to the components that produce the outputs. Each entry is `{module, options}`, or a module alone. The ROS 2 exporter needs the ROS 2 link, the `ros2:` section:

```elixir
%VisionCore.Config{
  ros2: [zenoh_endpoint_ip: "10.0.0.2"],
  components: [stereo_component()],
  exporters: [{VisionCore.Ros2.Exporter, heartbeat: [], stereo: []}]
}
```

Without `ros2:`, no ROS 2 process starts: no Zenoh session, no parameter services, no topic counts, no simulator clock. A ROS 2 exporter or a `VisionCore.Ros2.Camera` configured without it is not started. The reason is logged, and the unit runs on.

An exporter of your own needs no change to the core, the API or the dashboard. It takes one module, and one line in your composer.

An exporter can also declare **actions**: things people ask of it, rather than outputs it reads. It declares them with the optional `actions/1` and `handle_action/4` callbacks of `VisionCore.Exporter`. The API lists them in `GET /api/exporters` and runs them with `POST /api/exporters/:id/actions/:name` ([Vision API](./api.md#the-unit-and-its-exports)). The exporter's dashboard page shows a button for each.

An action answers a JSON result, an error or a file to download. It may answer later than it was asked, as an export that spans many pairs does. [`VisionCore.Debug.Exporter`](../../vision/core/lib/vision_core/debug/exporter.ex) is the one that ships with the core. Its `export` action returns a zip of a burst of pairs and the unit's state, for [tuning the unit's parameters](./tuning.md).

[`VisionCore.Exporters`](../../vision/core/lib/vision_core/exporters.ex) starts after the components in `VisionCore.Supervisor`. It starts before the Preview and before the Status, which reports the exporters' statuses. It runs each exporter under a supervisor with its own restart budget:

- An exporter that cannot start yet, such as one waiting for its storage, is tried again until it starts. It does not delay the rest of the unit.
- An exporter that keeps crashing stops alone, permanently, with an error logged. The cameras, the pipelines and the other exporters keep running.

The ROS 2 link stays in the unit's core, before the components: the simulator clock holds every stamp back until the first `/clock`, and a `VisionCore.Ros2.Camera` reads its frames through the Zenoh session. The Zenoh client opens its session in the background. A router that does not answer therefore delays neither the unit's start nor the processes that register with the client.

The ROS 2 exporter, [`VisionCore.Ros2.Exporter`](../../vision/core/lib/vision_core/ros2/exporter.ex), publishes the topics above, the cameras' diagnostics and a heartbeat, each part when its option is given. It also answers `cameracalibrator`'s commit. A calibration the stereo unit refuses is taken back: the file holds what it held before, and the commit is answered as failed.

Each time it starts, it reads the stereo unit's cameras in the configuration, the calibration a commit stored first. The camera info it publishes is therefore the calibration the stereo unit uses.

`GET /api/exporters` lists the exporters with their statuses, the outputs they read and their actions. An exporter that does not run says why. The API comes last, as it is the one answering. The dashboard's Exporters menu is built from it.

## The dashboard's previews

The dashboard opens one channel per preview: `preview:left`, `preview:right` and `preview:depth`. `VisionCore.Preview` encodes a frame for a channel only when that channel's previous frame has been shown and acknowledged, and at most `:max_hz` times a second. A slow link therefore gets the latest frame instead of a backlog, and a unit with no dashboard open encodes nothing. Each frame goes to the browser as a binary WebSocket message holding the JPEG.

Each preview encodes apart from the others, one frame at a time. A slow one, such as a camera's full-resolution frame, delays only its own stream. A frame that comes during its stream's encode waits, replaced by any newer one.

The previews and the exporters, the ROS 2 exporter's images among them, share a pool of `jpeg_codec` Ports. Set its size with `jpeg: [ports: n]` in your vehicle's `VisionCore.Config`, 3 by default.

Each encode runs on a free Port. Once every Port is busy, the encodes wait their turn in the order they came, so neither the previews nor the exporters starve the other. More Ports encode more at once, each taking a CPU core while it encodes.

A camera frame is encoded once for every preview and exporter that asks for it at the same quality. A request for a frame already waiting or encoding, or for the last one its stream encoded, takes that JPEG. The stereo cameras' frames that the preview and the ROS 2 exporter both send therefore cost one encode each.

A camera output sent as JPEG ([Outputs](./cameras.md#outputs)) costs the pool nothing: its frames carry the JPEG `v4l2_capture` encoded.

Each pipeline's results reach the dashboard on a channel of their own: `detections` or `detections:<name>` for a detection pipeline, `segmentation:<name>` for a segmentation pipeline. A segmentation channel sends a binary message holding the band and the grid, at most `max_hz` a second. As with a preview's frame, it sends one only once the previous one is acknowledged ([Vision API](./api.md#segmentation)).

The depth preview is the depth image coloured by `jpeg_codec`, near red and far blue, scaled by 1/depth.

## See also

- [Stereo stages](./stages.md)
- [Where depth is computed](./compute.md)
