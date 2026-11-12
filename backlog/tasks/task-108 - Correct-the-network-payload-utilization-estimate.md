---
id: TASK-108
title: Correct the network payload utilization estimate
status: To Do
priority: low
labels: [vms, review]
dependencies: []
---

nextLoads assumes exactly one second between updates and labels received payload bytes as bus load. A counter reset produces -1%; a delayed two-second sample that should indicate 10% payload utilization shows 20%.

## Acceptance Criteria

- [ ] Rates use elapsed sample time and reset counters establish a new baseline.
- [ ] Unavailable and first samples display no rate.
- [ ] The label accurately distinguishes payload utilization from CAN wire occupancy.

## Design

Use monotonic elapsed time and validated counters. Rename the measure to RX payload utilization unless actual frame-level bus occupancy is calculated; account for CAN overhead separately.
