---
id: TASK-110
title: Run several named detection pipelines on a vision unit
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-11 19:00'
labels:
  - vision
dependencies: []
parent_task_id: TASK-108
ordinal: 68000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Step 2 of TASK-108: pipelines named in the composer, each with its own supervisor, backend and model, keyed by name in outputs, parameters, channels, ROS 2 topics and the dashboard; an unnamed detector keeps today's ids. A second pipeline on a Hailo backend is refused at start. See TASK-108's Design.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A composer declares several detector components, each with a `:name`; each runs under its own supervisor, backend and model, and one crashing or failing to start leaves the others running
- [x] #2 A detector without `:name` is named `detection` and keeps today's process names, parameter ids, `"detections"` channel, exporter output and ROS 2 topics
- [x] #3 A named pipeline's parameters, channel, exporter output and ROS 2 topics carry its name
- [x] #4 A second pipeline on the Hailo-8 fails to start with its reason logged; two QNN pipelines keep their context binaries apart
- [x] #5 The status's `npu` covers every detection pipeline's backend
- [x] #6 The dashboard draws each pipeline as its own flow and each pipeline's boxes on the left preview
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Spec: TASK-108 (Named pipelines, Backends, ROS 2, Status, Dashboard). Inventory of today's single-pipeline assumptions: every `__MODULE__` registration in `vision/core/lib/vision_core/detection/`, `Exporter`'s `@outputs` and `output_key/2`, `Exporter.Runner`'s `route/2` and `newest/2`, `Ros2.Exporter`'s `detections` state, `Ros2.Exporter.Detections`'s topics, `DetectionChannel` on the fixed topic `"detections"`, `ExporterController`'s `:detections`, the dashboard's `Pipelines.jsx` placeholder and `Previews.jsx`'s `useDetections`.

Global constraints:
- A pipeline name is an atom matching `^[a-z][a-z0-9_]*$`, none of the reserved names (TASK-108, Pipeline names); the default is `:detection`. It is a ROS 2 parameter name segment, so no `.` or `-`.
- The default pipeline keeps everything it has today: process names (the modules), the Outputs key `{:detections, VisionCore.Detection.Pipeline}`, the group ids `detection.input`, `detection.inference`, `detection.filtering`, `detection.placement` and `pipeline: :detection`, the channel and event `"detections"`, the exporter output `:detections`, the ROS 2 topics `<prefix>/detections`, `<prefix>/detections/markers`, `<prefix>/left/detections` and marker namespace `"detections"`.

Review focus, each pinned by a test in the owning task:
- Two detectors without names: the second's supervisor would clash with the first's; the core refuses the config at start with a message naming both, rather than one silently replacing the other.
- A named pipeline's detections never reach the default pipeline's consumers, and the reverse, in the runner, `Live` and the ROS 2 exporter.
- A pipeline name that is not a valid atom name (`:"front-cam"`, `:stereo`) is refused at start, naming the rule.
- The status `npu` with one Hailo and one stub pipeline reports the Hailo-8; with two QNN pipelines one of which is unavailable, `failed`.
- The dashboard without any detection pipeline still shows the greyed detection placeholder; with only a named one, no placeholder.

