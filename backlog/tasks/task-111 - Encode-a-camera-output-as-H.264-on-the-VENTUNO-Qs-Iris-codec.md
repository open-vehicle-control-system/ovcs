---
id: TASK-111
title: Encode a camera output as H.264 on the VENTUNO Q's Iris codec
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-13 11:00'
labels:
  - vision
dependencies:
  - TASK-94
ordinal: 87000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The OVCS1 reference vehicle's `center` camera sends its 2028 × 1520 image as a JPEG at every frame (`view_jpeg`): 18 ms of a fast core per frame and about 13 MB/s to the dashboard and to ROS 2. The SoC's video codec, Iris, is bound by the mainline `qcom-iris` driver (`/dev/video1`, `qcom-iris-encoder`: NV12 in, H.264 or HEVC out) and starts once the Nerves system ships `qcom/vpu/vpu30_p4_s6.mbn` from linux-firmware. Measured on the unit with `v4l2-ctl`: 300 frames of 2032 × 1520 H.264 in 1.1 s (265 fps), with almost no CPU; it takes NV12 with lines padded to 2048 bytes and 1536 rows.

The SoC's ISP is not reachable through the mainline camera driver on this SoC (raw dump paths only); TASK-105 follows that up. The encoder is useful either way.

Design:
- A camera output `format: :h264` (`from:` another output, like `format: :jpeg`), with `bitrate:` and `keyframe_interval:`; refused at start on a board without an encoder.
- `v4l2_capture`: the output's source image is converted to NV12 on the conversion threads (or the colour path writes NV12 directly) and fed to the encoder through the V4L2 memory-to-memory API on a thread of its own; each encoded frame is a record of its own, its key-frame flag beside it. The encoder sits behind a small interface so another board's encoder slots in.
- The core: a frame carrying `h264:` and `keyframe?`; consumers take every frame of the stream in order (a decoder needs them all from a key frame), not the newest one.
- ROS 2: `foxglove_msgs/CompressedVideo` on `<prefix>/<camera>/video`, beside the JPEG image (`ros2_zenoh` gains its encoder, golden-tested against rclpy).
- Dashboard: decoded with WebCodecs (`VideoDecoder`), joining at the next key frame, the JPEG preview kept as a fallback where WebCodecs or H.264 is missing.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The Nerves system ships the Iris firmware, and the encoder starts on the unit
- [ ] #2 A camera output with `format: :h264` encodes on the Iris codec at the camera's rate, its CPU and bit rate measured on the unit
- [ ] #3 ROS 2 publishes the stream as `foxglove_msgs/CompressedVideo`, decodable by Foxglove
- [ ] #4 The dashboard shows the stream with WebCodecs where available, and the JPEG preview elsewhere
<!-- AC:END -->
