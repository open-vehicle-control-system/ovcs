---
id: TASK-175
title: Declare each part's specifications once
status: To Do
assignee: []
created_date: '2026-11-15 21:10'
labels:
  - simulator
  - vms
  - vehicles
dependencies: []
ordinal: 105000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A vehicle's VMS composer and its simulator each declare facts about the same parts. OVCS1's simulator passes its simulated parts the gearbox ratios, the Leaf motor's rotor inertia, the steering ratio, the stepper's steps per column degree and the column's end stop, the iBooster's rod speed and full-travel deceleration, the mass and the pack voltage, while the VMS composer holds the inverter's torque limits and the column's software limit. Nothing ties the two, so they can disagree, and a vehicle pack for a GUI simulator such as Godot repeats them a third time.

Only the networks, controllers, pins and radio channels (`Ovcs1.Vms.Composer.wiring/0`), the OVCS Mini's drivetrain (`OvcsMini.Vms.Composer.drivetrain/0`) and the vehicles' geometry (`geometry/0`) are declared once and read by both sides.

A part's parameters fall in three kinds, each with one home:

| Kind | Examples | Home |
|---|---|---|
| The part's model, true of every car fitted with it | the Leaf AZE0's rotor inertia, the iBooster Gen2's rod travel, the Polo 9N ABS's speed encoding, a Traxxas servo's pulse range | the part's modules, shared by every vehicle |
| The installation, true of this car | wiring, the gearbox the motor drives through, steering ratio, steps per column degree, end stops, current and torque limits | the vehicle, once, read by the VMS component and the simulated part |
| The simulation | the key and radio scripts, estimates only the simulator uses | the simulator |

Values that are estimates stay estimates, marked as such, in the home their kind gives them, so a measurement corrects one place. Vehicle-wide physical facts the geometry does not hold, such as the mass and the driven axle, need a home in `OvcsVehicle` as well; a Godot vehicle pack can then be checked against it.

The design (where installation specs live, their shape, whether `wiring/0` grows into them, how the composers and the simulators read them) is agreed in this task before any code.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The design is recorded in this task and agreed before implementation
- [ ] #2 Each part's model specifications are declared in the part's modules and read from there by the VMS component and the simulated part
- [ ] #3 Each vehicle declares its installation once, and both its VMS composer and its simulator read it
- [ ] #4 Each vehicle's simulator declares only what is about the simulation
- [ ] #5 A vehicle's mass and driven axle have one home in the vehicle contract
<!-- AC:END -->
