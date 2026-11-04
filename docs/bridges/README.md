---
title: Bridges
description: What a bridge is, the radio control and ROS bridges the framework ships, the bridge firmware image that hosts them, and how your vehicle declares, configures and boots its bridge firmwares.
---

A bridge carries data between the `ovcs` CAN bus and a world that has no CAN: a radio transmitter's link, a ROS 2 graph. Each bridge is an Elixir library under `bridges/<name>/` that implements the [`OvcsBridge`](../../libraries/ovcs_bridge/lib/ovcs_bridge.ex) behaviour. None of them is a firmware: the shared bridge firmware image, `bridges/firmware/`, hosts whichever bridges an entry of your vehicle's `bridge_firmwares/0` lists, and each entry becomes one board's image.

> [!NOTE]
> Everything on this page holds for any vehicle. The OVCS1 and OVCS Mini reference vehicles appear as worked examples. See [Framework and vehicles](../framework.md).

## The bridges the framework ships

| Bridge | Module | Carries |
|---|---|---|
| [Radio control bridge](./radio_control.md) | `RadioControlBridge` | a MAVLink-capable transmitter's eight channels, from an ExpressLRS receiver on a UART, onto `0x2A0` and `0x2A1` |
| [ROS bridge](./ros.md) | `RosBridge` | ROS 2 over native Zenoh: joystick and planner commands onto `0x2B0` and `0x2B1`; the vehicle's status, IMU, odometry, lidar, rangefinders and stereo depth onto ROS topics; [object detection](./perception.md) |

Commands from a bridge always reach the VMS as CAN frames on the `ovcs` bus, where the VMS checks their freshness and its [control levels](../vms/how_it_works.md#control-levels) decide whether they are in force. A bridge never commands an actuator directly.

A bridge firmware entry can also run children that are not bridges: the OVCS Mini reference vehicle runs the [bus gateway](../bus/gateway.md) in its `ros` bridge firmware that way.

## Why libraries, not one firmware per bridge

A vehicle often runs several bridge firmwares on different boards: the OVCS1 reference vehicle puts radio control on a Raspberry Pi 3A and ROS on a Pi 4. Keeping bridges as plain libraries means:

- one Nerves image, `bridges/firmware/`, handles fwup, the root filesystem and networking for every bridge, instead of one copy per bridge;
- your vehicle composes its own subset of bridges per image in `bridge_firmwares/0`;
- a bridge library can be bundled into several images without duplication.

Bridge libraries get [`OvcsBus`](../bus/README.md) for free: `ovcs_bridge` depends on `ovcs_bus`, so a bridge's processes subscribe and broadcast like any VMS component. A broadcast stays on the bridge's own BEAM.

## Bridge firmwares

Your vehicle declares its bridge firmwares in the optional `bridge_firmwares/0` callback of its top-level module. From the OVCS1 reference vehicle:

```elixir
@impl OvcsVehicle
def bridge_firmwares do
  %{
    "radio_control" => %{
      target: :ovcs_base_can_system_rpi3a,
      bridges: [RadioControlBridge],
      default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"}
    },
    "ros" => %{
      target: :ovcs_base_can_system_rpi4,
      bridges: [RosBridge],
      default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"}
    }
  }
end
```

Each key becomes a CLI role with the `bridge-` prefix, built, burned and uploaded like any other role:

```sh
./ovcs build ovcs1 bridge-radio_control
./ovcs build <vehicle> bridge-<id>
```

> [!NOTE]
> A bare id such as `radio_control` is rejected, and the error lists the valid roles for that vehicle. The prefix is what tells `build`, `burn` and `upload` to target the bridge image.

An entry takes `target` and `bridges` (required), and optionally:

| Key | Meaning |
|---|---|
| `default_can_mapping` | the `CAN_NETWORK_MAPPINGS` for the host and for the target |
| `can_config_path` | the CAN topology under your vehicle's `priv/`, `can/bridges/<id>.yml` by default. A list of paths is merged; a `%{host: _, target: _}` map picks one per build target, so a host run can declare frames the burned firmware never needs |
| `children` | child specs started after the bridges' children, as a list or a `%{host: [...], target: [...]}` map |
| `required_files` | paths relative to your vehicle app, for files a bridge needs but the repository doesn't carry. The build fails when one is missing rather than producing an image that boots without it. The OVCS Mini's `ros_vision` entry names its detection model this way (`priv/models/nanodet_repvgg.hef`, fetched by `mise run fetch-models`) |

The [`OvcsVehicle`](../../libraries/ovcs_vehicle/lib/ovcs_vehicle.ex) moduledoc is the reference for the entry's type.

### Targets

The bridge firmware's `mix.exs` target-gates the bridge libraries it compiles, so an image only carries what its board's bridges need. An entry's `target` picks one of:

| Target | Board |
|---|---|
| `:ovcs_base_can_system_rpi3a` | Raspberry Pi 3A |
| `:ovcs_base_can_system_rpi4` | Raspberry Pi 4 |
| `:rpi5` | Raspberry Pi 5, with libcamera and the Hailo-8 driver (system `ovcs_bridges_system_rpi5`) |

## How a bridge firmware boots

The CLI sets `VEHICLE`, `BRIDGE_FIRMWARE_ID` and `MIX_TARGET` from the entry, and the image is built once per entry. At boot:

1. `bridges/firmware`'s `config/runtime.exs` calls `apply_runtime_config/2` on every bundled bridge that exports it, before any application starts. A bridge uses it to write the application environment a dependency reads once at boot: the radio control bridge stamps the ExpressLRS receiver's UART there.
2. `BridgeFirmware.Application` starts `OvcsBridge.Supervisor`, which reads `VEHICLE` and `BRIDGE_FIRMWARE_ID`, looks the entry up in `bridge_firmwares/0`, and starts `OvcsBus.Cluster` so this BEAM joins the vehicle's [mesh](../bus/README.md#the-mesh).
3. It supervises each listed bridge's `children/0`, then the entry's `children`, under `one_for_one`. On the host, where bridges are `runtime: false` dependencies, it starts each bridge's OTP application first.

Each bridge reads its own configuration from a callback on your vehicle module, with a `:host` and a `:target` arm: `radio_control_bridge_config/1` for the radio control bridge, `ros_bridge_config/1` for the ROS bridge. The `:host` arm usually drops what needs hardware, so `./ovcs run <vehicle>` starts every bridge firmware on your workstation, as the `<vehicle>-bridge-<id>` BEAM, against virtual CAN.

## Where next

- [Write a bridge](./write_a_bridge.md): a bridge library of your own.
- [Radio control bridge](./radio_control.md) and [ROS bridge](./ros.md): the two the framework ships.
- [Running on hardware](../running_hardware.md): build, burn and upload a `bridge-<id>` role.
