---
title: Vision unit
description: Run depth, detection and road segmentation from cameras on a Pi 5, OKdo Nano C100 or Arduino VENTUNO Q, and opt your vehicle in.
---

The vision unit is an optional fourth role next to `vms`, `infotainment` and the bridges. It runs on a Raspberry Pi 5, an OKdo Nano C100 or an Arduino VENTUNO Q, where it:

- runs stereo depth, and optionally object detection and road segmentation;
- takes the results out through its exporters, such as ROS 2 messages over Zenoh;
- serves its own dashboard.

It has no CAN controller and does not touch the `ovcs` bus. It reaches the vehicle through the Zenoh router of the [ROS compute node](../ros2/compute_node.md), and the rest of the vehicle through the [Erlang mesh](../architecture.md#one-erlang-mesh-no-broker).

A vehicle without cameras omits the role and nothing is built for it. Among the reference vehicles:

- The OVCS Mini reference vehicle runs one on a Raspberry Pi 5 with two Camera Module 3 and a Hailo-8 (`OvcsMini.Vision.Composer`).
- The OVCS1 reference vehicle runs one on an Arduino VENTUNO Q with two Global Shutter Cameras and an HQ Camera (`Ovcs1.Vision.Composer`).

## Layers

The unit follows the same split as the VMS and the infotainment: a core, an API, a firmware shell and a dashboard. The vehicle package supplies everything vehicle-specific.

| Layer | Path | What it is |
|---|---|---|
| Core | [`vision/core`](../../vision/core/README.md) | `VisionCore`: camera drivers, the stereo pipeline and its stages (rectification, matching, depth, in Nx), detection, and the exporters, the ROS 2 one and the ROS 2 link under `VisionCore.Ros2`. No vehicle knowledge, no web dependencies. |
| API | [`vision/api`](../../vision/api/README.md) | `VisionApi`: a Phoenix endpoint serving the vision parameters and the active configuration as JSON:API resources, with channels that stream status and camera previews. |
| Firmware | [`vision/firmware`](../../vision/firmware/README.md) | The Nerves image for the `rpi5`, `okdo_c100` and `arduino_ventuno_q` targets. At boot it reads `VEHICLE` and loads the vehicle's composer. |
| Dashboard | [`vision/dashboard`](../../vision/dashboard/README.md) | A React app showing the unit's status, the left, right and depth previews, and the unit as its pipeline with each box's parameters. |
| Ports | [`vision/rust`](../../vision/rust/README.md) | The Rust programs the core drives as Ports: capture, detection, road segmentation, JPEG and stereo matching on the CPU. |

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
| Capture | `VisionCore.Camera.LibCamera`, JPEG frames, or grey frames with `format: :grey` | `VisionCore.Camera.V4L2Pair`, grey frames over raw V4L2 | `VisionCore.Camera.V4L2Pair`, grey frames over raw V4L2 through CAMSS |
| Synchronisation | libcamera's software sync, `sync: :server` on one camera and `sync: :client` on the other | `v4l2_capture` locks the right sensor's frame starts to the left one's | as on the C100 |
| Stereo stages | on the CPU, in native code (`compute: :native`) | on the GPU through Vulkan | on the GPU through Vulkan |
| `:defn_options` | only for Nx stages with no native implementation: `VisionCore.Stereo.NxSegment.rpi5_defn_options/1` | `VisionCore.Stereo.NxSegment.c100_defn_options/1` | `VisionCore.Stereo.NxSegment.ventuno_q_defn_options/1` |
| Detection | `VisionCore.Detection.Backend.Hailo` | none | `VisionCore.Detection.Backend.Qnn`, on the NPU |

## The Arduino VENTUNO Q

The Arduino VENTUNO Q carries a Qualcomm QCS8300: 4 Cortex-A78C and 4 Cortex-A55 cores, an Adreno 623 GPU, a Hexagon NPU (HTP v75) and 16 GB of memory. Its CAMSS camera subsystem has three CSI connectors, Camera 0, 1 and 2. Its system is [`nerves_system_arduino_ventuno_q`](https://github.com/Spin42/nerves_system_arduino_ventuno_q). The stereo stages run on the GPU, as on the C100 ([On the VENTUNO Q's GPU](./compute.md#on-the-ventuno-qs-gpu)), and detection on the NPU.

**Cameras.** `/boot/cameras.cfg`, in your vehicle's `priv/firmware/vision/rootfs_overlay/`, names the sensor on each connector. `VisionCore.Camera.V4L2Pair` takes the left and right cameras' connectors as `left_csiphy:` and `right_csiphy:` among the `:left` camera's options. `VisionCore.Camera.Camss` routes each one's sensor through CSID and VFE with media-ctl. At boot it waits up to 30 s for the media graph and the sensors.

`v4l2_capture` captures through V4L2's multiplanar API in packed 10-bit Bayer (pRAA), and knows the IMX708 and IMX296 sensors. A camera of its own also takes the IMX477 ([A camera of its own](./cameras.md)).

**Detection and segmentation.** The `:qnn_detector` and `:qnn_segmenter` components run their models on the NPU through QNN ([On the VENTUNO Q's NPU](./detection.md#on-the-ventuno-qs-npu), [Road segmentation](./segmentation.md)).

QAIRT is not in the repository: its licence allows shipping it only inside a firmware. `mise run fetch-qairt` downloads it into the firmware's rootfs overlay, and the image carries it as `/opt/qairt`. QNN's headers are proprietary too. The QNN Ports' bindings are generated at build time from the cached QAIRT archive. Nothing derived from them is committed.

To build a unit for this board, run from the repository root:

```sh
VEHICLE=<Vehicle> mise run fetch-qairt   # QAIRT, into the firmware's rootfs overlay
mise run fetch-models                    # the models, the YOLOX and FFNet DLCs among them
cd vehicles/<vehicle>
mix vision_core.nx_cache --composer <Vehicle>.Vision.Composer --out priv/nx_iree_cache
cd ../..
./ovcs build <vehicle> vision
```

The `nx_cache` step compiles the GPU modules on your workstation, as for the C100 ([Where depth is computed](./compute.md#nx-the-stages-as-tensor-programs)).

### Worked example: the OVCS1 reference vehicle

`Ovcs1.Vision.Composer` runs two Raspberry Pi Global Shutter Cameras (IMX296) with 6 mm lenses, 20 cm apart, on Camera 0 (left) and Camera 1 (right). They capture 728 × 544 at 30 frames a second. The pairs are matched at that size over 128 disparities with `search: "coarse_to_fine"` and 3 coarse paths. Depth keeps up with the cameras' 30 pairs a second. The pair computes depth only.

Detection and road segmentation run on `:center`, a Raspberry Pi HQ Camera (IMX477) on Camera 2 ([A camera of its own](./cameras.md#worked-example-the-ovcs1-reference-vehicle)).

The stereo pair's calibration, `priv/calibration/stereo_left.yaml` and `stereo_right.yaml`, comes from `cameracalibrator`. To replace it, calibrate the pair ([Calibration](./basics.md#calibration)), then do one of two things:

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

## Cameras and pipelines

A camera outside the stereo pair, and the pipelines on its image:

- [A camera of its own](./cameras.md): the `:camera` component, its outputs, calibration and pose.
- [Object detection](./detection.md): detection pipelines, the accelerator's load and the models you may ship.
- [Road segmentation](./segmentation.md): road and off-road clouds from a camera of its own.

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

The Row alignment card shows how many rows the right image's matches sit from the left image's, over the whole image and in four bands from left to right. A calibration that still fits the cameras reads within half a row. A larger offset means the cameras or their lenses have moved since the calibration, and depth degrades until you recalibrate. Offsets that change across the bands are a rotation.

The Sharpness card compares the two cameras' focus: the right image's sharpness over the left's, green between 0.8 and 1.25. Its absolute value depends on the scene, the ratio does not.

On a unit whose cameras have lens actuators, such as the Camera Module 3, both lenses follow one `focus` camera setting. Its default, 428, focuses the Camera Module 3 Wide at about 1.5 to 2 m. `VisionCore.Camera.FocusSweep.run/1` steps `focus` through a range, sets the position best for both cameras and returns the sharpness curve. Run it from IEx, on the unit facing a textured scene at the distance that matters. Recalibrate after changing the focus.

The vision parameters are the unit's own settings, grouped by component and pipeline stage:

- the cameras' controls;
- each stereo stage's settings, among them the matcher's `p1`, `p2` and `uniqueness`;
- on a unit with detection, the detection's settings.

Most apply live. The stereo settings are inputs of the stages, not compiled in, so a change applies from one of the next pairs without restarting anything. Others are fixed in the build, such as the image size. Some are set by an automatic mode while it is on, such as the exposure under auto exposure.

The dashboard shows each step of the unit's pipelines as a box. The stereo pipeline is the cameras, then each stage your vehicle composes, in order. Each detection pipeline is its input, inference, filtering and placement ([Several pipelines](./detection.md#several-pipelines)). The selected box stays in the URL (`?box=stereo.disparity`), so a link opens it again.

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

## Running it on a workstation

On the host the composer's `:host` arm applies: it can read USB cameras through `VisionCore.Camera.GStreamer`, or a simulator's camera topics through `VisionCore.Ros2.Camera`. No CAN interface is needed. The stereo stages compile with EXLA. `mix compile` builds for the host `jpeg_codec`, which decodes the cameras' JPEG frames, and `stereo_match`, for a pipeline computing with `compute: :native`.

## See also

- [Where depth is computed](./compute.md#rust-ports): the Rust Ports the core drives and how they are built.
- [ROS compute node](../ros2/compute_node.md): the router the unit peers with.
- [Hardware](../hardware.md#bridges-and-extras): the boards, the cameras and the optional Hailo-8.
