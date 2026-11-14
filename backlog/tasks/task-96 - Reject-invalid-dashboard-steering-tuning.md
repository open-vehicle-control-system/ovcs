---
id: TASK-96
title: Reject invalid dashboard steering tuning
status: In Progress
assignee:
  - Codex
created_date: '2026-11-13 00:26'
labels:
  - vms
  - safety
  - validation
dependencies: []
---

## Description

The steering controller parses dashboard tuning inside its GenServer with raising Decimal constructors. Malformed values crash the controller; non-finite numbers enter the PID, and filter alpha values outside [0, 1] turn smoothing into extrapolation.

## Acceptance Criteria

- [x] Malformed and non-finite tuning values return an error without changing controller state.
- [x] Filter alpha stays within [0, 1] and deadband is non-negative.
- [x] Valid numeric strings, integers and floats update stored and active tuning.
- [x] The validation decision is pure and tested independently of CAN.
- [x] Core tests, formatting, compilation and strict Credo pass.

## Design

Use a pure tuning validator with Decimal's non-raising cast and existing parsing limits. Check finiteness before comparisons. Validate before mutating a running PID/filter, preserving all state on errors. Keep the existing signed PID gain semantics; vehicle-specific gain limits and validation of startup/internal bulk configuration are separate decisions.
