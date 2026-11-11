---
id: TASK-65
title: Keep the OKdo C100's IREE runtime apart from the VENTUNO Q's
status: Done
assignee:
  - '@claude'
created_date: '2026-11-11 11:40'
labels:
  - vision
dependencies:
  - TASK-64
ordinal: 60000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The roomba's vision firmware on the OKdo Nano C100 restarted its VM a few seconds after every boot, without an error. nx_iree named its cross-build directories after the toolchain prefix, which the C100 and Arduino VENTUNO Q systems share, so the C100 firmware carried the IREE runtime built for the VENTUNO Q's Cortex-A78: 814 LSE atomics, `ldapr` and `sdot` instructions the C100's Cortex-A57 (ARMv8.0) cannot execute.

Chosen: nx_iree names those directories after `MIX_TARGET` too (Spin42/nx_iree#3), and OVCS pins it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The C100 firmware's `libnx_iree_runtime.so` has no ARMv8.1+ instruction outside libgcc's outline-atomic helpers
- [x] #2 The roomba's C100 boots and computes depth on Vulkan without restarting
- [x] #3 The VENTUNO Q firmware's runtime is unchanged and OVCS1's depth still runs at its camera rate
- [x] #4 OVCS pins nx_iree at the merged change
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Spin42/nx_iree#3. On the roomba's C100: depth at 29.97 Hz on the GPU, the stereo segment busy 59%, CPU about 30%, ROS 2 connected, firmware validated. On the VENTUNO Q the rebuilt runtime is byte-identical to the previous one; OVCS1's depth at 34 Hz with the cameras at 35 frames a second. A board's first build after the change compiles its runtime again, in the new directory.
<!-- SECTION:NOTES:END -->
