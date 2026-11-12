---
id: TASK-87
title: Run several inference pipelines, each on a chosen source
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-11 18:00'
labels:
  - vision
dependencies: []
ordinal: 66000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A vision unit runs at most one inference pipeline: object detection on the stereo pair's rectified left image, with one backend and one model. Its processes are singletons registered under their module names (`VisionCore.Detection.Supervisor`, `Pipeline`, `Live`, each backend), its output is the single `:detections` of `VisionCore.Exporter`, its parameters are the `detection.*` group, its API channel is `"detections"`, and its ROS 2 topics are `<prefix>/detections`, `<prefix>/detections/markers` and `<prefix>/left/detections`. A unit cannot run road segmentation next to object detection, nor detect on a camera other than the stereo left one.

The status bar's `Hailo` entry (`vision/dashboard/src/status.js`, the `hailo` field of `VisionCore.Status` and of the status JSON) only knows the Hailo backend: on the OVCS1 reference vehicle, which detects with `VisionCore.Detection.Backend.Qnn` on the VENTUNO Q's Hexagon NPU, it reads `absent` while the NPU runs.

This is a parent task. The work ships as the sequence of tasks under Plan, each its own PR.

### Requirements

1. The status bar shows the unit's accelerator as `NPU`, with its kind as the value (`Hailo-8`, `Hexagon`), coloured by its health; a unit without an accelerator shows `none`, muted.
2. A vehicle's vision composer declares any number of inference pipelines. Each has a name, a kind, a source and a backend with its model. The choice is made in the composer, fixed at build; nothing selects them at runtime.
3. Two kinds:
   - **Object detection**, as today: boxes placed in 3D with the stereo depth.
   - **Road segmentation**, semantic: each pixel of the source gets a class. It is published for a navigation stack and shown on the dashboard. Wiring it into Nav2 is out of scope.
4. A source is either the stereo pair's rectified left image, as today, or a camera of its own declared by the vehicle. Road segmentation takes a camera source only: the stereo images are grey, and road models are trained on colour.
5. On a camera source, depth comes from the stereo pair: the depth map is reprojected into that camera's image through the camera's calibration and its pose relative to the stereo left camera. A detection outside the stereo pair's view, or with no valid depth, is kept without a distance: its box and its bearing, no 3D position.
6. The camera source's frame is shrunk whole to the model's input; no tiling.
7. The OVCS1 reference vehicle gains a Raspberry Pi HQ Camera (IMX477) on the VENTUNO Q's Camera 2, with a wider view than the stereo pair, and runs object detection and road segmentation on it, in colour. Its stereo pair then computes depth only: detection moves from the stereo left image to the HQ camera. The detection model may be lighter than today's YOLOX, to leave the NPU room for the road model. The OVCS Mini reference vehicle keeps its two cameras and its single detector.
8. The road model may carry a non-commercial licence (most are trained on Cityscapes). It is fetched by the operator with its licence printed, as YOLOv8n's AGPL is today; no permissive default is required.

### Design

**Named pipelines.** A pipeline is a component instance with a `:name` (an atom), started under its own supervisor, as `VisionCore.Detection.Supervisor` is today: a crash loop in one stops at its own budget and leaves the stereo unit and the other pipelines running. Its processes register under names derived from the pipeline's name rather than their modules. The name keys the output (`{:detections, name}`, `{:segmentation, name}`), the parameter group (`<name>.*`), the API channel (`"detections:<name>"`, `"segmentation:<name>"`), the ROS 2 topics (`<prefix>/<name>/…`) and the dashboard's pipeline box. A pipeline declared without a name is named `detection` and keeps today's ids exactly: its parameter ids and saved values, the `"detections"` channel, and the `<prefix>/detections`, `<prefix>/detections/markers` and `<prefix>/left/detections` topics.

**Pipeline names.** An atom matching `^[a-z][a-z0-9_]*$`, none of the names reserved by `VisionCore.Detection`: the stereo pipeline's (`stereo`), the first segments of the topics the unit publishes directly under its ROS 2 prefix (`left`, `right`, `depth`, `disparity`, `points`, `detections`, `live`) and the Hailo-8 claim's (`device`). Two pipelines whose process names would coincide are refused at start. Cameras of their own share the `<prefix>/<name>/` namespace and follow the same rule.

