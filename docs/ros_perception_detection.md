# Object detection on the Hailo-8

The Mini's perception Pi runs stereo depth on the CPU and object
detection on the Hailo-8 accelerator, then fuses the two into 3D
detections. This page is the why and the how-to-check; the component
reference lives in [bridges/ros_bridge/README.md](../bridges/ros_bridge/README.md).

## Why detection and not depth

The accelerator was bought to make disparity faster. It does not. A
StereoNet HEF benchmarked on the device came out level with the
CPU SGBM already in the pipeline, and neural disparity would have cost
the calibration-derived accuracy and the tuned 0.55 m near clip for
nothing.

Detection is what the part is actually good at, and it is the thing the
CPU has no room for. `yolov8n` benchmarks at **340 FPS hw-only,
177 FPS streaming, 3.33 ms hardware latency** against a stereo pipeline
running at ~15 Hz.

## What it costs

Not nothing, despite how the arithmetic looks. Measured on the device
before and after:

| Topic | Before | After |
|---|---|---|
| `/stereo/depth/image_rect` | 15.27 Hz | 13.16 Hz |
| `/stereo/points` | 15.0 Hz | 13.30 Hz |
| `/stereo/left/image_raw/compressed` | 30.2 Hz | 29.7 Hz |
| `/stereo/detections` | — | 12.99 Hz |
| `/stereo/detections/markers` | — | 13.87 Hz |

About 14 % off the depth rate. Inference itself is 3.3 ms; the rest is
two more topics on the Zenoh session and the per-box depth median,
which currently sorts a few thousand floats in Elixir per detection per
frame. If that becomes the constraint, move the median into
Evision/Nx — it is the obvious next lever, and `:detect_every_n` is the
cheap one in the meantime.

## How a box becomes a position

The detector consumes the stereo backend's `Result`, which carries the
rectified left image and the metric depth `Mat` alongside the packed
bytes. Both are in the same rectified frame pixel for pixel, so fusing
them is a lookup rather than a registration problem — and the pixels
are already decoded and rectified, so detection adds no image
processing of its own.

1. **Median** of the valid depths in the middle half of the box. Median
   rather than mean because a box around a person contains background
   at its corners, and a mean walks the distance towards the wall
   behind them. Zero is the ROS "no measurement" value, so zeros are
   excluded rather than averaged in as 0 m.
2. **Unproject** the box centre with the rectified intrinsics:
   `X = (u - cx)·Z/fx`, `Y = (v - cy)·Z/fx`. The principal point comes
   from the calibration, not the image centre.
3. A detection with **no valid depth is dropped**, not published at a
   guessed range. Stereo genuinely returns nothing on untextured
   surfaces, and a box at an invented distance is worse than no box.

The published box has a fixed 0.1 m extent along the optical axis.
Nothing measures an object's depth from one view; a thin slab says
"the surface is here" rather than pretending to know how deep the
object goes.

## Two topics, two audiences

| Topic | Type | For |
|---|---|---|
| `/stereo/detections/markers` | `visualization_msgs/MarkerArray` | Foxglove's 3D panel |
| `/stereo/detections` | `vision_msgs/Detection3DArray` | nav2 and other consumers |
| `/stereo/left/detections` | `foxglove_msgs/ImageAnnotations` | labelled boxes on the Image panel |

The first two are both published because neither covers the other.
Foxglove's 3D panel **does not support `vision_msgs`** — publishing
only that puts the data on the wire with nothing to draw it. Markers,
conversely, carry no class label, score or covariance in
machine-readable form. (`ros-lyrical-vision-msgs` is installed in the
`vehicule` image, so `foxglove_bridge` can deserialise the
Detection3DArray too.)

Each detection draws two markers: a `CUBE` coloured red-to-green by
score, and a `TEXT_VIEW_FACING` label above it reading
`<class> <score> <distance>m`. Markers carry a 500 ms lifetime so they
do not flicker between frames, and ids that vanish get an explicit
`DELETE` — otherwise a box that goes away lingers on screen and reads
as a detection that is still there.

