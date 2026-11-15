---
id: TASK-165
title: Make the OVCS Mini's left camera a colour camera of its own
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-15T10:14:00Z'
updated_date: '2026-11-15 12:00'
labels:
  - vision
dependencies: []
ordinal: 110000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The OVCS Mini's vision unit has no colour image: both IMX708 cameras deliver 480×270 grey frames to the stereo unit. OVCS1 has a colour camera of its own, `:center`, on a third sensor. The Mini has no third sensor, but the Pi 5's ISP can make a second stream from the left camera's capture.

Give the Mini a colour camera of its own, `:left`, made from a second ISP stream of the stereo unit's left capture. It works as OVCS1's `:center` does: a `:camera` component, named outputs, the preview, the ROS 2 exporter's `cameras:`, the bag presets, its own calibration and its pose measured on the Calibration page. The stereo path is unchanged but for its sides' names (section 3): same driver, same grey frames, same rate. Detection stays on the stereo pairs; detection or segmentation on the colour image is out of scope.

Measured on the Mini with a throwaway build (`camera_capture` asking libcamera for two YUV420 streams in one request, `[VideoRecording 1152×648, ViewFinder 480×270]`):

| Figure | Value |
|---|---|
| 480×270 luma | byte for byte the grey frames of a one-stream capture: same size, stride and range |
| 1152×648 JPEG encode, every 3rd frame | about 5 ms |
| Added CPU | 4.8 % of one core |
| Stereo | 20 pairs a second, 0 % dropped, matching unchanged |

Not explained yet: `CameraConfiguration::validate()` returns Adjusted with two streams, probably for the colour space. The streams are limited-range YUV, written into the JPEG as full range, so the image has flat contrast; the `format: :jpeg` path has the same fault today.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A stereo unit and a camera of its own named `:left` run side by side: status, previews, exporter outputs, detection sources and calibration sessions tell them apart
- [ ] #2 The stereo sides are named under the stereo unit's prefix wherever a camera of its own's name can appear, on every vehicle: frame labels, status keys and channels `preview:<prefix>/left`, `preview:<prefix>/right`, `preview:<prefix>/depth`; exporter outputs `{:stereo_frame, side}`
- [ ] #3 `camera_capture` without `--output` behaves as today; with an ISP output it writes OUTPUT_JPEG records at most `--outputs-max-hz` a second beside unchanged grey records
- [ ] #4 A `:camera` with `driver: VisionCore.Camera.LibCameraStream, stream_of: :left` publishes its outputs under its own keys; the Pairer never receives them
- [ ] #5 A restart of the stereo unit leaves the camera unit up and reports it absent until frames return; a restart of the camera unit leaves the stereo unit untouched
- [ ] #6 `stream_of:` on a stereo unit whose driver is not `VisionCore.Camera.LibCamera`, a side taken twice, or an ISP output larger than the side's sensor mode is refused at start, saying why
- [ ] #7 On the Mini: `/left/image_raw/compressed` at 10 Hz, 1152×648, full-range colour; `/stereo/left/image_raw/compressed` unchanged; stereo at 20 pairs a second with 0 % dropped; added CPU within 6 % of one core
- [ ] #8 The `left` camera is calibrated at 1152×648 and its pose measured on the Calibration page, as OVCS1's `center`; both are shipped in `vehicles/ovcs_mini/priv/calibration/`
- [ ] #9 Guides updated: `docs/vision/cameras.md`, `docs/vision/data_flow.md`, `docs/vision/channels.md`, `docs/vision/api.md`, `vision/rust/README.md`
- [x] #10 PR 1: the stereo unit gives each side's driver its `:side`; `V4L2Pair`, the Pairer, the stereo parameters, the ROS 2 diagnostics and the focus sweep tell the sides apart by it or by the labels the unit gives, never by a label's text; nothing visible changes
- [ ] #11 PR 2: with a stereo unit and a camera `:left` of its own, the status, the preview channels, the exporter outputs, the detection sources and a pose session tell them apart; a camera `topic_prefix:` that lands on a stereo topic is refused; the stereo unit's ROS 2 topics, frame ids, parameters and calibration files are unchanged
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
### 1. Who owns the capture

