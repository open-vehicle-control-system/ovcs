---
id: TASK-61
title: Move the stereo engine and its CPU backend to nx_stereo
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-10 16:00'
labels:
  - vision
  - refactor
dependencies:
  - TASK-57
ordinal: 56000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
After TASK-57, nx_stereo holds every stereo stage's Nx code and Vulkan shader, but the rest of the stereo engine is still in vision_core: each stage's computation half (its step, params, carried state and the constants it shares with the native code), the runner that executes a list of stages on a pair on the GPU or the CPU (Segment, NxSegment, NativeSegment, Matcher), and stereo_match, the Rust program that computes the stages on CPU cores (the Raspberry Pi 5's path). Each stage's three implementations, Nx, shader and Rust, and the parity tests that keep them equal, are therefore split across two repositories.

Since nx_stereo is sideloaded into libraries/ and built through a path dependency, working on it from OVCS needs no second repository's push or lock bump, so the engine can live in nx_stereo without slowing development. Moving it there makes nx_stereo a stereo engine with two backends, Nx (any Nx compiler, with Vulkan shaders) and native Rust on CPU cores, usable without OVCS. vision_core keeps the vehicle side: cameras, pairing, the live Pipeline and its supervisor, each stage's settings, dashboard text and checks, the exporters, status and the board benchmark.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The design below is agreed before implementation starts
- [x] #2 nx_stereo defines a stage behaviour for the computation (requires, provides, params, step, carry, device-only outputs, native kind and constants) and implements every default stage with it
- [x] #3 nx_stereo runs a list of its stages on a pair, compiled as one Nx function or in its native CPU backend, with carried state and two pairs in flight, as vision_core's segments do today
- [x] #4 stereo_match is nx_stereo's CPU backend, built by nx_stereo for the host and the Nerves targets when cargo is available, and optional: nx_stereo compiles and its Nx backend runs without a Rust toolchain
- [x] #5 nx_stereo's tests check the native backend against the Nx code for every stage, as vision_core's parity tests do today
- [x] #6 vision_core's stages keep their settings, dashboard text and checks and delegate the computation to nx_stereo; vision_core carries no segment runner, Matcher or stereo_match
- [ ] #7 The VENTUNO Q gives the same results and depth rate as before the move, and the Raspberry Pi 5 the same results and depth rate on its native path
- [ ] #8 The nx_stereo changes are merged into Spin42/nx_stereo and pinned in scripts/libraries.tsv
- [x] #9 nx_stereo's README presents it as a stereo engine for someone who has never seen OVCS: what it computes, the stages and how to chain them with the runner, the two backends (Nx with Vulkan shaders, native Rust on CPU) and when to pick each, installing with and without Rust, a complete example from a camera pair to depth and a point cloud, and how each stage's three implementations are kept equal
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Design, to be agreed before implementation.

Options considered:
- A. A stage behaviour and runner in nx_stereo that work on maps of tensors, with both backends; vision_core's stages wrap nx_stereo's and translate a Pair to and from tensors (chosen). One place for each stage's three implementations, its runner and its parity tests; costs a public stage API in nx_stereo.
- B. Move only the Rust algorithms into nx_stereo as a crate, keeping the runner, protocol and Port in OVCS. Rejected: the runner and the protocol would still span both repositories, and every stage change would still touch both.
- C. Move vision_core's whole stereo tree, the live Pipeline included. Rejected: cameras, supervision, settings and the dashboard are the vehicle's, and change with OVCS's needs rather than with the algorithms.

Split of today's NxStage callbacks:
- To nx_stereo (NxStereo.Stage): init from options and the geometry (sizes, calibration-derived scalars), requires, provides, params, step, carry, device_only, native_kind, native_constants.
- Stay in vision_core: summary, explanation, option_specs, options, set_option, finish (which writes the Pair), compute. A vision_core stage names the nx_stereo stage it wraps and delegates the computation callbacks to it.

Runner in nx_stereo: build(stages, geometry, backend options), run(pair tensors) and its asynchronous form for two pairs in flight, reload and per-stage times, on maps of tensors rather than VisionCore.Stereo.Pair. The Nx backend is today's NxSegment (packed transfer, published outputs in one download, inputs kept on the device); the native backend is today's NativeSegment and Matcher with stereo_match and its framing code.

Build: nx_stereo builds stereo_match with cargo through elixir_make, as nx_iree builds its runtime, for the host and for MIX_TARGET's toolchain; without cargo the native backend reports itself unavailable.

Questions to settle in the design: the names of the stage behaviour and the runner; whether the protocol between the BEAM and stereo_match changes or moves as it is; how vision_core's parameter groups map onto nx_stereo stages.

Decisions taken while implementing:
- The protocol with stereo_match moved unchanged; its configuration takes each stage's numeric build settings from a `native_settings/1` callback, which a vehicle's module wrapping a core stage delegates.
- The runner runs any module with `NxStereo.Stage`'s computation callbacks, so vehicle-defined stages keep working; vision_core's stages delegate those callbacks to their nx_stereo stage (`stereo_stage/0`), checked by a test.
- vision_core keeps thin Pair-based adapters (`VisionCore.Stereo.Segment`, `NxSegment`, `NativeSegment`, `Matcher`) over nx_stereo's, plus the board defn options.
- `framing` is copied into stereo_match as a module trimmed to what it uses; OVCS's crate stays for its other Ports.
- nx_stereo builds stereo_match when cargo is installed (`NX_STEREO_NATIVE=false` skips it), for the host or the Nerves target, into a build priv of its own.

Steps (separate PRs, each with its tests):
1. This design, agreed in the task.
2. nx_stereo: the stage behaviour, the default stages' computation and the Nx runner; vision_core's stages and pipeline wrap them, with no change in results.
3. nx_stereo: stereo_match as the optional native backend, with its build and the parity tests; vision_core uses it and drops its own. The README is rewritten for the engine as a whole.
4. OVCS: remove what moved, update the pin, check the VENTUNO Q and the Raspberry Pi 5.
<!-- SECTION:PLAN:END -->
