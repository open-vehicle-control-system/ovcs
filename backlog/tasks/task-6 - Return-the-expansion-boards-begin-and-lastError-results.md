---
id: TASK-6
title: Return the expansion board's begin() and lastError() results
status: Done
assignee: []
created_date: '2026-11-08 10:41'
labels:
  - P06
  - controllers
milestone: m-0
dependencies: []
ordinal: 6000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
ExpansionBoard::begin() and lastError() call the MCP23008 library and return nothing, which is undefined behaviour in C++. Controller::verifyExpansionBoardErrors() reads lastError() every loop to raise EXPANSION_BOARDS_ERROR and reset the boards, and OVCS1's front and rear controllers drive their relay outputs (pins 3 to 7) through expansion board 1. Today's renesas-ra toolchain (GCC 7.2.1) happens to leave the library's result in r0, so the check works; GCC 8 and later may treat the missing return as unreachable and drop the function's epilogue, and the platform is not pinned, so a rebuild can change that without a change in this repository. A wrong lastError() then hides a dead expander while the VMS believes its outputs are set, or resets the boards for no reason.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 begin() and lastError() return the MCP23008 library's results
- [x] #2 Without the framework's -w, the build fails with -Werror=return-type before the change and passes after it
<!-- AC:END -->
