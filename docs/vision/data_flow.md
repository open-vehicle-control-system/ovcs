---
title: How a pair flows
description: The processes a pair of camera frames goes through on the vision unit, from capture to the ROS 2 topics, detection and the dashboard, and how the unit keeps up with the cameras.
---

This guide follows one pair of frames through the vision unit. What disparity and rectification are is in [Stereo vision basics](./basics.md), the stages themselves in [Stereo stages](./stages.md); where they run, in [Where depth is computed](./compute.md).

## The processes

Each box below is a process on the BEAM, or a Port: a separate program the BEAM drives over pipes. A Port that crashes cannot take the BEAM down. The diagram shows the Pi 5; on the C100, one `v4l2_capture` Port captures both cameras and sends their frames as pairs.

```text
 left camera Port ──► LibCamera / V4L2 driver ─┐
                                                ├─► Pairer ──► Pipeline ──► subscribers
 right camera Port ─► LibCamera / V4L2 driver ─┘                │
                                                                 ├─ stereo_match Port (Pi 5)
                                                                 └─ GPU through nx_iree (C100)

 subscribers:  ROS 2 exporter ── Zenoh ──► the vehicle's ROS 2 graph
               Detection pipeline ──► hailo_detect Port (Hailo-8)
               Status (rates, load, alignment, sharpness)
               Preview ──► jpeg_codec Port ──► dashboard channels
```

A Port's row below names the process that owns it.

| Box | Process | Started by |
|---|---|---|
| LibCamera / V4L2 driver | [`VisionCore.Camera.LibCamera`](../../vision/core/lib/vision_core/camera/lib_camera.ex) on the Pi 5, [`VisionCore.Camera.V4L2`](../../vision/core/lib/vision_core/camera/v4l2.ex) on the C100, one per side | `VisionCore.Stereo.Supervisor` |
| Pairer | [`VisionCore.Stereo.Pairer`](../../vision/core/lib/vision_core/stereo/pairer.ex), which also measures how far apart the cameras capture, for the Status | `VisionCore.Stereo.Supervisor` |
| Pipeline | [`VisionCore.Stereo.Pipeline`](../../vision/core/lib/vision_core/stereo/pipeline.ex) | `VisionCore.Stereo.Supervisor` |
| `stereo_match` Port | [`VisionCore.Stereo.Matcher`](../../vision/core/lib/vision_core/stereo/matcher.ex) | `VisionCore.Supervisor` |
| ROS 2 exporter | [`VisionCore.Ros2.Exporter`](../../vision/core/lib/vision_core/ros2/exporter.ex), with [`VisionCore.Ros2.Exporter.Diagnostics`](../../vision/core/lib/vision_core/ros2/exporter/diagnostics.ex) publishing what the cameras do and their sync, and a [`VisionCore.Ros2.Services.SetCameraInfoServer`](../../vision/core/lib/vision_core/ros2/services/set_camera_info_server.ex) per camera answering `cameracalibrator`'s commit | `VisionCore.Exporters` |
| Detection pipeline | [`VisionCore.Detection.Pipeline`](../../vision/core/lib/vision_core/detection/pipeline.ex), with [`VisionCore.Detection.Live`](../../vision/core/lib/vision_core/detection/live.ex) passing its results to the dashboard | `VisionCore.Detection.Supervisor` |
| `hailo_detect` Port | [`VisionCore.Detection.Backend.Hailo`](../../vision/core/lib/vision_core/detection/backend/hailo.ex) | `VisionCore.Detection.Supervisor` |
| Status | [`VisionCore.Status`](../../vision/core/lib/vision_core/status.ex) | `VisionCore.Supervisor` |
| Preview | [`VisionCore.Preview`](../../vision/core/lib/vision_core/preview.ex) | `VisionCore.Supervisor` |
| `jpeg_codec` Port | [`VisionCore.Jpeg`](../../vision/core/lib/vision_core/jpeg.ex), twice: the Pipeline decodes JPEG camera frames on `VisionCore.Jpeg`, the Preview and the exporters encode on `VisionCore.Jpeg.Export` | `VisionCore.Supervisor` |

The drivers, the Pipeline and the Detection pipeline publish their frames, pairs and detections through [`VisionCore.Outputs`](../../vision/core/lib/vision_core/outputs.ex), a registry of subscriptions that `VisionCore.Supervisor` starts before the components. A process subscribes to the outputs it reads, under the name of the process that produces them, and its subscription holds while that process restarts.

