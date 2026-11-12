---
id: TASK-89
title: Fix the statements in the guides that disagree with the code or each other
status: To Do
assignee: []
created_date: '2026-11-12 12:00'
labels:
  - docs
dependencies:
  - TASK-88
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Statements in the published guides that contradict the code or another guide. Each needs checking against the code before it is changed.

Toolchain and libraries
- docs/troubleshooting.md: `elixir --version` is said to report OTP 28 and Elixir 1.19; `mise.toml` pins Erlang 29.1.2 and Elixir 1.20.4. The same entry says nothing checks host against target, while docs/toolchain_and_otp.md says Nerves stops the build on a major mismatch.
- docs/community.md, docs/glossary.md, docs/getting_started.md, docs/repository.md: the sideloaded libraries are given as four or five; `scripts/libraries.tsv` has seven. The in-tree list omits `ovcs_bus_gateway` and `ovcs_ui`.
- docs/community.md: the `firmware.yml` triggers listed do not match the workflow's path filter.
- docs/toolchain_and_otp.md: "Two consequences" introduces four items.

Reference vehicles
- The OVCS Mini's bridges are "three bridges" in docs/quickstart.md, "three bridge firmwares" in docs/framework.md and "two bridges" in docs/vehicle_package.md; docs/framework.md does not mention its vision unit.
- docs/hardware.md: the OVCS1 Controllers table lists a test controller (`0x73x`) the composer does not declare; `polo_drive` lists "dashboard" where the other tables say instrument cluster; the airbag is in the diagram but in neither parts table.
- docs/hardware.md gives the ROS bridge firmware as Raspberry Pi 4 or 5, docs/running_hardware.md as Pi 4 only.
- docs/first_vehicle.md: names two BEAMs although the default scaffold has bridges; the threshold test "while 70 °C streams" follows the 95 °C step without restarting the stream.
- docs/getting_started.md is titled "Setup" and linked as "Getting started".

VMS
- docs/vms/how_it_works.md: `trigger_action/2` "must return `:ok`", while the controller also handles `{:error, reason}`; `Cantastic.Receiver.subscribe/3` here, `/4` in docs/vms/add_a_component.md.
- docs/vms/dashboard_pages.md: "also serves `GET /api/firmware`" omits `/api/board`; its description promises the infotainment block types, which are in docs/infotainment/README.md.
- `libraries/ovcs_can/priv/can/components/nissan/leaf_aze0/0x1DA_inverter_status.yml`: `unit: N/m` for a torque, quoted in docs/can_frames.md.

Vision
- docs/vision/api.md: the status example disagrees with itself (`fps` 30.0 against `cameraHz` 34.8, `depthHz` 26.0 against 34.4, sharpness against `pair.focus`), and its rates match the VENTUNO Q, not the Pi 5 the page says it comes from.
- docs/vision/compute.md says a stage runs on CPU or GPU; docs/vision/api.md's `runsOn` also lists `npu`.
- docs/vision/data_flow.md: step 1 and the diagram leave out the VENTUNO Q's capture.
- docs/vision/README.md: the board comparison table sits under "The OKdo Nano C100".

Bus, bridges, ROS 2
- docs/bus/gateway.md and the `OvcsBusGateway` moduledoc: `:vehicle` is said to name a `<vehicle>` MQTT topic segment; topics are `ovcs/<node>/<source>/<name>`.
- docs/bridges/ros.md: stereo cameras are listed among the bridge's drivers, which has no stereo component; the `:rpi5` row of docs/bridges/README.md may be stale for the same reason.
- docs/glossary.md: NervesHub is given for the VMS firmware only; the vision firmware ships it too.
- docs/ros2/README.md, "Two transform buffers": the clause about a point cloud stamped after the newest `/tf` sample has no stated condition. "Nav2 1.5.1" is stated as fact here and as "when written" in the simulation guide.
- compose/local/simulation/README.md: the tree names `ros_bridge_config/1` where the prose names `ros_bridge_simulation_config/0`.
- docs/ros2/commands.md: "works three of these steps through" follows a four-step list.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each statement is checked against the code, then corrected or confirmed
<!-- AC:END -->
