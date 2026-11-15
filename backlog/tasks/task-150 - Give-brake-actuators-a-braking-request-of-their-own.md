---
id: TASK-150
title: Give brake actuators a braking request of their own
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-14 22:00'
labels:
  - vms
  - safety
dependencies: []
ordinal: 110000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`Bosch.IBoosterGen2` brakes on the negative half of its braking source's `:requested_throttle`: a brake actuator reads a throttle and interprets its sign, and `requested_braking_sources` names sources of a throttle. Braking shares the throttle's fate, so a source cannot stop driving while it keeps braking.

A negative `:requested_throttle` meaning "brake" is the framework's convention for a hand's single axis: `Vesc.MotorController` and `Traxxas.MotorController` drive and brake from it, and `OVCS.InputCurve` shapes both halves.

Options:
1. The sources that carry a hand's axis also publish `:requested_braking`, in [0, 1], and a brake actuator follows that. `:requested_throttle` keeps its [-1, 1] range for the motor controllers.
2. Split everywhere: `:requested_throttle` becomes [0, 1] and every motor controller, `OVCS.InputCurve`, `OVCS.RosVelocityCommand` and both reference vehicles consume a separate braking request.
3. Keep the convention and document it on the iBooster.

Chosen: 1. The brake actuator gets a request that means what its name says, without reworking the path the OVCS Mini reference vehicle drives on. The request is carried twice, as the throttle's sign and as `:requested_braking`, until 2 is done.

- `VmsCore.NormalisedRequest.braking/1` gives the braking a signed request asks for: the magnitude of its negative half, held to [0, 1].
- `OVCS.RadioControl.Throttle` and `OVCS.RosActuatorCommand.Throttle` publish `:requested_braking` from it, with no dead zone: `:radio_braking` keeps its threshold, the request does not get one.
- `Bosch.IBoosterGen2` follows the `:requested_braking` of its braking source, holds it to [0, 1] and no longer reads a throttle. It still publishes the request it applies under its own name.
- A braking source that publishes no `:requested_braking` (`OVCS.InputCurve`, `OVCS.RosVelocityCommand`, `OVCS.ThrottlePedal`) brakes nothing.

The stale-input policy does not change: the ROS braking request expires to zero with the throttle. Braking on link loss is TASK-23 and TASK-24's.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 `NormalisedRequest.braking/1` is zero for a request at or above zero, its magnitude below, and at most one
- [x] #2 `OVCS.RadioControl.Throttle` and `OVCS.RosActuatorCommand.Throttle` publish `:requested_braking`; the ROS one goes to zero when the command goes stale
- [x] #3 `Bosch.IBoosterGen2` follows the `:requested_braking` of its braking source only, ignores `:requested_throttle`, and zeroes the request when no source is named
- [x] #4 `Bosch.IBoosterGen2` holds a request outside [0, 1] to that range
- [x] #5 The radio's braking under `:radio` is unchanged on the OVCS1 reference vehicle: the same rod target for the same trigger position
- [x] #6 The guides and moduledocs name `:requested_braking` and the components that publish it
<!-- AC:END -->
