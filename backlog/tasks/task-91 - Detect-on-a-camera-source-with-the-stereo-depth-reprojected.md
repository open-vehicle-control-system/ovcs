---
id: TASK-91
title: Detect on a camera source with the stereo depth reprojected
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-11 19:00'
labels:
  - vision
dependencies:
  - TASK-89
  - TASK-90
parent_task_id: TASK-87
ordinal: 70000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Step 4 of TASK-87: a detection pipeline whose source is a camera of its own (TASK-90), its boxes placed in 3D with the stereo depth reprojected into that camera's image, kept without a distance outside the stereo view. The camera publishes its image and `camera_info` on ROS 2 with a `set_camera_info` service, and its pose relative to the stereo pair comes from a calibration procedure. See TASK-87's Design.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A detector with `source: {:camera, name}` infers on that camera's frames, shrunk whole to the model's input
- [x] #2 Its boxes take their distance from the stereo pair captured closest in time, reprojected through the camera's calibration and pose; a box with no depth inside it is kept with `nil` 3D fields and its bearing
- [x] #3 The camera publishes its image, `camera_info` and a `set_camera_info` service on ROS 2; the pipeline publishes `Detection3DArray`, markers and `Detection2DArray` in the camera's frame
- [x] #4 The dashboard draws the pipeline's boxes on the camera's preview, without a distance where there is none
- [x] #5 A documented procedure produces the camera's pose relative to the stereo left camera
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Spec: TASK-87 (Sources, Depth on a camera source, ROS 2, Dashboard, Calibration). Builds on TASK-89's named pipelines and TASK-90's `:camera` component, `Frame.rgb` and `VisionCore.Camera.Unit`.

Global constraints:
- The stereo depth is in the rectified left optical frame (`Pair` `:depth`, millimetres per rectified left pixel). The camera's pose is the transform from that frame to the camera's optical frame: `p_cam = R * p_left + t`, `R` 3×3, `t` in metres.
- A frame is matched with the stereo pair whose left capture time is closest, within half the pair period; otherwise it has no depth.
- A detection without a distance has `nil` `:x`, `:y`, `:z`, `:width`, `:height`, `:depth`, and `:bearing`, `{azimuth, elevation}` in radians in the camera's optical frame (azimuth positive to the right, elevation positive up); its caption has no distance (`"person 0.62"`).
- A stereo-source pipeline behaves exactly as today.

Review focus, each pinned by a test in the owning task:
- A camera without a pose file: its pipeline runs and publishes every detection without a distance, with a warning logged once.
- No stereo pair within half a period (the stereo unit down or late): detections without a distance, not stale distances.
- A box at the image edge outside the stereo view: kept, with its bearing.
- Points behind the camera (`z_cam <= 0`) are never projected into the image.
- A camera frame larger or smaller than the calibration's size is scaled with `CameraCalibration.scale_to/3`, not projected with the wrong intrinsics.

