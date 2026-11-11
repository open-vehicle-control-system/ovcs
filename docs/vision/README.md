---
title: Vision unit
description: The vision role, a Pi 5, OKdo Nano C100 or Arduino VENTUNO Q that turns stereo cameras into depth and detection as ROS 2 topics, and how a vehicle opts in.
---

The vision unit is an optional fourth role next to `vms`, `infotainment` and the bridges. It runs on a Raspberry Pi 5, an OKdo Nano C100 or an Arduino VENTUNO Q, where it:

- runs stereo depth, and optionally object detection;
- takes the results out through its exporters, such as ROS 2 messages over Zenoh;
- serves its own dashboard.

It has no CAN controller and does not touch the `ovcs` bus. It reaches the vehicle through the Zenoh router of the [ROS compute node](../ros2/compute_node.md), and the rest of the vehicle through the [Erlang mesh](../architecture.md#one-erlang-mesh-no-broker).

A vehicle without cameras omits the role and nothing is built for it. Among the reference vehicles:

- The OVCS Mini reference vehicle runs one on a Raspberry Pi 5 with two Camera Module 3 and a Hailo-8 (`OvcsMini.Vision.Composer`).
- The OVCS1 reference vehicle runs one on an Arduino VENTUNO Q with two Global Shutter Cameras (`Ovcs1.Vision.Composer`).

## Layers

The unit follows the same split as the VMS and the infotainment: a core, an API, a firmware shell and a dashboard. The vehicle package supplies everything vehicle-specific.

| Layer | Path | What it is |
|---|---|---|
| Core | [`vision/core`](../../vision/core/README.md) | `VisionCore`: camera drivers, the stereo pipeline and its stages (rectification, matching, depth, in Nx), detection, and the exporters, the ROS 2 one and the ROS 2 link under `VisionCore.Ros2`. No vehicle knowledge, no web dependencies. |
| API | [`vision/api`](../../vision/api/README.md) | `VisionApi`: a Phoenix endpoint serving the vision parameters and the active configuration as JSON:API resources, with channels that stream status and camera previews. |
| Firmware | [`vision/firmware`](../../vision/firmware/README.md) | The Nerves image for the `rpi5`, `okdo_c100` and `arduino_ventuno_q` targets. At boot it reads `VEHICLE` and loads the vehicle's composer. |
| Dashboard | [`vision/dashboard`](../../vision/dashboard/README.md) | A React app showing the unit's status, the left, right and depth previews, a preview of each camera of its own, and the unit as its pipeline with each box's parameters. |
| Ports | [`vision/rust`](../../vision/rust/README.md) | The Rust programs the core drives as Ports: capture, detection, JPEG and stereo matching on the CPU. |

## Opting in

Two callbacks on your vehicle's `OvcsVehicle` module add the role:

```elixir
@impl OvcsVehicle
def vision, do: MyCar.Vision.Composer

@impl OvcsVehicle
def vision_target, do: :rpi5
```

`vision_target/0` is `:rpi5`, `:okdo_c100` or `:arduino_ventuno_q`. See [The OKdo Nano C100](#the-okdo-nano-c100) and [The Arduino VENTUNO Q](#the-arduino-ventuno-q) for the other two.

`vision/0` returns a module implementing `VisionCore.Composer`:

- `config/1` returns a `VisionCore.Config` for the `:host` or `:target` arm. It holds the components and their drivers, the exporters, and the ROS 2 link they need: Zenoh endpoint and ROS node name.
- The optional `required_files/0` lists files that the image needs and the repository does not carry, such as a detection model. Their paths are relative to your vehicle app. The build fails when one is missing.

The documentation is in:

- the behaviour, in `VisionCore.Composer`;
- the components you can list, in `VisionCore.Components`;
- the exporters, in [How a pair flows](./data_flow.md#exporters).

See also [Your vehicle package](../vehicle_package.md#the-five-behaviours).

A component given an option it does not take is left down, with the reason logged, and the unit runs on without it. When another component or exporter takes that option, as the ROS 2 exporter takes the stereo images' topics, the log names it.

Everything the unit needs from a vehicle lives in the package: resolution, the stereo stages and their settings, calibration, topic prefix, frame ids, detection model and thresholds. Boot files for the Pi go in `vehicles/<vehicle>/priv/firmware/vision/`. Files for the image's root filesystem, such as the VENTUNO Q's `/boot/cameras.cfg`, go in its `rootfs_overlay/`.

## The OKdo Nano C100

The OKdo Nano C100 carries a Jetson Nano module: a GPU, two CSI camera ports and no accelerator for detection. Its system is [`nerves_system_okdo_c100`](https://github.com/Spin42/nerves_system_okdo_c100). Power it from a dedicated supply rather than over USB.

| | Raspberry Pi 5 | OKdo Nano C100 | Arduino VENTUNO Q |
|---|---|---|---|
| Capture | `VisionCore.Camera.LibCamera`, JPEG frames, or grey frames with `format: :grey` | `VisionCore.Camera.V4L2`, grey frames over raw V4L2 | `VisionCore.Camera.V4L2`, grey frames over raw V4L2 through CAMSS |
| Synchronisation | libcamera's software sync, `sync: :server` on one camera and `sync: :client` on the other | `v4l2_capture` locks the right sensor's frame starts to the left one's | as on the C100 |
| Stereo stages | on the CPU, in native code (`compute: :native`) | on the GPU through Vulkan | on the GPU through Vulkan |
| `:defn_options` | only for Nx stages with no native implementation: `VisionCore.Stereo.NxSegment.rpi5_defn_options/1` | `VisionCore.Stereo.NxSegment.c100_defn_options/1` | `VisionCore.Stereo.NxSegment.ventuno_q_defn_options/1` |
| Detection | `VisionCore.Detection.Backend.Hailo` | none | `VisionCore.Detection.Backend.Qnn`, on the NPU |

## The Arduino VENTUNO Q

The Arduino VENTUNO Q carries a Qualcomm QCS8300: 4 Cortex-A78C and 4 Cortex-A55 cores, an Adreno 623 GPU, a Hexagon NPU (HTP v75) and 16 GB of memory. Its CAMSS camera subsystem has three CSI connectors, Camera 0, 1 and 2. Its system is [`nerves_system_arduino_ventuno_q`](https://github.com/Spin42/nerves_system_arduino_ventuno_q). The stereo stages run on the GPU, as on the C100 ([On the VENTUNO Q's GPU](./compute.md#on-the-ventuno-qs-gpu)), and detection on the NPU.

**Cameras.** `/boot/cameras.cfg`, in your vehicle's `priv/firmware/vision/rootfs_overlay/`, names the sensor on each connector. `VisionCore.Camera.V4L2` takes the left and right cameras' connectors as `left_csiphy:` and `right_csiphy:` among the `:left` camera's options. `VisionCore.Camera.Camss` routes each one's sensor through CSID and VFE with media-ctl. At boot it waits up to 30 s for the media graph and the sensors. `v4l2_capture` captures through V4L2's multiplanar API in packed 10-bit Bayer (pRAA), and knows the IMX708 and IMX296 sensors; a camera of its own also takes the IMX477 in packed 12-bit Bayer (pRCC), below.

**A camera of its own.** The `:camera` component runs one camera outside the stereo pair, for a view that is not a depth source: `{:camera, name: :hq, driver: VisionCore.Camera.V4L2Single, csiphy: 2}`. `:name` follows the rule of a detection pipeline's name, whose reserved names include `left`, `right` and `depth`, and no camera shares a pipeline's name. The camera's frames are the output `{:camera_frame, name}`, which an exporter lists like the stereo cameras' (`{:camera_frame, :hq}`), and each carries the optical frame `"<name>_optical"` unless you set `:frame_id`. A `:driver` that is not a `VisionCore.Camera` raises `ArgumentError` as the unit starts, so a mistyped one fails the boot. A unit that fails later, such as one whose sensor never registers, stays down with the reason logged while the stereo unit and the rest of the vision core run on.

`VisionCore.Camera.V4L2Single` captures a Raspberry Pi HQ Camera (IMX477) on a CAMSS connector, Camera 2 on the VENTUNO Q. It takes the sensor's 2028 × 1520 12-bit binned mode as packed Bayer (pRCC), and `v4l2_capture` demosaics it to 8-bit RGB: `output: :full`, the default, keeps the mode's 2028 × 1520, and `output: :half` gives 1014 × 760, each 2 × 2 Bayer cell one pixel. Auto exposure steers the green channel's mean and a grey-world white balance corrects the colour from the previous frame; `awb: false` applies `red_gain` and `blue_gain` as set instead. A full-resolution frame is 9 MB, which is why the unit's `VisionCore.Preview` encodes it only at the preview's rate.

The IMX477's colour follows libcamera's Raspberry Pi pipeline, with Raspberry Pi's tuning for the sensor. `v4l2_capture` subtracts the black level, applies the lens shading and white balance gains, and demosaics on linear 16-bit values. It then applies the colour correction matrix of the colour temperature that the white balance gives. A chroma denoise blurs the colour at the resolution of the 2 × 2 Bayer cells and keeps each pixel's brightness, which removes the coloured speckle of high gain. The tuning's contrast curve then encodes the result to 8 bits. Auto exposure measures the green after lens shading and white balance, through the contrast curve, before the colour matrix and the denoise. `ccm: false` leaves the matrix out and `denoise: false` the denoise. On this sensor `gamma` only sets how far auto exposure steps; on a sensor without a tuning it also encodes the image.

**Detection.** The `:qnn_detector` component runs YOLOX on the NPU through QNN, from Qualcomm's AI Runtime (QAIRT 2.50). YOLOX runs in the `qnn_detect` Port behind `VisionCore.Detection.Backend.Qnn`. It takes the model as a DLC, `dlc_path:`. On first boot the board generates the model's context binary from it with QAIRT's `qnn-context-binary-generator`, into `/data/vision/qnn`. Later boots reuse it. A new DLC or a new QAIRT makes a new one (`VisionCore.Detection.QnnContext`).

QAIRT is not in the repository: its licence allows shipping it only inside a firmware. `mise run fetch-qairt` downloads it into the firmware's rootfs overlay, and the image carries it as `/opt/qairt`. QNN's headers are proprietary too: `qnn_detect`'s bindings are generated at build time from the cached QAIRT archive, and nothing derived from them is committed.

To build a unit for this board, run from the repository root:

```sh
VEHICLE=<Vehicle> mise run fetch-qairt   # QAIRT, into the firmware's rootfs overlay
mise run fetch-models                    # the detection models, the YOLOX DLC among them
cd vehicles/<vehicle>
mix vision_core.nx_cache --composer <Vehicle>.Vision.Composer --out priv/nx_iree_cache
cd ../..
./ovcs build <vehicle> vision
```

The `nx_cache` step compiles the GPU modules on your workstation, as for the C100 ([Where depth is computed](./compute.md#nx-the-stages-as-tensor-programs)).

### Worked example: the OVCS1 reference vehicle

`Ovcs1.Vision.Composer` runs two Raspberry Pi Global Shutter Cameras (IMX296) with 6 mm lenses, 20 cm apart, on Camera 0 (left) and Camera 1 (right). They capture 728 × 544 at 35 frames a second. The pairs are matched at that size over 128 disparities with `search: "coarse_to_fine"` and 3 coarse paths, which keeps depth at about 34.5 pairs a second. YOLOX detects objects on more than 9 pairs in 10. The same composer shape works on your own vehicle with your cameras and connectors.

Its `priv/calibration` holds a nominal calibration until the rig is calibrated: a focal length of 869.6 px from the lens and the pixel pitch, no distortion, and the 20 cm baseline. To replace it, calibrate the pair ([Calibration](./basics.md#calibration)), then do one of two things:

- Replace the two YAML files and rebuild.
- Commit the calibration through the ROS 2 exporter's `set_camera_info` services, as `cameracalibrator` does. With `calibration_store_dir` set on the `:stereo` component, `/data/vision/calibration` on OVCS1, a calibration committed for both sides is stored there and takes precedence over the files (`VisionCore.Stereo.Supervisor`).

The rates measured on this unit are in [Vision performance](./performance.md#measured-on-an-arduino-ventuno-q).

## Depth

The stereo stages turn each pair of camera frames into a disparity, then a depth image and a point cloud. The disparity is the horizontal shift of each point between the two images. Where the stages run depends on the board. On the C100 and the VENTUNO Q, they run on the GPU, compiled from Nx. On the Raspberry Pi 5, they run on the CPU cores, in native code. The guides of this section explain them:

- [Stereo vision basics](./basics.md): lens, baseline, rectification, disparity, depth and point cloud, with diagrams and a worked example.
- [How a pair flows](./data_flow.md): the processes a pair goes through, from the cameras to the ROS 2 topics and the dashboard.
- [Stereo stages](./stages.md): what each stage does, what it reads and fills, and its settings.
- [Where depth is computed](./compute.md): Nx, `nx_iree`, the `stereo_match` Port, and how each uses the GPU, the CPU cores and memory.
- [Vision performance](./performance.md): measured rates and the settings that change them.

## Build, burn, upload

The role is addressed like the others:

```sh
./ovcs build  <vehicle> vision
./ovcs burn   <vehicle> vision
./ovcs upload <vehicle> vision
./ovcs clean  <vehicle> vision
```

`VEHICLE` selects the package and `vision_target/0` the `MIX_TARGET`. The build compiles the dashboard into the API's static files, cross-builds the Rust Ports and then runs `mix firmware`. Per-vehicle secrets, the Zenoh router address and Wi-Fi networks come from `vehicles/<vehicle>/.env.exs`, as for every other firmware. Rebuild after changing `ZENOH_ENDPOINT_IP`. Details are in [`vision/firmware/README.md`](../../vision/firmware/README.md) and [Running on hardware](../running_hardware.md).

The image's hostname is `<vehicle>-vision` and the node joins the Erlang mesh as role `vision`, so it reaches its peers and is reachable at `<vehicle>-vision.local`.

## Dashboard and API

The dashboard and the API are served from the board on port 4100:

```text
http://<vehicle>-vision.local:4100
```

A firmware version ending in `-dirty` is a build with uncommitted changes.

On a unit with detection, an object with no depth in the middle of its box, such as one nearer than the depth can measure, is left out of the detections.

The Row alignment card shows how many rows the right image's matches sit from the left image's, over the whole image and in four bands from left to right. A calibration that still fits the cameras reads within half a row. A larger offset means the cameras or their lenses have moved since the calibration, and depth degrades until you recalibrate. Offsets that change across the bands are a rotation.

The Sharpness card compares the two cameras' focus: the right image's sharpness over the left's, green between 0.8 and 1.25. Its absolute value depends on the scene, the ratio does not.

On a unit whose cameras have lens actuators, such as the Camera Module 3, both lenses follow one `focus` camera setting. Its default, 428, focuses the Camera Module 3 Wide at about 1.5 to 2 m. `VisionCore.Camera.FocusSweep.run/1` steps `focus` through a range, sets the position best for both cameras and returns the sharpness curve. Run it from IEx, on the unit facing a textured scene at the distance that matters. Recalibrate after changing the focus.

The vision parameters are the unit's own settings, grouped by component and pipeline stage:

- the cameras' controls;
- each stereo stage's settings, among them the matcher's `p1`, `p2` and `uniqueness`;
- on a unit with detection, the detection's settings.

Most apply live. The stereo settings are inputs of the stages, not compiled in, so a change applies from one of the next pairs without restarting anything. Others are fixed in the build, such as the image size. Some are set by an automatic mode while it is on, such as the exposure under auto exposure.

The dashboard shows each step of the unit's pipelines as a box. The stereo pipeline is the cameras, then each stage your vehicle composes, in order. Each detection pipeline is its input, inference, filtering and placement: `<name>.input`, `<name>.inference`, `<name>.filtering` and `<name>.placement` for a named one, `detection.*` for the default. The selected box stays in the URL (`?box=stereo.disparity`), so a link opens it again.

A box's panel lists its parameters with their constraints and defaults:

- a live parameter changes while the unit runs;
- a parameter fixed in the build is shown but locked;
- a parameter set by an automatic mode shows the mode that sets it.

A relation between two parameters, such as `p2` above `p1`, bounds each control by the other's value.

A change is unsaved until you save it. Unsaved changes live on the unit, not in the page: reloading the dashboard or opening it elsewhere loses nothing, and a reboot drops them. The dashboard offers:

- **Save**: stores the unsaved values on the unit, in `/data/vision_core.db`, where they are applied again at every boot.
- **Discard**: returns every unsaved parameter to its saved value, or to its default without one.
- **Reset**: a box's Reset, or a parameter's, returns it to the defaults; **Reset all** returns every parameter.

Discard and Reset all ask first. From IEx, the same actions are `VisionCore.Parameters.save/1`, `discard/1` and `reset/2`.

The parameters are also reachable with `ros2 param` and Foxglove's Parameters panel under their ids, `<prefix>.<stage>.<name>` (`stereo.disparity.p1`). A change made there is saved at once, and unsaved changes from the dashboard stay unsaved.

The compute node's `foxglove_bridge` offers the parameters under `/ovcs_vision.stereo.`. The Foxglove layout [`ovcs_stereo_tuning.json`](../../compose/local/foxglove/ovcs_stereo_tuning.json) shows them as sliders next to the depth and the cameras' sync, exposure and gain. Its rectified camera panels need `publish_rectified_image: true` in the ROS 2 exporter's `stereo:` options.

The API follows [JSON:API](https://jsonapi.org/). [Vision API](./api.md) shows how a program reads and changes the parameters and follows the live channels. [`vision/api/README.md`](../../vision/api/README.md) lists its routes.

The dashboard's Exporters menu lists what takes the unit's outputs out of it, from `GET /api/exporters`: each exporter with its status, the API last. [Tune with exports](./tuning.md) shows how to record the unit's results before and after a change of parameters, with the debug exporter's export action, and compare them.

`GET /api/ros2-node` describes what the unit exports over ROS 2:

- its node, named after the node name, with the Zenoh router endpoint and whether the session to it is open;
- the topics it has published, each with its message type and rate over the last second;
- the services it answers: the parameter services and each camera's `set_camera_info`.

Add `?include=topics,services`, or either alone, to get the topics and services themselves rather than their ids. A unit without the ROS 2 link has no node: `GET /api/ros2-node` answers 404.

The topic counts come from `VisionCore.Ros2.Topics`, which counts every message sent through `VisionCore.Ros2.Topics.publish/4`, so a new publisher appears without changes. A message that cannot be encoded is not sent. It is logged once per topic and message type and counted in `VisionCore.Ros2.Topics.topics/0` as `encode_failures`.

On the host, `./ovcs run <vehicle>` starts a BEAM for the role and the dashboard's Vite dev server as an add-on, like the VMS dashboard, on `http://localhost:5174`.

## Several detection pipelines

A composer may list several detector components (`:detector`, `:hailo_detector`, `:qnn_detector`), each with a `:name`: a lowercase atom such as `:vehicle_detection`, defaulting to `:detection`. Each named pipeline has its own supervisor, backend, model and parameter groups, and the dashboard's menu draws it as its own flow. Names that collide with a ROS 2 topic segment under the prefix, the stereo pipeline's name, or the Hailo-8 claim are reserved, and two detectors with the same name are refused; `VisionCore.Detection` lists the reserved names.

The Hailo-8 serves one pipeline: a second Hailo pipeline is left down, with "the Hailo-8 already serves another pipeline" logged, and the status `npu` shows `failed` because it covers every pipeline's backend and is `failed` when any of them is unavailable. Two QNN pipelines each run on the Hexagon, and a named one's default `cache_dir` is `/data/vision/qnn/<name>`.

The NPU in the top bar shows its kind and its load, and each detection pipeline's Inference box its mean inference time. Neither accelerator exposes a load counter to Linux, so each Port times its own inferences and the status sums them every second. A pipeline's inference time is the mean over the second's frames; the load is the share of the second the pipelines spent inferring, summed over every pipeline on the accelerator and at most 100 %. On the Hailo-8 the time runs from writing the input to reading the output, so it holds the device's work and the PCIe transfer. On the Hexagon it is the NPU's execute time as QNN's profiling reports it, without the wait for the NPU to be free, so two pipelines sharing it are not counted twice; where profiling is unavailable it is the wall time around the graph's execution, which includes the FastRPC call and overstates the NPU's work. The load is blank until a Port has reported a time; a pipeline's time is blank in a second without a frame, never 0.

Each exporter takes the pipelines it publishes: the ROS 2 exporter's `detections:` takes `pipelines:` (`[:detection]` by default), and the API serves a channel per pipeline ([Detections](./api.md#detections)). The Debug exporter reads the default pipeline only.

## Detection models

Each detector component runs the model its option names:

- `:hailo_detector` runs the HEF its `:hef_path` names, compiled for the Hailo-8.
- `:qnn_detector` runs the DLC its `:dlc_path` names, on the VENTUNO Q's NPU.

**No model weights are committed.** `mise run fetch-models` downloads them and verifies each against the sha256 in `scripts/models.tsv`, which also records each licence and prints it before the download.

[`vehicles/ovcs_mini/priv/models/README.md`](../../vehicles/ovcs_mini/priv/models/README.md) describes the OVCS Mini reference vehicle's models and what they require. The OVCS1 reference vehicle runs YOLOX (Apache-2.0) from Qualcomm AI Hub, `yolox_w8a8.dlc`.

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

## Running it on a workstation

On the host the composer's `:host` arm applies: it can read USB cameras through `VisionCore.Camera.GStreamer`, or a simulator's camera topics through `VisionCore.Ros2.Camera`. No CAN interface is needed. The stereo stages compile with EXLA. `mix compile` builds for the host `jpeg_codec`, which decodes the cameras' JPEG frames, and `stereo_match`, for a pipeline computing with `compute: :native`.

## See also

- [Where depth is computed](./compute.md#rust-ports): the Rust Ports the core drives and how they are built.
- [ROS compute node](../ros2/compute_node.md): the router the unit peers with.
- [Hardware](../hardware.md#bridges-and-extras): the boards, the cameras and the optional Hailo-8.
