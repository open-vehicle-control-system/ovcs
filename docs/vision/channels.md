---
title: Vision channels
description: How a program follows the vision unit's status, previews, detections and segmentation live over Phoenix channels.
---

Follow the vision unit live from a program: its status, its camera and depth previews, and its pipelines' detections and label grids. You need the unit's address and a Phoenix channels client. [Vision API](./api.md) covers the HTTP resources.

The unit serves a socket next to the dashboard, over HTTPS, at `/sockets/dashboard`. It speaks the Phoenix channels protocol. With the [`phoenix`](https://www.npmjs.com/package/phoenix) JavaScript client, in a browser or in Node.js:

```javascript
import { Socket } from 'phoenix'

const socket = new Socket('wss://<vehicle>-vision.local/sockets/dashboard')
socket.connect()

const status = socket.channel('status')
status.on('status', (snapshot) => console.log(snapshot.depthHz, snapshot.quality.matchedPercent))
status.join()
```

The socket takes connections from the unit's own pages only: a browser page of another origin is refused with a 403. A program that sends no `Origin` header connects.

The unit's certificate is self-signed. In a browser, accept it on the dashboard first. Run Node.js with `NODE_EXTRA_CA_CERTS=vision.pem`, a copy of it ([Dashboard and API](./README.md#dashboard-and-api)).

A channel answers an event it does not take with an error reply, `{"reason": "unknown event"}`, and stays joined.

## Status

`status` pushes a `status` event on join, then one a second: a `VisionCore.Status` snapshot with camelCase keys. A camera's or the sync's figures that were not measured are left out.

`cameras` holds the stereo sides and each camera of its own, by name (`center` here). A camera of its own has no `issues`.

`npu` is the accelerator the detection and segmentation pipelines run on, `null` on a unit without one:

- `kind`, and `state`: `starting` while a backend prepares its model, `running`, or `failed`;
- `loadPercent`, the share of the last second its pipelines spent inferring, at most 100, `null` until a Port has reported a time;
- each pipeline's mean `inferenceMs` over that second, `null` in a second without a frame.

[Accelerator load](./detection.md#accelerator-load) says what they measure on each accelerator.

`stereoLoadPercent` is the share of the last second the stereo pairs spent at the stereo pipeline's device, at most 100. A pair's time runs from its hand-over to the device's reply: on a GPU, the upload of its frames, the submission and the GPU's work. The download of its outputs is left out, as it runs during the next pair's device work. The device takes one pair at a time, so at 100 % the pipeline drops the cameras' pairs that come faster. [Stereo load](./performance.md#stereo-load) says how it compares with the GPU's own busy share.

`pipelines` holds the time of each pipeline, by its name, `stereo` for the stereo pipeline:

- `stages`, the mean time of each step over the last second's pairs or frames, in milliseconds, by the step's name. The name is the last segment of the stage's id in `GET /api/stages`: `stereo.speckle_filter` is `speckle_filter`.
- `segments`, the runs of steps computed as one, each with its `stages` in order and its one time, `ms`. Those steps have no entry in `stages`.
- `totalMs`, the sum of the steps' and segments' times: the work one pair or frame takes, without the time it waits. A stereo segment's download that runs during the next pair's device work counts once.

A step that did not run in the second is `null`, and so is the `totalMs` of a pipeline none of whose steps ran. [Step times](./performance.md#step-times) says what each time covers.

`latencies` holds, under `stereo` on a unit with stereo cameras, two waits over the last second, in milliseconds. They are no step's work, so no `totalMs` counts them:

- `cameras`, from a frame's capture to its arrival in the unit, the mean over both cameras' frames;
- `pairing`, from the arrival of a pair's earlier frame to the pair going to the stereo pipeline, the mean over the pairs.

Each is `null` in a second without a frame or a pair. [Latencies](./performance.md#latencies) says what each one covers.

`distances` holds each detection and segmentation pipeline on a camera of its own, by its name: its `camera`, and `available`, whether that camera has the calibration and the pose the stereo depth is projected into it with. Without them, the pipeline's detections have no distance and its segmentation no points. With them, a result can still lack a distance, as one whose frame no stereo pair matched. `reason` says what is missing, `null` when available:

| `reason` | The camera | To do |
|---|---|---|
| `no_calibration` | has no `calibration:` file | [calibrate it](./calibration.md#a-camera-of-its-own) |
| `unreadable_calibration` | has a calibration file that cannot be read | calibrate it again, or fix the file |
| `unusable_calibration` | has a calibration whose lens model the unit cannot project with | calibrate it with the `plumb_bob` or `equidistant` model |
| `no_pose` | has no pose: where it sits relative to the stereo pair is unknown | [measure its pose](./cameras.md#measure-the-pose) |
| `unreadable_pose` | has a pose file that cannot be read | fix the file |

A pipeline that does not answer is left out.

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
    "rate": {"level": "ok", "camera": null, "issues": [], "gauge": 0.2, "droppedPercent": 1.0,
             "depthHz": 29.7, "cameraHz": 30.0, "loadPercent": 94.8},
    "range": {"level": "warning", "camera": null, "issues": ["too_near"], "gauge": 1.5, "nearPercent": 22.5, "nearestM": 1.39}
  },
  "alignment": {"offsetRows": 0.09, "bandOffsetRows": [0.22, 0.28, 0.11, -0.14]},
  "sharpness": {"left": 0.0048, "right": 0.0056},
  "quality": {"matchedPercent": 64.7, "jitterPx": 0.087, "meanDisparityPx": 11.9, "spreadPx": 7.7},
  "depthHz": 30.0,
  "stereoLoadPercent": 94.8,
  "npu": {"kind": "Hexagon", "state": "running", "loadPercent": 23.1,
          "pipelines": {"objects": {"inferenceMs": 2.1}, "scene": {"inferenceMs": 5.6}}},
  "pipelines": {
    "stereo": {"totalMs": 31.6, "stages": {},
               "segments": [{"stages": ["rectification", "sharpness", "disparity", "speckle_filter", "row_alignment",
                                        "temporal_filter", "depth", "point_cloud", "quality"], "ms": 31.6}]},
    "objects": {"totalMs": 11.9, "stages": {"input": 0.8, "inference": 10.3, "filtering": 0.1, "placement": 0.7}, "segments": []},
    "scene": {"totalMs": 21.4, "stages": {"input": 0.3, "inference": 14.6, "classes": 6.5}, "segments": []}
  },
  "latencies": {"stereo": {"cameras": 4.2, "pairing": 1.1}},
  "distances": {
    "objects": {"camera": "center", "available": false, "reason": "no_pose"},
    "scene": {"camera": "center", "available": false, "reason": "no_pose"}
  },
  "exporters": [{"id": "ros2_zenoh", "name": "ROS 2 · Zenoh", "status": {"level": "warning", "detail": "Disconnected"}},
                {"id": "api", "name": "API", "status": {"level": "ok", "detail": "Answering"}}]
}
```

`exporters` holds the status of each exporter `GET /api/exporters` lists, the API's own last. A `level` is `ok`, `warning` or `off`; for an exporter that does not run, `detail` says why. The processors' load is the board's, in `GET /api/board`.

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
| `rate` | `droppedPercent`, the share of the slower camera's pairs, at `cameraHz`, that did not become depth, at `depthHz`, all three over the last 10 s; `loadPercent`, the last second's `stereoLoadPercent` | `pairs_dropped` | more than 5% of the pairs are dropped: lower the cameras' frame rate or the stereo work |
| `range` | `nearPercent`, the share of the last pair's matched pixels in the nearest 15% of the disparity range; `nearestM`, the nearest depth that range measures | `too_near` | more than 15% of the matches are in that band: the scene is nearer than the unit measures, so widen the range or move back |

The `rate` check is `off` until the unit has counted pairs for 10 s. Over 10 s, a frame counted in one second rather than the next moves `droppedPercent` by a pair in 300, not one in 30. `VisionCore.Stereo.DepthCheck` holds their thresholds and issues.

[Vision unit](./README.md#dashboard-and-api) and [Vision performance](./performance.md) give what each figure measures and the values to aim for.

## Previews

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

`preview:depth` pushes the distance the depth video colours blue as a `depth_range` event, `metres`, after every join and on every change, whoever makes it. `0` colours blue only what is infinitely far. The range is the unit's, shared by every client, and set with [`PATCH /api/depth-preview`](./api.md#the-depth-videos-colour-range).

```javascript
const depth = socket.channel('preview:depth')
depth.on('depth_range', ({ metres }) => console.log(`blue at ${metres} m`))
depth.join()
```

## Video

A camera with an H.264 output that the vehicle names in `preview: [videos: [center: :full_h264]]` ([A camera of its own](./cameras.md#outputs)) has a channel `video:<name>`. `GET /api/exporters` lists it among the API's outputs as `camera_video:<name>:<output>`. A camera whose video the unit does not relay is refused with `unknown video`, and any camera with `{"reason": "unavailable"}` while the relay does not run.

The channel pushes every frame of the stream in order, from the next key frame, as a `frame` event whose payload is binary:

| Bytes | Content |
|---|---|
| 0 | Flags: bit 0 is set on a key frame |
| 1–8 | The frame's capture time, in microseconds on the unit's monotonic clock, signed 64-bit little-endian |
| 9–12 | The frame's width and height, in pixels, unsigned 16-bit little-endian |
| 13– | The frame's NAL units in Annex B form; each key frame carries the sequence and picture parameter sets |

Push `ack` for each frame you have taken. The unit sends at most ten frames you have not acknowledged and queues thirty more. Past that it drops the queue and resumes at the next key frame, so a slow link skips frames instead of falling behind.

A decoder needs every frame since the last key frame. The detections and segmentation grids carry the same capture time as the frames, so a client draws each result on the frame it was found on.

In a browser, decode the frames with WebCodecs' `VideoDecoder`, which exists only in a secure context: HTTPS, as the unit serves it, or `localhost`. Configured without a `description`, it takes Annex B. The codec string is `avc1.` followed by bytes 1 to 3 of the key frame's sequence parameter set, in hexadecimal. The example draws each frame on a canvas, `canvas`:

```javascript
const context = canvas.getContext('2d')
const decoder = new VideoDecoder({
  output: (frame) => {
    context.drawImage(frame, 0, 0, canvas.width, canvas.height)
    frame.close()
  },
  error: (error) => console.error(error)
})

const video = socket.channel('video:center')
video.on('frame', (payload) => {
  const view = new DataView(payload)
  const key = (view.getUint8(0) & 1) === 1
  const captureUs = Number(view.getBigInt64(1, true))
  const h264 = new Uint8Array(payload, 13)
  if (key && decoder.state === 'unconfigured') decoder.configure({ codec: 'avc1.640032', optimizeForLatency: true })
  if (decoder.state === 'configured') decoder.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: captureUs, data: h264 }))
  video.push('ack', {})
})
video.join()
```

Each decoded frame's `timestamp` is its capture time.

## Detections

Each detection pipeline has its own channel, `detections:<name>`. It pushes each result as a `detections` event, at most the pipeline's `maxHz` a second (10 by default). `captureUs` is the capture time of the frame they were found on, as the video's frames carry it, so a client draws them on that frame. Each object has a label, a score, a distance in metres and an outline. The outline's vertices are `[x, y]` fractions of the left image's width and height. A pipeline on a camera of its own outlines its objects on that camera's image. An object it cannot place has a `distanceM` of `null`.

```json
{
  "captureUs": -576460646943025,
  "detections": [
    {"label": "person", "score": 0.81, "distanceM": 2.4, "outline": [[0.42, 0.18], [0.58, 0.18], [0.58, 0.83], [0.42, 0.83]]}
  ]
}
```

A pipeline named in the vehicle's composer, `:vehicle_detection` for instance, is on `detections:vehicle_detection`. A detector without a name is the pipeline `detection`, on `detections:detection`. A name no pipeline runs under is refused with `{"reason": "unavailable"}`. The names come from `GET /api/exporters` ([Vision API](./api.md#the-unit-and-its-exports)), whose API outputs list each `detections:<name>`.

## Segmentation

A unit with a segmentation pipeline ([Road segmentation](./segmentation.md)) has a channel per pipeline, `segmentation:<name>`. The names come from `GET /api/exporters`, with the camera each one segments as its `source`.

The channel pushes each result as a `segmentation` event whose payload is binary, at most the pipeline's `maxHz` a second (5 by default). It pushes the next one only once you push `ack`, as on the previews. A result that comes before replaces the one waiting, so a slow link gets the newest grid instead of a backlog. The payload is eight unsigned 16-bit little-endian integers, the frame's capture time, then the label grid.

| Bytes | Content |
|---|---|
| 0–3 | The camera frame's width and height, in pixels |
| 4–11 | The band of the frame the grid covers, in the frame's pixels: `x`, `y`, `width`, `height` |
| 12–15 | The grid's width and height, in cells |
| 16–23 | The capture time of the frame it was segmented from, in microseconds, signed 64-bit little-endian, as the video's frames carry it |
| 24– | One class id a cell, one byte each, row by row |

The grid is stretched over the band. Each cell is the band's width over the grid's width wide, and the band's height over the grid's height high.

On every join, a rejoin included, the channel pushes a `classes` event before any grid. It holds `labels`, the class names indexed by class id, and `roadClasses`, those the pipeline counts as road.

```javascript
const scene = socket.channel('segmentation:scene')
let classes = null
scene.on('classes', (names) => { classes = names })
scene.on('segmentation', (payload) => {
  const view = new DataView(payload)
  const [frameW, frameH, x, y, w, h, gridW, gridH] = [0, 1, 2, 3, 4, 5, 6, 7].map((i) => view.getUint16(i * 2, true))
  const grid = new Uint8Array(payload, 24, gridW * gridH)
  console.log(classes?.labels[grid[0]], `over ${w}×${h} at ${x},${y} of ${frameW}×${frameH}`)
  scene.push('ack', {})
})
scene.join()
```

A name no segmentation pipeline of the unit runs under, a detection pipeline's included, is refused with `{"reason": "unavailable"}`.

## Calibration

`calibration` follows what the [calibration routes](./api.md#calibration) change. On join, it pushes a `calibration` event for each calibration the unit has, then a `session` event; afterwards, a `calibration` event each time the unit takes another calibration, and a `session` event on each change of the session, a new detection at most 15 times a second.

- A `calibration` event carries the calibration's `id` and its attributes, as `GET /api/calibrations/:id` gives them.
- A `session` event carries the session's attributes, as the action routes answer them, and `calibration`, the id of the calibration it works on, `null` while idle.
- A `saved` event carries `calibration`, the id of a calibration whose [kept calibrations](./api.md#the-calibrations-kept) changed: one was kept, renamed, removed or put in force. Read `GET /api/saved-calibrations?filter[calibration]=<id>` again.

```javascript
const calibration = socket.channel('calibration')
calibration.on('calibration', ({ id, source }) => console.log(id, source))
calibration.on('session', ({ phase, samples, progress }) => console.log(phase, samples, progress))
calibration.join()
```

Joining turns the unit's board detection on, until the last client leaves. The channel takes no push: every change goes through the routes, and a pushed event gets an error reply. On a unit with nothing to calibrate, the join is refused with `{"reason": "nothing to calibrate"}`; while the unit's calibration session is not running, with `{"reason": "unavailable"}`, which the dashboard retries.
