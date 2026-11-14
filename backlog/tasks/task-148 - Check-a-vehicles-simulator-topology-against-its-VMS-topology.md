---
id: TASK-148
title: Check a vehicle's simulator topology against its VMS topology
status: To Do
assignee: []
created_date: '2026-11-14 10:30'
labels:
  - simulator
dependencies: []
ordinal: 102000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A vehicle's `priv/can/simulator.yml` is its `vms.yml` the other way round, written by hand, and some frames it emits come from a `simulated/` definition in `ovcs_can` that repeats the shared one. Nothing checks that a frame the simulator emits has the CAN id and signal layout the VMS receives it with, or that a frame it receives is one the VMS emits, so the two can drift apart unnoticed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A test fails when a frame a vehicle's simulator emits differs in id or signal layout from the one its VMS receives on that network
- [ ] #2 A test fails when a vehicle's simulator receives a frame its VMS does not emit on that network
<!-- AC:END -->
