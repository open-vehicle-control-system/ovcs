---
id: TASK-51
title: Expose CAN topology validation in Cantastic
status: To Do
assignee: []
created_date: '2026-11-08 17:22'
updated_date: '2026-11-08 17:22'
labels:
  - ovcs
  - cantastic
milestone: m-0
dependencies: []
ordinal: 51000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Each vehicle's can_topology_test loads its topology through Cantastic's ConfigurationStore and Interface, which are internal (@moduledoc false), and the three vehicles carry the same loader. A public Cantastic function that validates a topology file, frames in their direction, duplicate ids and OBD2 requests included, replaces both; the vehicle tests call it after the pin bump.
<!-- SECTION:DESCRIPTION:END -->