`VisionCore.Stereo.Supervisor` is one stereo unit. It starts its children in order and restarts everything after a child that fails (`:rest_for_one`): the Pairer waits on the Pipeline, and the process that declares the unit's parameters applies their values to the drivers and the Pipeline when it starts. The unit has its own restart budget; a camera that keeps failing stops the unit and leaves the rest of the vision core running.

## One pair, step by step

1. **Capture.** Each camera Port reads its sensor and writes frames on its stdout. On the Pi 5, libcamera's image signal processor debayers and scales the sensor's output to the configured size in hardware; with `format: :grey`, `camera_capture` sends the luma plane as it is, one byte per pixel. With `sync: :server` on the left camera and `sync: :client` on the right one, the right camera follows the left one's frame timing through libcamera's software sync, which the sensor's tuning file must support; on the C100, `v4l2_capture` locks the right sensor's frame starts to the left one's and sends the two frames as one pair.
2. **Pairing.** The Pairer pairs a left and a right frame by their capture times, and submits a pair only when the Pipeline says it can take one. Pairs that are ready while the Pipeline is busy are dropped, not queued: a queue would only make the depth older.
3. **Stages.** The Pipeline runs the stages in order. Consecutive stages that run on the same device form one segment, so a pair crosses to the GPU, or to the `stereo_match` Port, once and comes back once. The [stages guide](./stages.md) describes each one.
4. **Subscribers.** The finished `Pair` goes to every subscriber as a message. On the BEAM, a large binary such as an image is shared between processes by reference, not copied, so five subscribers cost no more memory than one.
5. **Publishing.** The ROS 2 exporter sends the disparity, depth and point cloud of every pair, and the raw camera images as frames arrive, at most `:raw_image_max_hz` a second per side (its `stereo:` options); detection runs on every `:detect_every_n`-th pair; the dashboard's previews are encoded only when a dashboard is open.

## Two pairs in flight

When the first segment is native, as on the Pi 5, the Pipeline keeps two pairs at the `stereo_match` Port. While the Port computes one pair, it reads the next pair's frames and writes the previous pair's outputs on two other threads. The pipes stop being dead time, and the rate depends on the computation alone. Pairs still come out in the order they went in.

Two figures in the Pipeline's log line describe this:

| Figure | Meaning |
|---|---|
| `total` | A pair's latency, from submission to the subscribers: about two segment times. |
| `wall` | The interval between finished pairs: one segment time when the Port is the bottleneck. |

A live setting, such as the matcher's `p1`, applies from the second pair submitted after the change, since one pair is already at the Port.

With a compiled segment first, as on the C100, the Pipeline overlaps differently: it collects one pair's outputs and runs the stages after the segment while the next pair's GPU work runs.

## What leaves the unit

The exporters take the unit's outputs out of it ([Exporters](#exporters) below). The ROS 2 exporter publishes them over Zenoh as ROS 2 messages, under its `:topic_prefix`, the stereo unit's `:prefix` by default, `stereo`:

| Topic | Content |
|---|---|
| `<prefix>/<side>/image_raw/compressed` | Each camera's frames as JPEG. Grey frames are encoded by `jpeg_codec`, at most `:raw_image_max_hz` a second per side. |
| `<prefix>/<side>/camera_info` | Each camera's calibration. |
| `<prefix>/disparity` | `stereo_msgs/DisparityImage`, the disparity in 32-bit float pixels. |
| `<prefix>/depth/image_rect` | The depth as a 16UC1 image of millimetres, 0 where there is no measurement: the ROS depth-image convention, at half the bytes of 32-bit metres. |
| `<prefix>/depth/camera_info` | The left camera's rectified intrinsics, next to the depth image so viewers can project it. |
| `<prefix>/points` | The decimated point cloud, organized, NaN where nothing was measured. |
| `<prefix>/detections`, `<prefix>/detections/markers` | Detected objects with their position in metres, and markers for RViz or Foxglove. |

Topics that are off unless you turn them on, such as the rectified images, are listed in `VisionCore.Ros2.Exporter.Stereo`'s documentation. `GET /api/ros2-node` on the unit lists every topic it has published, with its live rate ([Vision unit](./README.md#dashboard-and-api)).

Each message is stamped with the frame id of what it comes from. The stereo component's sides set each camera's (`left: [frame_id: "stereo_left_optical"]`, `<prefix>_left` without one), every frame carries its camera's, and a pair's outputs and its detections are in the left camera's frame: one setting reaches every exporter.

## Exporters

