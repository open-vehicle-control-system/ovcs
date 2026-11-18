---
id: TASK-184
title: Fit the dashboards' top and bottom bars to a phone
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-18T11:15:00Z'
labels:
  - dashboard
  - vision
  - vms
dependencies:
  - TASK-183
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
On a phone 412 px wide, the `OvcsTopBar`, which stays at the top of the screen, is 105 px tall: its summary of the vehicle, CPU, memory and clock wraps over two lines under the title. The `OvcsBottomBar`'s statuses wrap unevenly over three lines, some values broken in the middle.

On a phone the summary keeps to one line: the vehicle and the clock without their labels, and a synchronized clock by its dot alone; the labels and the word stay for a screen reader, and an unsynchronized clock still says so. The bottom bar's statuses go in two columns, each label over its value. On a laptop both bars are unchanged.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 On a Fairphone 4 the top bar's summary holds on one line under the title
- [x] #2 An unsynchronized clock still says so on a phone
- [x] #3 On a Fairphone 4 the bottom bar's statuses fill two even rows, none wider than the screen
- [x] #4 On a laptop both bars are unchanged
<!-- AC:END -->
