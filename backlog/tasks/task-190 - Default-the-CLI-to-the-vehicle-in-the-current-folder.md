---
id: TASK-190
title: Default the CLI to the vehicle in the current folder
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-19T21:00:00Z'
labels:
  - cli
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The `ovcs` CLI knows a vehicle by its folder under `vehicles/` and asks which vehicle to use whenever none is named, even when it runs inside one. A vehicle package kept in its own repository may be cloned under any folder name, so its identity has to come from its `mix.exs`.

A vehicle package is a Mix project whose `lib/<app>.ex` declares `@behaviour OvcsVehicle` (OVCS's own packages depend on `ovcs_vehicle` too). It is identified by the `app:` of its `mix.exs` (module derived from it), and a command run from inside a vehicle package, at any depth, uses that vehicle when no argument names one. This is the first step of building vehicles from their own repositories.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A vehicle is identified by the `app:` of its `mix.exs`, not its folder name
- [x] #2 Run from inside a vehicle package (any subfolder), a command that takes a vehicle uses it when no argument names one
- [x] #3 A named vehicle still wins; outside any vehicle the picker still appears
<!-- AC:END -->