An exporter takes the unit's outputs out of it, to a network or to storage. It is a module of plain functions implementing [`VisionCore.Exporter`](../../vision/core/lib/vision_core/exporter.ex): it names the outputs it reads (the stereo pairs, a camera's frames, the detections) and takes each value it is handed. [`VisionCore.Exporter.Runner`](../../vision/core/lib/vision_core/exporter/runner.ex) subscribes to those outputs and hands the exporter the newest value of each, at most the output's `:max_hz` times a second. A value that arrives while the exporter is busy replaces the one before it, so a slow exporter skips values instead of falling behind; an exporter whose transport answers later says it is busy with an output, and is handed its newest value once it says it is ready.

Your vehicle's composer lists the exporters in its `VisionCore.Config`, each `{module, options}`, or a module alone, next to the components that produce the outputs. The ROS 2 exporter needs the ROS 2 link, the `ros2:` section:

```elixir
%VisionCore.Config{
  ros2: [zenoh_endpoint_ip: "10.0.0.2"],
  components: [stereo_component()],
  exporters: [{VisionCore.Ros2.Exporter, heartbeat: [], stereo: []}]
}
```

Without `ros2:`, no ROS 2 process starts: no Zenoh session, no parameter services, no topic counts, no simulator clock. A ROS 2 exporter or a `VisionCore.Ros2.Camera` configured without it is not started, with the reason logged, and the unit runs on. An exporter of your own needs no change to the core, the API or the dashboard: one module, and one line in your composer.

An exporter can also declare **actions**, things people ask of it rather than outputs it reads, with the optional `actions/1` and `handle_action/4` callbacks of `VisionCore.Exporter`. The API lists them in `GET /api/exporters` and runs them with `POST /api/exporters/:id/actions/:name` ([Vision API](./api.md#the-unit-and-its-exports)), and the exporter's dashboard page shows a button for each. An action answers a JSON result, an error or a file to download, and it may answer later than it was asked, as an export that spans many pairs does. [`VisionCore.Debug.Exporter`](../../vision/core/lib/vision_core/debug/exporter.ex) is the one that ships with the core: its `export` action returns a zip of a burst of pairs and the unit's state, for [tuning the unit's parameters](./tuning.md).

[`VisionCore.Exporters`](../../vision/core/lib/vision_core/exporters.ex) starts after the components in `VisionCore.Supervisor`, before the Status, which reports the exporters' statuses, and the Preview, and runs each exporter under a supervisor with its own restart budget. An exporter that cannot start yet, such as one waiting for its storage, is tried again until it starts, without holding up the rest of the unit. One that keeps crashing stops alone, for good, with an error logged: the cameras, the pipelines and the other exporters keep running. The ROS 2 link stays in the unit's core, before the components: the simulator clock holds every stamp back until the first `/clock`, and a `VisionCore.Ros2.Camera` reads its frames through the Zenoh session. The Zenoh client opens its session in the background, so a router that does not answer holds up neither the unit's start nor the processes that register with the client.

The ROS 2 exporter, [`VisionCore.Ros2.Exporter`](../../vision/core/lib/vision_core/ros2/exporter.ex), publishes the topics above, the cameras' diagnostics and a heartbeat, each part when its option is given, and answers `cameracalibrator`'s commit: a calibration the stereo unit refuses is taken back, the file holding what it held before, and the commit answered as failed. It reads the stereo unit's cameras in the configuration each time it starts, the calibration a commit stored first, so the camera info it publishes is the calibration the stereo unit uses.

`GET /api/exporters` lists the exporters with their statuses, an exporter that does not run saying why, the outputs they read and their actions, the API last, as it is the one answering. The dashboard's Exporters menu is built from it, each entry with its status; the ROS 2 exporter and the API have pages of their own, another exporter a page with its status, its outputs and its actions as buttons. The top bar shows the ROS 2 exporter's status, its link to the Zenoh router.

## The dashboard's previews

The dashboard opens one channel per preview: `preview:left`, `preview:right` and `preview:depth`. `VisionCore.Preview` encodes a frame for a channel only when that channel's previous frame has been shown and acknowledged, and at most `:max_hz` times a second, so a slow link gets the latest frame instead of a backlog, and a unit with no dashboard open encodes nothing. Each frame goes to the browser as a binary WebSocket message holding the JPEG.

The depth preview is the depth image coloured by `jpeg_codec`, near red and far blue, scaled by 1/depth; the slider under the depth video sets the distance coloured blue.

## See also

- [Stereo stages](./stages.md)
- [Where depth is computed](./compute.md)
- [Perception: object detection](../bridges/perception.md): the ROS bridge's detector and its topics.
