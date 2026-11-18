---
id: TASK-181
title: Rebuild nx_iree's runtime from scratch when its compiler changes
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-18T10:30:00Z'
labels:
  - vision
  - build
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`libraries/nx_iree/Makefile` configures the IREE runtime of a cross build in `iree-runtime/<prefix>-<target>/iree-build`, passing the Nerves toolchain's `$(CC)` and `$(CXX)` as `CMAKE_C_COMPILER` and `CMAKE_CXX_COMPILER`. When the build directory's cache holds another compiler path, the toolchain artifact replacing a system's portable toolchain for instance, CMake deletes the cache and configures again without the command line's other `-D` values. `NX_IREE_SOURCE_DIR` and `IREE_RUNTIME_BUILD_DIR` come out empty, and the configure fails on `add_subdirectory` in `cmake/CMakeLists.txt`. The rule only runs when one of its inputs is newer than the installed runtime, such as the IREE patch stamp, which every target's build shares, so the failure appears long after the compiler changed. Deleting the build directory by hand fixes it.

Options:

- `cmake --fresh` on every configure: the configure succeeds, but Ninja then rebuilds every object even with the same compiler, so the whole runtime is rebuilt each time the rule runs.
- Delete the build directory when the compilers it was configured with differ from `$(CC) $(CXX)`, recorded in a stamp file beside the cache once the configure succeeds: a changed toolchain rebuilds from scratch, as it has to, and an unchanged one keeps building incrementally.

Chosen: the stamp file. A build directory without one is deleted once, on its first configure.

`nx_iree` is sideloaded from `Spin42/nx_iree`: the fix lands there, and `scripts/libraries.tsv` pins the commit that carries it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A cross build whose build directory was configured with another compiler path configures and builds the runtime
- [x] #2 A rebuild with the same compiler keeps the build directory and builds incrementally
- [x] #3 `scripts/libraries.tsv` pins the `nx_iree` commit with the fix
<!-- AC:END -->
