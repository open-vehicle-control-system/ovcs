# vision_api

Phoenix endpoint of the vision unit. It serves the [dashboard](../dashboard) build and exposes `VisionCore` to it. [Vision API](../../docs/vision/api.md) shows how a program uses it, with examples.

The `/api` routes follow [JSON:API](https://jsonapi.org/): a response is `application/vnd.api+json`, and a refusal's `errors` list holds one error object with `status`, `title` and `detail`. A refusal of the request document points at the member at fault with `source.pointer`, one of an `include` names it with `source.parameter`, and the others (the 404s, the 503 and a refused reset's 422) have no `source`. An unknown `/api` path answers a 404 whatever the client accepts. An error raised outside the controllers, such as a 500, is an `errors` list with `status` and `title`, as `application/json`.

A write reads its document from a JSON body only: sent as a form or in the query string, it is missing, and the answer is a 400.

| Route | Answer |
|---|---|
| `GET /api/stages?include=parameters` | The `stages`, one per `VisionCore.Parameters` group, by position: `name`, `summary`, `explanation` (a paragraph on what the step does, why it matters, what its settings change and what to watch, or `null`), `pipeline` (the pipeline it is a step of, such as `stereo` or `detection`), `position`, `status`, `role` (`source` for a component, `step` for a stage) and, for a pipeline stage, `compute`: where it runs (`runsOn`: `cpu`, `gpu` or `npu`), what it is written in (`implementation`: `nx`, `rust` or `elixir`) and what compiles Nx (`backend`: `vulkan`, `llvm_cpu`, `exla` or `evaluator`), their parameters in `included`, the unsaved count in `meta.unsaved`; 400 for any other include. |
| `GET /api/parameters` | Every parameter, the unsaved count in `meta.unsaved`. A parameter has `name`, `valueType`, `constraint`, `applies`, `description`, `default`, `value`, `saved` and `state`, and relates to its `stage`, the parameter it must stay `greaterThan`, and the automatic mode it is `controlledBy`. |
| `GET /api/parameters/:id` | One parameter; 404 when unknown. |
| `PATCH /api/parameters/:id` | Sets one as an unsaved change: 200 with the parameter, 422 when refused, 404 when unknown, 409 on a `type` or `id` mismatch, 400 without `data.type`, `data.id` or `data.attributes.value`. |
| `POST /api/parameter-saves` | Saves the unsaved changes: 201 with the saved parameter ids; 503 when the store fails, 409 for another `data.type`, 400 without one. |
| `POST /api/parameter-discards` | Discards the unsaved changes: 201 with their ids; 409 for another `data.type`, 400 without one. |
| `POST /api/parameter-resets` | Resets the `target` relationship (a `stages` or `parameters` resource), or everything without one: 201 with the reset ids; 404 for an unknown target, 422 when a parameter's owner refuses, 409 for another `data.type`, 400 without one or for a target of another type. |
| `GET /api/exporters` | What takes the unit's outputs out of it: each of its `exporters` (`VisionCore.Exporters.list/1`), identified by its id (`ros2` for the ROS 2 exporter), then the API itself, `api`, which is answering. An exporter has `name`, `module`, `status` (`level`: `ok`, `warning` or `off`, and `detail`, which for one that does not run says why), `actions` (each with a `name`, a `label` and a `description`; none for the API) and `outputs`, those of the unit it reads: each output's `name` (`stereo_pair`, `detections`, `camera_frame:left`, `camera_frame:right`) and `maxHz`, the most values it takes a second, `null` when unbounded; for the API, the rate its channel carries them at. |
| `POST /api/exporters/:id/actions/:name` | Runs an exporter's action (`VisionCore.Exporters.action/4`) with the document's `attributes` as its parameters, 60 s at most: 200 with the file as a download (`content-disposition: attachment`) for a file result, or with an `exporter-actions` resource whose attributes are the result for a JSON one; 404 for an unknown exporter or action, 409 when the exporter is busy or for another `data.type`, 503 when it does not run, 504 when it does not answer in time, 500 when the action fails (the error's `detail` says why), 400 without a document or for `attributes` that are no object. |
| `GET /api/ros2-node` | The ROS 2 node, `ros2-nodes` identified by its node name: `name`, `zenohEndpoint`, `connected`, related `topics` (`ros2-topics`: `name`, `messageType`, `rateHz`) and `services` (`ros2-services`: `name`, `serviceType`), in `included` with `include=topics,services` or either alone; 400 for any other include, 404 on a unit without the ROS 2 link (no `ros2:` section). |
| `GET /api/configuration` | The active vision configuration: `configurations` `current`, attribute `composer` holding `VisionCore.settings/0`, keyed by composer option names. |
| `GET /api/firmware` | The firmware the unit runs (`VisionCore.Firmware`): `firmwares` `current`, with `revision`, the commit it is built from, after the latest `v` version tag once there is one and `-dirty` when built with uncommitted changes, `target`, its Nerves target (`host` on a host), and `nervesSystem` and `nervesSystemVersion`, the Nerves system its `/usr/lib/os-release` names, `null` on a host. |

Channels:

- `status`: a `VisionCore.Status` snapshot on join, then one a second, with each exporter's status.
- `preview:left`, `preview:right` and `preview:depth`: JPEG frames as binary WebSocket messages, one at a time, sent when the client acknowledges the previous one with `ack`. On `preview:depth`, the client pushes `depth_range` with `metres` to set the depth video's colour range, or without to read it; the reply is the range in force, `{"metres": …}`. The range is the unit's: the channel pushes it as a `depth_range` event after every join and on every change, whichever dashboard makes it.
- `detections`: each detection result, at most ten a second, as `detections` events: every object's label, score, distance in metres and outline on the left camera's image, as fractions of its width and height. Refused on a unit without detection.

Any other path serves the dashboard.

The endpoint listens on port 4100. In development it also answers cross-origin requests, for the dashboard's Vite dev server (`:allow_cross_origin` in `config/dev.exs`). `vision_api` holds no vehicle knowledge; [`../firmware`](../firmware) boots it with the vehicle's composer. See [Vision unit](../../docs/vision/README.md).

```sh
mix deps.get
mix test
mix credo --strict
```
