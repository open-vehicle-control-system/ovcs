---
id: TASK-92
title: Segment the road on a camera source
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-11 19:00'
labels:
  - vision
dependencies:
  - TASK-91
parent_task_id: TASK-108
ordinal: 71000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Step 5 of TASK-108: road segmentation as a second pipeline kind, on a camera source, on the Hexagon NPU. Each pixel of the camera's image gets a Cityscapes class; with the stereo depth reprojected into the camera, the pipeline publishes road points and off-road points for a costmap, and the dashboard overlays the classes on the camera's preview. See TASK-108's Design.

The model is FFNet-122NS-LowRes from Qualcomm AI Hub, w8a8 for QNN: input `image` 1×512×1024×3 uint8 (scale 1/255), output `mask` 1×128×256×19 uint8 (scale 0.20315, zero point 153), the 19 Cityscapes classes with `road` first. DDRNet23-Slim (input 1×1024×2048×3, same output) is the alternative. Their weights are trained on Cityscapes, whose licence allows non-commercial use only.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A `:qnn_segmenter` component runs a named segmentation pipeline on a camera source, on the Hexagon
- [x] #2 Its label image covers the camera's image band the model sees, one Cityscapes class per cell
- [x] #3 It publishes the label image and the road and off-road clouds, in the stereo left frame, on ROS 2
- [x] #4 The dashboard overlays the classes on the camera's preview
- [x] #5 `mise run fetch-models` fetches the model with its licence printed
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Spec: TASK-108 (Road segmentation, ROS 2, Dashboard, requirement 8). Builds on TASK-110 (named pipelines, `Detection.server/2`, the NPU status over every backend), TASK-90 (`:camera`, `Frame.rgb`) and TASK-91 (`Reprojection`, the camera's calibration and pose, frame-to-pair matching).

Global constraints:
- The model sees a band of the camera's frame with the model's aspect ratio (2:1), full width, its top at `band_top` (a fraction of the frame's height, default: the band touches the frame's bottom), resized to the model's input; no letterbox. The label image is the model's output grid (256 × 128) over that band; pixels outside the band have no class.
- A cell's class is the argmax of its 19 scores.
- Road classes are a pipeline option, `road_classes`, default `["road"]`; every other class is off-road. A cell with no class contributes to neither cloud.
- The clouds are `sensor_msgs/PointCloud2` with `x`, `y`, `z` float32, in the stereo left optical frame, one point per reprojected stereo point whose camera pixel falls in a cell.
- Pipeline names, server names and the NPU status follow TASK-110; segmentation pipelines appear in the dashboard's menu as their own flow, `pipeline: name`.

Review focus, each pinned by a test in the owning task:
- A frame without a matched stereo pair: the label image is still published, the clouds are not.
- The class mapping is exact at the band's edges: a point projecting onto the band's first and last rows and columns gets the right cell, one just outside gets none.
- A model whose output is not `[1, H, W, C]` uint8 fails at start with a message naming the shape.
- Two segmentation pipelines' outputs never mix, in the runner, ROS 2 and the dashboard.

#### Task 1: `qnn_segment`.
- `vision/rust/qnn`: a library crate holding today's `qnn_detect/src/qnn.rs`; `qnn_detect` uses it unchanged in behaviour.
- `vision/rust/qnn_segment`: a Port like `qnn_detect` (same framing, logs and stdin protocol), reading the model's input and output shapes from the context; for each submitted RGB frame and band, resizes the band to the input (bilinear), runs the model, takes the argmax per cell and replies `<<7, sequence::little-32, width::little-16, height::little-16, labels, inference_us::little-32>>`, `labels` being `width * height` class ids and `inference_us` the accelerator time measured as `qnn_detect` measures it (TASK-95), absent when it could not be measured.
- Rust tests: band resize on a known image, argmax with quantised scores, the record, the shape check.

#### Task 2: the segmentation unit in the core.
- `VisionCore.Segmentation.Supervisor`, `Pipeline`, `Live` and `Backend.Qnn` (and `Backend.Stub` returning fixed labels), named with `VisionCore.Detection.server/2`, supervised and refused as TASK-110's detection units; `VisionCore.Components.start(:qnn_segmenter, opts)` and `:segmenter`; options `name` (required), `source` (`{:camera, name}`, required), `dlc_path`, `band_top`, `road_classes`, `labels` (Cityscapes 19 by default), `segment_every_n` (1).
- `Pipeline` matches each camera frame with a stereo pair as TASK-91's detection pipeline does; with a pair, `Reprojection.project/4` (extended to also return each point's `x`, `y`, `z` in the stereo left frame) gives the points, each classed by the cell it lands in; publishes `{:segmentation, name, frame, labels, clouds}` under `{:segmentation, server(Pipeline, name)}`, `labels` being `%{width, height, data, band: {x, y, w, h}}` and `clouds` `%{road: binary, off_road: binary}` (packed float32 xyz) or `nil`.
- Parameter groups `"#{name}.input"`, `"#{name}.inference"`, `"#{name}.classes"`, `pipeline: name`.
- `VisionCore.Status`'s NPU covers segmentation backends.
- Tests: pipeline with the stub backend (matched pair, no pair, band edges), components and application (names, duplicates), status.

