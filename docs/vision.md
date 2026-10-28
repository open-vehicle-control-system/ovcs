---
title: Vision unit
description: The vision role, a Raspberry Pi 5 that turns stereo cameras and a Hailo accelerator into ROS 2 depth and detection topics, and how a vehicle opts in.
---

The vision unit is an optional fourth role next to `vms`, `infotainment` and the bridges. It runs stereo depth and object detection on a Raspberry Pi 5, publishes the results as ROS 2 messages over Zenoh, and serves its own dashboard. It has no CAN controller and does not touch the `ovcs` bus: it reaches the vehicle through the Zenoh router of the [ROS compute node](./ros2_compute_node.md), and the rest of the vehicle through the [Erlang mesh](./architecture.md#one-erlang-mesh-no-broker).

A vehicle without cameras omits the role and nothing is built for it. None of the reference vehicles runs it yet: the OVCS Mini runs the same stack inside its `ros_vision` bridge firmware ([Perception](./ros2_perception.md)).

## Layers

The unit follows the same split as the VMS and the infotainment: a core, an API, a firmware shell and a dashboard, with the vehicle package supplying everything vehicle-specific.

| Layer | Path | What it is |
|---|---|---|
| Core | [`vision/core`](../vision/core/README.md) | `VisionCore`: the Zenoh client, camera drivers, SGBM stereo depth, rectification, publishers and detector backends. No vehicle knowledge, no web dependencies. |
| API | [`vision/api`](../vision/api/README.md) | `VisionApi`: a Phoenix endpoint with a `/api/settings` route and channels that stream status and camera previews. |
| Firmware | [`vision/firmware`](../vision/firmware/README.md) | The Nerves image for the `rpi5` target. At boot it reads `VEHICLE` and loads the vehicle's composer. |
| Dashboard | [`vision/dashboard`](../vision/dashboard/README.md) | A Vue app showing the left, right and depth previews, status cards and the active settings. |
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

`vision/0` returns a module implementing `VisionCore.Composer`: `config/1` returns a `VisionCore.Config` for the `:host` or `:target` arm (Zenoh endpoint, ROS node name, components and their drivers), and the optional `required_files/0` lists files, relative to your vehicle app, that the image needs and the repository does not carry, such as a detection model. The build fails when one is missing. The behaviour is documented in `VisionCore.Composer`, and the components you can list in `VisionCore.Components`; see also [Your vehicle package](./vehicle_package.md#the-five-behaviours).

Everything the unit needs from a vehicle lives in the package: resolution, SGBM tuning, calibration, topic prefix, frame ids, detection model and thresholds. Boot files for the Pi go in `vehicles/<vehicle>/priv/firmware/vision/`.

## Build, burn, upload

The role is addressed like the others:

```sh
./ovcs build  <vehicle> vision
./ovcs burn   <vehicle> vision
./ovcs upload <vehicle> vision
./ovcs clean  <vehicle> vision
```

`VEHICLE` selects the package and `MIX_TARGET` defaults to `rpi5`. The build compiles the dashboard into the API's static files, cross-builds the Rust Ports and then runs `mix firmware`. Per-vehicle secrets, the Zenoh router address and Wi-Fi networks come from `vehicles/<vehicle>/.env.exs`, as for every other firmware; rebuild after changing `ZENOH_ENDPOINT_IP`. Details are in [`vision/firmware/README.md`](../vision/firmware/README.md) and [Running on hardware](./running_hardware.md).

The image's hostname is `<vehicle>-vision` and the node joins the Erlang mesh as role `vision`, so it reaches its peers and is reachable at `<vehicle>-vision.local`.

## Dashboard and API

The dashboard and the API are served from the Pi on port 4100:

```text
http://<vehicle>-vision.local:4100
```

On the host, `./ovcs run <vehicle>` starts a BEAM for the role and the dashboard's Vite dev server as an add-on, like the VMS dashboard, on `http://localhost:5174`.

## Running it on a workstation

On the host the composer's `:host` arm applies: it can read USB cameras through `VisionCore.Camera.GStreamer`, or a simulator's camera topics through `VisionCore.Ros2.Camera`. No CAN interface is needed.

## Rust Ports

`camera_capture` (libcamera to JPEG) and `hailo_detect` (HailoRT inference) are Rust programs that the core starts as Ports, never as NIFs, so a crash in a driver cannot take the BEAM down. They speak a length-prefixed binary protocol over stdin and stdout. Compiling `vision_core` for `rpi5` cross-builds both through `vision/core/Makefile`. The build host needs the `aarch64-unknown-linux-gnu` Rust target, which `mise install` provides, and libclang for bindgen. See [`vision/rust/README.md`](../vision/rust/README.md).

## See also

- [Perception: object detection](./ros2_perception.md): the detector, the Hailo backend and the topics.
- [ROS compute node](./ros2_compute_node.md): the router the unit peers with.
- [Hardware you need](./hardware_you_need.md#bridges-and-extras): the Pi 5, cameras and Hailo-8.
