---
id: TASK-164
title: Say where each stereo pair check is measured
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-15T11:00:00Z'
updated_date: '2026-11-15T11:00:00Z'
labels:
  - vision
  - dashboard
dependencies: []
ordinal: 110000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The pair checks between the camera previews do not say whether a figure is before or after rectification and the row correction. On the OVCS Mini the Rows check showed a red "0.7 rows", "right lower · corrected 0.8": the 0.7 was what the calibration alone would leave (the measured −0.05 plus the 0.80 correction), while the matching sees −0.05, and the warning came from the band spread (2.29 rows, a rotation no row correction fixes), not from the 0.7.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Rule for every check: its value is what the stereo matching sees now, after every correction; the line under it says what was corrected and by how much; its hint says where it is measured.

- **Timing**: unchanged figures. Measured by `VisionCore.Stereo.Sync` in the Pairer on the capture times of every frame the cameras deliver, before pairing; nothing corrects it.
- **Rows**: `residual_rows`, the offset RowAlignment measures on the rectified images, which the correction has already moved, as a magnitude; `correction_rows`, how far `right_row_offset` moves the right image, and `correction_direction`, `up` or `down` (`nil` without a correction). The line is "right moved up 0.8 rows", or "no row correction". Issues `row_offset` and `large_row_correction`; its gauge takes only those two.
- **Rotation**, a new check split from Rows: `band_spread_rows`, the spread of the band offsets, `band_offset_rows`, and `turned`, `clockwise` or `counterclockwise`, the way the right image is turned against the left one on screen, from the least-squares slope of the measured bands. Off with fewer than two measured bands. Issue `uneven_rows` becomes `rotation_mismatch`, named as `focus_mismatch` and `brightness_mismatch` are. Points at the right camera, like Rows.
- **Focus** and **Brightness**: both from the Sharpness stage, on the rectified images, black borders left out; only their hints change.
- On a narrow screen the five checks sit two a row, and "Rotation" beside its value takes more than half the width: the values there are one size smaller, and the spread has one decimal, its threshold being a whole row.

Options considered:

- The line's direction bound to `offset + correction` (where the calibration alone leaves the right image), as before: on the Mini it reads "right lower" under a residual that sits higher, the before/after mix this task removes. Bound to the correction instead, which moves the right image one way, it reads as an action and does not flip with a residual near 0.
- "auto-corrected": `right_row_offset` keeps a value set by hand, or the one the automatic correction reached before it was switched off, so the line says the right image moved, whoever moved it.
- `offset_rows` kept signed beside a magnitude: a renamed `residual_rows` says it is what is left, and its sign flips with noise near 0. The top-level `alignment` keeps the signed offsets.
- A rotation line naming the lower edge ("right edge lower") collides with "right" naming the camera; clockwise does not.
<!-- SECTION:PLAN:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 `PairCheck` judges `rows` from the residual and the correction only, sending `residualRows`, `correctionRows` and `correctionDirection`
- [x] #2 `PairCheck` judges a `rotation` check from the band offsets, sending `bandSpreadRows`, `bandOffsetRows` and `turned`, raising `rotation_mismatch` past 1 row, off with fewer than two measured bands
- [x] #3 Each check's gauge reflects only its own issues
- [x] #4 The dashboard shows five checks, Rows' value the residual and its line the correction, Rotation's value the spread and its line the turn
- [x] #5 Each check's hint says where it is measured
- [x] #6 `docs/vision/channels.md` and the stage guides follow
<!-- AC:END -->
