---
id: TASK-93
title: Run OVCS1's detection and road segmentation on its HQ camera
status: To Do
assignee: []
created_date: '2026-11-11 19:00'
labels:
  - vision
dependencies:
  - TASK-90
  - TASK-91
  - TASK-92
parent_task_id: TASK-87
ordinal: 72000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Step 6 of TASK-87: the OVCS1 reference vehicle's composer declares the HQ camera and runs detection and road segmentation on it, its stereo pair computing depth only. The detection model is chosen by measuring both pipelines' rates on the NPU, a smaller YOLOX first. See TASK-87's Design.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 `Ovcs1.Vision.Composer` declares the HQ camera on Camera 2, the detector with the HQ camera as its source, and the road segmenter on it
- [ ] #2 The detector keeps the default name, so its parameter ids, channel and topics stay as they are
- [ ] #3 The HQ camera ships a nominal calibration until it is calibrated, and runs without a pose until one is measured
- [ ] #4 Both pipelines' rates on the VENTUNO Q are measured and recorded in `docs/vision/performance.md`
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Spec: TASK-87 (requirement 7). Builds on TASK-90 to TASK-92.

#### Task 1: the composer.
- `Ovcs1.Vision.Composer`'s target config: `{:camera, name: :hq, driver: VisionCore.Camera.V4L2Single, csiphy: 2, frame_id: "hq_optical", calibration: <priv>/calibration/hq.yaml, pose: <priv>/calibration/hq_pose.yaml, calibration_store_dir: "/data/vision/calibration"}`; `{:qnn_detector, source: {:camera, :hq}, dlc_path: …, score_threshold: 0.4}`; `{:qnn_segmenter, name: :road, source: {:camera, :hq}, dlc_path: <priv>/models/ffnet_122ns_lowres.dlc}`; the ROS 2 exporter's `cameras: [:hq]` and `segmentation: [pipelines: [:road]]`.
- `priv/calibration/hq.yaml`: nominal intrinsics for 2028 × 1520 from the 3.6 mm lens and the binned pixel pitch (3.1 µm): `fx = fy = 1161.3`, `cx = 1013.5`, `cy = 759.5`, no distortion. `hq_pose.yaml` is absent until measured, and the unit runs without distances on the HQ pipelines until then.
- `required_files` and `vehicles/ovcs1/test/vision_composer_test.exs` follow.
- `vehicles/ovcs1/priv/models/README.md` or the docs name the road model and its licence.

#### Task 2: measurements.
- On the unit, both pipelines' rates and the NPU's load with YOLOX, then with the smaller detector if Qualcomm AI Hub publishes one under Apache-2.0; the faster one that keeps detection above 5 Hz stays.
- `docs/vision/performance.md` records the rates; `docs/vision/README.md`'s OVCS1 worked example describes the HQ camera.

Checks before review: `mix test` in `vehicles/ovcs1`, `elixir scripts/check_docs.exs`; on the unit, the dashboard shows the HQ preview with boxes and the road overlay.
<!-- SECTION:PLAN:END -->
