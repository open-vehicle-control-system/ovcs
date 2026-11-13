---
id: TASK-113
title: Take the stereo stages' settings from nx_stereo
status: Done
assignee:
  - '@claude'
created_date: '2026-11-11 13:30'
labels:
  - vision
dependencies:
  - TASK-61
ordinal: 61000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
nx_stereo computes every stereo stage, but each `VisionCore.Stereo.Stage.*` module restated its stage's settings for the vision parameters (type, range, description, live or build), next to nx_stereo's own defaults and checks, and delegated each callback by hand. Two definitions drift apart: nx_stereo's disparity stage gained `band`, `margin` and `fine_census`, and vision_core refused them on a stage restart.

Options considered:

- A: nx_stereo stages declare their settings (`NxStereo.Stage.settings/0`) and check them against that declaration; vision_core derives its parameters from it, and one `use VisionCore.Stereo.NxStage, stage: ...` defines a stage's callbacks.
- B: keep the declarations in vision_core and generate only the delegations.
- C: leave both definitions and update vision_core whenever nx_stereo changes a setting.

Chosen: A. A stage module keeps what is OVCS's: its dashboard text, the `Pair` fields it fills, and the calibration it reads.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 nx_stereo's stages with settings declare them, and `init/2` checks settings against the declaration
- [x] #2 vision_core's stage parameters come from those declarations; a setting of another type is passed to the stage as given
- [x] #3 Each vision_core stage module keeps only its text and what differs from nx_stereo's stage
- [x] #4 nx_stereo's and vision_core's suites pass, and OVCS pins nx_stereo at the change
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
The Disparity stage's parameters gain `band` and `margin` (build), from nx_stereo; `fine_census` and `matcher`, atoms, stay composer options. The stage modules shrink from 1,101 to 507 lines. Error messages for a refused value are nx_stereo's generic ones ("band must be one of [8, 16, 32, 64], got 12").
<!-- SECTION:NOTES:END -->
