---
id: TASK-115
title: Document how to simulate a vehicle's hardware component
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-13 10:30'
labels:
  - simulator
  - docs
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A vehicle runs in simulation only once every piece of hardware its VMS drives has a simulated component. How to write one, declare its frames and wire it into the vehicle is scattered across the ROS command paths guide, the simulation guide and the modules' docs, and no guide explains it as a procedure. The OVCS1 reference vehicle's inverter, brake booster, steering column and ABS each need one.

Options:
1. A section in the simulation guide (`compose/local/simulation/README.md`).
2. A page next to "Add a component" in the VMS guides.
3. A simulator folder under `docs/`, with an overview and a how-to page, under a "Simulator" sub-section of the index.

Chosen: 3. The simulation guide is about running Gazebo, and the simulator grows beyond it (a simulator without a GUI, fault injection), which gets its pages in the same folder.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 `docs/simulator/README.md` says what the simulator is made of and where each part is documented
- [x] #2 `docs/simulator/simulate_a_component.md` walks through writing a simulated component, declaring its frames, wiring it into the vehicle and testing it, with the OVCS Mini reference vehicle as the worked example
- [x] #3 The docs index lists both pages under a Simulator sub-section; the simulation guide, the ROS command paths guide, the ROS bridge guide, the repository layout and `simulator/core/README.md` link to the how-to instead of repeating it; the glossary defines a simulated component
- [x] #4 `elixir scripts/check_docs.exs` passes
<!-- AC:END -->
