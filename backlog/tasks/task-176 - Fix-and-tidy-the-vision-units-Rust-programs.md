---
id: TASK-176
title: Fix and tidy the vision unit's Rust programs
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-16T10:00:00Z'
labels:
  - vision
dependencies: []
ordinal: 112000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Rust programs in vision/rust (the capture, JPEG and NPU inference Ports under vision_core) fail silently in a few places, trust some input sizes and shapes they should check, and repeat the same Port plumbing in every crate. This task fixes the defects, moves the shared plumbing into framing, and splits and renames what has outgrown its file or name, one commit per change in a single PR.

Chosen behaviour for each fix:

- A Port that cannot answer a request answers it empty and exits 1, as hailo already does, so vision_core's PortBackend counts a failure and reopens it; an empty answer alone resets that count.
- v4l2_capture exits 0 only when the host closed the Port; a V4L2 ioctl failing with EPIPE exits 1.
- camera_capture requeues a cancelled request and treats a failed requeue as a capture failure, so the pool of requests never shrinks.
- Every request reader reports a read error instead of ending as if the host had closed stdin.
- Input that would make a program allocate or index past what it was given (a JPEG's frame size, a model's tensor shapes, an unknown quantisation encoding, a Hailo output order other than NMS by class) is refused with a message.
- Arguments that cannot work (--fps 0, an unknown sensor name, a tiny --outputs-max-hz) are refused at startup instead of falling back or overflowing.
- Refactors change no output: the pinned image digests stay as they are, except in the commits that fix the white balance and the shading grid.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each defect fixed in this task has a test that fails without its fix
- [x] #2 qnn_detect and qnn_segment answer a failed graphExecute empty and exit 1
- [x] #3 v4l2_capture exits 1 on a V4L2 EPIPE and 0 only when the host closed the Port
- [ ] #4 camera_capture keeps its four requests in flight through cancellations and stops with an error when one cannot be requeued
- [x] #5 jpeg_codec refuses a JPEG whose frame header exceeds the largest frame it accepts, before allocating
- [x] #6 framing provides the log, exit, request-size, request-reading and host-presence helpers every Port uses; no crate defines its own
- [x] #7 qnn/src/lib.rs, v4l2_capture/src/colour.rs and camera_capture/src/capture.rs are split into modules, each split a move with no other change
- [x] #8 The names that meant two things (output, map_plane, Stream, ControlValue, describe, cell_rows, resize_into, model_px, Timing::micros, lock, Frames::next) mean one thing across the workspace
- [x] #9 cargo fmt --check, cargo clippy --all-targets and cargo test pass on every crate, the qnn crates included, at every commit; camera_capture and hailo's device features pass clippy at the last one
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Stacked on feat/vision-hailo-shared (PR #385), which replaces hailo_detect with hailo. One commit per line, in this order.

Fixes, each with its failing test first:

1. v4l2_capture: exit 1 on a V4L2 EPIPE, 0 only once the host closed the Port
2. qnn_detect, qnn_segment: answer a failed execution empty and exit 1
3. camera_capture: requeue cancelled requests; a failed requeue ends the capture
4. camera_capture: refuse an --outputs-max-hz whose interval overflows the schedule
5. camera_capture, v4l2_capture: refuse --fps 0
6. v4l2_capture: refuse an unknown sensor name
7. v4l2_capture: build the pair's tone curve for the sensor's bit depth
8. v4l2_capture: apply --focus in single mode
9. v4l2_capture: keep highlights white under white balance gains below 1
10. v4l2_capture: map the shading grid onto the sensor crop
11. jpeg_codec: bound the frame size before decoding
12. qnn_detect: check output tensor shapes, not only byte counts
13. qnn: refuse a quantisation encoding other than scale and offset
14. hailo: refuse an output order other than NMS by class, and more than one input
15. Soundness: unsafe xioctl and zeroed; v4l2 buffer lifetimes; OwnedFd in Node; bounds-checked map_plane; JpegEncoder::encode on slices; narrow unsafe blocks with true SAFETY comments in qnn and hailo
16. hailo: rebuild when HailoRT changes
17. Hot path: pair_record without copies; tuning cache under AWB; white balance record only on change; qnn per-request buffers reused; band threads kept; phase lock without a sort; LTO

Shared plumbing in framing:

18. Writer::log, framing::exit_early, framing::MAX_REQUEST_BYTES
19. framing::Requests: one reader reusing its buffer and reporting read errors
20. framing::host_present, one JPEG quality threshold, detection::score_threshold, one poll helper in v4l2_capture

Splits (moves only), then renames and types, crate by crate:

21. qnn: lib.rs into tensor, profile, interface, dlc and power
22. v4l2_capture: colour into denoise and shading; pair loop into pair.rs; shared timing, exposure retarget and band setup
23. camera_capture: capture.rs into jpeg, dmabuf and stderr; run into named steps
24. hailo: Detector::open and run into named steps
25. jpeg_codec: the colour table into turbo.rs
26. Types: Exposure, FormatReply, one qnn::Quantisation, Rotation, Option outputs_max_hz, Request::check returning a Frame with Channels, PairStatistics, named execution stages, metadata slots, Vote, Letterbox sizes, grey_half on a RawFrame
27. Renames per the readability review
28. Comments: misplaced and stale docs, the missing whys
29. Tests: shared fixtures
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Left out, each for a reason that holds on the code:

- Persistent band threads: spawning them costs about 0.5 to 0.8% of a frame's conversion, and keeping them alive needs unsafe lifetime erasure, a new dependency or owned buffers.
- Tests of camera_capture's requeue and of hailo's NMS order check, so criteria 1 and 4 stay open: the capture loop drives libcamera directly, and a seam for it would need a trait over the camera; the NMS check compiles only with the device feature.
- enum Rotation: two call sites compare with 180, and Settings::set already refuses any other value.
- One device module in hailo: only the serve loop moved into a device-only module; nesting detect, hailo and segment under one more directory clarifies nothing.
- hailo refusing more than one input: open_vstreams already refuses it.

camera_capture refuses an --outputs-max-hz below 2.2e-10 while LibCamera's check_outputs_max_hz accepts any rate above 0; such a rate makes the program exit 2 at startup.

Only hardware can confirm: libcamera's request flow on a Pi 5, the V4L2 sensors' crop selections and the shading over them, the IMX477 pair's tone, the lens focus, the Hailo-8's NMS order check, and QNN's tensor shapes, quantisation and in-place binding on the VENTUNO Q.
<!-- SECTION:NOTES:END -->
