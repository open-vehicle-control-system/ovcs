---
id: TASK-95
title: Show the NPU's load and each pipeline's inference time
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-12 00:00'
labels:
  - vision
dependencies:
  - TASK-89
ordinal: 74000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Nothing measures how busy the accelerator is: the status gives the NPU's kind and whether its backends are available, not how much of each second it spends inferring. Several pipelines will share one NPU (TASK-87), and the OVCS1 reference vehicle's detection model is chosen by measuring the pipelines' rates on it (TASK-93), so the load has to be visible.

The Hexagon NPU is reached through FastRPC and exposes no load counter to Linux; HailoRT gives per-model utilisation only through its monitor service, which the unit does not run. Each detection Port therefore measures the accelerator time of each inference itself and returns it with the answer: `qnn_detect` from QNN's basic profiling (the accelerator's execute time, measured on the Hexagon), or the time around the graph's execution when profiling is unavailable; `hailo_detect` the time around the inference call (the device's work and the PCIe transfer). The status sums these over each tick into the accelerator's load, and the mean inference time of each pipeline.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 `qnn_detect` and `hailo_detect` return each inference's accelerator time with its boxes
- [ ] #2 The status's `npu` carries `load_percent`, the share of the last tick the accelerator spent inferring, summed over every pipeline on it, and each pipeline's mean inference time
- [ ] #3 The dashboard shows the load next to the NPU's kind and each pipeline's inference time in its Inference step
- [ ] #4 On the OVCS1 unit, the load and inference time of YOLOX on the Hexagon are read and recorded in `docs/vision/performance.md`
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Global constraints:
- A pipeline's inference time is the accelerator time its Port reports, not the time between submitting and receiving in Elixir; the Elixir side only sums and averages.
- The load is a percentage of the tick, clamped to 100, per accelerator kind: the Hexagon's load sums every QNN pipeline's time, the Hailo-8's its one pipeline's.
- A Port that reports no time (the stub, or a Port of an older build) leaves the load and inference time `nil`, never 0.
- Profiling must not slow inference measurably: QNN's basic level only, read per execution.
- Today's detection replies, their tests and the detection behaviour are otherwise unchanged.

#### Task 1: the Ports report each inference's accelerator time.
- `vision/rust/qnn` (or `qnn_detect` if the shared crate is not there yet): create a QNN profile handle at the basic level when the backend supports it, pass it to the graph's execution, read the accelerator execute-time event after each execution (in µs); fall back to the wall time around `graphExecute` when the profile cannot be created, and log once which one is used.
- `vision/rust/hailo_detect`: the wall time around the inference call (writing the input and reading every output of one frame).
- Both Ports add the time to the detection reply, as one field the Elixir backends decode; the framing of every other record is unchanged. Document the field where the replies are documented.
- Rust tests: the reply's encoding with the time; the QNN profile event selection on recorded event data (no device needed).

#### Task 2: the backends, the status, the JSON, the dashboard and the docs.
- `VisionCore.Detection.Backend.Qnn` and `.Hailo` decode the time and keep, per tick, the sum and the count of inference times; `Backend` gains a callback `inference_times(server) :: %{sum_us: non_neg_integer(), count: non_neg_integer()} | nil` that returns and resets them; `Stub` returns `nil`. Update the test fakes (`test/support/fake_hailo_detect.py` and the QNN fake) to send a time.
- `VisionCore.Status`: `npu: %{kind, state, load_percent: float() | nil, pipelines: %{name => %{inference_ms: float() | nil}}}`; asked within the snapshot's deadline like `available?/1`.
- `VisionApiWeb.StatusJSON`: `npu.loadPercent`, `npu.pipelines.<name>.inferenceMs`; `docs/vision/api.md`.
- Dashboard: the NPU entry's value reads `Hexagon 64 %` (kind and load) with `widest` `Hexagon 100 %`; its health is unchanged; each detection pipeline's Inference step shows its inference time; `hints.js` says what the load measures for each accelerator.
- `docs/vision/README.md`: one paragraph on what the load and inference time measure, per accelerator.
- Tests: backend accumulation and reset, status with one and two QNN pipelines and with the stub, JSON, the NPU entry and the Inference step.

Checks: `cargo test`, `cargo clippy --all-targets -- -D warnings`, `cargo fmt --check` in `vision/rust` (the QNN and Hailo crates may only build for their targets: check how `vision/core/Makefile` builds them and build what the host can); focused tests and `mix test --stale` in `vision/core` and `vision/api`; the dashboard's tests and build; `elixir scripts/check_docs.exs`. The controller runs the full suites and the on-unit reading.
<!-- SECTION:PLAN:END -->
