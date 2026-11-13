---
title: Vision API
description: How a program reads and changes the vision unit's parameters, and reads its configuration, firmware and exports, over HTTPS.
---

The vision unit serves its API next to the dashboard, over HTTPS:

```text
https://<vehicle>-vision.local
```

Its certificate is self-signed. The examples check it against a copy, `vision.pem`, as [Dashboard and API](./README.md#dashboard-and-api) shows.

Everything the dashboard shows comes from it:

- resources under `/api`, which follow [JSON:API](https://jsonapi.org/);
- live channels on a Phoenix socket at `/sockets/dashboard` ([Vision channels](./channels.md)).

The examples come from units of several builds, shortened where a list is long. [`vision/api/README.md`](../../vision/api/README.md) lists every route with its status codes.

## Requests and errors

Every answer under `/api` is `application/vnd.api+json`. A write sends its document as a JSON body, with the content type `application/vnd.api+json` or `application/json`. Sent as a form or in the query string, the document is missing and the answer is a 400. A body that is not valid JSON is a 400 too, and a request whose `Accept` header takes no JSON a 406.

A refusal is an `errors` list holding one error object. When a member of your document is at fault, `source.pointer` names it:

```sh
curl --cacert vision.pem -X PATCH https://<vehicle>-vision.local/api/parameters/stereo.disparity.p1 \
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
curl --cacert vision.pem -X PATCH https://<vehicle>-vision.local/api/parameters/stereo.disparity.p1 \
  -H 'content-type: application/vnd.api+json' \
  -d '{"data": {"type": "parameters", "id": "stereo.disparity.p1", "attributes": {"value": 10}}}'
```

The answer is the parameter with `value` 10 and `state` `unsaved`. A live parameter applies from one of the next pairs. The unit answers:

- a 422 for a value outside the constraint or a parameter fixed in the build;
- a 409 for a `type` or `id` that does not match the URL;
- a 400 for a document without `data.type`, `data.id` or `data.attributes.value`.

Then save, discard or reset. Each is a `POST` that answers a 201 with the ids of the parameters it touched:

```sh
curl --cacert vision.pem -X POST https://<vehicle>-vision.local/api/parameter-saves \
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
- `POST /api/parameter-resets` returns parameters to their defaults: the stage or parameter its `target` relationship names, or every parameter in a document without `relationships`. `relationships` that do not hold a well-formed `target` are a 400, and nothing is reset.

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

## The depth video's colour range

`GET /api/depth-preview` returns the distance the depth video colours blue, in metres. `0` colours blue only what is infinitely far.

```json
{
  "data": {
    "type": "depth-previews",
    "id": "current",
    "attributes": {"colourRangeM": 8.0}
  }
}
```

`PATCH /api/depth-preview` sets it, from 0 to 50:

```sh
curl --cacert vision.pem -X PATCH https://<vehicle>-vision.local/api/depth-preview \
  -H 'content-type: application/vnd.api+json' \
  -d '{"data": {"type": "depth-previews", "id": "current", "attributes": {"colourRangeM": 12}}}'
```

The range is a view setting of the unit, shared by every client: it is not saved, and a restart puts back the one of the vehicle's configuration. The answers are:

- a 200 with the resource;
- a 422 for a range the unit refuses;
- a 409 for another `type` or `id`;
- a 400 for a document without `data.type`, `data.id` or `data.attributes.colourRangeM`;
- a 503 while the previews do not run.

The `preview:depth` channel pushes the range to its clients on every change; see [Live channels](./channels.md).

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
          {"name": "camera_frame:center:half_jpeg", "maxHz": null},
          {"name": "camera_video:center:full_h264", "maxHz": null}
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

The example unit has a camera `center`, with a detection pipeline `objects` and a segmentation pipeline `scene` on it. The API lists a `camera_frame:<name>` output for each camera of its own that sends an image, between `stereo_pair` and the detections: `camera_frame:center` here. Each has a `preview:<name>` channel ([Previews](./channels.md#previews)). An exporter that reads another output of a camera than its default lists it as `camera_frame:<name>:<output>`, such as `camera_frame:center:half_jpeg`. One that reads a camera's H.264 video lists it as `camera_video:<name>:<output>`, such as `camera_video:center:full_h264`, its `maxHz` `null`.

A unit lists each detection pipeline's output: `detections:<name>` for the pipeline `<name>`, `detections:detection` for a detector without a name. The API lists every pipeline's; the ROS 2 exporter lists those its `detections:` names. The API's detection outputs name their pipeline's `source`, the preview its boxes belong on. It is `left` for the stereo pair, or the name of a camera of its own: `center` for `objects`.

A unit with segmentation pipelines lists `segmentation:<name>` for the pipeline `<name>`, after the detections. The API lists every one, with the pipeline's camera as its `source`. The ROS 2 exporter lists them only with its `segmentation:` option: those its `pipelines:` names, or without `pipelines:` every one on a camera.

A status `level` is `ok`, `warning` or `off`; for an exporter that does not run, `detail` says why. Writing an exporter of your own is in [How a pair flows](./data_flow.md#exporters).

An action is listed with its `name`, a `label` and a `description`. `POST /api/exporters/:id/actions/:name` runs it, with a JSON:API document of the type `exporter-actions`. The action's parameters go in `attributes` when it takes any.

This request runs the `export` action of an exporter whose id is `debug`, which answers a zip file ([Tune with exports](./tuning.md)), and saves it:

```sh
curl --cacert vision.pem --fail-with-body -X POST https://<vehicle>-vision.local/api/exporters/debug/actions/export \
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

The unit pushes its status, its previews and its pipelines' results on a Phoenix socket at `/sockets/dashboard`. [Vision channels](./channels.md) has each channel's topic, events and payloads.