#### Task 1: the camera's calibration, pose and ROS 2 topics.
- `:camera` component options `calibration` (a camera_info YAML: K, D) and `pose` (a YAML with `rotation`, 9 numbers row-major, and `translation`, 3 numbers in metres, from the rectified left optical frame to the camera's optical frame), and `calibration_store_dir`, as the stereo unit's: a calibration committed through `set_camera_info` is stored there and takes precedence.
- `VisionCore.Camera.Pose`: `load(path) :: {:ok, %Pose{rotation: [float()], translation: [float()]}} | {:error, term()}`.
- `Ros2.Exporter`: `cameras: []` options publish each named camera's image as `sensor_msgs/CompressedImage` on `<prefix>/<name>/image_raw/compressed` at `raw_image_max_hz`, its `camera_info` (R identity, P = K padded) on `<prefix>/<name>/camera_info`, a `set_camera_info` service on `<prefix>/<name>/set_camera_info`, reusing `SetCameraInfoServer`; and a static transform from the stereo left optical frame to the camera's `frame_id` from its pose, when it has one.
- `scripts/camera_pose.py`: from a directory of synchronised image pairs (stereo left raw, camera) of a chessboard, with both intrinsics, computes the pose with OpenCV's `stereoCalibrate` on fixed intrinsics, composes the left camera's rectification rotation, and writes the pose YAML; it prints the RMS reprojection error. Run with `python3 -I`.
- Tests: pose loading (valid, missing, malformed), the exporter's camera topics and service, the script's composition of the rectification rotation on a synthetic case.

#### Task 2: depth reprojection and placement.
- `VisionCore.Detection.Reprojection.project(pair :: Pair.t(), calibration :: CameraCalibration.t(), pose :: Pose.t(), stride :: pos_integer()) :: %{count: non_neg_integer(), points: binary()}` (native-endian f32 `u, v, z` triples; Nx cannot hold the empty result a pair with nothing in view gives), given a calibration or a lens prepared once by `lens/1`: every `stride`-th depth pixel with a valid depth, unprojected with the rectified left intrinsics, moved by the pose, kept when `z > 0`, projected with the camera's K and distortion: `plumb_bob` as OpenCV's `projectPoints`, `equidistant` as OpenCV's `fisheye::projectPoints` (θ = atan2(r, z), θ_d = θ (1 + k1 θ² + k2 θ⁴ + k3 θ⁶ + k4 θ⁸)), chosen by the calibration's `distortion_model`; any other model is refused at start. Default stride 2.
- `VisionCore.Detection.Fusion`: a box's distance on a camera source is the median of the projected points' `z` inside its central `depth_sample_fraction`; position and size unprojected with the camera's K, as for the stereo source.
- Tests against OpenCV (`evision`, as the stereo stages are tested): projection of known points with a non-trivial pose and distortion, for both models; a box over a plane at a known distance gets that distance; a fisheye point beyond 90° off-axis but in front of the camera (`z > 0` is not the test for a fisheye: θ < the lens's half field) projects, one behind it does not.
- `scripts/camera_pose.py` and the bearing of a detection without distance use the same model: OpenCV's `fisheye.stereoCalibrate` and `fisheye.undistortPoints` for `equidistant`.

#### Task 3: the camera source in the detection pipeline.
- Detector option `source`: `:stereo` (default) or `{:camera, name}`. With a camera source, `Pipeline` subscribes to the camera's frames and to the stereo pairs, keeps the pairs captured within `pair_wait_ms` of the newest without their images, queues the results waiting for their pair in capture order (bounded; new frames are skipped when it is full), matches each submitted frame by capture time, submits the frame's RGB tensor to the backend (the backends shrink it whole to the model's input, letterboxed), and places boxes with `Reprojection` and `Fusion`; outlines are the boxes' rectangles in the camera's pixels (no distortion pass); `:bearing` from the box centre through K.
- Backends `Qnn`, `Hailo` and `Stub` accept a `{h, w, 3}` image; QNN's model takes RGB, so a grey `{h, w}` image is expanded to 3 channels as today and an RGB one is passed as is.
- `ROS 2`: a camera-source pipeline publishes `Detection3DArray` and markers for detections with a distance and `vision_msgs/Detection2DArray` on `<prefix>/<name>/detections_2d` for those without, all in the camera's `frame_id`, and its image annotations on `<prefix>/<name>/annotations` over the camera's image.
- API and dashboard: the exporter controller's output for a pipeline names its `source` (`"left"` or the camera's name); the dashboard draws each pipeline's boxes on its source's preview; a detection without a distance is captioned without one.
- Tests: pipeline with a camera source and a `Stub` backend (matched pair, no pair, no pose), ROS 2 message encoding of `Detection2DArray`, `Previews.test.jsx` for a camera-source overlay.
- Docs: `docs/vision/README.md` (detection on a camera, the pose procedure), `docs/vision/api.md`, `docs/vision/data_flow.md`.

Checks before review: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` in `vision/core`, `vision/api`, `vehicles/ovcs1`; the dashboard's tests; `elixir scripts/check_docs.exs`.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
The waits for a stereo pair are shared with segmentation: `CameraDepth` keeps the pairs, `DepthQueue` queues the results, and the newest frame arriving while one is in flight is held and submitted on its reply. Distances on the unit wait for the `:center` camera's pose.
<!-- SECTION:NOTES:END -->