#### Task 1: named detection units in the core.
- `VisionCore.Detection.server(module(), atom()) :: module()`: `module` for `:detection`, else `Module.concat(module, Macro.camelize(Atom.to_string(name)))`. `VisionCore.Detection.name!(atom())` validates a name, raising `ArgumentError` with the rule.
- `Detection.Supervisor` takes `:name` (default `:detection`), registers as `server(Supervisor, name)`, passes `name: server(backend, name)` and `pipeline: name` to the backend, `name:`/`backend_server:` to `Pipeline`, `name:` to `Live`. `Components.start(:detector, opts)` gives the child spec the id `server(VisionCore.Detection.Supervisor, name)`.
- `VisionCore.Application` (where `resolve_component/1` feeds the core supervisor) refuses a config with two detectors of the same name, as an `ArgumentError` naming the name.
- `Pipeline` publishes under `{:detections, server(Pipeline, name)}`. A named pipeline's message is `{:detections, pair, positioned, name}`; the default's stays `{:detections, pair, positioned}`. Groups: ids `"#{name}.#{step}"`, `pipeline: name`, same positions; `inference_group/2` takes the pipeline name.
- `Live`: `start_link(name: …)`, `subscribe(name \\ :detection)`, `max_hz(name \\ :detection)`.
- Backends `Hailo`, `Qnn`, `Stub`: `start_link` takes `:name` (default the module) and `:pipeline` (default `:detection`) for their inference group; `detect/3` and `available?/1` use the server they are given. A Hailo unit's first child is a claim process registered as `VisionCore.Detection.Backend.Hailo.Device`; a second Hailo unit cannot start it and is left down with `"the Hailo-8 already serves another pipeline"` logged. `Qnn`'s default `:cache_dir` is `"/data/vision/qnn"` for `:detection` and `"/data/vision/qnn/#{name}"` otherwise.
- `Supervisor.backend/1` becomes `backends(VisionCore.Config.t()) :: [{module(), server :: module()}]`, one per detector in config order; `outputs/1` returns `[{{:detections, name}, {:detections, server(Pipeline, name)}}]` per detector, `:detections` for the default. `Status` asks each accelerator backend's `available?/1`: `npu` is the first accelerator's kind, `:failed` when any of them is unavailable.
- Tests: `supervisor_test.exs`, `pipeline_test.exs`, `live_test.exs`, each backend's test, `components_test.exs`, `application_test.exs`, `status_test.exs`, each with the review-focus cases above that are core's.

#### Task 2: exporters.
- `VisionCore.Exporter`'s output type gains `{:detections, atom()}`; `:detections` is the default pipeline's. `output_key/2` resolves `{:detections, name}` through `Detection.Supervisor.outputs/1`.
- `Exporter.Runner` routes a 4-tuple `{:detections, pair, positioned, name}` to the output `{:detections, name}` and drains the mailbox per output in `newest/2`; the default's 3-tuple keeps routing to `:detections`. Its `handle_output` payload stays `{pair, detections}`.
- `Ros2.Exporter`: the `detections:` options take `pipelines:` (default `[:detection]`); each listed pipeline gets its own `Ros2.Exporter.Detections` settings and drawn counter. The default publishes on today's topics; a named one on `<prefix>/<name>/detections`, `<prefix>/<name>/detections/markers` and `<prefix>/<name>/annotations`, with marker namespace `"<name>"`.
- `ExporterController` lists `detections` for the default and `detections:<name>` for each named pipeline, each with its `Live.max_hz/1`.
- `Debug.Exporter` keeps reading the default pipeline only.
- Tests: `exporter_test.exs`, `exporter/runner_test.exs` (two pipelines, each message reaching only its output), `ros2/exporter_test.exs`, `ros2/exporter/detections_test.exs`, `exporter_controller_test.exs`.

#### Task 3: API channel and dashboard.
- `DashboardSocket` adds `channel "detections:*"`; `DetectionChannel` joins `"detections:<name>"` through `Live` of that name, refusing an unknown name like an unavailable `Live`; `"detections"` stays the default's.
- `Pipelines.jsx` shows the greyed detection placeholder only when the unit has no pipeline other than `stereo`.
- `Previews.jsx`'s left preview subscribes to every detection channel the API exporter lists (`detections`, `detections:<name>`), drawing each pipeline's boxes with `DetectionOverlay`; the objects figure counts all of them.
- `ApiPage.jsx` and `ExporterPage.jsx` name the `detections:<name>` channels and outputs.
- Tests: `detection_channel_test.exs`, `Pipelines.test.jsx`, `Menu.test.jsx`, `Previews.test.jsx`, `ExporterPage.test.jsx`.

#### Task 4: docs.
- `docs/vision/README.md` (detectors and the menu's pipelines), `docs/vision/api.md` (the `detections:<name>` channel, exporter outputs), `docs/vision/data_flow.md` (processes per pipeline, topics), `vision/core/README.md`, `vision/api/README.md`, `vision/dashboard/README.md`: several named detectors, the default's names, the Hailo-8's single pipeline.
- `elixir scripts/check_docs.exs`.

Checks before review: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` in `vision/core`, `vision/api` and `vehicles/ovcs1`; the dashboard's tests; `elixir scripts/check_docs.exs`. No commit until the change is validated.
<!-- SECTION:PLAN:END -->
