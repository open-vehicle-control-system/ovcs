---
id: TASK-63
title: Move nx_stereo's SPIR-V out of priv
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-10 23:30'
labels:
  - vision
dependencies:
  - TASK-61
ordinal: 58000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
nx_stereo commits its compiled shaders in `priv/spirv`, but `NxStereo.Kernels` and `NxStereo.Vulkan` read them at compile time and embed them in their modules: nothing reads them at run time. A release still copies them, 77 files and 1.2 MB in every vision firmware, and the source `priv/` they make is why nx_stereo's Makefile replaces Mix's priv link with a copy.

Chosen: the binaries move to `shaders/spirv/`, beside their GLSL sources; the source tree has no `priv/`, so the build's `priv/` holds only `stereo_match`.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The SPIR-V binaries are in `shaders/spirv/`, where `mix nx_stereo.shaders` writes them, and nx_stereo has no source `priv/`
- [x] #2 A fresh build's `priv/` holds only `stereo_match`, and the Makefile no longer copies a source priv
- [x] #3 The package files, README and `docs/optimizing.md` name the new place
- [ ] #4 nx_stereo's suite passes with Vulkan and native, and OVCS pins nx_stereo at the merged change
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Spin42/nx_stereo#7. The Makefile still turns a build's priv from a link into a directory: a stray source `priv/`, such as the empty one `git mv` leaves behind, makes Mix link the build's priv to it, and `stereo_match` then lands in the source tree, shared by the host and every target. Build directories made before the change keep their copy of `priv/spirv` until cleaned (`mix deps.clean nx_stereo --build`).
<!-- SECTION:NOTES:END -->
