---
id: TASK-88
title: Show the NPU and its kind in the vision status bar
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-11 19:00'
labels:
  - vision
dependencies: []
parent_task_id: TASK-87
ordinal: 67000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Step 1 of TASK-87. The status bar's `Hailo` entry and the status JSON's `hailo` field only know the Hailo backend: a unit detecting with `VisionCore.Detection.Backend.Qnn` on a Hexagon NPU, such as the OVCS1 reference vehicle's, reads `absent` while its NPU runs.

Chosen: each detection backend names the accelerator it runs on, `npu_kind/0`: `"Hailo-8"` for `Backend.Hailo`, `"Hexagon"` for `Backend.Qnn`, `nil` for `Backend.Stub`, which runs on none. `VisionCore.Detection.Supervisor.backend/1` resolves the configured backend from the config's components. `VisionCore.Status` reports `npu: %{kind: kind, state: :running | :failed}`, or `nil` without a detector or with a backend on no accelerator; the status JSON carries it as `npu`, `null` or `{"kind": …, "state": …}`. The status bar shows `NPU` with the kind as its value, green when running, red when failed, and `none` in grey without one.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 `VisionCore.Status` reports `npu` with the configured backend's kind and state, `nil` without a detector or for the stub backend
- [x] #2 A QNN detector is reported as a `Hexagon` NPU, a Hailo detector as `Hailo-8`
- [x] #3 The status JSON carries `npu` in place of `hailo`, documented in `docs/vision/api.md`
- [x] #4 The status bar shows `NPU` with the kind, red when failed, and `none` in grey on a unit without one
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Spec: TASK-87, requirement 1 and its Status paragraph.

Review focus, each pinned by a test below:
- A unit whose detector is the stub backend shows `none`, not `failed`.
- A detector declared as `{:detector, backend: …}` resolves to that backend; `:detector` without one resolves to Hailo, the supervisor's default.
- A backend that does not answer is reported failed without stalling the snapshot (existing tests, kept on `npu`).
- The bar keeps room for the widest kind, `Hexagon`, so it does not jump between `none` and a kind.

**Task 1: core.**
- `VisionCore.Detection.Backend`: `@callback npu_kind() :: String.t() | nil`, documented in the moduledoc next to `available?/1`. Implement in `Backend.Hailo` (`"Hailo-8"`), `Backend.Qnn` (`"Hexagon"`), `Backend.Stub` (`nil`).
- `VisionCore.Detection.Supervisor.backend(VisionCore.Config.t()) :: module() | nil`: the `:backend` of the component whose child spec starts this supervisor (as `outputs/1` finds it through `VisionCore.Components.start/2`), `@default_backend` when the opts name none, `nil` without one. Tests in `supervisor_test.exs`: `[:qnn_detector]` → `Backend.Qnn`; `[{:detector, backend: Backend.Stub}]` → `Backend.Stub`; `[:detector]` → `Backend.Hailo`; `[]` → `nil`.
- `VisionCore.Status`: the `hailo` field becomes `npu :: %{kind: String.t(), state: :running | :failed} | nil`; `init/1` keeps the backend and its kind (`nil` when the backend has no NPU); the snapshot's call is `backend.available?/0` under `:npu`. Moduledoc names the NPU, not the Hailo detector. Tests in `status_test.exs`: nothing configured → `npu == nil`; `{:qnn_detector, dlc_path: "/missing.dlc"}` → `%{kind: "Hexagon", state: :failed}`; `{:hailo_detector, hef_path: "/missing.hef"}` → `%{kind: "Hailo-8", state: :failed}`; `{:detector, backend: VisionCore.Detection.Backend.Stub}` → `nil`; the two silent-backend tests assert `npu: %{state: :failed}`. `debug/export_test.exs`'s fixture snapshot takes `npu: nil`.
- Run `mix test` in `vision/core`.

**Task 2: API and docs.**
- `VisionApiWeb.StatusJSON`: `npu: nil` or `%{kind: kind, state: Atom.to_string(state)}`, replacing `hailo`. Tests: `status_json_test.exs` with `npu: nil` → `npu: nil` and `npu: %{kind: "Hexagon", state: :running}` → `npu: %{kind: "Hexagon", state: "running"}`; `status_channel_test.exs` and `exporter_status_test.exs` assert `npu: nil`.
- `docs/vision/api.md`: the example's `"hailo": "running"` becomes `"npu": {"kind": "Hexagon", "state": "running"}`, with one sentence: `npu` is the accelerator detection runs on, its kind and state, `null` on a unit without one.
- Run `mix test` in `vision/api`, `elixir scripts/check_docs.exs`.

**Task 3: dashboard.**
- `status.js` `unitStatus`: entry `id: 'npu'`, `title: 'NPU'`, `value: status.npu?.kind ?? 'none'`, `widest: 'Hexagon'`, `healthy: status.npu?.state === 'running'`, `tone: 'muted'` when `status.npu` is null, `hint: HINTS.npu`.
- `hints.js`: `npu` replaces `hailo`: title `NPU`, text "The accelerator running the unit's inference, by kind. Red when its backend cannot run; none on a unit without one."
- Tests in `UnitStatus.test.jsx`: `npu: null` shows `none` with neither ok nor error tone; `npu: { kind: 'Hexagon', state: 'failed' }` shows `Hexagon` in red; `{ kind: 'Hailo-8', state: 'running' }` shows ok; `widest('npu')` is `Hexagon`; the warning-slot loop uses `npu`. `AppStatus.test.jsx`'s snapshot takes `npu`.
- Run the dashboard's `npm test`.

Checks before review: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` in `vision/core` and `vision/api`; the dashboard's tests and lint; `elixir scripts/check_docs.exs`. No commit until the change is validated.
<!-- SECTION:PLAN:END -->
