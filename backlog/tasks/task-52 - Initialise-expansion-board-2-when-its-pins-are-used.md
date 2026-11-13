---
id: TASK-52
title: Initialise expansion board 2 when its pins are used
status: To Do
assignee: []
created_date: '2026-11-08 18:50'
labels:
  - controllers
milestone: m-7
dependencies: []
ordinal: 51000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Configuration::computeDigitalPins() sets _expansionBoard1InUse for a pin on expansion board 2, so board 2 is never initialised and its errors are never read. No reference vehicle enables pins 11 to 18, so it only affects a vehicle that fits a second MCP23008.
<!-- SECTION:DESCRIPTION:END -->