**Backends.** Each pipeline starts its own backend process, with its own Port and model. On the Hexagon, QNN opens one context per model on the HTP. On the Hailo-8, `hailo_detect` opens its own vdevice, and sharing the device between two processes needs HailoRT's multi-process service; whether the Pi 5's Nerves system can carry it is not verified. A Hailo unit therefore starts a claim process, `VisionCore.Detection.Backend.Hailo.Device`, as its first child, before its backend: a second Hailo unit cannot start its claim and is left down with `the Hailo-8 already serves another pipeline` logged, until a task makes the Hailo-8 serve two models. The backend contract stays asynchronous and lossy, one frame in flight per backend.

**Sources.** A pipeline subscribes to its source through `VisionCore.Outputs`: the stereo pairs, as today, or `{:camera_frame, name}` of a camera component. A frame from a camera source is matched with the stereo pair captured closest in time, within half a pair period; a frame without such a pair is inferred on and published without distances.

**Depth on a camera source.** The stereo depth map's points, in the rectified left optical frame, are transformed by the camera's pose relative to that frame and projected through the camera's intrinsics and distortion. A box's distance is the median of the projected points that fall inside its central fraction, as `VisionCore.Detection.Fusion` takes it from the depth map today; a box with none is kept with `nil` 3D fields. Only the points are projected, never a dense depth image: the boxes and clouds need nothing more.

**Road segmentation.** The backend returns a grid of class ids over a band of the submitted image. Each stereo point reprojected into the camera's image takes the class of the cell it lands in. The pipeline publishes the label image and two point clouds in the stereo left frame, road points and off-road points, so a costmap can mark the second and clear with the first. Which classes count as road is a pipeline option. The backend is QNN, on the Hexagon: `qnn_detect` replies with boxes only, so segmentation needs its own Port or a second output mode of it.

**ROS 2.** Detections with a distance go out as today, under the pipeline's topics. Detections without one go out as a `vision_msgs/Detection2DArray` on `<prefix>/<name>/detections_2d`, in the source camera's frame. A segmentation pipeline publishes its label image as a `sensor_msgs/Image` (`mono8`, class ids) and its clouds as `sensor_msgs/PointCloud2`. A camera source publishes its image and `camera_info`, with a `set_camera_info` service, as each stereo side does.

**Status.** The status JSON's `hailo` field becomes `npu`: the accelerator's kind and its state (`running`, `failed`), or `null` on a unit without one; `docs/vision/api.md` documents it. With several pipelines on one accelerator, it reads `failed` when any of their backends is unavailable.

**Dashboard.** Each pipeline is a box in the menu's pipelines and an overlay on its source's preview: boxes, or the label image as a translucent colour per class. A camera source gets its own preview.

**IMX477 on the VENTUNO Q.** OVCS1's `/boot/cameras.cfg` already names the IMX477 on Camera 2 (`imx296-imx296-imx477`), which only shows the configuration string exists: whether its driver probes on this board is the first thing to check. It then needs its CSIPHY routing in `VisionCore.Camera.Camss`, which routes only the stereo pair's two connectors, and its format in `v4l2_capture`, which knows the IMX296 and IMX708. It captures in its 2×2 binned mode, 2028 × 1520, demosaiced to colour, which loses nothing once shrunk to the model's input.

**Calibration.** The camera source needs its intrinsics and its pose relative to the stereo left camera. Its intrinsics are committed through its own `set_camera_info` service, as each stereo side's. Its pose comes from synchronised chessboard pairs of the left camera and the camera source (`VisionCore.Camera.PoseCapture`), solved offline by `scripts/camera_pose.py` with OpenCV's `stereoCalibrate` (or `fisheye.stereoCalibrate`) on fixed intrinsics. The pose is stored in a pose file of its own, the `:camera` component's `pose:` option, expressed in the rectified left frame by composing the left camera's rectification rotation.

