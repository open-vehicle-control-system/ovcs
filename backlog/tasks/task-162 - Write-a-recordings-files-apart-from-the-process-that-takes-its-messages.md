---
id: TASK-162
title: Write a recording's files apart from the process that takes its messages
status: In Progress
assignee: []
created_date: '2026-11-15T09:00:00Z'
labels:
  - vision
dependencies: []
ordinal: 115000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
PR 6 of the ROS 2 bag exporter, after #363. A `review` recording on the OVCS1 vision unit, about 215 messages and 4 MB a second, dropped 959 messages (6.9 %, spread over all 12 topics) on a SanDisk Cruzer Fit f2fs stick, which writes 8.2 MB/s synced, and none of 14,252 on the eMMC. `Bag.Recording.write/5` drops a message while more than 256 messages wait for the recording process, about 1.2 s at that rate, and the process stalls longer than that while it compresses a chunk, writes it and syncs it to the stick.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A recording whose writer stalls for 3 s at 215 messages a second records every message within its buffer
- [x] #2 Past its buffer, in bytes, a message is dropped and counted per topic in the status and `metadata.yaml`
- [x] #3 A stop writes what the buffer holds before the files close, within the stop's wait
- [x] #4 The buffer and the writer stop together; failover to the next disk works as before
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Problem: the process that takes a recording's messages is the one that writes them, so a slow disk stalls the intake and its mailbox, bounded at 256 messages, overflows.

Options considered:

- A byte budget on the recording's mailbox, without a new process. The stop and the disk check, every chunk interval, would wait behind up to the whole budget of messages.
- A separate writer process (chosen): `Bag.Recording` stays the writer, with its files, parts, failover, metadata and counts, and a new `VisionCore.Ros2.Bag.Buffer` process holds the messages between `write/5` and it.

Design:

- `write/5` encodes the message to CDR in the caller, as `Ros2Zenoh.Client.publish/4` does for the ROS 2 exporter, and admits it against a byte budget, `:buffer_bytes` (64 MiB), in an `:atomics` counter the buffer shares. Encoding first gives the budget the exact bytes held and holds only the payload, never a struct whose binary is part of a larger frame. A message past the budget, or that does not encode, is counted as a drop at once, as today, so the status shows it without waiting on any process.
- The buffer holds the admitted payloads in order and hands the writer one at a time, the next once the writer says it wrote the last. The writer's mailbox holds one message at most, so its disk check and a stop never wait behind the buffer. A payload counts against the budget until the writer has written it. The buffer never waits on the writer.
- A stop, or the exit of the process that started the recording, closes the buffer, which answers what it holds; the writer writes it, then closes its files and `metadata.yaml`. It writes for `:drain_ms` at most, 20 s, within `stop/1`'s 30 s and the bag exporter's 45 s; what is left is counted as dropped. 64 MiB takes about 8 s on the stick.
- The writer starts the buffer, linked; the buffer traps exits, so it stops with the writer whatever the reason, and the writer stops when the buffer exits. `restart: :temporary` as before; `start_link/1`, `write/5`, `status/1` and `stop/1` keep their signatures, the pid still the writer's.
- `:queue` is replaced by `:buffer_bytes`, in `Bag.Recording` and in the bag exporter's `:recording` options.
- 64 MiB holds about 16 s of the `review` preset. The VENTUNO Q has 16 GB; the Pi 5 vision unit's memory is not recorded in the repository.
<!-- SECTION:PLAN:END -->
