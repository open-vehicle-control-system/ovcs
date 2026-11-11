---
id: TASK-96
title: Keep the IMX477's shadow noise signed through the black level
status: To Do
assignee: []
created_date: '2026-11-12 00:30'
labels:
  - vision
dependencies:
  - TASK-90
ordinal: 75000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`v4l2_capture`'s single mode subtracts the black level with `saturating_sub` on each sample before any gain. Noise around black is therefore clipped at zero instead of averaging out, which raises the shadows' mean per channel; white balance and the colour matrix then amplify the channels unequally, and the shadows take a colour cast, blue under tungsten light, where white balance's blue gain is about 3. The chroma denoise cannot undo a bias that is already in the samples.

Keep the black-subtracted samples signed until after white balance and the colour matrix (as libcamera's pipeline does with its black level and offsets), and clip only at the contrast curve. Also refuse single mode on a sensor without a tuning, whose `black_level` default (256, a 12-bit value) is meaningless for it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A dark grey patch with noise around black keeps its mean grey through the colour path, within one level
- [ ] #2 On the OVCS1 unit under tungsten light, the shadows of the HQ camera show no colour cast
- [ ] #3 Single mode refuses a sensor without a colour tuning, naming it
<!-- AC:END -->
