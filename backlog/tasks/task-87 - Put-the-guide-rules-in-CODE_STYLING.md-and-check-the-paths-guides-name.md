---
id: TASK-87
title: Put the guide rules in CODE_STYLING.md and check the paths guides name
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-12 10:00'
updated_date: '2026-11-12 10:00'
labels:
  - docs
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The rules a published guide follows are only in CLAUDE.md, which a contributor who is not an assistant does not read, and scripts/check_docs.exs checks Markdown links but not the repository paths guides name in inline code: docs/ros2/README.md names three files that moved to libraries/ros2_zenoh/ and simulator/core/.

Options for the rules: a CONTRIBUTING.md, a page under docs/ (published, or exempted from the index), or a section of CODE_STYLING.md. Chosen: a Guides section in CODE_STYLING.md, which already holds the moduledoc and comment rules and is what docs/community.md sends contributors to; CLAUDE.md keeps a pointer.

Options for the path check: every inline-code span that looks like a path, with an exemption list; or only paths whose first segment is a top-level directory of the repository. Chosen: the second, which skips vehicle-relative (`lib/...`), on-device (`/boot/...`) and output (`frames/...`) paths without a list. Gitignored paths pass, and the two names the tutorials build under are skipped.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 CODE_STYLING.md has a Guides section holding the writing, structure, vocabulary, format and code-reference rules; CLAUDE.md, docs/community.md, scripts/README.md and the checker point to it
- [x] #2 The section states what the site does with a guide: URL from the path, description as lede and meta description, alerts as callouts, images served from main, page length
- [x] #3 check_docs.exs fails on a repository path in inline code that does not exist, and passes on the 42 guides once docs/ros2/README.md names the moved files
- [ ] #4 The website compiles the guides of this branch (check:mdx, check:links with OVCS_DIR)
- [x] #5 CI runs the docs check on every pull request, not only those touching Markdown
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
With the website's `OVCS_DIR` on this branch, `check:mdx` compiles the 42 guides. `check:links` reports one problem, the website's redirect `ros2-perception → bridges/perception`: `docs/bridges/perception.md` left `main` with the ROS bridge's stereo and detection stack, so the redirect needs a new target in the website repository.

The path check does not cover shortened paths (`timing.ex`), paths under gitignored directories or module names. The description and page-length targets are stated, not checked: 18 descriptions exceed 160 characters.
<!-- SECTION:NOTES:END -->
