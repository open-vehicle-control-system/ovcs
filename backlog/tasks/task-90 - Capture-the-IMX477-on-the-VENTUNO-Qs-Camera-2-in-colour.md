---
id: TASK-90
title: Capture the IMX477 on the VENTUNO Q's Camera 2 in colour
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-11 19:00'
labels:
  - vision
dependencies: []
parent_task_id: TASK-108
ordinal: 69000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Step 3 of TASK-108: a camera of its own, outside the stereo pair, declared in the composer as a `:camera` component and captured in colour. On the VENTUNO Q it is the IMX477 on Camera 2, routed through CAMSS and captured by `v4l2_capture` in its 2×2 binned mode, 2028 × 1520, demosaiced to colour. The dashboard shows its preview.

On the OVCS1 unit, the IMX477 driver probes (`imx477 5-001a: Device found is imx477`) and is linked to `msm_csiphy2`; the sensor offers `SRGGB12_1X12`, `SRGGB10_1X10` and `SRGGB8_1X8`; `msm_vfe2_video0` (`/dev/video8`, multiplanar) offers `pRCC`, 12-bit packed RGGB, among others. The binned whole-sensor mode is the 12-bit one.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 `v4l2_capture` captures one camera in packed 12-bit Bayer and returns colour frames, demosaiced 2×2, with auto exposure and grey-world white balance
- [x] #2 A `:camera` component starts a named camera whose colour frames are published under `{:camera_frame, name}`, and a failing camera leaves the rest of the unit running
- [x] #3 The dashboard shows a named camera's preview next to the stereo pair's
- [x] #4 On the OVCS1 unit, the IMX477 on Camera 2 streams colour frames to the dashboard
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Spec: TASK-108 (IMX477 on the VENTUNO Q, Sources). The camera's calibration, its pose, its ROS 2 topics and its use as a detection source are TASK-91's.

Global constraints:
- The camera captures the sensor's `SRGGB12_1X12` 2028 × 1520 mode as `pRCC`, packed 12-bit RGGB: 3 bytes per 2 samples, `s0 = b0 << 4 | (b2 & 0x0F)`, `s1 = b1 << 4 | (b2 >> 4)`.
- Demosaic is the 2×2 superpixel: one RGB pixel per RGGB cell, `R`, `(G1 + G2) / 2`, `B`, so a 2028 × 1520 capture gives 1014 × 760 RGB.
- The stereo pair's capture, its protocol and its tests are unchanged.
- A camera name follows the pipeline-name rule of TASK-110, checked by the same function (`VisionCore.Detection.name?/1`, or a module both use): an atom matching `^[a-z][a-z0-9_]*$`, none of the reserved names that collide with the stereo unit's ROS 2 topic segments and preview streams (`left`, `right`, `depth`, …); and no camera may share a name with a pipeline, since both publish under `<prefix>/<name>/`.

Review focus, each pinned by a test in the owning task:
- A capture whose node refuses `pRCC` fails with a message naming the formats it offers, not with a garbled image.
- A dark scene does not drive white balance to infinite gains: gains are clamped.
- Two `:camera` components with the same name are refused at start, naming it.
- A camera that crashes on start is restarted within its own budget, and the stereo pair keeps streaming.
- The preview of a named camera on a unit without one shows nothing and raises nothing.

