---
id: TASK-54
title: Pin the generic controller's PlatformIO platform and libraries
status: To Do
assignee: []
created_date: '2026-11-08 18:51'
labels:
  - controllers
milestone: m-7
dependencies: []
ordinal: 53000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
platformio.ini names renesas-ra without a version and fetches MCP23008, FakeIt and ArduinoFake from their git HEAD, so a rebuild can pick up a different compiler or library with no change in this repository.
<!-- SECTION:DESCRIPTION:END -->