One libcamera camera is opened by one process. Today the left capture belongs to the stereo unit's left `VisionCore.Camera.LibCamera` driver.

Constraints from the code:

- `VisionCore.Stereo.Supervisor` runs one driver module for both sides. The side drivers carry the sync roles and the `stereo.cameras.*` controls, which `VisionCore.Stereo.Parameters`, the Pairer, `VisionCore.Status` and the diagnostics call.
- `VisionCore.Status` reports a camera of its own present only when a process is registered under its driver's `name_for/1`.
- The consumers find a camera's outputs from the `:camera` component's own options (`VisionCore.Camera.Unit.camera_outputs/2`, `output_key/3`, `settings/1`), not from a started process.
- `VisionCore.Application` resolves each component from its own options.

Options:

| Option | For | Against |
|---|---|---|
| A. The stereo side's driver owns the capture and opens the second stream. A camera of its own, whose driver relays that stream, names the side with `stream_of:`. (chosen) | Stereo path, driver and restarts unchanged; the camera unit is a real registered process with honest `outputs/1`; outputs declared once, on the camera, as on OVCS1 | The side's driver must be told about the stream: see the wiring below |
| B. The camera of its own owns the capture and makes the grey too; the stereo left side reads it | One owner of the colour settings | Two driver modules in one stereo unit; sync roles, controls and diagnostics move out of the stereo unit; a crash of the camera unit stops the depth |
| C. The camera unit asks the side's driver at runtime to add the stream | No wiring at the root | Restarts the left capture after boot, and again after every restart of either unit; ordering between units |

**Design (A):**

- New driver `VisionCore.Camera.LibCameraStream`: "a camera of its own made by a second stream of a stereo camera's libcamera capture". It registers under `name_for/1`, as every driver does. It subscribes to the side driver's output keys and republishes each frame under `{:camera_frame, name_for(label), output}`, with its own `:label` and `:frame_id`. It implements `name_for/1`, `outputs/1`, `fixed_settings/1` and `running?/1`, which asks the side's driver and answers `false` while it is not registered. It has no `control_specs/0`: the sensor's controls stay the stereo unit's `stereo.cameras.*`, so the camera has no parameter group. It has no `live/1`, so no duplicate of `/stereo/left/exposure_us` is published.
- `VisionCore.Camera.LibCamera` takes two side options: `:outputs`, the camera's resolved outputs, and `:outputs_max_hz`. It passes them to `camera_capture` and publishes the records under `{:camera_frame, name_for(label), output}`. Its grey frames stay under `{:camera_frame, name_for(label)}`, the key the Pairer subscribes to, so the Pairer never receives a colour frame.
- Wiring: a pure function in `VisionCore.Components`, called by `VisionCore.Application` before the components resolve. It hands each `:camera` with `stream_of: side` its outputs and `max_hz`, as the `:outputs` and `:outputs_max_hz` of that side in the `:stereo` component. It refuses at start, naming the camera:
  - a stereo driver other than `LibCamera`;
  - no stereo unit;
  - a side named twice: the Pi 5 ISP is taken to have two output streams, the grey using one, which PR 3 checks on the unit;
  - an ISP output larger than the side's `:sensor_mode`, or of an odd size.

  The refusal happens before any capture opens, so a wrong colour size never stops the stereo side.
- The wiring lands in the stereo unit's child spec. `VisionCore.Reviver` and `VisionCore.Stereo.Calibration` restart the unit with `Supervisor.restart_child/2`, which reuses that spec, so the stream survives a revival and a calibration commit.
- The relay finds the side's driver as the Pairer does: the stereo unit's driver module and `name_for/1` of the side's label (`VisionCore.Stereo.Supervisor.cameras/1`).
- Alternative wiring, not chosen: the composer passes the same outputs to the side and to the camera, and the root checks that they match. It is explicit, but declares the same thing twice.

**Restarts:**

