---
id: TASK-97
title: Mount the VMS application partition at early boot
status: In Progress
assignee:
  - Codex
created_date: '2026-11-13 00:35'
labels:
  - vms
  - firmware
  - reliability
dependencies: []
---

## Description

The VMS erlinit override mounts `/dev/mmcblk0p3` as F2FS at `/data`. The pinned `ovcs_base_can_system_rpi4` v3.0.0-rc.1 layout declares `/dev/mmcblk0p7` as its application partition; partition 3 is a boot partition. The intended early application-data mount therefore fails.

## Acceptance Criteria

- [x] The evaluated target config mounts the pinned system's application partition at `/data`.
- [x] A host regression test evaluates target config without loading vehicle secrets.
- [x] Firmware formatting, host compilation, tests and strict Credo pass.

## Design

Correct the explicit mount to partition 7 and document its link to the pinned system layout. Keep the existing `/data` target and F2FS options. Validate configuration locally and firmware assembly in CI; no device is mounted, formatted, flashed or rebooted.