## Labelled boxes on the camera image

`/stereo/left/detections` is the Image panel's annotation topic — set
under the panel's *Annotations* section, which the checked-in layout
already does for the left camera. Each detection draws a `LINE_LOOP`
box coloured red-to-green by score, with a `<class> <score>
<distance>m` label above it on a dark backing plate.

**Why `foxglove_msgs` and not `visualization_msgs`.**
`visualization_msgs/ImageMarker` was the first implementation and
cannot carry text at all — it has no text type, so a box drawn with it
can never say what it is. ROS 2 also has no `ImageMarkerArray`, and
the Image panel takes one message per annotation topic, so N
detections would have needed N topics.
`foxglove_msgs/ImageAnnotations` solves both: boxes and labels in one
message, and `LINE_LOOP` closes a rectangle in four points where a
`LINE_LIST` of segment pairs needs eight.

The cost is a dependency. `foxglove_msgs` is not in a ROS base
install, so `ros-lyrical-foxglove-msgs` is installed in
`ros2/vehicule/image/Dockerfile` — **without it `foxglove_bridge`
cannot resolve the type and never advertises the topic**. Both the
`vehicule` and `base` composes build from that one Dockerfile, so a
single change covers them, but the vehicle container has to be
redeployed (`balena push <device-ip>`) before the overlay appears.

**The boxes are moved back into raw pixels first.** Detection happens
on the rectified image, but the stream the panel shows is
`image_raw`. Measured on the Mini those differ by ~10 px on average
and up to 23 px on a 480-wide frame — enough that drawing rectified
coordinates directly puts the box visibly beside the object. Each
vertex is therefore mapped back through OpenCV's rectification map,
which costs nothing on the wire compared with publishing a second
rectified image stream.

That map is `CV_16SC2` — interleaved int16 pairs per rectified pixel,
with `map_y` being the interpolation table rather than a coordinate.
Reading it as two single-channel float maps gives a plausible-looking
240 px mean displacement instead of the real 10.

Because a straight edge in rectified space is a *curve* in raw space,
each edge is subdivided (`:outline_segments`, default 4) and every
vertex mapped individually — so a box is 16 vertices, and its top edge
comes off the wire as y = 101, 101, 100, 100, 99 rather than a
constant. That 2 px bow is the distortion being followed.

## Grayscale is fine

The detector is fed the pipeline's existing grayscale frame. Measured
on the device against ultralytics' `bus.jpg`, grayscale scored within
0.01 of colour (person 0.881 vs 0.888; bus 0.87 vs 0.84). Colour would
mean a second JPEG decode for no measurable gain.

