---
id: TASK-88
title: Rewrite the guides to the writing rules
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-12 11:00'
updated_date: '2026-11-12 11:00'
labels:
  - docs
dependencies:
  - TASK-87
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The published guides predate the writing rules of CODE_STYLING.md: 156 sentences run past 35 words, 20 paragraphs past 120, and 18 descriptions past 160 characters. Rewrite each guide to the rules without changing what it says: same headings, URLs, code blocks, commands, links and figures; prose split into short sentences, lists, tables and numbered steps; passages describing a dashboard's screen removed.

No page is split, merged or renamed here: URLs and redirects live in the website repository. The diff splits into one commit per docs folder.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Every guide keeps its title, headings, fenced blocks, inline code, link targets and figures, except the passages removed as dashboard description or design rationale, which are listed
- [x] #2 No description exceeds 160 characters
- [x] #3 Sentences over 35 words and paragraphs over 120 words are gone or listed with the reason
- [x] #4 check_docs.exs passes and the website compiles the 42 guides
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Across the 42 guides, sentences over 35 words go from 156 to 13 and paragraphs over 120 words from 20 to 0; the word count barely moves (72340 to 72218), since the prose was restructured rather than cut. The 13 remaining are two sentences the counter joins because the second starts with inline code, or a troubleshooting entry's cause and fix.

Removed under the dashboard rule: the OVCS1 grid walk-through in docs/infotainment/README.md; the theme, card layout, narrow-screen and chart-colour sentences in docs/vms/dashboard_pages.md; the menu, panel, save bar and caption descriptions in docs/vision/README.md, data_flow.md and stages.md; the export button's states in docs/vision/tuning.md; the bus drawing, tables, filter box and `@ovcs/ui` frame in docs/bus/gateway.md.

Removed as design rationale the reader does not act on: the section "Why not relay the site Wi-Fi onto the wire" and the list of rejected operating systems in docs/ros2/compute_node.md, and the Jazzy-to-Lyrical migration sentences in compose/local/simulation/README.md. The "Why…" sections that state a constraint or guide a choice stay.

Not done, because it needs facts the guides do not state: expected output after most commands, and an opening that says what the reader needs first. Pages over 2500 words are not split.

check_docs.exs also rejects an unquoted `: ` in a frontmatter value, which the website's YAML parser refuses. check_docs.exs passes; the website's check:mdx compiles the 42 guides.
<!-- SECTION:NOTES:END -->
