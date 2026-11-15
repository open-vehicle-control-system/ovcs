---
id: TASK-160
title: Cut the fixed per-pair overhead of OVCS1's GPU stereo
status: To Do
assignee: []
created_date: '2026-11-15T03:42:00Z'
labels:
  - vision
  - performance
dependencies: []
ordinal: 110000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Measured on OVCS1's vision unit (paths 3, 128 disparities, 728x544, live pipeline suspended, medians of 22 pairs, GPU time from the DRM fdinfo counter): send-to-reply is about 24.3 ms for 21.4 ms of GPU, so about 3.0 ms of overhead: about 0.6 ms allocating and uploading the two frames (a 16-byte upload alone takes 65-454 us: per-buffer allocation and mapping), about 2.2-2.4 ms inside IREE's call (allocations, command recording with memoization off, submit, fence wake-up). The Elixir and defn layers cost nothing; no input is copied before the call; one command buffer and one submit per call (about 38 dispatches); two pooled transient allocations within the 512 MiB slab. Off the send-to-reply path, the 3.47 MB output download costs about 1.9 ms of CPU and 0.25 ms of GPU per pair. Options: (1) reuse persistent device buffers for the frames, or one input for both frames (up to 0.3-0.5 ms, bit-identical; a write-in-place NIF in nx_iree or a new compiled module); (2) command-buffer memoization back on (gain unknown; compiler.ex documents wrong slice windows with memoized buffers on Vulkan); (3) smaller or host-cached readback (not bit-identical, or an IREE runtime patch); (4) split IREE's ~2 ms into fixed and per-dispatch cost with a 1-dispatch module first. nx_iree and nx_stereo are separate repositories. A probe that subscribes to an output must match {:"$gen_cast", message}: an unmatched subscription filled the unit's memory.
<!-- SECTION:DESCRIPTION:END -->
