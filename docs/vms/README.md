---
title: VMS
description: The Vehicle Management System, the one firmware on every CAN bus of your vehicle, what it does, where it runs, its four layers and what talks to it.
---

The Vehicle Management System (VMS) is the firmware that makes your vehicle's components work together. It is the only node on every CAN bus of the vehicle: it reads each manufacturer's frames, runs a driver per component, decides who commands the vehicle, and emits the frames each component expects. Every other role (infotainment, vision, bridges) is optional; the VMS is not.

> [!NOTE]
> Everything on this page holds for any vehicle. The OVCS1 and OVCS Mini reference vehicles appear as worked examples. See [Framework and vehicles](../framework.md).

## What it does

- **Keeps the buses apart.** Components from different manufacturers reuse CAN identifiers, so each manufacturer's bus stays physically separate and the VMS is the only node on all of them ([bus isolation](../architecture.md#bus-isolation)). When one component needs another's data, the VMS reads it on one bus and emits it on the other. In the OVCS1 reference vehicle, that is how the Volkswagen Polo's instrument cluster shows the Nissan Leaf motor's RPM.
- **Runs one driver per component.** A driver is a GenServer that decodes the component's frames, publishes what it learns on the [OVCS bus](../bus/README.md), and emits the frames that command it. The framework ships the [drivers](./drivers.md) its reference vehicles use; your vehicle picks the ones it needs and [adds its own](./add_a_component.md).
- **Decides who commands.** `VmsCore.Managers.ControlLevel` arbitrates between the pedals, the radio transmitter and the ROS bridge, and refuses unsafe changes. `VmsCore.Managers.Gear` turns the requested direction into a gear. See [How the VMS works](./how_it_works.md#managers).
- **Supervises the generic controllers.** It adopts each Arduino board with its pinout, drives its outputs and emits the heartbeat that keeps them alive. See [Generic controllers](../generic_controllers/README.md).
- **Feeds the debug dashboard.** It keeps the last value of every bus message and serves them, with the pages your vehicle declares, to the dashboard. See [Dashboard pages](./dashboard_pages.md).

## Where it runs

On the vehicle, the VMS is a Nerves image on a Raspberry Pi 4 with a multi-CAN SPI hub, built on the [`ovcs_base_can_system_rpi4`](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi4) system. [Hardware](../hardware.md) lists the boards and CAN interfaces, and [Running on hardware](../running_hardware.md) builds, burns and updates the image:

```sh
./ovcs build <vehicle> vms
./ovcs burn <vehicle> vms
```

On your workstation, `./ovcs run <vehicle>` starts it as the `<vehicle>-vms` BEAM against virtual CAN, next to the vehicle's other roles. The API answers on `http://localhost:4000` and the dashboard on `http://localhost:5173`. The [Quickstart](../quickstart.md) runs it end to end.

## Four layers

The VMS is four projects, each depending on the one below through a relative `path:` dependency. None contains vehicle code.

| Layer | Path | What it is |
|---|---|---|
| Core | [`vms/core/`](../../vms/core/README.md) | `VmsCore`: the component drivers, the managers, `VmsCore.Metrics`, `VmsCore.Status` and the `VmsCore.Vehicle` behaviour. No web dependencies. Depends on `cantastic`, `ovcs_can`, `ovcs_bus`, `ovcs_control`, `ovcs_vehicle`, `ecto_sqlite3` |
| API | [`vms/api/`](../../vms/api/README.md) | `VmsApi`: a Phoenix JSON API and WebSocket server in front of the core. Controllers and channels only route traffic to it |
| Dashboard | [`vms/dashboard/`](../../vms/dashboard/README.md) | A Vue 3 single-page app (Vite, Pinia, ECharts, TailwindCSS) that renders the pages your composer declares |
| Firmware | [`vms/firmware/`](../../vms/firmware/README.md) | `VmsFirmware`: the Nerves shell that packages the API, the core and the prebuilt dashboard for the Pi 4 |

At boot the firmware reads `VEHICLE`, prepends your vehicle package's compiled code to its path, and hands its VMS composer to the core. [Your vehicle package](../vehicle_package.md#boot-flow) follows that sequence.

### The API

```text
GET  /api/vehicle                         vehicle name, main colour, refresh interval
GET  /api/vehicle/pages                   the dashboard's pages
GET  /api/vehicle/pages/:page_id/blocks   the blocks of one page
POST /api/actions                         call an action on a component
```

A Phoenix socket at `/sockets/dashboard` carries two channels: `metrics` streams the values of the module and key pairs a client subscribes to, and `network-interfaces` streams each CAN interface's counters and bus state. In development, Phoenix LiveDashboard is at `/dev/dashboard`.

### The dashboard

The dashboard is a debugging tool for development and the bench, not an in-car display: that is the [infotainment](../infotainment/README.md). It fetches the layout from the API, subscribes to the metrics its blocks reference, and posts actions when you press a button. `./ovcs run` starts it with hot reload on port `5173`; the API on port `4000` serves the bundle the firmware build last produced.

## What your vehicle provides

Your vehicle's `<Vehicle>.Vms.Composer` implements [`VmsCore.Vehicle`](../../vms/core/lib/vms_core/vehicle.ex): the children to supervise (drivers, managers, `VmsCore.Status`, generic controllers), where its CAN topology YAML lives and which interface each network maps to on the host and on the target, and optionally the dashboard pages and the generic controller pinouts. The behaviour's moduledoc documents each callback. Your vehicle's top-level module points to the composer through `vms/0` and names the Nerves target through `vms_target/0`.

## What talks to it

| Peer | How | Carries |
|---|---|---|
| Generic controllers | CAN, `ovcs` bus | adoption, digital and analog I/O, the `0x1A0` heartbeat |
| Infotainment | CAN, `ovcs` bus | the requested gear on `0x201`; the status frames back: VMS, gear, drivetrain, passenger compartment, battery (`0x1A0`, `0x600`, `0x60A`, `0x60D`, `0x650`, `0x651`) |
| Radio control bridge | CAN, `ovcs` bus | the transmitter's channels on `0x2A0` and `0x2A1` |
| ROS bridge | CAN, `ovcs` bus | actuator and velocity commands on `0x2B0` and `0x2B1`; status, gear and control level back (`0x1A0`, `0x600`, `0x60C`) |
| Other roles | the Erlang mesh | metrics, status, the [bus gateway](../bus/gateway.md) |
| Debug dashboard | HTTP and WebSocket | pages, metrics, actions |

Commands always travel as CAN frames, where the VMS watches their freshness; the mesh carries only metrics, status and coordination. See [One Erlang mesh, no broker](../architecture.md#one-erlang-mesh-no-broker).

## Where next

- [How the VMS works](./how_it_works.md): the supervision tree, the component pattern, the managers and control levels.
- [Add a component](./add_a_component.md): write a driver for your own hardware.
- [Dashboard pages](./dashboard_pages.md): declare what the dashboard shows.
- [Drivers](./drivers.md): every driver the framework ships.