Resolution is likewise not the limit. At the pipeline's 480×270 the
model still scores people at 0.91 / 0.87 / 0.74.

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
RosBridge.Inference.Hailo.available?()                      # true — Port up
RosBridge.Inference.Hailo.busy?()                           # often true; not a fault
:sys.get_state(RosBridge.Publishers.Detections)             # frame_count, seq, published
:sys.get_state(RosBridge.Inference.Hailo).dropped           # 0
```

`seq` tracking `frame_count` exactly means every frame reached the
accelerator; `dropped` climbing means it could not keep up. `busy?`
being true is the normal state at frame rate — there is usually an
inference in flight — so it says nothing about health on its own.

An empty `MarkerArray` streaming at ~13 Hz is correct when nothing
COCO-shaped is in front of the rig — the topic being live and the
arrays being empty are different facts, and `published` in the
publisher's state distinguishes them.

## Failure is not fatal

A missing binary, missing HEF or absent accelerator logs once at boot
and leaves the detector alive but inference-less. Frames are dropped
rather than queued when the accelerator is busy, since a stale
detection has no value. The pair runs under its own supervisor
(`RosBridge.Inference.Supervisor`, `:rest_for_one`, 10 restarts a
minute) so a detector crash-looping at frame rate cannot exhaust the
bridge supervisor's budget and take the cameras down with it.

## Swapping the model

`vehicles/ovcs_mini/priv/models/yolov8n.hef` (fetched, not committed —
see **Model licensing**) is the COCO nano model
compiled for **HAILO8** — a HEF is architecture-specific and will not
load on a Hailo-8L. `yolov8s.hef` from the same model zoo path has an
identical input and output contract and is a drop-in. Anything with a
different input size, or without in-graph NMS, is not: `hailo_detect`
reads `HAILO_NMS_BY_CLASS` output directly and decodes no anchors.

## Running the detector without a Hailo

`RosBridge.Inference.Hailo` is one of three backends behind the
`RosBridge.Inference` behaviour. The other two exist so the whole
stack — detection included — runs on a workstation against the
simulator, rather than everything-but-the-detector.

| Backend | Where it runs | What it is for |
|---|---|---|
| `Inference.Hailo` | Hailo-8, via a Port | the vehicle |
| `Inference.Dnn` | OpenCV DNN: CPU, or GPU via OpenCL | a workstation |
| `Inference.Stub` | nowhere — fixed boxes | proving the plumbing |

`Detections` cannot tell them apart: each answers `detect/3`
asynchronously and replies `{:inference_detections, seq, detections}`
with boxes in the submitted image's pixels. Every backend owns its own
resize transform in both directions.

### The DNN backend, CPU and GPU

`:target` chooses `:cpu`, `:opencl` or `:opencl_fp16`. They are one
module because they differ by two calls — `setPreferableBackend/2` and
`setPreferableTarget/2` — while model loading, blob preparation, output
decoding and NMS are identical.

**CUDA is not an option with the precompiled Evision.** Every `cuda*`
module is listed *Unavailable* in its OpenCV build, so a CUDA target
would mean building Evision from source against CUDA + cuDNN. OpenCL
is available and does use the GPU, but OpenCV's OpenCL DNN kernels are
much less tuned than its CUDA ones — expect roughly 1.5–3x CPU on an
NVIDIA card, not the 10x+ CUDA would give.

Asking for OpenCL where no device is usable logs the reason and
continues on the CPU. It does not silently pretend, because a machine
that quietly lost its GPU should look like a log line rather than an
unexplained slowdown.

### The model is not in the repo

The Hailo path uses `yolov8n.hef`; the DNN path needs the ONNX export
of an equivalent model at `vehicles/ovcs_mini/priv/models/yolov8n.onnx`.
Neither is committed, and for the same reason — see **Model licensing**
below. `mise run fetch-models` downloads and verifies both against
`scripts/models.tsv`.

Until one is present the sim runs stereo-only, which is why the default
is "no detector" rather than "a detector that logs a missing file every
time it starts".

### Choosing a backend in the simulator

`OVCS_DETECTOR` selects it:

```sh
cd bridges/firmware
VEHICLE=OvcsMini OVCS_SIM=1 OVCS_DETECTOR=gpu ZENOH_ENDPOINT_IP=127.0.0.1 \
  BRIDGE_FIRMWARE_ID=ros_perception CAN_NETWORK_MAPPINGS=ovcs:vcan0 \
  iex -S mix