#### Task 3: exporters.
- `VisionCore.Exporter` output `{:segmentation, name}`; the runner routes it as named detections.
- `Ros2.ZenohExporter` `segmentation: [pipelines: [...]]`: `<prefix>/<name>/labels` (`sensor_msgs/Image`, `mono8`, the band's label image, `frame_id` the camera's), `<prefix>/<name>/road/points` and `<prefix>/<name>/off_road/points` (`PointCloud2`, the stereo left `frame_id`).
- `ExporterController` lists `segmentation:<name>`.
- Tests: runner routing, ROS 2 messages, controller.

#### Task 4: API, dashboard, model, docs.
- `VisionApiWeb` channel `segmentation:<name>` pushing each result at most `max_hz` (5) a second as a binary event: the band and the label image.
- The dashboard draws the label image over the source camera's preview, each class in the Cityscapes palette at 40 % opacity, road highlighted; a legend lists the classes present.
- `scripts/models.tsv`: `vehicles/ovcs1/priv/models/ffnet_122ns_lowres.dlc`, sha256 `96e5a015e792c04526cb77ea48d46cfd12b3da390df243725ac719660f270f7c`, licence `BSD-3-Clause code (Qualcomm FFNet); weights trained on Cityscapes, non-commercial use only`, url `https://qaihub-public-assets.s3.us-west-2.amazonaws.com/qai-hub-models/models/ffnet_122ns_lowres/releases/v0.66.0/ffnet_122ns_lowres-qnn_dlc-w8a8.zip`, member `ffnet_122ns_lowres-qnn_dlc-w8a8/ffnet_122ns_lowres.dlc`.
- Docs: `docs/vision/README.md` (segmentation pipelines, the model and its licence; the QNN bindings are the `qnn` crate's), `docs/vision/api.md` (`segmentation:<name>`), `docs/vision/data_flow.md`, and the lists of Ports and crates that now miss `qnn` and `qnn_segment`: `vision/core/README.md`, `docs/vision/compute.md` (the Port table and what the Makefile builds for the VENTUNO Q), `docs/repository.md` (the `rust/` line).
- Tests: channel, `Previews.test.jsx` overlay, `elixir scripts/check_docs.exs`.

Checks before review: `cargo test`, `cargo clippy -- -D warnings` in `vision/rust`; `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` in `vision/core`, `vision/api`, `vehicles/ovcs1`; the dashboard's tests; `elixir scripts/check_docs.exs`.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decisions taken during the work:
- A point's cell follows OpenCV's pixel-centre convention: `(⌊(u − x + ½)·W/w⌋, ⌊(v − y + ½)·H/h⌋)`.
- On ROS 2 the label image has a sibling `<prefix>/<name>/camera_info` (image_transport's rule) whose intrinsics are the camera's mapped to the label grid, `K' = S·K`, so a consumer can project points into the labels; empty when the camera has no usable calibration.
- The road and off-road clouds are stamped with their stereo pair's capture time, the labels and their camera info with the frame's; a consumer syncing them needs an approximate-time policy.
- The dashboard acks each grid it draws; the channel holds at most one waiting grid per client. Road classes are drawn at 60 % opacity, the others at 40 %.
- The waits for a stereo pair are shared with detection (`CameraDepth`, `DepthQueue`, TASK-91).

Follow-ups: TASK-99 (QNN Port reopen), TASK-101 (unknown detection names), TASK-102 (class names on ROS 2).

Checked on the unit: pending (the VENTUNO was off).
On OVCS1 the pipeline is named `:scene`, as it labels the whole scene; its clouds are still `road` and `off_road`.
`VisionCore.Detection.server/2` is `VisionCore.Pipelines.server/2`, a `Registry` via tuple; `CameraDepth` is `VisionCore.CameraDepth` and `DepthQueue` is `VisionCore.CameraDepth.Queue`.
<!-- SECTION:NOTES:END -->