- When the stereo unit restarts or gives up, the colour stream stops with the left capture. The camera unit stays up and its subscription holds (`VisionCore.Outputs`). Status reports it absent through `running?/1` until frames return.
- When the camera unit restarts or gives up, the stereo unit is untouched. The stream is still encoded with no subscriber, until the Reviver starts the camera unit again.

### 2. Outputs

The OVCS1 output names, with the same meaning: `full` is the sensor mode's size, `half` is half of it. The Mini's sensor mode is 2304×1296, so 1152×648 is `half`.

```elixir
{:camera,
 name: :left,
 driver: VisionCore.Camera.LibCameraStream,
 stream_of: :left,
 # 10 of the cameras' 30 frames a second keep the encode off the stereo's cores.
 max_hz: 10,
 outputs: [
   half: [resolution: {1152, 648}, processor: :isp, send: false],
   half_jpeg: [from: :half, format: :jpeg, quality: 80]
 ],
 calibration_store_dir: "/data/vision/calibration"}
```

- `processor: :isp` is the ISP's second stream: YUV420, never sent. `VisionCore.Camera.Output.resolve/3` already refuses a JPEG made by a processor, so the JPEG is made `from:` it, as OVCS1's `half_jpeg` is. `half_jpeg` is the camera's default output, its only sent one.
- `LibCameraStream.outputs/1` resolves them with `formats: [:rgb, :jpeg]` and, for `:isp`, the even sizes its outputs ask for: it does not see the side's sensor mode, so the wiring checks each size against it.
- No raw output is sent. Detection stays on the stereo pairs, and nothing reads raw colour. A 1152×648 RGB frame would cross the Port at 2.2 MB a frame for no consumer.
- `max_hz:` is the one new concept. On OVCS1 every output is made at every frame. Here the camera makes its outputs on at most `max_hz` frames a second, chosen on capture times by the rule of the stereo component's `max_hz` (`VisionCore.Stereo.Pairer`): a slot every `1 / max_hz` s, a frame due within three quarters of a frame period of its slot. Alternative: `every_n: 3`, after `detect_every_n`. It is simpler, but tied to the frame rate.

### 3. Names

**The camera is `:left`.** Its ROS 2 topics sit at the root, `/left/...`, beside `/stereo/left/...`, as OVCS1's `/center/...` sits beside `/stereo/...`. The dashboard menu shows "Left camera" (`cameraName` in `vision/dashboard/src/cameras.js`), beside "Stereo cameras".

A camera of its own named `left` collides with the stereo sides today. The rule: **the stereo sides are named under the stereo unit's prefix wherever a camera of its own's name can appear**, as their topics (`<prefix>/left`) and frame ids (`<prefix>_left`) already are. The prefix is the stereo unit's `:prefix`, `stereo` by default and on both reference vehicles, so the names below read `stereo/left`. The dashboard takes it from the API, not from its `STEREO` constant. The rule applies to every vehicle; OVCS1 changes only by these names.

