---
id: TASK-123
title: Start the simulator before the VMS
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-13 14:00'
updated_date: '2026-11-13 22:05'
labels:
  - simulator
  - cli
dependencies:
  - TASK-122
ordinal: 83000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`./ovcs run <vehicle> --simulate` starts the simulator runner first, waits for its ready line, then starts the VMS and the other BEAMs, so the VMS boots against hardware that already answers, as on the vehicle. Without `--simulate` nothing changes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 With `--simulate`, the VMS starts only after the runner is ready, and the run fails clearly if the runner never gets ready
- [x] #2 The OVCS Mini boots to `vms_status` OK under `--simulate`
- [x] #3 The CLI reference (`cli/README.md`), where `run` is documented, and the simulator docs describe the flag
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
The runner is the `simulator` role, spawned first as `<vehicle>-simulator`. `simulator/runner/build.sh` compiles it with the firmware projects. `run` waits up to 60 s for its `OVCS simulator ready` line, then spawns the other BEAMs; the runner exiting or staying silent stops `run` with an error. A vehicle without `simulator/0` is refused before anything is built. `attach` does not list the runner, which has no `RingLogger`.

`docs/running_hardware.md` covers boards, so the flag is documented in `cli/README.md`, where `run` is described, and in the simulator overview.

Live check on vcan0 and vcan1, OVCS Mini, `--simulate --no-addons`: the VMS started after the ready line and sent `vms_status` OK for the whole 60 s run, apart from its 1 s boot reset at 3 s. The Gazebo drive check (`OVCS_SIM=1`, unchanged by this task) passed twice: 3.82 m of 4.00 m commanded, /odom 0.0 % from ground truth.
<!-- SECTION:NOTES:END -->
