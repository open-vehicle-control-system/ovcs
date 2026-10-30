# vision_api

Phoenix endpoint of the vision unit. It serves the [dashboard](../dashboard) build and exposes `VisionCore` to it.

- `GET /api/settings`: the active vision configuration.
- `GET /api/parameters`: the unit's vision parameters (`VisionCore.Parameters`) by id, with their values and constraints.
- `PUT /api/parameters/:name` with `{"value": ...}`: sets one as an unsaved change; a refusal is a 422 with its reason.
- `status` channel: a `VisionCore.Status` snapshot on join, then one a second.
- `preview:left`, `preview:right` and `preview:depth` channels: JPEG frames, one at a time, sent when the client acknowledges the previous one.
- Any other path serves the dashboard.

The endpoint listens on port 4100. `vision_api` holds no vehicle knowledge; [`../firmware`](../firmware) boots it with the vehicle's composer. See [Vision unit](../../docs/vision.md).

```sh
mix deps.get
mix test
mix credo --strict
```
