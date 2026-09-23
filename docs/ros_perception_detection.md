---
title: "Perception: object detection"
description: Object detection on a Hailo-8 fused with stereo depth into 3D detections, the topics it publishes, the CPU/GPU backends for the simulator, and model licensing.
---

`RosBridge` can run object detection next to its stereo depth pipeline and fuse the two into 3D detections. The OVCS Mini reference application is the worked example: its `ros_perception` bridge (a Pi 5) runs SGBM stereo depth on the CPU and detection on a Hailo-8. Numbers on this page are measured on that board. The component reference is [`bridges/ros_bridge/README.md`](../bridges/ros_bridge/README.md).

## Why detection and not depth

A Hailo-8 doesn't make disparity faster: a StereoNet HEF benchmarked on the device came out level with the CPU SGBM, and neural disparity would give up the calibration-derived accuracy and the tuned 0.55 m near clip.

Detection is what the accelerator is good at, and what the CPU has no room for. `yolov8n` benchmarks at **340 FPS hardware-only, 177 FPS streaming, 3.33 ms hardware latency**, against a stereo pipeline running at about 15 Hz.

## What it costs

Measured on the Mini before and after enabling detection:

| Topic | Before | After |
|---|---|---|
| `/stereo/depth/image_rect` | 15.27 Hz | 13.16 Hz |
| `/stereo/points` | 15.0 Hz | 13.30 Hz |
| `/stereo/left/image_raw/compressed` | 30.2 Hz | 29.7 Hz |
| `/stereo/detections` | — | 12.99 Hz |
| `/stereo/detections/markers` | — | 13.87 Hz |

About 14 % off the depth rate. Inference is 3.3 ms; the rest is two more topics on the Zenoh session and the per-box depth median, which sorts a few thousand floats in Elixir per detection per frame. Moving the median into Evision/Nx is the next lever; `:detect_every_n` is the cheap one.

## How a box becomes a position

The detector consumes the stereo backend's `Result`, which carries the rectified left image and the metric depth `Mat`. Both are in the same rectified frame pixel for pixel, so fusing them is a lookup, not a registration, and detection adds no image processing of its own.

1. **Median** of the valid depths in the middle half of the box. A box around a person contains background at its corners, and a mean walks the distance towards the wall behind them. Zero is the ROS "no measurement" value, so zeros are excluded.
2. **Unproject** the box centre with the rectified intrinsics: `X = (u - cx)·Z/fx`, `Y = (v - cy)·Z/fx`. The principal point comes from the calibration, not the image centre.
3. A detection with **no valid depth is dropped**, not published at a guessed range. Stereo returns nothing on untextured surfaces, and a box at an invented distance is worse than no box.

The published box has a fixed 0.1 m extent along the optical axis: one view can't measure an object's depth, so a thin slab says "the surface is here" without pretending to know how deep the object goes.

## Three topics, three audiences

| Topic | Type | For |
|---|---|---|
| `/stereo/detections/markers` | `visualization_msgs/MarkerArray` | Foxglove's 3D panel |
| `/stereo/detections` | `vision_msgs/Detection3DArray` | Nav2 and other consumers |
| `/stereo/left/detections` | `foxglove_msgs/ImageAnnotations` | labelled boxes on the Image panel |

The first two are both needed: Foxglove's 3D panel **doesn't support `vision_msgs`**, and markers carry no class label, score or covariance in machine-readable form. `ros-lyrical-vision-msgs` is installed in the shared ROS image, so `foxglove_bridge` can deserialise the `Detection3DArray` too. The `/stereo` prefix is the stereo unit's `topic_prefix`.

Each detection draws two markers: a `CUBE` coloured red to green by score, and a `TEXT_VIEW_FACING` label above it reading `<class> <score> <distance>m`. Markers live 500 ms (`:marker_lifetime_ms`) so they don't flicker between frames, and ids that vanish get an explicit `DELETE`; otherwise a box that went away lingers and reads as a detection still there.

## Labelled boxes on the camera image

`/stereo/left/detections` is the Image panel's annotation topic, set under the panel's *Annotations* section; the checked-in layout `compose/local/foxglove/ovcs_perception.json` does it for the left camera. Each detection draws a `LINE_LOOP` box coloured by score, with a `<class> <score> <distance>m` label on a dark backing plate.