### Options considered

- **Run every model in one pipeline and one backend.** Fewer processes, but one failing model takes the others down, and the outputs, parameters and topics of two kinds would share one name. Rejected.
- **One backend process owning the Hailo-8 and serving every Hailo pipeline**, through HailoRT's model scheduler in one process. Lets the OVCS Mini run two models, but no reference vehicle needs two Hailo models now, and it ties those pipelines' failures together. Deferred.
- **Road segmentation on the stereo left image.** Available on both vehicles sooner, but on grey images. Rejected.
- **Choose the source and model from the dashboard at runtime.** Deferred: the composer is enough for now, and a runtime switch would restart backends and models on a live unit.
- **Reproject the depth into a dense depth image aligned with the camera.** Costs a full reprojection and hole filling per frame for what the boxes and clouds do not use. Rejected for now.
- **Tile the camera source's frame to use its full resolution.** Multiplies inferences per frame by the number of tiles. Deferred.
- **Drop detections without depth, as the stereo source does.** On a camera wider than the pair, it would discard everything at the sides of its image. Rejected for camera sources.

### Risks

- **IMX477 capture on the VENTUNO Q.** The sensor is declared but has never been captured through CAMSS on this board, and its driver may not probe.
- **Road model on the Hexagon.** The model has to convert to a DLC that QNN runs on the HTP, in w8a8 as YOLOX is; Qualcomm AI Hub publishes Cityscapes models (FFNet, DDRNet) that may serve as is.
- **Load on the HTP.** OVCS1 runs two models on one NPU; each pipeline's rate drops as they share it. A lighter detector, such as a smaller YOLOX (Apache-2.0), is measured against today's YOLOX in step 6.
- **Sync.** The IMX477 is rolling shutter and not triggered with the pair; its frames are matched to pairs by timestamp only.

### Plan

Each step is its own task and PR:

1. TASK-88: the NPU and its kind in the status bar and the status JSON.
2. TASK-89: named detection pipelines: several per unit, each with its own backend and model.
3. TASK-90: the IMX477 on the VENTUNO Q's Camera 2, in colour; it starts by checking that the driver probes.
4. TASK-91: a camera as a pipeline's source: its calibration and pose, depth reprojection, detections without a distance, its preview and ROS 2 topics.
5. TASK-92: road segmentation as a second pipeline kind on the Hexagon, with its model, label image, road and off-road clouds, ROS 2 topics and overlay.
6. TASK-93: the OVCS1 reference vehicle's HQ camera with detection and road segmentation on it, detection moved off the stereo left image, and the detection model chosen by measuring both pipelines' rates on the NPU.

Steps 1, 2 and 3 depend on nothing. Step 4 depends on 2; it is developed on the host with a USB camera through `VisionCore.Camera.GStreamer`, and runs on the VENTUNO Q once 3 lands. Step 5 depends on 4; on the host it runs with a stub backend returning fixed labels, and on the VENTUNO Q with its model. Step 6 depends on 3, 4 and 5.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The status bar shows `NPU` with the accelerator's kind, and `none` on a unit without one; the status JSON carries it as `npu`
- [x] #2 A composer declares several named pipelines, each with its kind, source, backend and model, and a failing pipeline leaves the stereo unit and the others running
- [x] #3 A unit with one unnamed detector keeps its parameter ids, its `"detections"` channel and its ROS 2 topics
- [x] #4 A detection pipeline on a camera source places boxes with the reprojected stereo depth, and publishes those outside the stereo view without a distance
- [x] #5 A road segmentation pipeline on a camera source publishes its label image and its road and off-road clouds on ROS 2, and the dashboard overlays it on the camera's preview
- [x] #6 The OVCS1 reference vehicle runs detection and road segmentation on an IMX477 on the VENTUNO Q's Camera 2, and its stereo pair computes depth only
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Checked on the OVCS1 unit at 30 fps: every stereo and `:center` stream, `:objects` and `:scene` at 30 a second. Distances and clouds on a camera source wait for the camera's measured pose.
<!-- SECTION:NOTES:END -->
