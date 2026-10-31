---
title: How a pair flows
description: The processes a pair of camera frames goes through on the vision unit, from capture to the ROS 2 topics, detection and the dashboard, and how the unit keeps up with the cameras.
---

This guide follows one pair of frames through the vision unit. The stages themselves, and what disparity and rectification are, are in [Stereo stages](./stages.md); where they run, in [Where depth is computed](./compute.md).

## The processes

Each box below is a process on the BEAM, or a Port: a separate program the BEAM drives over pipes. A Port that crashes cannot take the BEAM down. The diagram shows the Pi 5; on the C100, one `v4l2_capture` Port captures both cameras and sends their frames as pairs.

```text
 left camera Port ──► LibCamera / V4L2 driver ─┐
                                                ├─► Pairer ──► Pipeline ──► listeners
 right camera Port ─► LibCamera / V4L2 driver ─┘                │
                                                                 ├─ stereo_match Port (Pi 5)
                                                                 └─ GPU through nx_iree (C100)

 listeners:  ROS 2 publishers ── Zenoh ──► the vehicle's ROS 2 graph
             Detection pipeline ──► hailo_detect Port (Hailo-8)
             Status (rates, load, alignment, sharpness)
             Preview ──► jpeg_codec Port ──► dashboard channels
```

| Process | Started by | What it does |
|---|---|---|
| Camera driver | `VisionCore.Stereo.Supervisor` | `VisionCore.Camera.LibCamera` on the Pi 5 starts one `camera_capture` Port per camera; `VisionCore.Camera.V4L2` on the C100 starts one `v4l2_capture` Port for both. Each frame arrives as a `VisionCore.Camera.Frame`, grey or JPEG, with its capture time. |
| `VisionCore.Stereo.Pairer` | `VisionCore.Stereo.Supervisor` | Keeps the last few frames of each side and pairs the two whose capture times are closest, within `:pair_tolerance_ms`. |
| `VisionCore.Stereo.Pipeline` | `VisionCore.Stereo.Supervisor` | Runs the pair through the stages and sends the finished `VisionCore.Stereo.Pair` to its listeners. |
| `VisionCore.Ros2.Publishers.Stereo` | `VisionCore.Stereo.Supervisor` | Publishes the raw images, camera infos, disparity, depth and point cloud over Zenoh. |
| `VisionCore.Stereo.Matcher` | the application | Owns the `stereo_match` Port that computes native stages. |
| `VisionCore.Detection.Pipeline` | `VisionCore.Detection.Supervisor` | Sends the rectified left image to the detector and places each box with the depth. |
| `VisionCore.Status` | `VisionCore.Supervisor` | Counts the rates and load the dashboard's top bar and captions show. |
| `VisionCore.Preview` | `VisionCore.Supervisor` | Encodes the left, right and depth previews for the dashboard. |

`VisionCore.Stereo.Supervisor` is one stereo unit. It starts its children in order and restarts everything after a child that fails (`:rest_for_one`): a restarted driver or pipeline has no listeners, so the processes after it start again and register on it. The unit has its own restart budget; a camera that keeps failing stops the unit and leaves the rest of the vision core running.

## One pair, step by step

1. **Capture.** Each camera Port reads its sensor and writes frames on its stdout. On the Pi 5, libcamera's image signal processor debayers and scales the sensor's output to the configured size in hardware; with `format: :grey`, `camera_capture` sends the luma plane as it is, one byte per pixel. With `sync: :server` on the left camera and `sync: :client` on the right one, the right camera follows the left one's frame timing through libcamera's software sync, which the sensor's tuning file must support; on the C100, `v4l2_capture` locks the right sensor's frame starts to the left one's and sends the two frames as one pair.
2. **Pairing.** The Pairer submits a pair only when the Pipeline says it can take one. Pairs that are ready while the Pipeline is busy are dropped, not queued: a queue would only make the depth older.
3. **Stages.** The Pipeline runs the stages in order. Consecutive stages that run on the same device form one segment, so a pair crosses to the GPU, or to the `stereo_match` Port, once and comes back once. The [stages guide](./stages.md) describes each one.
4. **Listeners.** The finished `Pair` goes to every listener as a message. On the BEAM, a large binary such as an image is shared between processes by reference, not copied, so five listeners cost no more memory than one.
5. **Publishing.** The ROS 2 publishers send the disparity, depth and point cloud of every pair, and the raw camera images as frames arrive, at most `:raw_image_max_hz` a second per side; detection runs on every `:detect_every_n`-th pair; the dashboard's previews are encoded only when a dashboard is open.

## Two pairs in flight

When the first segment is native, as on the Pi 5, the Pipeline keeps two pairs at the `stereo_match` Port. While the Port computes one pair, it reads the next pair's frames and writes the previous pair's outputs on two other threads. The pipes stop being dead time, and the rate depends on the computation alone. Pairs still come out in the order they went in.

Two figures in the Pipeline's log line describe this:

| Figure | Meaning |
|---|---|
| `total` | A pair's latency, from submission to the listeners: about two segment times. |
| `wall` | The interval between finished pairs: one segment time when the Port is the bottleneck. |

A live setting, such as the matcher's `p1`, applies from the second pair submitted after the change, since one pair is already at the Port.

With a compiled segment first, as on the C100, the Pipeline overlaps differently: it collects one pair's outputs and runs the stages after the segment while the next pair's GPU work runs.

## What leaves the unit

Everything the unit publishes goes over Zenoh as ROS 2 messages, under the component's `:topic_prefix`, `stereo` by default:

| Topic | Content |
|---|---|
| `<prefix>/<side>/image_raw/compressed` | Each camera's frames as JPEG. Grey frames are encoded by `jpeg_codec`, at most `:raw_image_max_hz` a second per side. |
| `<prefix>/<side>/camera_info` | Each camera's calibration. |
| `<prefix>/disparity` | `stereo_msgs/DisparityImage`, the disparity in 32-bit float pixels. |
| `<prefix>/depth/image_rect` | The depth as a 16UC1 image of millimetres, 0 where there is no measurement: the ROS depth-image convention, at half the bytes of 32-bit metres. |
| `<prefix>/depth/camera_info` | The left camera's rectified intrinsics, next to the depth image so viewers can project it. |
| `<prefix>/points` | The decimated point cloud, organized, NaN where nothing was measured. |
| `<prefix>/detections`, `<prefix>/detections/markers` | Detected objects with their position in metres, and markers for RViz or Foxglove. |

Topics that are off unless you turn them on, such as the rectified images, are listed in `VisionCore.Stereo.Supervisor`'s documentation. `GET /api/ros2-node` on the unit lists every topic it has published, with its live rate ([Vision unit](./overview.md#dashboard-and-api)).

## The dashboard's previews

The dashboard opens one channel per preview: `preview:left`, `preview:right` and `preview:depth`. `VisionCore.Preview` encodes a frame for a channel only when that channel's previous frame has been shown and acknowledged, and at most `:max_hz` times a second, so a slow link gets the latest frame instead of a backlog, and a unit with no dashboard open encodes nothing. Each frame goes to the browser as a binary WebSocket message holding the JPEG.

The depth preview is the depth image coloured by `jpeg_codec`, near red and far blue, scaled by 1/depth; the slider under the depth video sets the distance coloured blue.

## See also

- [Stereo stages](./stages.md)
- [Where depth is computed](./compute.md)
- [Perception: object detection](../ros2_perception.md): the detector and its topics.
