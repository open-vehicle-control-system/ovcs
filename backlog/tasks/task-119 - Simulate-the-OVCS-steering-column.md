---
id: TASK-119
title: Simulate the OVCS steering column
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-13 11:50'
labels:
  - simulator
  - ovcs1
dependencies: []
ordinal: 79000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
OVCS1 steers through VmsCore.Components.OVCS.SteeringColumn. It powers a stepper driver through a relay on one generic controller, and sets the step frequency on an external PWM and the direction on a digital pin of another. It closes the loop on the Bosch LWS angle (lws_status, 0x2B0). With no simulated column, the angle never moves, the PID winds up and the simulated wheels never steer.

A simulated component reads the relay, the direction pin and the PWM request. While powered and enabled, it turns the column at the PWM frequency over its steps per column degree, clockwise while the direction pin is high, as the VMS drives it. It reports the angle on lws_status with the LWS's sign, which the VMS negates, and with the sensor ready, calibrated and trimmed. The wheels turn by the column angle over the steering ratio, and a clockwise column steers right.

lws_status leaves bits 24–28 undefined, which Cantastic refuses in an emitted frame. A static filler covers them; a received static signal is decoded and never checked.

Options for a column the PID drives the wrong way, or past the rack:
1. No limit: the angle grows until it wraps lws_status's 16-bit field, past ±3276.8°, and the VMS reads a jump.
2. An end stop at :column_limit_deg either side of centre, as the rack has.

Chosen: 2. A fault then shows as a column held at its stop, as on the vehicle.

The angular speed is saturated at 1020 °/s, the most its 8-bit field holds at 4 °/s per bit; Cantastic would otherwise wrap it.

The steps per column degree, the steering ratio and the column limit are options of the vehicle's configuration; none of them is measured on OVCS1.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 SimulatorCore.SimulatedComponents.OVCS.SteeringColumn turns the column from the VMS's relay, direction pin and step PWM, stops at its end stops, and steers the wheels through the steering ratio
- [x] #2 lws_status emits with the shared definition and reads back through it as the VMS receives it, ready and calibrated, tested with no CAN bus
- [x] #3 simulator/core tests pass, with format, credo, dialyzer and warnings as errors
<!-- AC:END -->
