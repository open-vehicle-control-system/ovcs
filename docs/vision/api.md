---
title: Vision API
description: How a program reads and changes the vision unit's parameters, follows its status, previews and detections, and finds its exports over HTTP and Phoenix channels.
---

The vision unit serves its API next to the dashboard, on port 4100 (see [Vision unit](./README.md#dashboard-and-api)):

```text
http://<vehicle>-vision.local:4100
```

Everything the dashboard shows comes from it:

- resources under `/api`, which follow [JSON:API](https://jsonapi.org/);
- live channels on a Phoenix socket at `/sockets/dashboard`.

The examples come from a Raspberry Pi 5 unit with detection, shortened where a list is long. [`vision/api/README.md`](../../vision/api/README.md) lists every route with its status codes.

## Requests and errors

Every answer under `/api` is `application/vnd.api+json`. A write sends its document as a JSON body, with the content type `application/vnd.api+json` or `application/json`. Sent as a form or in the query string, the document is missing and the answer is a 400.

A refusal is an `errors` list holding one error object. When a member of your document is at fault, `source.pointer` names it:

```sh
curl -X PATCH http://<vehicle>-vision.local:4100/api/parameters/stereo.disparity.p1 \
  -H 'content-type: application/vnd.api+json' \
  -d '{"data": {"type": "parameters", "id": "stereo.disparity.p1", "attributes": {"value": 500}}}'
```

```json
{
  "errors": [
    {
      "status": "422",
      "title": "Invalid value",
      "source": {"pointer": "/data/attributes/value"},
      "detail": "must be from 0 to 78, got 500"
    }
  ]
}
```

An unknown resource answers a 404 whose `detail` names it, such as `no parameter stereo.disparity.nope`.

## Stages and parameters

The unit's settings are parameters, grouped by stage. A stage is a component, such as the cameras, or a step of a pipeline.

`GET /api/stages?include=parameters` returns the stages in pipeline order, their parameters in `included`, and the count of unsaved parameters in `meta.unsaved`. One stage of `data`:

```json
{
  "type": "stages",
  "id": "stereo.disparity",
  "attributes": {
    "name": "Disparity",
    "pipeline": "stereo",
    "position": 3,
    "role": "step",
    "status": null,
    "summary": "Matches the rectified pair into a disparity with semi-global matching.",
    "explanation": "The core of stereo: for each pixel of the left image, it finds the same point in the right image, along the same row.",
    "compute": {"runsOn": "cpu", "implementation": "rust", "backend": null}
  },
  "relationships": {
    "parameters": {
      "data": [
        {"type": "parameters", "id": "stereo.disparity.p1"},
        {"type": "parameters", "id": "stereo.disparity.p2"},
        {"type": "parameters", "id": "stereo.disparity.uniqueness"},
        {"type": "parameters", "id": "stereo.disparity.num_disparities"},
        {"type": "parameters", "id": "stereo.disparity.paths"}
      ]
    }
  }
}
```

`compute` says where a step runs:

| Member | Value |
|---|---|
| `runsOn` | `cpu`, `gpu` or `npu` |
| `implementation` | `nx`, `rust` or `elixir` |
| `backend` | The compiler of Nx code: `vulkan`, `llvm_cpu`, `exla` or `evaluator` |

A component, such as the cameras, has the role `source` and no `compute`. [Where depth is computed](./compute.md) says where each stage runs and why.

`GET /api/parameters` lists every parameter, and `GET /api/parameters/stereo.disparity.p1` returns one:

```json
{
  "data": {
    "type": "parameters",
    "id": "stereo.disparity.p1",
    "attributes": {
      "name": "p1",
      "description": "Penalty for a disparity change of one between neighbours",
      "valueType": "integer",
      "constraint": {"kind": "range", "min": 0, "max": 78, "step": null},
      "applies": "live",
      "default": 8,
      "value": 8,
      "saved": null,
      "state": "builtin"
    },
    "relationships": {
      "stage": {"data": {"type": "stages", "id": "stereo.disparity"}},
      "controlledBy": {"data": null},
      "greaterThan": {"data": null}
    }
  }
}
```

| Member | Meaning |
|---|---|
| `constraint` | A `range`, with `min`, `max` and a `step` when values go by steps; a set of `choices` in `values`; or a `bool`. |
| `applies` | `live` for a parameter that changes while the unit runs. `build` for one fixed in the build, such as `num_disparities`, which the unit refuses to change. |
| `state` | `builtin` while the built-in default is in force. `saved` while a saved value is. `unsaved` for a change not saved yet. `automatic` while an automatic mode sets the value. |
| `controlledBy` | For an `automatic` parameter, that mode's parameter. `stereo.cameras.exposure_time_us` is `automatic`, controlled by `stereo.cameras.auto_exposure`, while auto exposure is on. |
| `greaterThan` | The parameter this one must stay above: `stereo.disparity.p2` relates to `stereo.disparity.p1`. |

## Change a parameter

A change is unsaved until you save it, as on the dashboard. Unsaved changes live on the unit, shared by every client, and a reboot drops them. Set a value with `PATCH`:

```sh
curl -X PATCH http://<vehicle>-vision.local:4100/api/parameters/stereo.disparity.p1 \
  -H 'content-type: application/vnd.api+json' \
  -d '{"data": {"type": "parameters", "id": "stereo.disparity.p1", "attributes": {"value": 10}}}'
```

The answer is the parameter with `value` 10 and `state` `unsaved`. A live parameter applies from one of the next pairs. The unit answers:

- a 422 for a value outside the constraint or a parameter fixed in the build;
- a 409 for a `type` or `id` that does not match the URL;
- a 400 for a document without `data.type`, `data.id` or `data.attributes.value`.

Then save, discard or reset. Each is a `POST` that answers a 201 with the ids of the parameters it touched:

```sh
curl -X POST http://<vehicle>-vision.local:4100/api/parameter-saves \
  -H 'content-type: application/vnd.api+json' \
  -d '{"data": {"type": "parameter-saves"}}'
```

```json
{
  "data": {
    "type": "parameter-saves",
    "id": "12",
    "attributes": {"parameters": ["stereo.disparity.p1"]}
  }
}
```

- `POST /api/parameter-saves` stores the unsaved values on the unit, which applies them again at every boot. It answers a 503 when the store fails.
- `POST /api/parameter-discards` returns every unsaved parameter to its saved value, or to its default without one.
- `POST /api/parameter-resets` returns parameters to their defaults: the stage or parameter its `target` relationship names, or every parameter without one.

A reset of the Disparity stage:

```json
{
  "data": {
    "type": "parameter-resets",
    "relationships": {"target": {"data": {"type": "stages", "id": "stereo.disparity"}}}
  }
}
```

The same parameters are reachable over ROS 2 under the same ids ([Vision unit](./README.md#dashboard-and-api)).

## The unit and its exports

`GET /api/firmware` returns the firmware the unit runs:

- the commit it is built from;
- its Nerves target;
- the Nerves system the board runs;
- the name of your vehicle, `null` without `VEHICLE`.

```json
{
  "data": {
    "type": "firmwares",
    "id": "current",
    "attributes": {
      "revision": "ce99e251",
      "target": "rpi5",
      "nervesSystem": "ovcs_bridges_system_rpi5",
      "nervesSystemVersion": "3.0.0-rc.2",
      "vehicle": "OVCS Mini"
    }
  }
}
```

`GET /api/board` returns the board the unit runs on:

- **Interfaces.** Each network interface that is up, with a device and an address, with its addresses. Loopback, container bridges and IPv6 link-local addresses are left out.
- **Load.** The CPU's busy share over half a second, and the 1, 5 and 15 minute load averages.
- **Clock.** The board's UTC time and whether NTP has synchronized it. On a host, `clockSynchronized` is `null`.

A board whose clock is not synchronized publishes nothing to ROS 2. The dashboard's top bar reads `GET /api/board` every 10 s while connected.

```json
{
  "data": {
    "type": "boards",
    "id": "current",
    "attributes": {
      "interfaces": [
        {"name": "eth0", "addresses": ["192.168.10.232"]},
        {"name": "usb0", "addresses": ["172.31.42.1"]}
      ],
      "cpuPercent": 23.4,
      "loadAverage": [0.52, 0.48, 0.4],
      "time": "2026-11-11T14:53:12Z",
      "clockSynchronized": true
    }
  }
}
```

`GET /api/configuration` returns the configuration your vehicle's composer gives the unit, as `VisionCore.settings/0` returns it. It holds the components with their options, the exporters, the previews, the JPEG encoders and the ROS 2 link. The example is shortened: the stereo component's options also hold its calibration directories, each camera's settings and its stages.

```json
{
  "data": {
    "type": "configurations",
    "id": "current",
    "attributes": {
      "composer": {
        "components": [
          {
            "name": "stereo",
            "options": {"driver": "VisionCore.Camera.LibCamera", "width": 480, "height": 270, "fps": 30, "compute": "native"}
          }
        ],
        "exporters": [
          {"module": "VisionCore.Ros2.Exporter", "options": {"stereo": [], "detections": [], "heartbeat": []}}
        ],
        "preview": [],
        "jpeg": [],
        "ros2": {"zenoh_endpoint_ip": "192.168.1.20"}
      }
    }
  }
}
```

`GET /api/exporters` lists what takes the unit's outputs out of it: each exporter, then the API itself. Each entry has its status, the outputs it reads and the actions you can run on it. `maxHz` is the most values of an output the exporter takes a second, `null` when unbounded.

```json
{
  "data": [
    {
      "type": "exporters",
      "id": "ros2",
      "attributes": {
        "name": "ROS 2",
        "module": "VisionCore.Ros2.Exporter",
        "status": {"level": "ok", "detail": "Connected"},
        "outputs": [
          {"name": "stereo_pair", "maxHz": null},
          {"name": "camera_frame:left", "maxHz": null},
          {"name": "camera_frame:right", "maxHz": null},
          {"name": "detections:objects", "maxHz": null},
          {"name": "segmentation:scene", "maxHz": null},
          {"name": "camera_frame:center", "maxHz": null}
        ],
        "actions": []
      }
    },
    {
      "type": "exporters",
      "id": "api",
      "attributes": {
        "name": "API",
        "module": "VisionApiWeb.Endpoint",
        "status": {"level": "ok", "detail": "Answering"},
        "outputs": [
          {"name": "camera_frame:left", "maxHz": 10},
          {"name": "camera_frame:right", "maxHz": 10},
          {"name": "stereo_pair", "maxHz": 10},
          {"name": "camera_frame:center", "maxHz": 10},
          {"name": "detections:objects", "maxHz": 10, "source": "center"},
          {"name": "segmentation:scene", "maxHz": 5, "source": "center"}
        ],
        "actions": []
      }
    }
  ]
}
```

The example is the OVCS1 reference vehicle's unit: a camera `center` with a detection pipeline `objects` and a segmentation pipeline `scene` on it. The API lists a `camera_frame:<name>` output for each camera of its own, between `stereo_pair` and the detections: `camera_frame:center` here. Each has a `preview:<name>` channel ([Previews](#previews)). An exporter that reads another output of a camera than its default lists it as `camera_frame:<name>:<output>`, such as `camera_frame:center:inference`.

A unit with named detection pipelines lists each one's output too: `detections:<name>` for the pipeline `<name>`, next to `detections` for the default one. The API lists every pipeline's; the ROS 2 exporter lists those its `detections:` names. The API's detection outputs name their pipeline's `source`, the preview its boxes belong on. It is `left` for the stereo pair, or the name of a camera of its own: `center` for `objects`.

A unit with segmentation pipelines lists `segmentation:<name>` for the pipeline `<name>`, after the detections. The API lists every one, with the pipeline's camera as its `source`. The ROS 2 exporter lists them only with its `segmentation:` option: those its `pipelines:` names, or without `pipelines:` every one on a camera.

A status `level` is `ok`, `warning` or `off`; for an exporter that does not run, `detail` says why. Writing an exporter of your own is in [How a pair flows](./data_flow.md#exporters).

An action is listed with its `name`, a `label` and a `description`. `POST /api/exporters/:id/actions/:name` runs it, with a JSON:API document of the type `exporter-actions`. The action's parameters go in `attributes` when it takes any.

This request runs the `export` action of an exporter whose id is `debug`, which answers a zip file ([Tune with exports](./tuning.md)), and saves it:

```sh
curl --fail-with-body -X POST http://<vehicle>-vision.local:4100/api/exporters/debug/actions/export \
  -H 'content-type: application/vnd.api+json' \
  -d '{"data": {"type": "exporter-actions"}}' \
  -o export.zip
```

`--fail-with-body` needs curl 7.76 or later. On an error answer, curl exits with 22 and `export.zip` holds the JSON error, not a zip: check the exit status before you use the file.

An action that produces a file answers it with a 200 and `content-disposition: attachment`. One that answers JSON gets a 200 with an `exporter-actions` resource whose `attributes` hold the result. The request waits up to 60 s for the answer. The unit answers:

- a 400 for a document without `data.type`, one sent as a form or in the query string, or `attributes` that are no object;
- a 409 for another `data.type`, or when the exporter is busy;
- a 404 for an exporter or an action it does not have;
- a 503 when the exporter does not run;
- a 504 when the action does not answer in time;
- a 500 when the action fails.

The error's `detail` says why.

`GET /api/ros2-node?include=topics,services` describes the ROS 2 node:

- its Zenoh router;
- whether the session is open;
- the topics it has published, with their rate over the last second;
- the services it answers.

A unit without the ROS 2 link answers a 404. The example is shortened to one topic and one service:

```json
{
  "data": {
    "type": "ros2-nodes",
    "id": "ovcs_vision",
    "attributes": {"name": "ovcs_vision", "zenohEndpoint": "tcp/192.168.1.20:7447", "connected": true},
    "relationships": {
      "topics": {"data": [{"type": "ros2-topics", "id": "/stereo/depth/image_rect"}]},
      "services": {"data": [{"type": "ros2-services", "id": "/stereo/left/set_camera_info"}]}
    }
  },
  "included": [
    {
      "type": "ros2-topics",
      "id": "/stereo/depth/image_rect",
      "attributes": {"name": "/stereo/depth/image_rect", "messageType": "sensor_msgs/msg/Image", "rateHz": 29.9}
    },
    {
      "type": "ros2-services",
      "id": "/stereo/left/set_camera_info",
      "attributes": {"name": "/stereo/left/set_camera_info", "serviceType": "sensor_msgs/srv/SetCameraInfo"}
    }
  ]
}
```

## Live channels

The socket at `/sockets/dashboard` speaks the Phoenix channels protocol. With the [`phoenix`](https://www.npmjs.com/package/phoenix) JavaScript client, in a browser or in Node.js:

```javascript
import { Socket } from 'phoenix'

const socket = new Socket('ws://<vehicle>-vision.local:4100/sockets/dashboard')
socket.connect()

const status = socket.channel('status')
status.on('status', (snapshot) => console.log(snapshot.depthHz, snapshot.quality.matchedPercent))
status.join()
```

### Status

`status` pushes a `status` event on join, then one a second: a `VisionCore.Status` snapshot with camelCase keys. A camera's or the sync's figures that were not measured are left out.

`cameras` holds the stereo sides and each camera of its own, by name (`center` here). A camera of its own has no `issues`.

`npu` is the accelerator the detection and segmentation pipelines run on, `null` on a unit without one:

- `kind`, and `state`: `running` or `failed`;
- `loadPercent`, the share of the last second its pipelines spent inferring, at most 100, `null` until a Port has reported a time;
- each pipeline's mean `inferenceMs` over that second, `null` in a second without a frame.

[Accelerator load](./detection.md#accelerator-load) says what they measure on each accelerator.

```json
{
  "cameras": {
    "left": {"present": true, "fps": 30.0, "exposureTimeUs": 33013, "analogueGain": 8, "colourTemperature": 6177, "issues": []},
    "right": {"present": true, "fps": 30.0, "exposureTimeUs": 33013, "analogueGain": 8, "colourTemperature": 6155, "issues": ["focus_mismatch"]},
    "center": {"present": true, "fps": 30.0, "exposureTimeUs": 12000, "analogueGain": 4}
  },
  "sync": {"present": true, "pairs": 150, "offsetMedianMs": -0.02, "offsetMaxMs": -0.77},
  "pair": {
    "timing": {"level": "ok", "camera": null, "issues": [], "gauge": -0.02, "later": "left", "offsetMs": 0.02, "maxOffsetMs": 0.77, "pairs": 150},
    "rows": {"level": "ok", "camera": null, "issues": [], "gauge": 0.42, "direction": "lower", "misalignmentRows": 0.09,
             "offsetRows": 0.09, "correctionRows": 0.0, "bandOffsetRows": [0.22, 0.28, 0.11, -0.14], "bandSpreadRows": 0.42},
    "focus": {"level": "warning", "camera": "right", "issues": ["focus_mismatch"], "gauge": 1.0, "softer": "right",
              "differencePercent": 38, "ratio": 0.62, "left": 0.0052, "right": 0.0032},
    "brightness": {"level": "ok", "camera": null, "issues": [], "gauge": 0.2, "brighter": "right",
                   "differencePercent": 4, "left": 96.1, "right": 99.9}
  },
  "depth": {
    "rate": {"level": "ok", "camera": null, "issues": [], "gauge": 0.24, "droppedPercent": 1.2,
             "depthHz": 34.4, "cameraHz": 34.8, "loadPercent": 98.0},
    "range": {"level": "warning", "camera": null, "issues": ["too_near"], "gauge": 1.5, "nearPercent": 22.5, "nearestM": 1.39}
  },
  "alignment": {"offsetRows": 0.09, "bandOffsetRows": [0.22, 0.28, 0.11, -0.14]},
  "sharpness": {"left": 0.0048, "right": 0.0056},
  "quality": {"matchedPercent": 64.7, "jitterPx": 0.087, "meanDisparityPx": 11.9, "spreadPx": 7.7},
  "depthHz": 26.0,
  "stereoLoadPercent": 98.0,
  "cpuPercent": 84.8,
  "npu": {"kind": "Hexagon", "state": "running", "loadPercent": 23.1,
          "pipelines": {"objects": {"inferenceMs": 2.1}, "scene": {"inferenceMs": 5.6}}},
  "exporters": [{"id": "ros2", "name": "ROS 2", "status": {"level": "warning", "detail": "Disconnected"}}]
}
```

`pair` judges the two cameras together, so a reader computes nothing. Each check has:

- a `level`: `ok`, `warning` as soon as the check has an issue, or `off` with nothing to judge;
- the `camera` its issues point at: `left`, `right` or `null`;
- its `issues`;
- its `gauge`;
- its figures, with their direction already worked out.

The `gauge` places the check against its threshold: 0 at best, 1 at the threshold, negative toward the left camera and positive toward the right. The `rows` check takes the worst of its three measures, toward the right camera, whose image the correction moves.

| Check | Figures | Issue | Raised when |
|---|---|---|---|
| `timing` | `later`, the camera whose capture starts later, by `offsetMs`, the median, and `maxOffsetMs` over `pairs` | `timing_offset` | the median offset is over 1 ms; points at the later camera |
| `rows` | `misalignmentRows`, how far the right image sits from where the calibration puts it, `lower` or `higher` (`direction`): the measured `offsetRows` plus the `correctionRows` the automatic row correction moves it by; `bandOffsetRows` and their spread, `bandSpreadRows` | `row_offset` | the measured offset is over half a row |
| | | `large_row_correction` | the correction moves the right image more than 3 rows: recalibrate |
| | | `uneven_rows` | the four bands are more than 1 row apart: a camera turned, recalibrate |
| `focus` | `softer`, the less sharp camera, by `differencePercent`; `ratio`, right over left, and each camera's sharpness | `focus_mismatch` | the ratio is outside 0.8 to 1.25; points at the softer camera |
| `brightness` | `brighter`, the brighter camera, by `differencePercent`; each camera's mean grey, 0 to 255 | `brightness_mismatch` | one camera is more than 20% brighter than the other at the same exposure and gain, as through a hazy or dirty lens; points at the brighter camera |

Each camera's `issues` are those of the checks pointing at it. `VisionCore.Stereo.PairCheck` holds the thresholds and the issues.

`depth` judges how well the unit turns pairs into depth, with checks shaped as `pair`'s. They point at no camera, and their `gauge` runs from 0 to 1 at the threshold.

| Check | Figures | Issue | Raised when |
|---|---|---|---|
| `rate` | `droppedPercent`, the share of the slower camera's pairs, at `cameraHz`, that do not become depth, at `depthHz`; `loadPercent`, the stereo segment's busy share | `pairs_dropped` | more than 5% of the pairs are dropped: lower the cameras' frame rate or the stereo work |
| `range` | `nearPercent`, the share of the last pair's matched pixels in the nearest 15% of the disparity range; `nearestM`, the nearest depth that range measures | `too_near` | more than 15% of the matches are in that band: the scene is nearer than the unit measures, so widen the range or move back |

`VisionCore.Stereo.DepthCheck` holds their thresholds and issues.

[Vision unit](./README.md#dashboard-and-api) and [Vision performance](./performance.md) give what each figure measures and the values to aim for.

### Previews

`preview:left`, `preview:right` and `preview:depth` push `frame` events whose payload is one JPEG image, as binary. So does `preview:<name>` for each camera of its own, a `:camera` component ([A camera of its own](./cameras.md)): `preview:center` for the camera named `center`. A name the unit has no camera for is refused with `unknown stream`. The unit encodes a camera's frame only when your client is due one: at most `preview.max_hz` a second, whatever the camera's own rate.

The next frame comes once you push `ack`, so a slow link gets the newest frame instead of a backlog:

```javascript
const left = socket.channel('preview:left')
left.on('frame', (jpeg) => {
  URL.revokeObjectURL(image.src)
  image.src = URL.createObjectURL(new Blob([jpeg], { type: 'image/jpeg' }))
  left.push('ack', {})
})
left.join()
```

On `preview:depth`, push `depth_range` with `metres` to set the distance the depth video colours blue, or without to read it. `0` colours blue only what is infinitely far. The reply is the range in force. The range is the unit's, shared by every client. The channel pushes it as a `depth_range` event after every join and on every change, whoever makes it.

```javascript
const depth = socket.channel('preview:depth')
depth.on('depth_range', ({ metres }) => console.log(`blue at ${metres} m`))
depth.join()
depth.push('depth_range', { metres: 8 }).receive('ok', ({ metres }) => console.log(metres))
```

### Detections

On a unit with detection, `detections` pushes each result, at most ten a second, as a `detections` event. Each object has a label, a score, a distance in metres and an outline. The outline's vertices are `[x, y]` fractions of the left image's width and height. A pipeline on a camera of its own outlines its objects on that camera's image. An object it cannot place has a `distanceM` of `null`.

```json
{
  "detections": [
    {"label": "person", "score": 0.81, "distanceM": 2.4, "outline": [[0.42, 0.18], [0.58, 0.18], [0.58, 0.83], [0.42, 0.83]]}
  ]
}
```

On a unit without detection, the join is refused with `{"reason": "unavailable"}`.

`detections` carries the default pipeline. A pipeline named in the vehicle's composer, `:vehicle_detection` for instance, has its own channel, `detections:vehicle_detection`, which pushes the same `detections` event with the same payload. `detections:detection` and a name no pipeline runs under are refused with `{"reason": "unavailable"}`. The names come from `GET /api/exporters`, whose API outputs list each `detections:<name>`.

### Segmentation

A unit with a segmentation pipeline ([Road segmentation](./segmentation.md)) has a channel per pipeline, `segmentation:<name>`. The names come from `GET /api/exporters`, with the camera each one segments as its `source`.

The channel pushes each result as a `segmentation` event whose payload is binary, at most the pipeline's `maxHz` a second (5 by default). It pushes the next one only once you push `ack`, as on the previews. A result that comes before replaces the one waiting, so a slow link gets the newest grid instead of a backlog. The payload is eight unsigned 16-bit little-endian integers, then the label grid.

| Bytes | Content |
|---|---|
| 0–3 | The camera frame's width and height, in pixels |
| 4–11 | The band of the frame the grid covers, in the frame's pixels: `x`, `y`, `width`, `height` |
| 12–15 | The grid's width and height, in cells |
| 16– | One class id a cell, one byte each, row by row |

The grid is stretched over the band. Each cell is the band's width over the grid's width wide, and the band's height over the grid's height high.

On every join, a rejoin included, the channel pushes a `classes` event before any grid. It holds `labels`, the class names indexed by class id, and `roadClasses`, those the pipeline counts as road.

```javascript
const scene = socket.channel('segmentation:scene')
let classes = null
scene.on('classes', (names) => { classes = names })
scene.on('segmentation', (payload) => {
  const view = new DataView(payload)
  const [frameW, frameH, x, y, w, h, gridW, gridH] = [0, 1, 2, 3, 4, 5, 6, 7].map((i) => view.getUint16(i * 2, true))
  const grid = new Uint8Array(payload, 16, gridW * gridH)
  console.log(classes?.labels[grid[0]], `over ${w}×${h} at ${x},${y} of ${frameW}×${frameH}`)
  scene.push('ack', {})
})
scene.join()
```

A name no segmentation pipeline of the unit runs under, a detection pipeline's included, is refused with `{"reason": "unavailable"}`.
