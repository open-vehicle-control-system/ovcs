---
id: TASK-189
title: Fetch the OVCS Mini's segmentation model
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-18T13:50:00Z'
labels:
  - vision
  - models
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`OvcsMini.Vision.Composer` requires `ddrnet_23_slim_576x1152.hef`, DDRNet-23-slim compiled for the Mini's 1152 × 576 band. Hailo's model zoo does not publish it at that size, and building it takes Hailo's Dataflow Compiler and calibration frames, so a checkout without a copy could not build the Mini's vision firmware.

The HEF the Mini runs is hosted on the repository's release `models/ovcs-mini-ddrnet-23-slim-576x1152`, and `scripts/models.tsv` lists it with its sha256 and licence: DDRNet's code is MIT, its weights trained on Cityscapes are for non-commercial use only. `mise run fetch-models` downloads it with the others.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 `mise run fetch-models` downloads `ddrnet_23_slim_576x1152.hef` and verifies it against its sha256
- [x] #2 The hosted HEF is the one the OVCS Mini ran
<!-- AC:END -->
