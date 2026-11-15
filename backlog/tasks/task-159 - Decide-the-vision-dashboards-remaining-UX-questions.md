---
id: TASK-159
title: Decide the vision dashboard's remaining UX questions
status: To Do
assignee: []
created_date: '2026-11-15T01:11:00Z'
labels:
  - vision
  - dashboard
  - ux
dependencies: []
ordinal: 110000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Left by the dashboard UX pass for a decision: (1) phones: collapse the menu below lg and make the top bar not sticky there (ovcs_ui, shared with the VMS dashboard); (2) one warning colour: amber for camera dots and preview badges, red for exporter and step warnings, pair checks and the status bar today; (3) ovcs_ui contrast: --ovcs-text-muted on --ovcs-bg is 4.39:1, warn badge text about 2.9:1; (4) the uncalibrated banner on the stereo Calibration page repeats 'Not calibrated', and says 'applied'; (5) Position page wording: Measure / Measure again, 'position' in its saved list and delete question; (6) page titles naming the camera ('Center camera · Settings'); (7) bigger hint targets on touch screens; (8) fewer compute tags in the menu, a label on Pairing's two times. Found in files other open PRs change: Saved.jsx's OvcsBadge tone ok does not exist (IN USE renders grey); saved names in UTC above a local 'Made' time; status.js lower-cases the ROS 2 value and tones a warning pair check red; millimetres() lacks a non-breaking space; hints.js says boxes are outlined on the left video (OVCS1 detects on the centre camera) and points to 'the Calibration page'; calibration.md:138 says top bar for the status bar.
<!-- SECTION:DESCRIPTION:END -->
