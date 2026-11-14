---
id: TASK-139
title: Solve a camera's pose relative to the stereo pair from the dashboard
status: To Do
assignee: []
created_date: '2026-11-13T18:40:00Z'
updated_date: '2026-11-14T01:04:00Z'
labels: []
dependencies: []
ordinal: 96000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A camera of its own takes its detections' distances from the stereo depth projected into it, through its pose file (center_pose.yaml on OVCS1). Today the pose is measured off the unit: VisionCore.Camera.PoseCapture writes image pairs from the IEx shell, scripts/camera_pose.py solves them on a workstation, and the file is copied into the vehicle package. Solve it on the unit, from the Calibration page, from views of the board seen by the stereo left camera and the camera together.

Design (proposed, to agree before implementation; a pull request of its own):

Target. Each camera of its own on a unit with a stereo pair gains a third calibration target beside its lens: its pose, id <name>-pose, kind pose, listed in the calibrations collection and in the menu as '<Name> camera position'. It is offered once the stereo pair and the camera both have a calibration, since the solve holds both.

Session. The existing session runs on it. Detection looks for the board in the stereo left camera's raw frame and in the camera's frame captured closest to it in time, within half a stereo pair period, the rule PoseCapture uses. A view counts when both see the whole board. Coverage is the session's, measured in the camera's image, with the same four gauges.

Solve. OpenCV stereoCalibrate between the left camera and the camera, both intrinsics held (CALIB_FIX_INTRINSIC), each at the size its frames have, the stored intrinsics scaled to it. It gives the rotation and translation from the left camera's unrectified frame to the camera's; the pose file holds them relative to the rectified left frame, so the left rectification rotation is applied, as scripts/camera_pose.py does. The result shows the reprojection error, with the verdict thresholds of a calibration, and the translation in millimetres, to check against a ruler.

Commit. VisionCore.Camera.Pose gains a store path beside the built-in one, as a calibration has: a commit writes <store>/camera_<name>_pose.yaml whole or not at all, and a reset removes it. The consumers of the pose (the camera depth reprojection of the detection and segmentation pipelines on that camera) read it when they start, so a commit restarts those pipelines, which takes under a second and leaves the stereo unit running. The change is published like a calibration's.

Kept poses. The library keeps them as it keeps calibrations: a calibration_poses table (calibration_id, r00..r22, tx, ty, tz, rms_px), one row per kept pose, the calibrations row carrying the name, origin, board and views.

API. No new route: the calibrations collection lists the pose targets, with rotation and translation as attributes; a session and a reset name one as their calibration relationship; saved-calibrations and calibration-selections work on them unchanged.

Options considered: keeping the script (rejected: needs a workstation, file copies and a firmware build to try a pose); solving the camera's intrinsics and pose in one session (rejected: the pose needs views in the overlap of three cameras, the lens needs views across the whole image, and one session would do both badly); taking the pose from the stereo depth and detected board plane instead of the left image (rejected: it adds the depth's error to the pose).

Open points for agreement: whether a pose commit may restart the camera's pipelines by itself (proposed: yes); whether PoseCapture and scripts/camera_pose.py stay as an offline path (proposed: remove both once the page is verified against them on one unit).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Design agreed and recorded in this task
- [ ] #2 A camera's pose is solved and committed from the Calibration page, on a unit
- [ ] #3 The solved pose agrees with scripts/camera_pose.py on the same views
<!-- AC:END -->
