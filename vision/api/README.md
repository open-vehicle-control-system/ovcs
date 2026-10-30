# vision_api

Phoenix endpoint of the vision unit. It serves the [dashboard](../dashboard) build and exposes `VisionCore` to it.

The `/api` routes follow [JSON:API](https://jsonapi.org/): every response is `application/vnd.api+json`, and a refusal is an `errors` object with `status`, `title`, `detail` and `source.pointer`.

| Route | Answer |
|---|---|
| `GET /api/stages?include=parameters` | The `stages`, one per `VisionCore.Parameters` group, by position: `name`, `summary`, `position`, `status` and `role` (`source` for a component in the pipeline flow, `step` for a pipeline stage in it, `branch` beside it), their parameters in `included`, the unsaved count in `meta.unsaved`; 400 for any other include. |
| `GET /api/parameters` | Every parameter, the unsaved count in `meta.unsaved`. A parameter has `name`, `valueType`, `constraint`, `applies`, `description`, `default`, `value`, `saved` and `state`, and relates to its `stage`, the parameter it must stay `greaterThan`, and the automatic mode it is `controlledBy`. |
| `GET /api/parameters/:id` | One parameter; 404 when unknown. |
| `PATCH /api/parameters/:id` | Sets one as an unsaved change: 200 with the parameter, 422 when refused, 404 when unknown, 409 on a `type` or `id` mismatch, 400 without `data.type`, `data.id` or `data.attributes.value`. |
| `POST /api/parameter-saves` | Saves the unsaved changes: 201 with the saved parameter ids; 503 when the store fails. |
| `POST /api/parameter-discards` | Discards the unsaved changes: 201 with their ids. |
| `POST /api/parameter-resets` | Resets the `target` relationship (a `stages` or `parameters` resource), or everything without one: 201 with the reset ids. |
| `GET /api/composer-snippet` | The saved values as a composer snippet: `composer-snippets` `current`, attribute `snippet`. |
| `GET /api/ros2-node` | The ROS 2 node, `ros2-nodes` identified by its node name: `name`, `zenohEndpoint`, `connected`, related `topics` (`ros2-topics`: `name`, `messageType`, `rateHz`) and `services` (`ros2-services`: `name`, `serviceType`), in `included` with `include=topics,services` or either alone; 400 for any other include. |
| `GET /api/configuration` | The active vision configuration: `configurations` `current`, attribute `composer` holding `VisionCore.settings/0`, keyed by composer option names. |

Channels:

- `status`: a `VisionCore.Status` snapshot on join, then one a second.
- `preview:left`, `preview:right` and `preview:depth`: JPEG frames, one at a time, sent when the client acknowledges the previous one.

Any other path serves the dashboard.

The endpoint listens on port 4100. `vision_api` holds no vehicle knowledge; [`../firmware`](../firmware) boots it with the vehicle's composer. See [Vision unit](../../docs/vision.md).

```sh
mix deps.get
mix test
mix credo --strict
```