```

| value | backend |
|---|---|
| unset | `Dnn` on CPU if the ONNX model exists, otherwise no detector |
| `dnn` | `Dnn`, CPU |
| `gpu` | `Dnn`, OpenCL FP16 |
| `stub` | `Stub` — fabricated boxes |
| `off` | no detector |

`detect_every_n: 3` in the sim wiring, because CPU inference shares
the machine with SGBM and Gazebo. On the car the accelerator runs every
frame.

### What the stub is actually good for

It fabricates boxes, so it says nothing about detection quality — and
it warns loudly on every start, because boxes on a screen look equally
convincing whether or not anything detected them.

What it *does* test is everything downstream of the box, none of which
involves a neural network: the median-depth sample, the unprojection,
the marker and `Detection3DArray` publishing. Against `workshop.sdf`
its centred box fuses to

```
position: x 0.0  y 0.0  z 0.8088 m
```

and the world puts that box's front face 0.808 m from the lens. Correct
to the millimetre, on the optical axis — which checks the fusion
geometry against ground truth rather than against itself. That path was
previously only exercisable on hardware.

## Known limitation

The `base_link` → `stereo_left` translation in
`vehicles/ovcs_mini/lib/ovcs_mini.ex` is still the placeholder
`{0.10, 0.0, 0.12}`. Every detection is correctly positioned relative
to the camera and inherits that offset relative to the car. Measuring
the lens centre against the chassis origin is the cheapest accuracy
win available here.

## Model licensing

**No model weights are committed to this repository.** `mise run
fetch-models` downloads them and verifies each against a sha256 in
`scripts/models.tsv`, which also records the licence of each one.

### Why

OVCS is MIT licensed (`LICENCE.txt`, Spin42 SRL). Ultralytics YOLOv8 is
dual-licensed **AGPL-3.0** or a paid Enterprise licence, and Ultralytics
asserts that covers the pretrained *weights*, not only their Python
code.

Those two do not compose in this direction. MIT tells downstream users
they may use the work without source-disclosure obligations; AGPL-3.0
does not permit anyone to grant that. A public MIT repository
distributing YOLOv8-derived weights therefore makes a promise its
licence cannot keep — anyone who took `LICENCE.txt` at face value would
inherit an obligation nobody told them about.

Fetching rather than vendoring moves that choice to the operator, who
sees the licence printed before the download starts.

### What is not affected

The inference code. `Inference.Dnn` runs OpenCV's DNN module and
`Inference.Hailo` runs the Hailo runtime; neither contains Ultralytics
code. The decode test fixture (`test/support/tiny_head.onnx`) was
authored from scratch for exactly this reason. The exposure is the
weights, and only the weights.

### Where this is genuinely unsettled

Worth stating rather than implying more certainty than exists:

  * Whether neural network weights attract copyright at all is
    unsettled, and differs between the US and the EU.
  * Whether a compiled `.hef` is a derivative work of the weights it
    was built from. By analogy to compilation, probably; untested for
    models.
  * AGPL-3.0 §13 triggers on "interacting with users remotely through a
    computer network". A vehicle publishing to Foxglove over Zenoh is
    arguably not that.

None of which is legal advice. If OVCS is going anywhere commercial
with YOLOv8 specifically, that needs a real answer and an Ultralytics
Enterprise licence is the direct route to one.

### Permissively licensed alternatives

The durable fix is a detector that does not raise the question. All
Apache-2.0 unless noted:

  * **YOLOX** (Megvii)
  * **NanoDet**
  * **DAMO-YOLO**
  * **RT-DETR** — the original Baidu release, *not* the Ultralytics port
  * **RF-DETR** (Roboflow), **D-FINE**
  * **SSD-MobileNet**, **EfficientDet** — weaker, but long-supported
  * torchvision's detectors (BSD-3)

Avoid: YOLOv5/v8/v10/v11 (Ultralytics, AGPL-3.0), YOLOv6 and YOLOv7
(GPL-3.0), YOLO-NAS (restrictive Deci licence).

A swap is not free. `hailo_detect` reads `HAILO_NMS_BY_CLASS` directly
because YOLOv8's HEF runs NMS in-graph, and `Inference.Dnn.decode/6`
expects an attribute-major `[1, 4 + classes, anchors]` output. A model
without in-graph NMS needs suppression adding back on the Hailo path; a
different output layout needs `decode/6` taught about it. Both are
bounded, and `decode/6` already derives the class count from the shape
rather than assuming 80.

### One thing fetching does not fix

`yolov8n.hef` was committed at one point, so it remains in this
repository's git history and in every existing clone. Removing it from
`HEAD` stops further distribution but does not undo what is already
published; that would take a history rewrite.
