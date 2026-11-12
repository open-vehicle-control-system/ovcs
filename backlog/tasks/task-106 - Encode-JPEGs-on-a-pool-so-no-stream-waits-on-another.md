---
id: TASK-106
title: Encode JPEGs on a pool so no stream waits on another
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-12 16:00'
labels:
  - vision
dependencies:
  - TASK-94
ordinal: 85000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Every JPEG the vision unit sends out goes through one `jpeg_codec` Port, `VisionCore.Jpeg.Export`, one image at a time: the dashboard's previews (left, right, depth, each camera of its own) and the ROS 2 exporter's compressed images. `VisionCore.Preview` also encodes inside its own process, waiting for each image. On the OVCS1 reference vehicle a 2028 × 1520 frame takes 85 to 184 ms to encode (405 KB), so while it encodes the other previews wait, and the ROS 2 exporter's HQ images at 10 Hz keep the Port busy: the dashboard lags by a few hundred milliseconds on every stream.

Options: a pool of `jpeg_codec` Ports, each request on a free one; one Port per stream; several threads inside `jpeg_codec`, behind one pipe. Chosen: a pool of Ports, its size an option, with each preview stream encoded off the preview process, so a slow stream delays only itself; the pipe of one Port stays serial, and the pool bounds the Ports and their memory.

After the pool, `jpeg_codec` moves from the pure-Rust `jpeg-encoder` crate, which has no NEON path, to libjpeg-turbo, which the VENTUNO Q's system image ships (`libturbojpeg.so`, `turbojpeg.h`): the pool stops streams waiting on each other, libjpeg-turbo makes each encode cheaper.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 `VisionCore.Jpeg` encodes on a pool of `jpeg_codec` Ports of a configured size; concurrent requests run on different Ports
- [x] #2 `VisionCore.Preview` encodes each stream apart, one encode in flight per stream, the newest frame replacing a waiting one; a slow stream does not delay another
- [x] #3 The ROS 2 exporter's encodes and the previews share the pool without one starving the other
- [ ] #4 On the VENTUNO Q, the left, right and depth previews keep their rate and latency while the HQ camera's preview and ROS 2 image run; measured and recorded in `docs/vision/performance.md`
- [x] #5 `jpeg_codec` encodes with libjpeg-turbo (NEON on the VENTUNO Q), linked from the board's system image; a 2028 × 1520 encode time measured on the unit before and after
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
A 2028 × 1520 encode in the core: 85 to 184 ms before, 43 to 91 ms with libjpeg-turbo. OVCS1's center camera now sends its own JPEG (TASK-94), so the pool encodes only the stereo previews and images, once per frame for every consumer. AC #4 is not measured.
<!-- SECTION:NOTES:END -->
