---
title: Vision unit
description: The vision role, a Raspberry Pi 5 or an OKdo Nano C100 that turns stereo cameras into ROS 2 depth and detection topics, and how a vehicle opts in.
---

The vision unit is an optional fourth role next to `vms`, `infotainment` and the bridges. It runs stereo depth and object detection on a Raspberry Pi 5 or an OKdo Nano C100, publishes the results as ROS 2 messages over Zenoh, and serves its own dashboard. It has no CAN controller and does not touch the `ovcs` bus: it reaches the vehicle through the Zenoh router of the [ROS compute node](./ros2_compute_node.md), and the rest of the vehicle through the [Erlang mesh](./architecture.md#one-erlang-mesh-no-broker).

A vehicle without cameras omits the role and nothing is built for it. None of the reference vehicles runs it yet: the OVCS Mini runs the same stack inside its `ros_vision` bridge firmware ([Perception](./ros2_perception.md)).

## Layers

The unit follows the same split as the VMS and the infotainment: a core, an API, a firmware shell and a dashboard, with the vehicle package supplying everything vehicle-specific.

| Layer | Path | What it is |
|---|---|---|
| Core | [`vision/core`](../vision/core/README.md) | `VisionCore`: camera drivers, the stereo pipeline and its stages (rectification, matching, depth, in Nx), detection, and the ROS 2 side under `VisionCore.Ros2`. No vehicle knowledge, no web dependencies. |
| API | [`vision/api`](../vision/api/README.md) | `VisionApi`: a Phoenix endpoint serving the vision parameters and the active configuration as JSON:API resources, with channels that stream status and camera previews. |
| Firmware | [`vision/firmware`](../vision/firmware/README.md) | The Nerves image for the `rpi5` and `okdo_c100` targets. At boot it reads `VEHICLE` and loads the vehicle's composer. |
| Dashboard | [`vision/dashboard`](../vision/dashboard/README.md) | A React app showing the status cards, the left, right and depth previews, and the unit as its pipeline with each box's parameters. |
| Ports | [`vision/rust`](../vision/rust/README.md) | The Rust programs the core drives as Ports: capture, detection, JPEG and stereo matching on the CPU. |

The [ROS bridge](../bridges/ros_bridge/README.md) carries the same stereo and detection stack as components; a vehicle runs it in one or the other.

## Opting in

Two callbacks on your vehicle's `OvcsVehicle` module add the role:

```elixir
@impl OvcsVehicle
def vision, do: MyCar.Vision.Composer

@impl OvcsVehicle
def vision_target, do: :rpi5
```

`vision_target/0` is `:rpi5` or `:okdo_c100`; see [The OKdo Nano C100](#the-okdo-nano-c100) for the second.

`vision/0` returns a module implementing `VisionCore.Composer`: `config/1` returns a `VisionCore.Config` for the `:host` or `:target` arm (Zenoh endpoint, ROS node name, components and their drivers), and the optional `required_files/0` lists files, relative to your vehicle app, that the image needs and the repository does not carry, such as a detection model. The build fails when one is missing. The behaviour is documented in `VisionCore.Composer`, and the components you can list in `VisionCore.Components`; see also [Your vehicle package](./vehicle_package.md#the-five-behaviours).

Everything the unit needs from a vehicle lives in the package: resolution, the stereo stages and their settings, calibration, topic prefix, frame ids, detection model and thresholds. Boot files for the Pi go in `vehicles/<vehicle>/priv/firmware/vision/`.

## The OKdo Nano C100

The OKdo Nano C100 carries a Jetson Nano module: a GPU, two CSI camera ports and no accelerator for detection. Its system is [`nerves_system_okdo_c100`](https://github.com/Spin42/nerves_system_okdo_c100). Power it from a dedicated supply rather than over USB.

| | Raspberry Pi 5 | OKdo Nano C100 |
|---|---|---|
| Capture | `VisionCore.Camera.LibCamera`, JPEG frames, or grey frames with `format: :grey` | `VisionCore.Camera.V4L2`, grey frames over raw V4L2 |
| Synchronisation | the Pi's camera sync | `v4l2_capture` locks the right sensor's frame starts to the left one's |
| Stereo stages | on the CPU, in native code (`compute: :native`) | on the GPU through Vulkan |
| `:defn_options` | `VisionCore.Stereo.NxSegment.rpi5_defn_options/1` | `VisionCore.Stereo.NxSegment.c100_defn_options/1` |
| Detection | `VisionCore.Detection.Backend.Hailo` | none |

## Depth in Nx

The stereo stages, `VisionCore.Stereo.Pipeline.default_stages/1`, are written in Nx and compiled by `nx_iree` for the board: consecutive stages become one module, so on the C100 a pair goes to the GPU once and comes back once. JPEG frames are decoded to grey by the `jpeg_codec` Port; grey frames are used as they are.

The `:stereo` component's `:defn_options` names the board's compiler options, with a module cache directory in your vehicle's `priv/`. A board has neither EXLA nor the IREE compiler, so the modules are compiled on your workstation into that cache, without a board of that kind attached. Run this in your vehicle's project, on the host, where `vision_firmware` brings EXLA:

```sh
cd vehicles/<vehicle>
mix vision_core.nx_cache --composer <Vehicle>.Vision.Composer --out priv/nx_iree_cache
```

It compiles what the composer's stereo pipeline compiles when it starts. The cache keys each module on the stages, their options and the matching size, so rebuild it after changing any of them; a unit whose cache lacks a module fails to start its stereo pipeline. A calibration is an input of the modules, so a new calibration needs no rebuild. List the directory in `required_files/0` so a build without it fails.

The cameras can deliver more pixels than the board matches in time: `:match_width` and `:match_height` on the `:stereo` component set the matching size, and the frames are scaled down to it before rectification.

On the Raspberry Pi 5 the stages run on its CPU. Compiled for a CPU, the Nx stages are far too slow there: `nx_iree`'s code runs 15 to 30 times slower on the Pi's cores than on a workstation's. Give the `:stereo` component `compute: :native` and every default stage runs in native code instead, in the `stereo_match` Port, on every core:

```elixir
{:stereo,
 [
   compute: :native,
   stages: Pipeline.default_stages(disparity: [num_disparities: 64, paths: 3]),
   # driver, sizes, calibration and cameras as above
 ]}
```

The stages keep their names, their parameters (`stereo.disparity.p1`, `stereo.rectification.right_row_offset` and the others, live ones still live) and their outputs, so the publishers, the dashboard and detection work unchanged. Their results are the Nx stages': images, disparities and depths are identical to Nx's evaluator, and the sums behind the sharpness, row alignment and quality figures agree to the rounding of their order. Consecutive native stages run as one segment, so a pair crosses the Port once; a stage without a native implementation, such as one of your own, runs between two segments. The pipeline's log line gives each stage's time in the Port, and the segment's in total.

When the native segment comes first, as with the default stages, the pipeline keeps two pairs at the Port: it computes one while the next one's frames come in and the previous one's outputs go out, so the rate is bound by the computation rather than by the round trip. A pair is published once its outputs are back, in the order the pairs came in, and a live setting applies from the second pair after the change. The pipeline's `total` is then a pair's latency, about two segment times, and `wall` the interval between pairs.

`mix vision_core.nx_cache` then has nothing to compile, unless some stages still run in Nx, and the composer needs no module cache. `config :vision_core, :stereo_match_threads` limits the threads the Port computes on, every core by default; the threads are kept from one pair to the next.

A stage can override the component's choice: `Disparity`'s `matcher: :native` matches natively in a pipeline otherwise compiled with Nx, and `matcher: :nx` compiles the matching in a native one:

```elixir
Pipeline.default_stages(disparity: [num_disparities: 64, paths: 3, matcher: :native])
```

Give both cameras `format: :grey` in the `:stereo` component's `:left` and `:right` options so the CPU goes to depth: `camera_capture` then sends the luma it already has instead of encoding JPEG frames that the core decodes again, and only the raw images and dashboard previews actually sent are encoded.

## Build, burn, upload

The role is addressed like the others:

```sh
./ovcs build  <vehicle> vision
./ovcs burn   <vehicle> vision
./ovcs upload <vehicle> vision
./ovcs clean  <vehicle> vision
```

`VEHICLE` selects the package and `vision_target/0` the `MIX_TARGET`. The build compiles the dashboard into the API's static files, cross-builds the Rust Ports and then runs `mix firmware`. Per-vehicle secrets, the Zenoh router address and Wi-Fi networks come from `vehicles/<vehicle>/.env.exs`, as for every other firmware; rebuild after changing `ZENOH_ENDPOINT_IP`. Details are in [`vision/firmware/README.md`](../vision/firmware/README.md) and [Running on hardware](./running_hardware.md).

The image's hostname is `<vehicle>-vision` and the node joins the Erlang mesh as role `vision`, so it reaches its peers and is reachable at `<vehicle>-vision.local`.

## Dashboard and API

The dashboard and the API are served from the board on port 4100:

```text
http://<vehicle>-vision.local:4100
```

The Row alignment card shows how many rows the right image's matches sit from the left image's, over the whole image and in four bands from left to right. A calibration that still fits the cameras reads within half a row; a larger offset means the cameras or their lenses have moved since the calibration, and depth degrades until you recalibrate. Offsets that change across the bands are a rotation.

The Sharpness card compares the two cameras' focus: the right image's sharpness over the left's, green between 0.8 and 1.25. Its absolute value depends on the scene, the ratio does not. On a unit whose cameras have lens actuators, such as the Camera Module 3, both lenses follow one `focus` camera setting; `VisionCore.Camera.FocusSweep.run/1`, from IEx on the unit facing a textured scene at the distance that matters, steps it through a range, sets the position best for both cameras and returns the sharpness curve. Recalibrate after changing the focus.

The vision parameters are the unit's own settings, grouped by component and pipeline stage: the cameras' controls, the dashboard video settings and the stereo settings, among them the matcher's `p1`, `p2` and `uniqueness`. Most apply live: the stereo settings are inputs of the compiled depth pipeline, so a change applies from the next pair without compiling. Others are fixed in the build, such as the image size, and some are set by an automatic mode while it is on, such as the exposure under auto exposure.

The dashboard draws the unit as its pipeline: the cameras, then each stereo stage your vehicle composes, in order, with the components that sit beside it, such as detection, apart. A box shows its status and how many of its parameters are unsaved; selecting it opens its panel, and the selected box stays in the URL (`?box=stereo.disparity`), so a link opens it again. The panel lists the box's parameters with their constraints and defaults: a live parameter changes while the unit runs, a parameter fixed in the build is shown but locked, and a parameter set by an automatic mode shows the mode that sets it. A relation between two parameters, such as `p2` above `p1`, bounds each control by the other's value.

A change is unsaved until you save it. Unsaved changes live on the unit, not in the page: reloading the dashboard or opening it elsewhere loses nothing, and a reboot drops them. The save bar below the panel counts the unsaved changes and offers:

- **Save**: stores the unsaved values on the unit, in `/data/vision_core.db`, where they are applied again at every boot.
- **Discard**: returns every unsaved parameter to its saved value, or to its default without one.
- **Reset**: a box's Reset, or a parameter's, returns it to the defaults; **Reset all** returns every parameter.
- **Export**: the saved values as a composer snippet, to make them the vehicle's defaults.

Discard and Reset all ask first. The same actions are `VisionCore.Parameters.save/1`, `discard/1`, `reset/2` and `export/1` from IEx. The parameters are also reachable with `ros2 param` and Foxglove's Parameters panel under their ids, `<stage>.<name>` (`stereo.disparity.p1`); a change made there is unsaved too.

The API follows [JSON:API](https://jsonapi.org/); its routes are listed in [`vision/api/README.md`](../vision/api/README.md).

`GET /api/ros2-node` describes what the unit exports over ROS 2: its node, named after the node name, with the Zenoh router endpoint and whether the session to it is open, the topics it has published, each with its message type and rate over the last second, and the services it answers, the parameter services and each camera's `set_camera_info`. Add `?include=topics,services`, or either alone, to get the topics and services themselves rather than their ids. The topic counts come from `VisionCore.Ros2.Topics`, which counts every `VisionCore.Ros2.ZenohClient.publish/4`, so a new publisher appears without changes.

On the host, `./ovcs run <vehicle>` starts a BEAM for the role and the dashboard's Vite dev server as an add-on, like the VMS dashboard, on `http://localhost:5174`.

## Running it on a workstation

On the host the composer's `:host` arm applies: it can read USB cameras through `VisionCore.Camera.GStreamer`, or a simulator's camera topics through `VisionCore.Ros2.Camera`. No CAN interface is needed. The stereo stages compile with EXLA, and `mix compile` builds `jpeg_codec` for the host, which decodes the cameras' JPEG frames, and `stereo_match`, for a pipeline computing with `compute: :native`.

## Rust Ports

`camera_capture` (libcamera to JPEG or grey frames), `hailo_detect` (HailoRT inference), `v4l2_capture` (the C100's paired grey frames), `jpeg_codec` (JPEG encoding and decoding) and `stereo_match` (semi-global matching on the CPU) are Rust programs that the core starts as Ports, never as NIFs, so a crash in a driver cannot take the BEAM down. They speak a length-prefixed binary protocol over stdin and stdout. Compiling `vision_core` for a vision target cross-builds that target's Ports through `vision/core/Makefile`: `camera_capture`, `hailo_detect`, `jpeg_codec` and `stereo_match` for `rpi5`, tuned for its Cortex-A76 cores, `v4l2_capture` and `jpeg_codec` for `okdo_c100`. The build host needs the `aarch64-unknown-linux-gnu` Rust target, which `mise install` provides, and libclang for bindgen. See [`vision/rust/README.md`](../vision/rust/README.md).

## See also

- [Perception: object detection](./ros2_perception.md): the detector, the Hailo backend and the topics.
- [ROS compute node](./ros2_compute_node.md): the router the unit peers with.
- [Hardware you need](./hardware_you_need.md#bridges-and-extras): the Pi 5, cameras and Hailo-8.