| Where | Today | Collides with a camera `:left` | Becomes |
|---|---|---|---|
| `VisionCore.Pipelines` reserved names | `:left`, `:right` reserved, so `Unit.name!/1` raises | yes, refused at boot | `:left` and `:right` dropped. `:stereo`, `:depth`, `:disparity` and `:points` stay. The ROS 2 exporter refuses a `topic_prefix:` that puts a camera's or pipeline's topics on a stereo topic |
| Frame `:label` of a stereo side | `"left"`, `"right"` | yes: `VisionCore.Status` counts frames by label, `VisionCore.Preview` picks its stream by label, `VisionCore.Calibration` pairs a pose session's frames by label (`@pose_left_label "left"`) | `"<prefix>/left"`, `"<prefix>/right"`. A driver tells its side from a `:side` option, not its label: `VisionCore.Camera.V4L2Pair` (`label == "left"`, `name_for("left")`), the Pairer, `VisionCore.Stereo.Parameters`, `VisionCore.Ros2.ZenohExporter.Diagnostics`, `VisionCore.Camera.FocusSweep`, `VisionCore.Ros2.Camera` |
| Status `cameras` | sides `:left`, `:right` merged with cameras of their own by name | yes: one count key, and the side overwrites the camera in `Map.merge` | `stereo/left`, `stereo/right` beside camera names |
| Preview channels | `preview:left`, `preview:right`, `preview:depth`, `preview:<camera>` | yes: `@stereo_streams` wins `preview:left` | `preview:stereo/left`, `preview:stereo/right`, `preview:stereo/depth`. Depth moves too: it is the stereo unit's product, under `<prefix>/depth` on ROS 2. `preview:center` is unchanged |
| Exporter output of a side's frames | `{:camera_frame, :left}` (`VisionCore.Stereo.Supervisor.outputs/1`, `VisionCore.Exporter.producer/1`, the bag exporter's `Preset.kind/1`, `ExporterController`'s `camera_frame:left`) | yes: the same term as a camera `:left`'s default output | `{:stereo_frame, :left}`, API `stereo_frame:left`, after `:stereo_pair`. Output names carry no prefix today |
| Detection source in the API and dashboard | `"left"` for the stereo (`ExporterController.source_name/1`, `pipelineResults.js`) | yes | `"stereo/left"`, the id of the preview its boxes are drawn on |
| Calibration session cameras (API JSON, Result and In use tables) | the pose target's stereo camera is `"left"` | yes: two cameras `left` | the label, `stereo/left` |
| ROS 2 topics | `/stereo/left/...` | no | unchanged; the camera publishes `/left/...` |
| Frame ids | stereo `stereo_left_optical` on both reference vehicles, `<prefix>_left` by default | no | unchanged; the camera's is `left_optical`, the `:camera` default |
| Parameters | `stereo.cameras.*` | no; and `LibCameraStream` has none | unchanged |
| Calibration files | `stereo_left.yaml` | no | the camera's are `camera_left.yaml` and `camera_left_pose.yaml` in the store |
| Registered names | `LibCamera.L_left` | no: `LibCameraStream.L_left` is another module | follow the labels |

**Frame labels.** `Status`, `Preview` and `Calibration` tell cameras apart by `Frame.label`, so one of the two `"left"` labels must change. Options:

| Option | Changes | For | Against |
|---|---|---|---|
| A. The stereo sides are labelled `"<prefix>/left"`, `"<prefix>/right"`, and drivers take their side from a `:side` option (chosen) | the stereo drivers (`V4L2Pair`, `LibCamera`, `GStreamer`, `Ros2.Camera`), Pairer, stereo parameters, diagnostics, focus sweep, `Calibration` and `Calibration.Library`'s lens names | One rule: a frame's label is its camera's public name everywhere: status, previews, calibration tables, logs | Touches OVCS1's stereo driver, so it is a refactor of its own (PR 1), with no behaviour change |
| B. A camera of its own's frames take a scoped label (`"camera/left"`), and the stereo labels stay | `Camera.Unit`, and the name-to-label mapping in `Status`, `Preview` and `Calibration` | No stereo driver changes | A camera's label stops being its name; the stereo sides still need the visible renames of the table; two naming schemes to map |
| C. `Frame` gets a field naming its camera, set by every driver | every driver and the `VisionCore.Camera` contract | Labels untouched | The largest contract change |

Nothing persisted holds a side's label: the stored stereo calibrations have `left` and `right` fields (`VisionCore.Models.StereoCameraCalibration`), and the debug export names its files by side. `Calibration.Library` maps lens names to those fields, so it maps from the side, with no migration.

`/left` and `/stereo/left` are the same sensor on ROS 2. `/left/...` is the colour image at 1152×648 in `left_optical`. `/stereo/left/...` is the grey frame the depth is computed from.

**Frame id.** `left_optical` must stay distinct from the stereo left's frame. The pose is published on `/tf_static` from the frame the depth is in, the rectified left camera (`stereo_left_optical`), to the camera's frame. Two consequences:

- One id would make a transform from a frame to itself.
- The colour image is the raw camera, so its pose is the left rectification rotation, not the identity.

**Other new names:**

