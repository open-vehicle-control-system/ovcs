---
id: TASK-183
title: Toggle the dashboards' menu, hidden by default on a phone
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-18T11:00:00Z'
labels:
  - dashboard
  - vision
  - vms
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Below the laptop breakpoint, `OvcsShellBody` puts the `OvcsMenu` above the page, every entry shown. On a phone 412 px wide, the vision unit's menu (its cameras, the 17 steps of OVCS1's pipelines and its exporters) is about 1650 px tall: a stage's parameters start two screens down, and going to another page means scrolling back to the top.

A Menu button at the left of the top bar shows and hides the menu. On a phone the menu is hidden until the button opens it under the top bar, which stays at the top of the screen, the current entry in view; choosing an entry, or Escape, closes it. On a laptop the menu is shown beside the page until the button hides it, a choice the browser keeps. Its entries are 44 px tall on a phone, the height of a finger's target. The menu and the top bar are the shared `@ovcs/ui` ones, so the VMS dashboard works the same way.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 On a phone the menu is hidden until the top bar's Menu button opens it
- [x] #2 On a phone, choosing an entry or Escape closes the menu
- [x] #3 On a phone the open menu stays under the top bar as the page scrolls, under the top bar's details
- [x] #4 On a laptop the menu is shown beside the page until the Menu button hides it, and the browser remembers the choice
- [x] #5 The vision unit's stage page shows its parameters on the first screen of a Fairphone 4
<!-- AC:END -->
