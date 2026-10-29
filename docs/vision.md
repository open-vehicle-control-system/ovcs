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
| API | [`vision/api`](../vision/api/README.md) | `VisionApi`: a Phoenix endpoint with a `/api/settings` route and channels that stream status and camera previews. |
| Firmware | [`vision/firmware`](../vision/firmware/README.md) | The Nerves image for the `rpi5` and `okdo_c100` targets. At boot it reads `VEHICLE` and loads the vehicle's composer. |
| Dashboard | [`vision/dashboard`](../vision/dashboard/README.md) | A Vue app showing the left, right and depth previews, status cards, the runtime parameters and the active settings. |
| Ports | [`vision/rust`](../vision/rust/README.md) | `camera_capture` and `hailo_detect`, the Rust programs the core drives as Ports. |

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
| Capture | `VisionCore.Camera.LibCamera`, JPEG frames | `VisionCore.Camera.V4L2`, grey frames over raw V4L2 |
| Synchronisation | the Pi's camera sync | `v4l2_capture` locks the right sensor's frame starts to the left one's |
| Stereo stages | on the CPU | on the GPU through Vulkan |
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

On the Raspberry Pi 5 the stages run on its CPU. Aim for 13 to 15 depth frames a second there: what OpenCV's SGBM gives on that CPU.

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

The Parameters panel lists the unit's ROS 2 parameters and changes them while it runs: the cameras' controls, the preview settings and the stereo settings, among them the matcher's `p1`, `p2` and `uniqueness`. These are inputs of the compiled depth pipeline, so a change applies from the next pair without compiling. The same parameters are reachable with `ros2 param set` and Foxglove's Parameters panel; changes last until the unit restarts, and values worth keeping go back into the vehicle's composer.

On the host, `./ovcs run <vehicle>` starts a BEAM for the role and the dashboard's Vite dev server as an add-on, like the VMS dashboard, on `http://localhost:5174`.

## Running it on a workstation

On the host the composer's `:host` arm applies: it can read USB cameras through `VisionCore.Camera.GStreamer`, or a simulator's camera topics through `VisionCore.Ros2.Camera`. No CAN interface is needed. The stereo stages compile with EXLA, and `mix compile` builds `jpeg_codec` for the host, which decodes the cameras' JPEG frames.

## Rust Ports

`camera_capture` (libcamera to JPEG), `hailo_detect` (HailoRT inference), `v4l2_capture` (the C100's paired grey frames) and `jpeg_codec` (JPEG encoding and decoding) are Rust programs that the core starts as Ports, never as NIFs, so a crash in a driver cannot take the BEAM down. They speak a length-prefixed binary protocol over stdin and stdout. Compiling `vision_core` for a vision target cross-builds that target's Ports through `vision/core/Makefile`: `camera_capture`, `hailo_detect` and `jpeg_codec` for `rpi5`, `v4l2_capture` and `jpeg_codec` for `okdo_c100`. The build host needs the `aarch64-unknown-linux-gnu` Rust target, which `mise install` provides, and libclang for bindgen. See [`vision/rust/README.md`](../vision/rust/README.md).

## See also

- [Perception: object detection](./ros2_perception.md): the detector, the Hailo backend and the topics.
- [ROS compute node](./ros2_compute_node.md): the router the unit peers with.
- [Hardware you need](./hardware_you_need.md#bridges-and-extras): the Pi 5, cameras and Hailo-8.
