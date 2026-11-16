---
id: TASK-177
title: Read the bag test's refused metadata.yaml without a FIFO race
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-16T21:10:00Z'
updated_date: '2026-11-16T21:10:00Z'
labels:
  - vision
  - tests
dependencies: []
ordinal: 119000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Issue #392: VisionCore.Ros2.Bag.RecordingTest's "a stop whose metadata.yaml the disk refuses keeps the messages of the file it closed" reads the FIFO standing in for metadata.yaml.tmp once per write. A FIFO gives a reader end-of-file only once no writer holds it, so the recording's two writes can land in one read, leaving the second read to wait in open or read nothing, and the second write can fail with EPIPE.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The test holds the FIFO open for writing while it reads, so no end-of-file comes between the recording's writes and neither waits nor fails
- [x] #2 It reads both documents to an end marker it writes once the recording stopped, and asserts on the second
- [x] #3 Only the test changes
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
A raw `:file.read/2` of n bytes waits for all n or end-of-file, and with the test holding a writer end no end-of-file comes: the reader takes a byte at a time, the documents being a few KB. Under 24 busy loops on a 20-core workstation, the test as it was failed on its second run, its second read empty; the test now passed 230 runs in a row there, and 201 unloaded. The issue's two writes against this reading passed 500 of 500, against 11 of 100 with the old one.
<!-- SECTION:NOTES:END -->