**Why `foxglove_msgs`.** `visualization_msgs/ImageMarker` has no text type, so its boxes can't say what they are, and ROS 2 has no `ImageMarkerArray`: with one message per annotation topic, N detections would need N topics. `foxglove_msgs/ImageAnnotations` carries boxes and labels in one message, and `LINE_LOOP` closes a rectangle in four points where a `LINE_LIST` needs eight.

The cost is a dependency: `foxglove_msgs` isn't in a ROS base install, so `ros-lyrical-foxglove-msgs` is installed in `compose/compute/images/ros2/Dockerfile`. **Without it `foxglove_bridge` can't resolve the type and never advertises the topic.** The vehicle and local stacks build from that one Dockerfile; on the vehicle, redeploy the compute node (`balena push`, see [ROS compute node](./ros_compute_node.md#deploying)) before the overlay appears.

**Boxes are mapped back into raw pixels.** Detection runs on the rectified image, but the panel shows `image_raw`. On the Mini the two differ by about 10 px on average and up to 23 px on a 480-wide frame, enough to put a box visibly beside its object. Each vertex is mapped back through OpenCV's rectification map, which costs nothing on the wire compared with a second rectified image stream.

That map is `CV_16SC2`: interleaved int16 pairs per rectified pixel, with `map_y` being the interpolation table rather than a coordinate. Reading it as two single-channel float maps gives a plausible-looking 240 px mean displacement instead of the real 10.

A straight edge in rectified space is a curve in raw space, so each edge is subdivided (`:outline_segments`, default 4) and every vertex mapped individually. A box is 16 vertices, and its top edge comes off the wire as y = 101, 101, 100, 100, 99 rather than a constant: the 2 px bow is the distortion being followed.

## Grayscale is fine

The detector is fed the pipeline's existing grayscale frame. Against ultralytics' `bus.jpg`, grayscale scored within 0.01 of colour (person 0.881 vs 0.888; bus 0.87 vs 0.84); colour would mean a second JPEG decode for no measurable gain. Resolution isn't the limit either: at the Mini's 480×270 the model still scores people at 0.91 / 0.87 / 0.74.

## Wiring it into your application

The detector is a component of the perception bridge's `RosBridge.Config`, listed after `:stereo_camera` (it registers on that unit's backend while starting). The OVCS Mini's `vehicles/ovcs_mini/lib/ovcs_mini.ex`:

```elixir
{:hailo_detector,
 hef_path: Path.join(priv_models_dir(), "#{hailo_model()}.hef"),
 score_threshold: 0.4,
 frame_id: "stereo_left"}
```

`frame_id` is the stereo unit's own frame, since boxes are positioned in its rectified pixels. Your application also needs a `base_link` → `stereo_left` static transform (the `:static_transforms` component) so consumers can place detections relative to the vehicle.

## Checking it works

From the laptop, with the `ovcs-ros2` container up:

```sh
docker exec ovcs-ros2 bash -lc \
  'source /opt/ros/*/setup.bash; export RMW_IMPLEMENTATION=rmw_zenoh_cpp
   ros2 topic hz /stereo/detections
   ros2 topic echo /stereo/detections --once'
```

On the device:

```elixir
RosBridge.Inference.Hailo.available?()                      # true: the Port is up
RosBridge.Inference.Hailo.busy?()                           # often true; not a fault
:sys.get_state(RosBridge.Publishers.Detections)             # frame_count, seq, published
:sys.get_state(RosBridge.Inference.Hailo).dropped           # 0
```

`seq` tracking `frame_count` exactly means every frame reached the accelerator; a climbing `dropped` means it couldn't keep up. `busy?` is normally true at frame rate (there is usually an inference in flight), so it says nothing about health on its own.

An empty `MarkerArray` at about 13 Hz is correct when nothing COCO-shaped is in view: the topic being live and the arrays being empty are different facts, and `published` in the publisher's state distinguishes them.

## Failure isn't fatal

A missing binary, missing HEF or absent accelerator logs once at boot and leaves the detector alive but inference-less. Frames are dropped rather than queued while the accelerator is busy, since a stale detection has no value. The pair runs under its own supervisor (`RosBridge.Inference.Supervisor`, `:rest_for_one`, 10 restarts a minute), so a detector crash-looping at frame rate can't exhaust the bridge supervisor's budget and take the cameras down with it.

## Choosing the model

The Hailo path loads `vehicles/ovcs_mini/priv/models/<model>.hef`, with `<model>` from `OVCS_HAILO_MODEL`:

| `OVCS_HAILO_MODEL` | Model | Licence |
|---|---|---|
| unset (`nanodet_repvgg`) | NanoDet-RepVGG | Apache-2.0 |
| `yolov8n` | YOLOv8 nano, COCO | AGPL-3.0, see [Model licensing](#model-licensing) |

Neither is committed: `mise run fetch-models` downloads both and verifies each against a sha256 in `scripts/models.tsv`. A model you add there becomes selectable the same way.

A HEF is compiled for one architecture: these are **HAILO8** builds and won't load on a Hailo-8L. `hailo_detect` reads the input size from `input_vstream.get_info().shape` and the class count from `nms_shape.number_of_classes`; its hard requirements are a square 3-channel input and an in-graph NMS producing `HAILO_NMS_BY_CLASS` output (net flow `HAILO_NET_FLOW_YOLOV8_NMS`), since it decodes no anchors. NanoDet-RepVGG and `yolov8s` meet them; `yolox_tiny` carries `HAILO_NET_FLOW_YOLOX_NMS` and doesn't.

The 0.4 score threshold was measured against yolov8n at 480×270, where it stops furniture being reported as animals. Re-measure it for NanoDet before relying on it.

## Running the detector without a Hailo

`RosBridge.Inference.Hailo` is one of three backends behind the `RosBridge.Inference` behaviour. The other two run the whole stack, detection included, on a workstation against the simulator.

| Backend | Where it runs | What it is for |
|---|---|---|
| `Inference.Hailo` | Hailo-8, via a Port | the vehicle |
| `Inference.Dnn` | OpenCV DNN: CPU, or GPU via OpenCL | a workstation |
| `Inference.Stub` | nowhere: fixed boxes | proving the plumbing |

`RosBridge.Publishers.Detections` can't tell them apart: each answers `detect/3` asynchronously and replies `{:inference_detections, seq, detections}` with boxes in the submitted image's pixels. Every backend owns its resize transform in both directions.

### The DNN backend, CPU and GPU

`:target` is `:cpu`, `:opencl` or `:opencl_fp16`. They share one module because they differ by two calls (`setPreferableBackend/2`, `setPreferableTarget/2`); model loading, blob preparation, decoding and NMS are identical.

**CUDA isn't available with the precompiled Evision**: every `cuda*` module is listed *Unavailable* in its OpenCV build, so a CUDA target means building Evision from source against CUDA and cuDNN. OpenCL does use the GPU, but OpenCV's OpenCL DNN kernels are much less tuned than its CUDA ones: expect roughly 1.5 to 3× CPU on an NVIDIA card.

Asking for OpenCL where no device is usable logs the reason and continues on the CPU, so a machine that lost its GPU shows up as a log line rather than an unexplained slowdown.

`Inference.Dnn.decode/6` expects YOLOv8's attribute-major `[1, 4 + classes, anchors]` output. It derives the class count from the shape, so any size of YOLOv8-style head works, but a different layout doesn't: YOLOX ONNX is anchor-major `[1, anchors, 5 + classes]` with a separate objectness column, and NanoDet splits classification and box regression into separate outputs with distribution-based box encoding. Running a permissive model on this backend means teaching `decode/6` a second layout; its tests build fixtures from raw float32 with the layout explicit.

### The ONNX model

The DNN path needs an ONNX export of a YOLOv8-shaped model at `vehicles/ovcs_mini/priv/models/yolov8n.onnx`. It isn't committed and `scripts/models.tsv` doesn't list it, for the licensing reason below: export it yourself. Until it exists the simulator runs stereo-only, so the default is "no detector" rather than one that logs a missing file on every start.

### Choosing a backend in the simulator

`OVCS_DETECTOR` selects it:

```sh
cd bridges/firmware
VEHICLE=OvcsMini OVCS_SIM=1 OVCS_DETECTOR=gpu ZENOH_ENDPOINT_IP=127.0.0.1 \
  BRIDGE_FIRMWARE_ID=ros_perception CAN_NETWORK_MAPPINGS=ovcs:vcan0 \
  iex -S mix
```

| Value | Backend |
|---|---|
| unset | `Dnn` on CPU if the ONNX model exists, otherwise no detector |
| `dnn` | `Dnn`, CPU |
| `gpu` | `Dnn`, OpenCL FP16 |
| `stub` | `Stub`: fabricated boxes |
| `off` | no detector |

The simulator wiring sets `detect_every_n: 3`, because CPU inference shares the machine with SGBM and Gazebo. On the vehicle the accelerator runs every frame.

### What the stub is good for

It fabricates boxes, so it says nothing about detection quality, and it warns on every start because boxes on a screen look equally convincing either way.

It does test everything downstream of the box: the median-depth sample, the unprojection, the marker and `Detection3DArray` publishing. Against `workshop.sdf` its centred box fuses to

```text
position: x 0.0  y 0.0  z 0.8088 m
```

and the world puts that box's front face 0.808 m from the lens: correct to the millimetre on the optical axis, which checks the fusion geometry against ground truth.

## Known limitation

In the OVCS Mini's `base_link` → `stereo_left` transform (`vehicles/ovcs_mini/lib/ovcs_mini.ex`), `{0.042, 0.0, 0.12}`, x is measured but z (the lens height) isn't. Detections are correct relative to the camera and inherit that error relative to the vehicle.

## Model licensing

**No model weights are committed.** `mise run fetch-models` downloads them and verifies each against the sha256 in `scripts/models.tsv`, which also records each licence and prints it before the download.

OVCS is MIT licensed (`LICENCE.txt`). Ultralytics YOLOv8 is dual-licensed **AGPL-3.0** or a paid Enterprise licence, and Ultralytics asserts that covers the pretrained *weights*, not only the Python code. The two don't compose in this direction: MIT tells downstream users they may use the work without source-disclosure obligations, and AGPL-3.0 doesn't let anyone grant that. Distributing YOLOv8-derived weights under MIT would make a promise the licence can't keep. Fetching moves the choice to the operator. `yolov8n.hef` is in this repository's git history, which removing it from `HEAD` doesn't undo.

The inference code isn't affected: `Inference.Dnn` runs OpenCV's DNN module and `Inference.Hailo` the Hailo runtime, neither containing Ultralytics code, and the decode test fixture (`bridges/ros_bridge/test/support/tiny_head.onnx`) was authored from scratch.

Unsettled, and not legal advice:

- whether neural network weights attract copyright at all (it differs between the US and the EU);
- whether a compiled `.hef` is a derivative work of the weights it was built from (by analogy to compilation, probably; untested for models);
- whether AGPL-3.0 §13 ("interacting with users remotely through a computer network") covers a vehicle publishing to Foxglove over Zenoh.

For commercial use of YOLOv8 specifically, an Ultralytics Enterprise licence is the direct answer.

### Permissive models

Apache-2.0 unless noted; those with a prebuilt HAILO8 HEF in model zoo v2.15.0 are marked, with sizes as served:

- **NanoDet-RepVGG**: in the zoo (6.7 MB). The default.
- **YOLOX** tiny / s-leaky: in the zoo (9.3 / 9.4 MB), different NMS op.
- **DAMO-YOLO** tinynasL20_T: in the zoo (13.4 MB).
- **SSD-MobileNet** v1/v2: in the zoo (6.7 MB), weaker but long-supported.
- **CenterNet** ResNet-v1-18, **EfficientDet-lite0**: in the zoo.
- **RT-DETR**: the original Baidu release, not the Ultralytics port.
- **RF-DETR** (Roboflow), **D-FINE**.
- torchvision's detectors (BSD-3).

Avoid YOLOv5/v8/v10/v11 (Ultralytics, AGPL-3.0), YOLOv6 and YOLOv7 (GPL-3.0; `yolov6n.hef` is in the zoo), and YOLO-NAS (restrictive Deci licence).
