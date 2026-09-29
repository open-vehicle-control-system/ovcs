---
title: Framework and vehicles
description: What OVCS provides, what a vehicle built on it is, and why OVCS1, OVCS Mini and OBD2 are examples rather than requirements.
---

OVCS is not a car, and not three cars. It is a **framework** for building a vehicle's embedded control system. OVCS1, OVCS Mini and OBD2, the things people usually see first, are **vehicles** built on it. This page fixes the vocabulary the rest of the documentation uses.

## The vocabulary

| Word | Meaning | Lives in |
|---|---|---|
| **Framework** | Everything vehicle-agnostic: the VMS and infotainment cores, their Phoenix APIs and dashboards, the Nerves firmware shells, the bridge libraries (radio control, ROS 2), the generic Arduino controller firmware, the shared libraries, and the `ovcs` CLI. It contains **no vehicle-specific code**. | The monorepo, everywhere except `vehicles/` |
| **Vehicle** | One package: a Mix project implementing the `OvcsVehicle` behaviour that tells the framework what to run for this vehicle: supervision tree, CAN topology, controller pinouts, dashboard pages, Nerves targets, bridge firmwares. | `vehicles/<name>/` |
| **Reference vehicle** | One of the three vehicles in the repository: **OVCS1**, **OVCS Mini**, **OBD2**. They prove the framework on real hardware and serve as worked examples. | `vehicles/ovcs1/`, `vehicles/ovcs_mini/`, `vehicles/obd2/` |
| **Composer** | A module of a vehicle package that tells one side of the framework what to run: `<Vehicle>.Vms.Composer` implements `VmsCore.Vehicle` (component drivers, CAN topology and host/target mapping, dashboard pages, controller pinouts), and the optional `<Vehicle>.Infotainment.Composer` implements `InfotainmentCore.Vehicle`. The vehicle's top-level module points to them. | `vehicles/<name>/lib/<name>/vms/composer.ex`, `…/infotainment/composer.ex` |
| **Role** | One firmware of a vehicle, and so one BEAM: `vms`, `infotainment` if the vehicle has that side, and `bridge-<id>` for each entry of its `bridge_firmwares/0`. The CLI takes a role after the vehicle (`./ovcs build ovcs1 vms`), `./ovcs run` spawns one BEAM per role, and each role becomes one Raspberry Pi image. Generic controllers are Arduino boards, not roles. | Declared by the vehicle's top-level module |

The framework never imports a vehicle. At boot each firmware reads one environment variable, `VEHICLE`, prepends that vehicle's compiled code to its path, and asks it what to supervise. Change the variable and the same firmware runs a different vehicle.

> [!TIP]
> To build your own vehicle you need the framework and one vehicle package: yours. You need none of OVCS1, OVCS Mini or OBD2. They stay in the repository to be read, run on a laptop, and to check that a framework change did not break a real vehicle.

## What the framework gives you

- **A Vehicle Management System** that speaks CAN to any number of isolated buses, translates between manufacturers, and exposes metrics and actions over HTTP and WebSocket.
- **An infotainment side** with the same shape, driving a Flutter touchscreen.
- **Bridges** to non-CAN worlds: an ExpressLRS radio link, a ROS 2 graph over Zenoh.
- **Generic controllers**: one Arduino firmware for every board, configured over CAN by the VMS.
- **One Erlang mesh** joining every firmware BEAM, with no broker.
- **A CLI** that boots everything on a laptop with virtual CAN, builds and burns Nerves images, pushes firmware to a running board over SSH, and attaches a debugging TUI.
- **Libraries** for CAN (Cantastic), PID control, ExpressLRS, MSP OSD, and shared CAN frame definitions for common automotive components.

None of it knows which car it is in. [Architecture](./architecture.md) shows how the pieces fit; [Framework components](./components.md) is the inventory.

## What a vehicle provides

A vehicle answers the framework's questions about itself:

- **Which components exist**, as supervised processes: an inverter driver, a brake booster, a steering servo, a BMS.
- **Which CAN buses exist**, their frames, and how logical bus names map to interfaces on the laptop and on the car.
- **Which Arduino controllers exist** and what each pin does.
- **What the dashboards show**: pages, metrics, charts, action buttons.
- **Which Raspberry Pi images to build**, and which bridges to bundle.
- **Who may command the vehicle**: the throttle, steering, gear and direction sources per control level.

That is the whole contract. [Your vehicle package](./vehicle_package.md) walks through it and shows how `./ovcs new` scaffolds one.

## The reference vehicles, and what each one teaches

- **OVCS1** ([hardware](./hardware.md)): a 2007 VW Polo converted to electric. Every side of the framework in use: VMS, infotainment, radio-control and ROS bridges, three controllers, five isolated buses. Multi-manufacturer integration done for real.
- **OVCS Mini** ([simulation](../compose/local/simulation/README.md)): a Traxxas RC car with a VESC-driven motor. Two buses (`ovcs` and the VESC's `misc`), no infotainment, radio-control, ROS and perception bridges. The smallest drivable vehicle, and the one the Gazebo simulator models.
- **OBD2** ([guide](./obd2.md)): no drivetrain. The VMS as an OBD2 / UDS scan tool for any car. How little a vehicle package needs.

All three are ordinary vehicles. Nothing in the framework treats them specially, and `./ovcs vehicles` lists them next to whatever you add under `vehicles/`.

## How the documentation uses them

Commands are shown on the reference vehicles because anyone can run them: `./ovcs run ovcs_mini`, `./ovcs build ovcs1 vms`. Every one works the same on your vehicle, with your package's name in their place. Vehicle-specific detail, such as OVCS1's five buses or the Mini's radio channel layout, is labelled as a worked example. [Architecture](./architecture.md), [Framework components](./components.md), [Hardware](./hardware.md) and [Toolchain and OTP](./toolchain_and_otp.md) describe what every vehicle inherits.

## Before you start

OVCS draws on three fields at once, and most readers know one or two of them. Pick the line that matches you.

- **A maker new to Elixir.** Learn enough Elixir to read a GenServer and a supervision tree: the [Elixir getting-started guide](https://hexdocs.pm/elixir/introduction.html) covers it, through processes and OTP. Then read [Architecture](./architecture.md) for how components talk over the bus, and [Hardware](./hardware.md) for the boards the framework targets.
- **An Elixir developer new to CAN and Nerves.** CAN is a broadcast bus of small frames identified by id; the [Linux SocketCAN documentation](https://docs.kernel.org/networking/can.html) explains the model and the virtual `vcan` interfaces OVCS develops on. [Testing with CAN](./testing_with_can.md) shows how OVCS describes frames in YAML and how you inject them. For firmware, the [Nerves documentation](https://hexdocs.pm/nerves/getting-started.html) explains targets, systems and burning images, and [Toolchain and OTP](./toolchain_and_otp.md) explains why OVCS pins the host's OTP to each target's.
- **An automotive engineer new to Elixir.** You know the buses; what changes is the runtime. Read [Architecture](./architecture.md) for the process model, where each component driver is a supervised process that its supervisor restarts when it crashes, then the [Elixir getting-started guide](https://hexdocs.pm/elixir/introduction.html) as far as processes and supervisors. [Framework components](./components.md) lists the drivers for familiar parts: a Nissan Leaf inverter, an Orion BMS, a Bosch iBooster.

## Build yours

```sh
./ovcs new my_car --vms-target ovcs_base_can_system_rpi4 --infotainment-target ovcs_base_can_system_rpi5
./ovcs run my_car
```

The scaffold is a working vehicle with an example controller and a vehicle GenServer. Replace the example components with the drivers your hardware needs and fill in the CAN YAMLs. [Your vehicle package](./vehicle_package.md) covers the contract, the scaffold, the boot flow and control levels.

## Where next

- [Getting started](./getting_started.md): set up your workstation and check it with `./ovcs doctor`.
- [Quickstart](./quickstart.md): boot the OVCS Mini reference vehicle to see what "working" looks like.
