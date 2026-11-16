---
id: TASK-169
title: Detect and segment on the OVCS Mini's left colour camera, on its Hailo-8
status: Done
assignee:
  - '@claude'
created_date: '2026-11-15T15:07:00Z'
updated_date: '2026-11-16T21:20:00Z'
labels:
  - vision
dependencies: []
ordinal: 116000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The OVCS Mini detects on the stereo pair's grey frames and does not segment. Its left colour camera (TASK-165) sends a 1152×648 JPEG at every frame. Detection should run on that colour image, and a road segmentation pipeline should run on it too, both on the Hailo-8, as OVCS1 runs both on its centre camera.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A detection pipeline on a JPEG camera output gets the frame in colour (RGB), decoded by jpeg_codec with libjpeg-turbo
- [x] #2 A segmentation pipeline segments a JPEG camera output's frames
- [x] #3 Detection and segmentation pipelines run together on one Hailo-8
- [x] #4 A :hailo_segmenter component runs a Cityscapes HEF and publishes its labels and road clouds as the QNN segmenter does
- [x] #5 The OVCS Mini detects and segments on its left colour camera; on the unit the stereo keeps 20 pairs a second and both pipelines' rates and the CPU are measured
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Approach (agreed):
1. Colour for the pipelines from the JPEG the camera already sends: jpeg_codec decodes a JPEG to RGB with libjpeg-turbo; a pipeline on a JPEG output gets colour (detection was given the luma, segmentation skipped the frame). Rejected for now: camera_capture sending a raw RGB output (TASK-170), costlier in the capture loop and through the Port, kept in case JPEG artefacts or decode time prove a problem.
2. One Hailo-8 for two networks: one Port opens the device once and serves the detection and the segmentation networks through HailoRT's scheduler; the one-pipeline claim on the device becomes a claim per network. Rejected: HailoRT's multi-process service in the Pi 5 system.
3. Segmentation model: DDRNet-23-slim compiled for the Mini's 1152x576 band (TASK-173); the model zoo's stdc1 at 1024x1920 cost the Pi 5 too much memory bandwidth. Cityscapes weights are non-commercial, as FFNet's.
4. The hailo Port decodes a JPEG frame itself, with the same libjpeg-turbo decode as jpeg_codec, so a colour frame crosses the Port as its JPEG rather than as its pixels.
One PR: colour from JPEG, the shared Hailo Port, the Hailo segmentation backend and :hailo_segmenter, the JPEG decode in hailo, its DMA and shared decode, the model's recipe and the Mini's composer.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Measured on the OVCS Mini (Pi 5, Hailo-8 on one PCIe Gen 3 lane), detection on every frame:

| Segment every | Depth | Cameras | CPU | NPU |
|---|---|---|---|---|
| never | 19.8 Hz | 30 fps | 72 % | 27 % |
| 3rd | 12.1 Hz | 23 fps | 93 % | 100 % |
| 6th | 16.7 Hz | 23–25 fps | 89 % | 79 % |
| 10th | 18.3 Hz | 25–26 fps | 84 % | 67 % |

STDC1 takes about 70 ms a frame on the device (Hailo lists 58 fps, on a wider PCIe link) plus 15 ms of resize and 10 ms of PCIe write; its input and output need no HailoRT format conversion, and neither PCIe ASPM nor the ultra performance power mode changes it. Decoding the JPEG in hailo took detection's input step from 125 ms to 2 ms with identical boxes. That traffic, not the CPU work, slowed the board: a thread writing 8 MB ten times a second slows the cameras and the depth as much.

With DDRNet-23-slim at 1152x576, the cameras at 25 frames a second and every pair matched, detection on every frame:

| Segment every | Depth | Detections | Segmentations | Cameras | CPU (of 400 %) |
|---|---|---|---|---|---|
| never | 25.0 Hz | 25/s | – | 25 fps | 218 % |
| 3rd | 25.0 Hz | 25/s | 8.3/s | 25 fps | 233 % |
| 2nd | 25.1 Hz | 25.0/s | 12.6/s | 25 fps | 249 % |
| 1st | 20.3 Hz | 23.6/s | 25.0/s | 25 fps | 377 % |

Those runs had the ROS 2 exporter dropping its messages, before a ROS 2 clock was on the network. Publishing (the pair's disparity, depth and points on every pair, the rectified image, the camera's JPEG), with detection on every frame and segmentation on every third, in a dark room (analogue gain 8, 39 ms exposures):

| ROS 2 exporter | Depth | Cameras | BEAM | stereo_match |
|---|---|---|---|---|
| publishing | 16.4 Hz | 21–23 fps | 99 % | 154 % |
| stopped | 20.8 Hz | 24 fps | 62 % | 175 % |

Depth is capped at 20 pairs a second: the cap changes nothing while the exporter publishes, and leaves room otherwise. The exporter's cost is TASK-174.

With depth capped at 20 and the ROS 2 exporter publishing, detection and segmentation on the same frames (results published per second counted):

| Detect / segment every | Inferences each | Depth | Dropped | CPU | Hailo-8 |
|---|---|---|---|---|---|
| 5th | 5.0/s | 20.0 Hz | 0 % | 44 % | 24 % |
| 3rd | 8.3/s | 20.0 Hz | 0 % | 53 % | 42 % |
| 2nd | 12.1/s | 16.5 Hz | 27.5 % | 92 % | 61 % |

Detection on every frame with segmentation on every third gave 15.7 Hz at 93 %. The composer detects and segments on every third frame.
<!-- SECTION:NOTES:END -->