| Name | What |
|---|---|
| `VisionCore.Camera.LibCameraStream` | the driver; singular, after `LibCamera`, and libcamera's own word for a camera's output |
| `stream_of:` | the `:camera` option naming the stereo side whose capture makes it |
| `max_hz:` | the camera's cap on the frames it makes its outputs on |
| `processor: :isp` | the ISP stream, as `:cpu` is `v4l2_capture`'s conversion |
| `:outputs`, `:outputs_max_hz` | `LibCamera`'s side options, set by the wiring |
| `--output isp:<width>x<height>[:unsent]`, `--output from:<index>:<width>x<height>:jpeg:<quality>` | `camera_capture`'s outputs, `v4l2_capture`'s grammar |
| `--outputs-max-hz <hz>` | `camera_capture`'s cap |
| OUTPUT_JPEG (tag 8, output index) | `v4l2_capture`'s record, parsed by one function both drivers share |

The repository spells "colour" (vision code and guides). The only "color" is in Foxglove message fields.

### 4. Calibration and pose

Same flow as OVCS1's `center`:

1. Calibrate the camera on its own at 1152×648 on the Calibration page. It is stored as `camera_left.yaml`. The page looks for the board in the default output, `half_jpeg`, which `VisionCore.Camera.Frame.to_tensor/1` decodes to grey.
2. Measure the pose on the Calibration page. It is stored as `camera_left_pose.yaml`.
3. Download both and ship them as `priv/calibration/left.yaml` and `left_pose.yaml`, with `calibration:` and `pose:` pointing at them.

No intrinsics are derived from the stereo calibration. A calibration at its own size also covers any difference in crop between the two ISP streams.

The pose session pairs frames captured within half a pair period of each other. Both streams come from one request, so the two frames have the same capture time.

Expected result: a translation near 0 mm and a rotation near the transpose of `stereo_left.yaml`'s `rectification_matrix`. It checks the measurement, and the page's position read-out shows it.

Until the pose is measured, `/tf_static` carries no transform for the camera. No pipeline runs on it, so nothing needs a distance.

### 5. Rates, encoding, range

- **Rate and size** are set in the composer: `max_hz:` and `outputs:` on the `:camera`. `camera_capture` skips the encode, and the record, for frames outside the schedule. Libcamera still fills the colour buffer on every request. Requests that carry the colour buffer only on scheduled frames would save that ISP write. That is a follow-up, only if memory bandwidth shows in the stereo times.
- **Encode inline**, on the request-completion thread after the grey record is written, as measured: 5 ms on every third frame. The grey record of the next frame can wait up to 5 ms. Check it against the Pairer's camera latency in the status (`latencies.cameras`). An encoder thread with a copy of the YUV buffer, as `v4l2_capture` does, is the alternative if it shows.
- **Range** is in scope, as its own PR:
  1. Log the colour space libcamera chooses, and find why `validate()` adjusts.
  2. Expand limited-range YUV to full range before the JPEG encode, for every JPEG `camera_capture` writes.
  3. Leave the grey stream as it is: the stereo is tuned on it.

### 6. ROS 2

`cameras: [names: [:left]]` publishes, as for `center`:

- `/left/image_raw/compressed`: `half_jpeg` as it is, no re-encode;
- `/left/camera_info`: empty until calibrated, then at 1152×648;
- `/left/set_camera_info`;
- `/tf_static` from `stereo_left_optical` to `left_optical`, once a pose exists.

`/stereo/left/image_raw/compressed` does not change. It is the grey frame that `/stereo/left/camera_info` (480×270) and the depth describe, and the bag `replay` preset records it. The bag presets pick the camera up as any camera of their own: `replay` records `half_jpeg`, at 10 Hz from the cap, and `review` records it at 10 Hz. `BagExporter.Preset` is not on `main` yet, so its rename to `{:stereo_frame, side}` goes with whichever of the two lands second.

### 7. Generality

Nothing in this design is specific to the Mini outside `vehicles/ovcs_mini/`:

