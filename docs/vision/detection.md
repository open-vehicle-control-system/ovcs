---
title: Object detection
description: Run named detection pipelines on the stereo pair or a camera of its own, read the accelerator's load and choose a model.
---

Find objects in a camera's image and place them in 3D with the stereo depth. Run several detection pipelines, detect on a camera of its own, and choose a model you may ship. You need a board with an accelerator: the Hailo-8 on a Raspberry Pi 5, or the Arduino VENTUNO Q's NPU. The table in [The OKdo Nano C100](./README.md#the-okdo-nano-c100) compares the boards.

## Detector components

Each detector component runs the model its option names:

- `:hailo_detector` runs the HEF its `:hef_path` names, compiled for the Hailo-8.
- `:qnn_detector` runs the DLC its `:dlc_path` names, on the VENTUNO Q's NPU.

A stereo detection pipeline leaves out an object with no depth in its box's middle, such as one nearer than the depth can measure. A pipeline on a camera of its own keeps it, without a distance.

### On the VENTUNO Q's NPU

The `:qnn_detector` component runs YOLOX on the NPU through QNN, from Qualcomm's AI Runtime (QAIRT 2.50). YOLOX runs in the `qnn_detect` Port behind `VisionCore.Detection.Backend.Qnn`. It takes the model as a DLC, `dlc_path:`. On first boot the board generates the model's context binary from it with QAIRT's `qnn-context-binary-generator`, at the HTP's graph optimisation level 3, into `/data/vision/qnn/<name>`, the pipeline's name. Later boots reuse it. A new DLC, a new QAIRT or new generator options make a new one (`VisionCore.Inference.QnnContext`). While it is generated, the status's `npu` reads `starting`. A generation that fails is tried again; a missing DLC or QAIRT is not.

Each QNN Port holds a power vote on the NPU for as long as it runs, with the performance profile its `performance:` names:

- `:burst`, the default: the highest voltage corner, with dynamic clock scaling off;
- `:sustained_high_performance`, `:balanced` or `:power_saver`;
- `:none`, for the NPU's default power policy.

The vote also sets the RPC polling in µs, `rpc_polling_us:`, 0 by default. It is how long the Port's thread polls for the end of an inference before it sleeps until the NPU signals it:

- 0, the default, frees the thread's core while the NPU runs, and wakes the thread up to about a millisecond after the inference ends;
- up to 9999 µs wakes it sooner, but keeps a core busy for each Port through each inference.

`performance: :none` makes no vote, so it takes no `rpc_polling_us:`. The Port's log says the vote it applied, or why it could not.

The board needs QAIRT in its image: [The Arduino VENTUNO Q](./README.md#the-arduino-ventuno-q) lists the build steps.

## Several pipelines

A composer may list several detector components (`:detector`, `:hailo_detector`, `:qnn_detector`), each with a `:name`. The name is a lowercase atom such as `:vehicle_detection`, `:detection` by default. Each named pipeline has its own supervisor, backend, model and parameter groups: `<name>.input`, `<name>.inference`, `<name>.filtering` and `<name>.placement`.

Some names are reserved: those that collide with a ROS 2 topic segment under the prefix, and the stereo pipeline's name. `VisionCore.Pipelines` lists them. Two detectors with the same name are refused.

The Hailo-8 serves one pipeline. A second Hailo pipeline is left down, with "the Hailo-8 already serves another pipeline" logged. The status's `npu` then reads `failed`: it covers every pipeline's backend, and is `failed` when any of them is unavailable. Two QNN pipelines each run on the NPU; a pipeline's default `cache_dir` is `/data/vision/qnn/<name>`.

Each exporter takes the pipelines it publishes. The ROS 2 exporter's `detections:` takes `pipelines:` (`[:detection]` by default), and the API serves a channel per pipeline ([Detections](./channels.md#detections)). The Debug exporter reads the pipeline `detection` only, the one a detector without a name runs.

## Settings

A pipeline's settings are options of its detector component and vision parameters, `<name>.<step>.<setting>`. The option is the value the pipeline starts with, and the parameter's default. The live ones change while the unit runs, from the next pair or frame ([Change a parameter](./api.md#change-a-parameter)). A value outside a setting's range is refused, at start and at a change.

| Parameter | Kind | Default | Values | Meaning |
|---|---|---|---|---|
| `input.detect_every_n` | live | 1 | 1 to 1000 | Detects on one pair or frame in `n`. |
| `inference.model` | build | | | The model file the accelerator runs. |
| `inference.score_threshold` | build | 0.4 | | Lowest score the accelerator reports: an argument of its program. |
| `inference.performance` | build | `burst` | | On a QNN backend, the NPU's performance profile. |
| `inference.rpc_polling_us` | build | 0 | | On a QNN backend, the RPC polling of its power vote. |
| `inference.infer_timeout_ms` | build | 2000 | | Longest wait for an inference before the program is restarted. |
| `filtering.min_score` | live | 0.4 | 0 to 1 | Lowest score passed on, at or above `score_threshold`. |
| `filtering.max_detections` | live | 20 | 0 to 1000 | Most detections passed on per image, best first. |
| `placement.depth_sample_fraction` | live | 0.5 | 0.05 to 1 | Share of a box's width and height whose depths give its distance. |
| `placement.outline_segments` | live | 4 | 1 to 32 | On the stereo source, pieces each edge of an outline is cut into. |
| `placement.reprojection_stride` | live | 3 | 1 to 32 | On a camera source, every how many pixels and rows of the depth are projected. |
| `placement.pair_wait_ms` | live | 500 | 0 to 60000 | On a camera source, the longest a frame's boxes wait for their pair. |

The build parameters are fixed when the pipeline starts: change them in your composer.

## Accelerator load

The status's `npu` gives the accelerator's kind and load, and each detection or segmentation pipeline's mean inference time ([Status](./channels.md#status)). Neither accelerator exposes a load counter to Linux, so each Port times its own inferences and the status sums them every second:

- A pipeline's inference time is the mean over the second's frames.
- The load is the share of the second the pipelines spent inferring, summed over every pipeline on the accelerator, at most 100 %.
- On the Hailo-8, the time runs from writing the input to reading the output: the device's work and the PCIe transfer.
- On the VENTUNO Q's NPU, it is the execute time QNN's profiling reports, without the wait for the NPU to be free. Two pipelines sharing it are therefore not counted twice.
- Where QNN's profiling is unavailable, it is the wall time around the graph's execution. That includes the FastRPC call and overstates the NPU's work.

The load is `null` until a Port has reported a time. A pipeline's time is `null` in a second without a frame, never 0.

The inference step takes longer than the accelerator's time: its Port also reads the image, resizes it and decodes the model's output. The status's `pipelines` gives that step's whole time, and each other step's ([Step times](./performance.md#step-times)).

## Detect on a camera of its own

A detector with `source: {:camera, name}` detects on the camera of its own `name` ([A camera of its own](./cameras.md)). It places its boxes in 3D with the stereo depth seen from that camera.

`source: {:camera, name, output}` takes that camera's output `output`; the boxes, depth and bearings are then in that output's pixels. With the OVCS1 reference vehicle's colour camera, `:center`, and its `:half` output, it reads as below; it works the same with your camera and backend:

```elixir
{:qnn_detector,
 name: :objects,
 source: {:camera, :center, :half},
 dlc_path: Application.app_dir(:<vehicle>, "priv/models/yolox_w8a8.dlc")}
```

- **Input.** Each frame goes to the backend whole, in colour, or in grey for a camera that delivers JPEG, as `VisionCore.Camera.GStreamer` does. The backend shrinks it to its model's input, letterboxed. `detect_every_n` counts the camera's frames: the pipeline detects on the `n`th, `2n`th, `3n`th…
- **One frame at a time.** One frame is with the backend at a time. A frame to detect on that comes meanwhile waits, the newest one only, and goes to the backend as soon as the reply is back. A detection a little slower than the camera's frame period therefore does not wait for the frame after next.
- **Matching.** The pipeline keeps the depth of the stereo pairs captured within `pair_wait_ms` of the newest one, at least two. It matches the frame with the pair whose left capture time is closest, within half the pairs' period.
- **Placement.** It projects that pair's depth into the camera's image through the camera's calibration and pose ([Calibration and pose](./cameras.md#calibration-and-pose)), every `reprojection_stride`-th pixel and row (3). Each box takes the median depth projected in its middle, as on the stereo source. Only a frame with at least one box is projected.
- **Waiting for the pair.** The stereo pipeline publishes a pair well after its capture, which can be after the frame's boxes. The boxes then wait for the pair captured closest to the frame, at most `pair_wait_ms` (500 ms), while the next frames go to the backend. The boxes are published in the frames' order.
- **No pair coming.** When no stereo pair has come for two pair periods, the boxes are published at once. They are placed with the pair already kept if one was captured within half a pair period of the frame, otherwise without a distance.
- **Backlog.** While 32 frames' boxes wait, the camera's frames are skipped, which is logged.
- **Without a distance.** A box with no depth in its middle, outside the stereo view or without a matched pair, is kept rather than dropped. Its position and size are `nil`. Its `bearing`, `{azimuth, elevation}` in radians in the camera's optical frame, says where it is seen: azimuth positive to the right, elevation positive up.
- **Without a pose.** On a camera without a pose, or whose pose or calibration cannot be read, every detection has no distance. A warning is logged once. Without a calibration, a detection has no bearing either.
- **Its own frame.** Its detections are in the camera's `frame_id`. The ROS 2 exporter publishes those with a distance as markers and `vision_msgs/Detection3DArray`. It publishes those without as `vision_msgs/Detection2DArray` boxes in the camera's pixels, on `<prefix>/<pipeline>/detections_2d`. All of them go on `<prefix>/<pipeline>/annotations`, over the camera's image ([What leaves the unit](./data_flow.md#what-leaves-the-unit)).
- **Another output.** When the exporter publishes a camera output other than the pipeline's, it scales the boxes to the published image.

The pipeline reads the camera's calibration and pose at start, so it takes a committed calibration once the unit restarts ([Calibration and pose](./cameras.md#calibration-and-pose)).

## Detection models

**No model weights are committed.** `mise run fetch-models` downloads them and verifies each against the sha256 in `scripts/models.tsv`, which also records each licence and prints it before the download.

[`vehicles/ovcs_mini/priv/models/README.md`](../../vehicles/ovcs_mini/priv/models/README.md) describes the OVCS Mini reference vehicle's models and what they require. The OVCS1 reference vehicle runs YOLOX (Apache-2.0) from Qualcomm AI Hub, `yolox_w8a8.dlc`, and a road segmentation model with non-commercial weights ([Road segmentation](./segmentation.md#the-model)).

OVCS is MIT licensed (`LICENCE.txt`). Ultralytics YOLOv8 is dual-licensed **AGPL-3.0** or a paid Enterprise licence, and Ultralytics asserts that covers the pretrained *weights*, not only the Python code. The two don't compose in this direction: MIT tells downstream users they may use the work without source-disclosure obligations, and AGPL-3.0 doesn't let anyone grant that. Distributing YOLOv8-derived weights under MIT would make a promise the licence can't keep. Fetching moves the choice to the operator. `yolov8n.hef` is in this repository's history, which removing it from `HEAD` doesn't undo.

The detection code isn't affected: `VisionCore.Detection.Backend.Hailo` runs the Hailo runtime, `VisionCore.Detection.Backend.Qnn` runs QNN, and neither contains Ultralytics code.

Unsettled, and not legal advice:

- whether neural network weights attract copyright at all (it differs between the US and the EU);
- whether a compiled `.hef` is a derivative work of the weights it was built from (by analogy to compilation, probably; untested for models);
- whether AGPL-3.0 §13 ("interacting with users remotely through a computer network") covers a vehicle publishing to Foxglove over Zenoh.

For commercial use of YOLOv8 specifically, an Ultralytics Enterprise licence is the direct answer.

### Permissive models

The models below are Apache-2.0 unless noted. Those with a prebuilt HAILO8 HEF in model zoo v2.15.0 are marked, with sizes as served:

- **NanoDet-RepVGG**: in the zoo (6.7 MB). The OVCS Mini's.
- **YOLOX** tiny / s-leaky: in the zoo (9.3 / 9.4 MB), different NMS op.
- **DAMO-YOLO** tinynasL20_T: in the zoo (13.4 MB).
- **SSD-MobileNet** v1/v2: in the zoo (6.7 MB), weaker but long-supported.
- **CenterNet** ResNet-v1-18, **EfficientDet-lite0**: in the zoo.
- **RT-DETR**: the original Baidu release, not the Ultralytics port.
- **RF-DETR** (Roboflow), **D-FINE**.
- torchvision's detectors (BSD-3).

Avoid YOLOv5/v8/v10/v11 (Ultralytics, AGPL-3.0), YOLOv6 and YOLOv7 (GPL-3.0; `yolov6n.hef` is in the zoo), and YOLO-NAS (restrictive Deci licence).

## See also

- [A camera of its own](./cameras.md): the camera, its outputs, calibration and pose.
- [Road segmentation](./segmentation.md): the other pipeline that runs on a camera of its own.
- [Vision channels](./channels.md#detections): the detection channels.