#### Task 1: single-camera colour capture in `v4l2_capture`.
- `vision/rust/v4l2_capture`: a single-camera mode, selected by `--video <node> --sensor <subdev name>` without `--left-*`/`--right-*`, with `--sensor-width`, `--sensor-height` for the capture size; no `Pairer` and no `PhaseLock` in that mode.
- `v4l2.rs`: `PIX_FMT_SRGGB12P = "pRCC"`; negotiation picks the layout matching the sensor's bit depth, 12-bit for the IMX477, and the error lists the node's formats when none fits.
- `bayer.rs`: `Layout::Packed12` with `row_bytes = width * 3 / 2` and its `samples`; `Tone` built for a bit depth (1024 or 4096 entries, black level in that depth: the IMX477's default `black_level` is 256 in 12-bit); `rgb_half(...) -> Vec<u8>`, the superpixel demosaic through the tone, honouring `rotation`.
- White balance: grey-world over the previous frame, red and blue gains relative to green, each clamped to `0.5..4.0`, applied before the tone; a setting `awb` (`true` by default) and fixed `red_gain`, `blue_gain` used when it is off.
- `sensor.rs`: `SensorModel::Imx477`, recognised by the name prefix `imx477`, with the mainline driver's analogue gain mapping, `gain = 1024 / (1024 - code)`, code `0..=978`, no lens.
- Auto exposure works on the green channel's mean, through `exposure.rs` as for the pair.
- `framing`: a record tag `6`, RGB: `<<6, width::little-16, height::little-16, ns::little-signed-64, rgb>>`, `rgb` being `width * height * 3` bytes.
- Rust tests: `Packed12` unpacking, `rgb_half` on a known RGGB pattern (with and without rotation), the clamped grey-world gains, the 12-bit tone, the RGB record. Run `cargo test` and `cargo clippy -- -D warnings` in `vision/rust`.

#### Task 2: the camera component and colour frames in the core.
- `VisionCore.Camera.Frame` gains `rgb`, `width * height * 3` bytes; exactly one of `jpeg`, `grey`, `rgb` is set. `to_jpeg/2` encodes `rgb` with 3 channels; `to_tensor/1` gives a `{h, w, 3}` u8 tensor for `rgb`.
- `VisionCore.Camera.V4L2Single`: a camera driver (`@behaviour VisionCore.Camera`) running `v4l2_capture` in single-camera mode; options `name` (atom), `csiphy`, `sensor_width` (2028), `sensor_height` (1520), `code` (`"SRGGB12_1X12"`), `fps` (15), `frame_id`, plus the capture settings it shares with `V4L2` (`rotation`, `auto_exposure`, `exposure_us`, `analogue_gain`, `target_brightness`, `max_exposure_us`, `max_gain`, `black_level` 256, `gamma`) and `awb`, `red_gain`, `blue_gain`. It routes with `VisionCore.Camera.Camss.route(csiphy, width: sensor_width, height: sensor_height, code: code, await: 30_000)` and publishes `{:camera_frame, %Frame{label: Atom.to_string(name), rgb: …}}` under `{:camera_frame, name_for(label)}`, with the stall watchdog `V4L2` has. On the host, `VisionCore.Camera.GStreamer` serves the same role with JPEG frames.
- `VisionCore.Components.start(:camera, opts)`: `name` required, `driver` required; the child spec has the id `{:camera, name}` and `restart: :transient`, under a supervisor of its own with its own restart budget, as the detection unit's. `VisionCore.Application` refuses two cameras of the same name.
- `VisionCore.Camera.Unit.cameras(config) :: [{name :: atom(), driver :: module(), server :: atom()}]` and `outputs(config)`, `[{{:camera_frame, name}, {:camera_frame, server}}]`; `VisionCore.Exporter` maps `{:camera_frame, name}` for any name but `:left` and `:right` to this unit.
- Tests: Frame (rgb to jpeg, to tensor), `V4L2Single` with a fake capture executable printing RGB records (as the `V4L2` tests do for pairs), `components_test.exs`, `application_test.exs` (duplicate name, a failing camera leaving the stereo pair running), `exporter_test.exs`.

#### Task 3: the camera's preview.
- `VisionCore.Preview` serves a stream per named camera, `preview:<name>`, next to `left`, `right`, `depth`, encoding `rgb` frames to JPEG at the preview rate.
- `VisionApiWeb` routes `preview:<name>` for the unit's cameras; an unknown name is refused.
- The dashboard's `Previews.jsx` shows a tile per named camera, titled by its name, listed from the API (`GET /api/configuration`'s components or the exporter outputs, whichever already lists them).
- Tests: `preview_test.exs`, the preview channel's test, `Previews.test.jsx`.
- Docs: `docs/vision/README.md` (a camera of its own, the `:camera` component, the IMX477 on the VENTUNO Q), `docs/vision/api.md` (`preview:<name>`), `vision/core/README.md`.

#### Task 4: full-resolution colour output.
- `v4l2_capture` single mode: `--output full|half`, default `full`. `half` is the 2×2 superpixel (1014 × 760 from 2028 × 1520). `full` is a bilinear demosaic at the capture's resolution (2028 × 1520 from 2028 × 1520): each pixel keeps its own sample and interpolates the two missing channels from its 4-neighbours (green) or its 2 or 4 diagonal or axial neighbours (red, blue), replicating samples at the image's edges; white balance and the tone apply as in `half`; `rotation` 180 rotates the output.
- Auto exposure and white-balance statistics stay on the superpixel means, so both outputs expose and balance alike.
- Rust tests: a uniform colour field comes out uniform in `full`; a known 4×4 RGGB pattern gives the expected interpolated pixels, edges included; rotation; output size per mode.
- On the OVCS1 unit: the frame rate at `full`, 15 fps asked; if the Port or the conversion cannot hold it, the driver's default `fps` drops to the rate it holds, recorded in the task's notes.