- `LibCameraStream`, the wiring and `camera_capture`'s outputs serve any `LibCamera` stereo unit, on either side, one stream per side.
- `stream_of:` on a `V4L2Pair`, `GStreamer` or `Ros2.Camera` stereo unit is refused at start.
- OVCS1 (`V4L2Pair`, IMX296) gets nothing new. It changes only by the names of the PRs below: preview channels, status keys, outputs, detection source.

### 8. Pull requests

Each PR becomes its own task once this design is agreed. Each one ships on its own.

Unmerged work this plan builds on, not on `main` yet:

- the stereo unit's `max_hz` (TASK-157): the slot rule of section 2, and the Mini's 20 pairs a second in AC #7;
- the bag exporter (TASK-154, 155, 156, 162): `BagExporter.Preset`, and the Mini's bag exporter entry;
- `vehicles/ovcs_mini/test/vision_composer_test.exs`, added with that work.

PR 2 splits into core (2a) and API with dashboard (2b) if it passes 400 lines; the two ship together in one release, as the API and the dashboard ship in one firmware.

| # | PR | Tests first | Verified |
|---|---|---|---|
| 1 | Refactor: the stereo unit gives each side a `:side` option; drivers, Pairer, parameters, diagnostics and focus sweep use it rather than the label text. No visible change. | Existing suites green; V4L2Pair and Pairer tests switch to `:side` | OVCS1 and the Mini: depth, status and calibration as before |
| 2 | Stereo sides under the prefix, cameras of their own may be named `left` (section 3): labels, status keys, preview channels including depth, `{:stereo_frame, side}`, detection source, reserved names, exporter refusal, API, dashboard, guides | A config with a stereo unit and a `GStreamer` camera `:left`: status, preview channels, exporter outputs, detection source and a pose session tell them apart; `topic_prefix: "stereo"` with a camera `:left` refused | Dashboards of both vehicles: previews, status, Exporters, Calibration |
| 3 | `camera_capture`: `--output isp:…`, `--output from:…:jpeg:…`, `--outputs-max-hz`, the second stream, OUTPUT_JPEG records; nothing changes without `--output` | `cargo test`: argument parsing, the rate schedule, the record header | On the Mini, the binary run with and without outputs: same grey frames, JPEG records at 10 Hz |
| 4 | `LibCamera` `:outputs` and `:outputs_max_hz`; OUTPUT_JPEG parsed by one function shared with `V4L2Single` (refactor commit first) | Arguments built from outputs; a fake executable: grey only under the side's key, JPEG only under the output key | Host suite |
| 5 | `VisionCore.Camera.LibCameraStream`, `stream_of:`, `max_hz:`, the wiring and its refusals; `cameras.md` ("A stream of a stereo camera"), `data_flow.md` | Wiring as a pure function; relay with label, frame id and output; `running?/1` while the side is down; each refusal | Host suite |
| 6 | JPEG range and the cause of Adjusted | `cargo test` of the range expansion | On the Mini: contrast of `/left` against a reference shot |
| 7 | OVCS Mini composer: the `:left` camera, `cameras: [names: [:left]]`, moduledoc | The vehicle's composer test | On the Mini, AC #7: `ros2 topic hz`, status, CPU against the figures above |
| 8 | Ship `left.yaml` and `left_pose.yaml` after calibrating on the unit | Composer test lists them in `required_files/0` | Calibration page shows them in use after a reflash |
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
PR 1:

- Of the stereo drivers, only `V4L2Pair` read its side from its label. `LibCamera`, `GStreamer` and `Ros2.Camera` take no side from their label: they receive `:side` and need nothing of it.
- Each side's `:label` is among the side options the stereo unit resolves (`VisionCore.Stereo.Supervisor.camera_options/1`). The Pairer, the stereo parameters, the ROS 2 diagnostics and `V4L2Pair`'s peer take it from there, so PR 2 changes the label in one function.
- `VisionCore.Camera.FocusSweep` sets the focus through the stereo unit's own driver, found in the configuration, rather than `V4L2Pair` by its registered name.
<!-- SECTION:NOTES:END -->
