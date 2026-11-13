---
id: TASK-117
title: Simulate the Nissan Leaf AZE0 inverter
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-13 11:50'
labels:
  - simulator
  - ovcs1
dependencies: []
ordinal: 77000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
OVCS1 drives through a Nissan Leaf AZE0 inverter. Its VMS sends vms_torque_request (0x1D4) and reads inverter_status (0x1DA) and inverter_temperatures (0x55A). The inverter's output voltage also ends precharge in VmsCore.Components.OVCS.HighVoltageContactors, which waits for it to reach its required voltage before closing the main positive relay. Without a simulated inverter, OVCS1 neither precharges nor moves in simulation.

A simulated component reads the torque request and the relays on its generic controller's digital pin request, moves the vehicle by the torque through the reduction ratio, and reports its status and temperatures.

When the output voltage is present:
1. while any contactor pin is requested;
2. while the main negative relay and either the precharge or the main positive relay are requested, as the high voltage circuit closes.

Chosen: 2. Option 1 reports a voltage with the main negative relay alone, which no real circuit gives, so a precharge fault with the precharge relay stuck open would go unseen.

When it applies torque:
1. while its power relay is requested;
2. while its power relay is requested and it has its output voltage.

Chosen: 2. An inverter without high voltage makes no torque.

0x1DA and 0x55A leave bits undefined, so Cantastic refuses to emit them. A static filler covers each gap; a received static signal decodes as its raw value and is never checked.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 SimulatorCore.SimulatedComponents.Nissan.LeafAZE0.Inverter reads vms_torque_request and its controller's digital pin request
- [x] #2 Its output voltage is the pack's while the main negative relay and the precharge or main positive relay are requested
- [x] #3 It accelerates the vehicle by the requested torque through its reduction ratio only while powered and with high voltage, and reports that torque as its effective torque
- [x] #4 inverter_status and inverter_temperatures emit with the shared definitions and read back through them as the VMS receives them, tested with no CAN bus
- [x] #5 simulator/core tests pass, with format, credo, dialyzer and warnings as errors
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
vms_torque_request carries a checksum signal, which the pinned Cantastic cannot decode on reception. The simulator receives the frame only once Cantastic decodes checksum signals (open-vehicle-control-system/cantastic#17) and scripts/libraries.tsv pins that version. The tests hand the component the decoded signals directly.

The output voltage is present as soon as the relays close: precharge takes no time in simulation.

The VMS inverter test that checks 0x55A labels its temperatures in °F now looks at the temperature signals only, since the filler has no unit.
<!-- SECTION:NOTES:END -->
