---
id: TASK-151
title: 'Name the ROS 2 exporter after where it sends: ZenohExporter'
status: In Progress
assignee: []
created_date: '2026-11-14T19:13:00Z'
labels:
  - vision
  - ros2
dependencies: []
ordinal: 104000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
PR 0 of the ROS 2 bag exporter, TASK-151 to TASK-156.
## Design

Problem: record the vision unit's ROS 2 output in a car, to review drives, build datasets and replay them in ROS 2 tools; started from the dashboard.

Options: a Rust MCAP writer behind a Port; an Elixir MCAP writer with OTP 29's `:zstd`; `ros2 bag record` on a laptop. Chosen: the Elixir writer — no new program, the messages the ROS 2 exporter builds are written in-process; the laptop option needs a laptop and Wi-Fi bandwidth in the car.

Decided: two exporters share the message builders, `VisionCore.Ros2.ZenohExporter` (network) and `VisionCore.Ros2.BagExporter` (files, ROS 2 · Bag in the dashboard). A recording is a rosbag2 folder of MCAP files (ROS 2 profile, `ros2msg` schemas, `cdr`), zstd chunks closed every second, files split at 2 GB, the calibrations and parameters in force as attachments. Presets built from the configuration: replay (uncompressed stereo, other cameras compressed, TF) and review (compressed images, depth, pipeline results, TF); a preset decides what is built. Clock per recording: system, since start, or automatic (default); it stamps log times and header stamps. Delivery queued with drops counted; the writer drops and counts when the disk cannot keep up. Storage: ext4 USB disks by UUID and the unit's `/data`, in a saved order, filled one after another, ejectable. Not in scope: other triggers than the dashboard, replay through the vision core's pipelines, other filesystems, automatic deletion.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 VisionCore.Ros2.Exporter is VisionCore.Ros2.ZenohExporter, id ros2_zenoh, named ROS 2 · Zenoh
- [ ] #2 Dashboard links with page=ros2 still open its page
- [ ] #3 No reference to VisionCore.Ros2.Exporter remains
<!-- AC:END -->