#### Task 5: the IMX477's colour processing.
- The single mode's colour path follows what libcamera's Raspberry Pi pipeline does for this sensor, with the values of its IMX477 tuning (`src/ipa/rpi/pisp/data/imx477.json` in libcamera, Raspberry Pi's calibration, licence checked and credited in the module that holds them): black level, lens shading (`rpi.alsc`: the luminance table and the colour tables for the current colour temperature, bilinear over the frame), white balance, demosaic on linear samples, colour correction matrix (`rpi.ccm`, interpolated between the two calibrated colour temperatures around the current one; the colour temperature from the white-balance gains through `rpi.awb`'s `ct_curve`), then `rpi.contrast`'s `gamma_curve` to 8 bits, replacing the plain gamma. `half` and `full` both take this path.
- The tuning values live in one Rust module per sensor; a sensor without one (none today but the IMX477 in single mode) keeps the plain gamma.
- `gamma` stays a setting for that fallback; a setting `ccm` (`true` by default) turns the matrix off to compare.
- Rust tests: the matrix interpolation at, between and beyond the calibrated temperatures; the colour temperature from known gains; the contrast curve's end points and monotony; lens shading gains at the centre and corners; a grey patch stays grey through the whole path.
- On the OVCS1 unit: both outputs still hold 15 fps; a frame of the same scene before and after, compared.

#### Task 6: denoise, exposure on what is shown, and the settings.
- Chroma denoise in the single mode's colour path, after the colour matrix and before the contrast curve: the chroma (Cb, Cr of the linear RGB) is computed and blurred at the 2×2 cell resolution (a separable 5-tap kernel), luma untouched; setting `denoise` (`true` by default). It removes the coloured speckle at high gain, which also tints the shadows.
- Auto exposure measures the green of the image as shown: after lens shading and through the contrast curve, on the same sampling as today.
- The contrast table's index rounds instead of truncating.
- The 9 MB output and the scratch rows are reused across frames.
- `VisionCore.Camera.V4L2Single` passes `ccm` and `denoise` as settings like `awb`, and its `gamma` describes what it does for a sensor with a tuning (only the fallback for sensors without one).
- `docs/vision/README.md` describes a camera of its own's colour path in one paragraph: black level, lens shading, white balance, demosaic, colour matrix, chroma denoise and contrast curve, after Raspberry Pi's libcamera tuning for the IMX477.
- Tests: denoise keeps a uniform colour field, flattens chroma noise of known variance, leaves a sharp luma edge sharp; the exposure statistic on a known frame; the rounding; the settings pass through `V4L2Single`.
- On the OVCS1 unit: 15 fps held at `full` with denoise on; the conversion's time per frame from the capture's 60 s statistics log, recorded in the task's notes.

#### Task 7: a camera of its own's figures.
- `VisionCore.Status` reports each camera of its own beside the stereo sides, under its name in `cameras`: `present`, `fps` counted over the tick from its frames, and `exposure_time_us`, `analogue_gain`, `colour_temperature` from its driver's `live/1` when the driver has one (as for the sides). The stereo sides' entries and the pair's checks are unchanged.
- The status JSON carries it with the sides' camelCase keys; `docs/vision/api.md` documents it.
- The dashboard shows under each camera of its own's preview the figures the stereo sides show: rate, exposure, gain (with the same `cameraFigures`), and nothing while the status has no entry for it.
- Tests: status with a named camera (rate counted, metadata from `live/1`, absent when not running), the JSON, the preview's figures.

Checks before review: `cargo test`, `cargo clippy -- -D warnings` in `vision/rust`; `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` in `vision/core` and `vision/api`; the dashboard's tests; `elixir scripts/check_docs.exs`. On the OVCS1 unit, with the camera declared in the composer (TASK-93 makes it permanent), the dashboard shows the HQ camera in colour.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Measured on the OVCS1 reference vehicle's VENTUNO Q, IMX477 on Camera 2 (`imx477 3-001a` or `5-001a`: the bus number changes across boots; the camera is found by its link to `msm_csiphy2`), captured as `pRCC` from `msm_vfe2_video0`:

| Output | Asked | Delivered | Conversion per frame |
|---|---|---|---|
| `half`, denoise on | 35 fps | 34.9–35.0 fps | 17.1 ms |
| `full`, before the colour processing | 15 fps | 15.0 fps | — |
| `full`, colour processing, before the denoise | 15 fps | 15.0 fps | 29.0 ms |
| `full`, denoise on | 35 fps | 16.6 fps | — |
| `full`, denoise off | 35 fps | 21.3 fps | — |

The sensor's `horizontal_flip` and `vertical_flip` read 0, so Raspberry Pi's lens-shading tables apply turned by 180°; its analogue gain spans 0..978. Indoors in the evening, auto exposure reached its limits (60 ms then 25 ms, gain about 16) with white balance at about 2850 K. With the camera at 35 fps half, the stereo pair kept about 33 pairs a second and detection about 10 results a second. Full resolution at 35 fps is TASK-94.
<!-- SECTION:NOTES:END -->
