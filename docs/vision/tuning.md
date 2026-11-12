---
title: Tune with exports
description: How to record what the vision unit sees and computes as an export, change a parameter, export again and compare the two exports, step by step.
---

Tuning the unit's parameters needs results you can keep and compare. The dashboard and the log show the unit as it is now. They keep nothing of what it did before your change. The debug exporter records an **export**: a burst of stereo pairs and the state the unit was in, as one zip of plain files. Take one export before a change and one after, then compare them. This guide is written to be followed step by step, by a person or by an agent.

An export tells you what a change did and by how much. It does not score the result: whether it is better is your decision.

## The loop

1. Put the unit in front of a still scene, under steady light ([The fixed scene](#the-fixed-scene)).
2. Take an export, `before.zip` ([Take an export](#take-an-export)).
3. Change one thing. Change a parameter through the API or the dashboard ([Change a parameter](./api.md#change-a-parameter) has the request). Upload a firmware when the change is in the build or the code.
4. Take an export, `after.zip`.
5. Compare the two ([Compare two exports](#compare-two-exports)).
6. Decide: keep the change or discard it, and start again at step 2 from the state you kept.

Change one thing between two exports, or you cannot tell which change did what. Before step 3, you can take a second export with nothing changed and compare it with the first. The differences you see are the noise between exports of one setup, which a real change has to exceed.

A parameter you change through the API or the dashboard is unsaved until you save it, and a reboot drops it. Each export records every parameter's value, its saved value and its state, so you can tell what was unsaved when you exported.

## Enable the exporter

The exporter is off until your vehicle's composer lists it among its `exporters:`:

```elixir
%VisionCore.Config{
  components: [stereo_component()],
  exporters: [{VisionCore.Debug.Exporter, []}]
}
```

The exporter is `VisionCore.Debug.Exporter`, with the id `debug` and the name "Debug". A change to the composer reaches the unit with a firmware upload ([Vision unit](./README.md#build-burn-upload)).

The exporter reads the stereo unit's pairs, and the detections when the configuration has a detector. It does nothing with them between exports. Without a stereo unit it does not start: `GET /api/exporters` lists it at the level `off`, with the `detail` "Not started: no stereo unit to export", and its action answers a 503.

Its options are the second element of the tuple, for example `{VisionCore.Debug.Exporter, burst_ms: 5_000}`:

| Option | Default | Meaning |
|---|---|---|
| `burst_pairs` | `30` | The fewest pairs a burst records. |
| `burst_ms` | `3_000` | The shortest time a burst lasts. A burst ends when both are reached. |
| `settle_ms` | `2_000` | How old the last change must be for a burst to start. |
| `deadline_ms` | `30_000` | The time from the request to the end of the burst. |
| `frames_kept` | `30` | How many of the burst's first pairs keep their raw frames. |
| `snapshot_delay_ms` | `1_000` | How long after the burst starts a status snapshot must arrive to be kept. |

The settle wait counts against `deadline_ms`. If you raise `burst_pairs` or `burst_ms`, raise `deadline_ms` with them. Keep it, with the encoding, under the 60 s the API waits for an answer ([Take an export](#take-an-export)). [`VisionCore.Debug.Exporter`](../../vision/core/lib/vision_core/debug/exporter.ex) documents the remaining options, whose defaults read the running unit.

## Take an export

The exporter has one action, `export`, which answers a zip. From the API:

```sh
curl --fail-with-body -X POST http://<vehicle>-vision.local:4100/api/exporters/debug/actions/export \
  -H 'content-type: application/vnd.api+json' \
  -d '{"data": {"type": "exporter-actions"}}' \
  -o before.zip
```

`--fail-with-body` needs curl 7.76 or later. On an error answer, curl exits with 22 and `before.zip` holds the JSON error, not a zip: check the exit status before you use the file.

From the dashboard, open Exporters in the menu, then Debug, and click **Export**. When the export ends, the browser downloads the zip.

An export lasts at least `burst_ms`. It runs in this order:

1. **Settle.** The exporter waits until the last change to the unit is `settle_ms` old ([The settle time](#the-settle-time)).
2. **Burst.** It records the pairs the stereo pipeline publishes, for at least `burst_ms` and at least `burst_pairs` pairs, whichever ends later. The pairs are in the order the pipeline published them, but not always consecutive. A pair the pipeline dropped while busy, or one the exporter skipped while it was behind, is not in the burst. `intervalMs` is longer where a pair is missing.
3. **Answer.** It collects the unit's state, encodes the zip and answers. The unit keeps nothing of it: no history, no list of exports.

An export changes nothing on the unit, and the status of the exporter reads "Exporting" from the request until the answer. One export runs at a time. The API waits up to 60 s for the answer. After that it answers a 504 while the exporter goes on, and answers a 409 to the next request until the exporter has finished. The unit answers:

| Answer | Meaning | What to do |
|---|---|---|
| 200 | The zip. | |
| 409 | Another export is running. | Wait for it, then ask again. |
| 504 | The burst did not end within `deadline_ms`, or the API's 60 s ran out. For the burst, the `detail` names how many pairs arrived. | Look for a pipeline or cameras that stopped, a unit too slow for the burst, or parameters still changing: each change restarts the settle wait. |
| 500 | The export failed. The `detail` holds the message. | Read it. It names, for example, a last pair without images, disparity or depth, on a unit whose stages do not provide them. |
| 503 | The exporter does not run. | Read its status in `GET /api/exporters`. |
| 404 | No `debug` exporter. | Add it to your composer and upload the firmware. |
| 400 | The request has no JSON:API document. | Send the document as in the example above. |

## The fixed scene

The comparison assumes the unit does not move and nothing in front of it does: the unit sits facing a still scene, and the light stays steady. What an export compares is then the unit's computation, not the scene. If the scene changes between two exports, you cannot tell its effect from the effect of your change.

Take both exports the same way: from the API both times, or from the dashboard both times, with the same pages open ([Traps](#traps)).

## The settle time

A change to the unit does not show in the pairs at once. The temporal filter carries the previous pairs' disparity, and a live setting applies from the next pair, or from the second one with native stages ([Two pairs in flight](./data_flow.md#two-pairs-in-flight)). So the exporter does not start a burst on a unit that changed a moment ago.

A change is anything that alters what the stages compute or what the cameras deliver:

- the stereo pipeline's start, which a reboot after a firmware upload includes;
- any change of the pipeline's options: a parameter, the automatic row-offset correction (`stereo.rectification.auto_row_offset`, with the default prefix) or a calibration reload. A setting set to the value it already has is not a change;
- any parameter applied through `VisionCore.Parameters`, the camera controls included.

The exporter takes the age of the later of the pipeline's last change and the parameters' last change. Under `settle_ms`, it waits until the age reaches it, then starts the burst. It records that age in the manifest as `changeAgeMs`, in milliseconds. If a change happens during the burst, the manifest's `changesDuringBurst` is 1, and the export is not comparable: take it again.

The light, and what auto exposure does in answer to it, are not changes the exporter sees ([Traps](#traps)).

## What an export holds

The zip has one top directory with the same name, `vision-export-<hostname>-<UTC timestamp>`, where the timestamp reads `YYYYMMDDTHHMMSSZ`. Its `README.md` describes the other files.

| File | Content |
|---|---|
| `README.md` | What each file is, the burst size, and how the export was taken. |
| `manifest.json` | Time, hostname, firmware, burst size, the age of the last change, the image size and the format of each binary file. |
| `parameters.json` | Every parameter: `id`, `value`, `saved` (the saved value) and `state`. |
| `configuration.json` | The unit's configuration, as `VisionCore.settings/0` returns it. |
| `calibration/left.yaml`, `calibration/right.yaml` | The calibration files in use, as they are. |
| `figures.json` | The figures of each pair and of each status snapshot, and a summary of each figure. |
| `timings.json` | Each stage's time over the burst. |
| `detections.json` | What the detector published during the burst. Present only on a unit with detection. |
| `frames/NNN-left.*`, `frames/NNN-right.*` | The raw frames of the first `frames_kept` pairs, as the cameras delivered them: grey frames as 8-bit PNG (`.png`), JPEG frames as the JPEG bytes (`.jpg`). `NNN` is the pair's index in the burst, from `000`. |
| `last/left-rectified.png`, `last/right-rectified.png` | The last pair's rectified images, 8-bit PNG. |
| `last/disparity.f32` | The last pair's disparity: little-endian float32 in pixels, row-major, with the shape in the manifest. A pixel is matched when its value is above 0. |
| `last/disparity.png` | The same disparity coloured for viewing, unmatched pixels black. |
| `last/depth.png` | The last pair's depth: 16-bit PNG in millimetres, 0 where there is none. |
| `last/depth-coloured.jpg` | The depth as the dashboard colours it, blue at infinity whatever range the dashboard shows, so the colours of two exports compare. Present when it could be encoded. |

### manifest.json

| Field | Meaning |
|---|---|
| `time`, `hostname`, `firmware` | When and where the export was taken, and the firmware: its `revision`, `target` and the Nerves system. |
| `burstPairs`, `framesKept` | The pairs in the burst, and how many keep their raw frames. |
| `statusSnapshots`, `statusAvailable` | The status snapshots kept, and whether the unit's status could be read. |
| `changeAgeMs` | How long before the burst the last change was, in milliseconds; `null` when none was recorded. |
| `changesDuringBurst` | 0 or 1: whether anything changed during the burst. |
| `imageSize` | `width` and `height` of the images. |
| `formats` | The format of each binary file. For `last/disparity.png`, `colourRangePx` gives the disparities the colours span. |

### figures.json

`figures.json` has three members:

- `pairs`, one entry per burst pair;
- `snapshots`, one entry per status snapshot;
- `summary`, which holds `mean`, `min`, `max`, `std` and `n` for each figure with a number.

`std` is the population standard deviation and `n` counts the samples. A figure that was not measured on a pair is `null` for it and not counted. The names are camelCase, and a name ending in `Ms`, `Px`, `Hz`, `Percent` or `Rows` says its unit.

| Figure | In | Meaning |
|---|---|---|
| `intervalMs` | pairs | Time since the burst's previous pair, in milliseconds, longer where a pair is missing. The depth rate is 1000 divided by its mean. The burst's first pair has none. |
| `deviceMs` | pairs | The time the pair kept the pipeline's compiled or native segments busy, in milliseconds. |
| `sharpnessLeft`, `sharpnessRight` | pairs | Each rectified image's sharpness. The scene sets the absolute value; see [Stereo stages](./stages.md#2-sharpness). |
| `alignmentOffsetRows` | pairs | How far the right image's rows sit from the left one's, in rows. Within half a row, the calibration fits. `null` when it cannot be measured. |
| `alignmentBandOffsetRows` | pairs | The same per vertical band, as a list. It has no summary. |
| `matchedPercent` | pairs | The share of matched pixels. A pixel is matched when its disparity is above 0. |
| `meanDisparityPx`, `spreadPx` | pairs | The mean and spread of the matched pixels' disparity, in pixels. |
| `jitterPx` | pairs | How much a pixel's disparity changes from one pair to the next, in pixels: the matcher's noise on a still scene. |
| `alignRows` | pairs | The RowAlignment stage's offset over the whole image, the same value as `alignmentOffsetRows`. |
| `depthHz` | snapshots | Depth images computed in the last second. |
| `stereoLoadPercent`, `cpuPercent` | snapshots | The share of the second the stereo stages took, and the processors' busy share. |
| `leftCameraFps`, `rightCameraFps` | snapshots | Frames each camera delivered in the last second. |
| `leftCameraExposureTimeUs`, `leftCameraAnalogueGain`, `leftCameraColourTemperature`, and the `rightCamera` ones | snapshots | What each camera reports, when it reports it. |
| `syncPairs`, `syncOffsetMedianMs`, `syncOffsetMaxMs` | snapshots | The cameras' synchronisation, as on the dashboard. |

`matchedPercent`, `meanDisparityPx`, `spreadPx`, `jitterPx` and `alignRows` are metrics a stage reports, under the stage's name for them. Any other figure of the pairs is one too, and the stage's module documents it.

The first four come from the Quality stage ([Stereo stages](./stages.md#9-quality)). It measures the final disparity, after the temporal filter: held matches raise `matchedPercent` and smoothing lowers `jitterPx`. To measure the matcher alone, set the temporal filter's `alpha` to 1 and `hold` to 0 for both exports.

A figure of the pairs has a sample for each pair of the burst. A status snapshot describes one second, so a figure of the snapshots has only a few samples, and the comparison task never judges it against its spread.

### timings.json

One entry for each stage, with `median`, `p95` and `max` in milliseconds over the burst's pairs, and `n`. The names are the pipeline's:

- A stage is named after its module, underscored: `SpeckleFilter` is `speckle_filter`.
- Consecutive stages that run on one device form a segment, timed as one entry named after its members joined with `+`. The members of a native segment are timed under their own names too.
- `total` is the time from the pipeline taking a pair to just before it publishes it.

### detections.json

A list with one entry for each publication during the burst: the pair's `captureNs` and its `detections`. Each detection has `label`, `score`, `distanceM` and `outline`. The outline is the `[x, y]` vertices as fractions of the left image's width and height, as in the API's [detections event](./api.md#detections).

## Compare two exports

Run the commands of this section from the repository's root, with both zips there. Unzip both exports, each into a directory that does not exist yet, and run the comparison task on the two zips ([The comparison task](#the-comparison-task)). The task prints most of what the steps below read. For what it does not print, the steps name the file each figure comes from.

```sh
unzip -q before.zip -d before
unzip -q after.zip -d after
```

Each export unzips into one top directory with its own timestamp, which the `diff` commands below match with `*`. A `before` that already holds an earlier export breaks them. On a later pass, remove the two directories first (`rm -rf before after`) or use other names.

Follow the steps in order: each catches what would make the next one mislead you.

### 1. Check that the two can be compared

The task's Exports block, or `manifest.json` in each export, says how each was taken. Check that:

- `hostname` is the same: both come from the same unit. `firmware`, the revision, is the same, unless the firmware is what you changed.
- `changes during the burst` (`changesDuringBurst`) is 0 in both. A 1 means something changed while the burst ran: take that export again.
- `status` is `available` (`statusAvailable` is `true`) in both. Otherwise the figures of the status are missing.
- `last change before the burst` (`changeAgeMs`) is a time in milliseconds, or `none recorded`.

Only the manifest has `imageSize` and `statusSnapshots`. Check that `imageSize` is the same in both: the task stops on two sizes. Check that `statusSnapshots` is not 0.

### 2. The state: what changed between them

Compare the parameters. A parameter whose `value` differs is what you changed, or what changed by itself. The automatic row-offset correction moves `stereo.rectification.right_row_offset`, and a reboot drops the parameters you left unsaved. If a parameter differs that you did not change, find out why before you read the figures.

The task's Parameters section lists each parameter whose `value` differs in `parameters.json`, with `-` for an export that lacks the parameter, or reads `Parameters: none differ`. It does not compare the configuration or the calibration; compare them yourself. `diff` exits with 1 when the files differ:

```sh
diff before/*/configuration.json after/*/configuration.json
diff before/*/calibration/left.yaml after/*/calibration/left.yaml
diff before/*/calibration/right.yaml after/*/calibration/right.yaml
```

### 3. The figures, against their spreads

Compare each figure's `summary` in `figures.json`. Its change is B's mean minus A's. The rule is the comparison task's. A change counts only when it is larger than the larger of the two `std`. It never counts:

- for a figure of the status snapshots: its spread, over a few snapshots, is too rough to judge by;
- when either figure has fewer than 3 samples: a figure with too few samples has no spread to judge by.

A change smaller than the spread is noise.

- Read the figures of the pairs first: they have a sample for each pair of the burst. `intervalMs` gives the depth rate; `matchedPercent` and `jitterPx` tell how complete and how steady the depth is. On a fixed scene, a change beyond the spread in `meanDisparityPx` or `spreadPx` comes from the unit, not from the scene.
- Read the figures of the status as indications. They have a few samples each, and the comparison task never judges them, however many there are: it reads `status figure, not judged`. For the depth rate, use `intervalMs`.
- Check the cameras' exposure and gain by their values, not by a spread. `leftCameraExposureTimeUs`, `leftCameraAnalogueGain` and the `rightCamera` ones are status figures, which the task never judges. Compare their `mean`, `min` and `max` in `figures.json`; the Figures table shows the means. With auto exposure off, the values are equal in both exports. With it on, a difference between the means means the light moved: take the exports again once it is steady ([Traps](#traps)).
- A figure that only one export measured is named under the table, as `Figures only in A: ...` or `Figures only in B: ...`, and is not compared. Find out why: for example, the status was unavailable in one export, or a stage that reports it is in one unit's stages only.

### 4. The timings

Compare the `median` and `p95` of each stage in `timings.json`, and of `total`, a pair's latency. A stage whose time grew is where your change cost time; one whose time shrank is where it saved some. The timings carry no `std`: `p95` and `max` tell how far a stage's time varies.

The comparison task prints only the stages that both exports timed, and names the others under the table, as `Stages only in A: ...` or `Stages only in B: ...`. Adding or removing a stage renames the segment that holds it, so the segment's old and new entries appear there.

### 5. The images

Look at each export's last pair: `last/disparity.png`, `last/depth-coloured.jpg` and the rectified pair. The comparison task counts and draws the difference between the two last pairs' disparity and depth:

- The pixels matched in both, in A only and in B only (matched means a disparity above 0). The A-only pixels are the matches your change lost, the B-only pixels the matches it gained.
- The mean absolute difference of the disparity, in pixels, and of the depth, in millimetres, over the pixels that both exports have a value for.
- `disparity-diff.png` and `depth-diff.png`, 8-bit grey images of the exports' size. A pixel is black where neither export has a value, and white where only one has. Otherwise it is as bright as the absolute difference: 32 grey levels for a pixel of disparity, 1 grey level for 4 mm of depth, capped at white. A difference of about 8 pixels of disparity, or about 1 m of depth, or more, is white too.

Each export has one last pair, so its images carry the noise of a single pair. Read them against the noise between two exports of one setup. Run the comparison task once on two exports with nothing changed between them, and keep that result as the floor for the changed pair.

The colours of `last/disparity.png` span `colourRangePx` in the manifest: two exports compare by colour only when their ranges are the same. The first frames of each export, `frames/000-left.png` and `frames/000-right.png` (or `.jpg`), show whether the scene and the light were the same.

## The comparison task

`vision_core` has a task for the host that prints the Exports, Parameters, Figures, Timings and pixel sections of the steps above. It runs in `vision/core`, on a workstation where `mix compile` works ([Running it on a workstation](./README.md#running-it-on-a-workstation)). From the repository's root, run it in a subshell, so that your shell stays at the root for the other commands. The paths the task takes are relative to `vision/core`:

```sh
(cd vision/core && mise exec -- mix vision_core.compare_exports ../../before.zip ../../after.zip --out ../../compare-out)
```

It prints five sections, with B read against A, and writes the two difference images to the directory `--out` names, `compare-out` by default. The paths it prints are the ones it was given, relative to `vision/core`. From the repository's root, the images of the example are in `compare-out/`. Figures, timings and pixel differences carry 4 significant digits, and one under 0.0001 reads in scientific notation, as `3.699e-06`. Parameter values print in full. The values below are illustrative:

```text
Exports
export  hostname          time                  firmware  last change before the burst  changes during the burst  status     file
A       <vehicle>-vision  2026-11-03T14:02:11Z  ce99e251  5120 ms                       0                         available  ../../before.zip
B       <vehicle>-vision  2026-11-03T14:06:40Z  ce99e251  2003 ms                       0                         available  ../../after.zip

Parameters that differ
parameter            A  B
stereo.disparity.p1  8  10

Figures, change is B - A
figure                    A mean    A std      A n  B mean    B std      B n  change     against spread
intervalMs                38.41     1.907      29   38.6      2.114      29   0.189      within spread
jitterPx                  0.087     0.011      30   0.052     0.009      30   -0.035     beyond spread
leftCameraExposureTimeUs  33013     0          2    33013     0          2    0          status figure, not judged
matchedPercent            64.7      0.812      30   68.1      0.79       30   3.4        beyond spread
sharpnessLeft             0.004592  3.699e-06  30   0.004594  3.912e-06  30   2.000e-06  within spread
stereoLoadPercent         97.5      0.5        2    98.0      0          2    0.5        status figure, not judged

Timings, in milliseconds
stage           A median  B median  A p95  B p95
disparity       30.51     30.48     31.9   31.88
speckle_filter  3.301     3.296     3.512  3.54
total           61.25     61.19     66.4   66.31

Last pairs' pixels
matched in both                         60112
matched in A only                       1204
matched in B only                       3871
mean absolute disparity difference, px  0.412
mean absolute depth difference, mm      18.64

Difference images:
  ../../compare-out/depth-diff.png
  ../../compare-out/disparity-diff.png
```

The lines below show when no parameter differs, or a figure or a stage is in one export only, each in its own section. The first replaces the Parameters table; the others come right below the Figures and Timings tables:

```text
Parameters: none differ
Figures only in A: leftCameraLensPosition, rightCameraLensPosition
Stages only in B: median_filter
```

| Section | What it holds |
|---|---|
| Exports | For A, then B, what the manifest says: `hostname`, `time`, `firmware` (the revision), the last change before the burst, the changes during the burst, whether the status was available, and the file you gave. `-` where the manifest lacks a value. |
| Parameters | Each parameter whose `value` differs, by id, under `Parameters that differ`; `-` where an export lacks the parameter. When none differs, the section is the single line `Parameters: none differ`. |
| Figures | Each figure that both exports measured: the summaries side by side and the change. The last column reads `within spread` or `beyond spread`; `status figure, not judged` for a figure of the status snapshots; or `too few samples` for a figure of the pairs when either export has fewer than 3 samples of it. A figure only one export measured is named below the table, as `Figures only in A: ...` or `Figures only in B: ...`. |
| Timings | The median and the 95th percentile of each stage that both exports timed. A stage only one export timed is named below the table, as `Stages only in A: ...` or `Stages only in B: ...`. |
| Last pairs' pixels | The counts of matched pixels and the mean differences of step 5. `-` where no pixel counts. |

The task stops with a message that names the export and the file when:

- a file is not a zip;
- an export lacks a file the task reads: `manifest.json`, `parameters.json`, `figures.json`, `timings.json`, `last/disparity.f32` or `last/depth.png`;
- an export holds one that is malformed;
- the two exports' images differ in size.

The task does not read the configuration, the calibration, the frames or the detections: read them yourself. [`VisionCore.Debug.Compare`](../../vision/core/lib/vision_core/debug/compare.ex) documents each value.

## Traps

- **Auto exposure.** With auto exposure on, the cameras change their exposure and gain with the light. The brightness of both images moves with them, with no parameter change. The exporter does not count it as a change. Compare the cameras' exposure and gain figures between the exports, by their values, as step 3 says.

  To take the cameras out of the comparison, switch auto exposure off and set the exposure and gain yourself, then tune. The switch is a parameter change: take the first export after it. After a boot, or after switching auto exposure on, wait until the exposure figures are steady before you export: the exporter waits only for `settle_ms`.

  The parameter ids depend on the camera driver. Read `GET /api/parameters` for the ids your unit has: the camera controls are the ids that start with `stereo.cameras.` (with the default prefix).

  - With `VisionCore.Camera.LibCamera`, the switches are `stereo.cameras.auto_exposure` and `stereo.cameras.auto_gain`, and the settings `stereo.cameras.exposure_time_us` and `stereo.cameras.analogue_gain`.
  - With `VisionCore.Camera.V4L2`, the one switch is `stereo.cameras.auto_exposure`, which covers the gain too: there is no `auto_gain`. The settings are `stereo.cameras.exposure_us` and `stereo.cameras.analogue_gain`.
- **Light.** Daylight, a cloud, a lamp that you switch: any of them changes the images, and the matched pixels with them. Keep the light steady, and use the noise floor ([The loop](#the-loop)) to see what one setup does by itself.
- **An open dashboard.** The unit encodes the previews only while a dashboard is showing them, and the encoding takes processor time. A dashboard open for one export and closed for the other moves the depth rate and the load figures. Take both exports with the same pages open, or with none: use the API.
- **What else runs.** The other exporters, the detection and the dashboard load the unit too: keep them the same for both exports.
- **Status figures.** The depth rate of the status, the stereo load, the CPU and the cameras' rates have only a few samples per export. The comparison task never judges their differences. Read them as indications; use `intervalMs` for the depth rate.
- **A change during the burst.** A parameter you set, or the automatic row-offset correction moving, while the burst runs makes `changesDuringBurst` 1. Take the export again.
- **A firmware upload.** The unit reboots and drops its unsaved parameters; the new export's `parameters.json` shows what is in force. The pipeline's start counts as a change, so the export waits `settle_ms` after it.
- **A different working size.** Exports with different `imageSize` cannot be compared by the task.

## See also

- [Vision API](./api.md): the parameters and the exporters' actions over HTTP.
- [Stereo stages](./stages.md): what each stage does and its settings.
- [Vision performance](./performance.md): the settings that change the depth rate.
- [How a pair flows](./data_flow.md#exporters): the exporters, and how to write your own.
