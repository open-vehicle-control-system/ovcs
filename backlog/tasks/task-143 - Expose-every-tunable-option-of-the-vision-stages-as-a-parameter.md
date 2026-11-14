---
id: TASK-143
title: Expose every tunable option of the vision stages as a parameter
status: In Progress
assignee:
  - '@loic'
created_date: '2026-11-14T00:18:00Z'
updated_date: '2026-11-14T00:26:00Z'
labels:
  - vision
dependencies: []
ordinal: 99000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Some options a stage reads are set only by the composer and cannot be tuned at runtime, and nothing checks that a change to an exposed parameter reaches the running stage.

Design: list the options each stage of each pipeline reads against the parameters registered; expose the tunable ones through the stage's existing parameter declaration; verify each exposed parameter on a unit by setting it over the API and reading its effect.

### Design notes

**A saved value lost when the parameter could not be read at declaration.** The registry took the first value it read as the default. Read after a saved value was applied, that value became the default, and the next save deleted its row as "back at the default". Chosen: the registry remembers the ids it has set, and a value read from then on is never a default. Such a parameter has no default while the registry runs: reset and discard leave it alone. Not chosen: forgetting those ids when the owner declares again, which cannot tell an owner that restarted from one whose values survived.

**An uncalibrated stereo unit had no parameters.** `VisionCore.Stereo.Parameters` takes `pipeline: nil` and declares the cameras' group alone; the unit starts it after its two drivers. Not chosen: a second declaring process for the cameras in every unit, which would change the owner of the cameras' group on a calibrated unit for no gain.

**A camera of its own had no parameters.** `VisionCore.Camera.Parameters` holds the declaration of a driver's controls, taken out of `VisionCore.Stereo.Parameters`, which now calls it for a driver whose one set of controls drives both cameras. `VisionCore.Camera.Unit` starts it after the driver, `:rest_for_one`, so a restarted driver gets its saved values again. The group is `<name>.camera`, a component of a pipeline named after the camera, at position 50: after the stereo steps, before the inference pipelines'. A camera feeds several pipelines, so it is not a step of one of them. The automatic modes are a table (`exposure_us` and `analogue_gain` under `auto_exposure`, `red_gain` and `blue_gain` under `awb`), applied only when the driver has the mode. A driver lists what it fixes at start through the optional `c:VisionCore.Camera.fixed_settings/1`.

**Detection and segmentation settings fixed at start.** Each pipeline declares its settings once, as specs with a type, a range and a default (`VisionCore.Settings`), checked at start and at each change, so a declared type no longer follows how the composer spells a value. `band_top` is a double from 0 to 1, where 1, the default, puts the band at the image's bottom: `band/3` already clamped the top there, so `nil` needed no type of its own. The pipelines declare from `handle_continue`, after `init/1`: the registry reads a group's values from the pipeline (`values:`), and sets through it, only once it runs. Not chosen: an ETS or persistent_term copy of the settings, a second source of truth to keep in step.

**Pairing tolerance and row correction.** `pair_tolerance_ms` is the one setting of a new component group, `<prefix>.pairing`, declared while the pairer runs. The row correction's `window`, `threshold_rows`, `gain` and `max_rows` are parameters of the stage it moves, `auto_row_offset_<setting>`, after that stage's own.

**Left fixed at start, listed as build parameters.** What is an argument of a program or compiled into the stereo function: the models, `score_threshold`, the QNN power vote (`performance`, `rpc_polling_us`), `classes`, `infer_timeout_ms`, `road_classes`, a camera's frame rate, sensor mode and outputs, and the stereo build settings already listed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Every tunable option a stage reads is a registered parameter, documented in the tuning guide
- [ ] #2 Each exposed parameter changed over the API reaches the running stage, checked on a unit
<!-- AC:END -->
