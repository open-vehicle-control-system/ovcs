# vision_api

Phoenix endpoint of the vision unit. It serves the [dashboard](../dashboard) build and exposes `VisionCore` to it.

The parameter routes follow [JSON:API](https://jsonapi.org/): every response is `application/vnd.api+json`, and a refusal is an `errors` object with `status`, `title`, `detail` and `source.pointer`.

| Route | Answer |
|---|---|
| `GET /api/parameter-groups?include=parameters` | The groups (`VisionCore.Parameters`) by position, their parameters in `included`, the unsaved count in `meta.unsaved`. |
| `GET /api/parameters` | Every parameter, the unsaved count in `meta.unsaved`. |
| `GET /api/parameters/:id` | One parameter; 404 when unknown. |
| `PATCH /api/parameters/:id` | Sets one as an unsaved change: 200 with the parameter, 422 when refused, 404 when unknown, 409 on a `type` or `id` mismatch, 400 without `data.attributes.value`. |
| `POST /api/parameter-saves` | Saves the unsaved changes: 201 with the saved parameter ids; 503 when the store fails. |
| `POST /api/parameter-discards` | Discards the unsaved changes: 201 with their ids. |
| `POST /api/parameter-resets` | Resets the `target` relationship (a `parameter-groups` or `parameters` resource), or everything without one: 201 with the reset ids. |
| `GET /api/parameter-export` | The saved values as a composer snippet. |
| `GET /api/settings` | The active vision configuration. |

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
