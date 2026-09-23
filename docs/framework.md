---
title: Framework and applications
description: What OVCS provides, what an application built on it is, and why OVCS1, OVCS Mini and OBD2 are examples rather than requirements.
---

OVCS is not a car, and not three cars. It is a **framework** for building a vehicle's embedded control system. OVCS1, OVCS Mini and OBD2, the things people usually see first, are **applications** built on it. This page fixes the vocabulary the rest of the documentation uses.

## Two words, used precisely

| Word | Meaning | Lives in |
|---|---|---|
| **Framework** | Everything vehicle-agnostic: the VMS and infotainment cores, their Phoenix APIs and dashboards, the Nerves firmware shells, the bridge libraries (radio control, ROS 2), the generic Arduino controller firmware, the shared libraries, and the `ovcs` CLI. It contains **no vehicle-specific code**. | The monorepo, everywhere except `vehicles/` |
| **Application** | One vehicle package: a Mix project implementing the `OvcsVehicle` behaviour that tells the framework what to run for this vehicle: supervision tree, CAN topology, controller pinouts, dashboard pages, Nerves targets, bridge firmwares. | `vehicles/<name>/` |
| **Reference application** | One of the three applications in the repository: **OVCS1**, **OVCS Mini**, **OBD2**. They prove the framework on real hardware and serve as worked examples. | `vehicles/ovcs1/`, `vehicles/ovcs_mini/`, `vehicles/obd2/` |

The framework never imports an application. At boot each firmware reads one environment variable, `VEHICLE`, prepends that application's compiled code to its path, and asks it what to supervise. Change the variable and the same firmware runs a different vehicle.

> [!TIP]
> To build your own vehicle you need the framework and one application: yours. You need none of OVCS1, OVCS Mini or OBD2. They stay in the repository to be read, run on a laptop, and to check that a framework change did not break a real vehicle.

## What the framework gives you

- **A Vehicle Management System** that speaks CAN to any number of isolated buses, translates between manufacturers, and exposes metrics and actions over HTTP and WebSocket.
- **An infotainment side** with the same shape, driving a Flutter touchscreen.
- **Bridges** to non-CAN worlds: an ExpressLRS radio link, a ROS 2 graph over Zenoh.
- **Generic controllers**: one Arduino firmware for every board, configured over CAN by the VMS.
- **One Erlang mesh** joining every firmware BEAM, with no broker.
- **A CLI** that boots everything on a laptop with virtual CAN, builds and burns Nerves images, uploads over the air, and attaches a debugging TUI.
- **Libraries** for CAN (Cantastic), PID control, ExpressLRS, MSP OSD, and shared CAN frame definitions for common automotive components.

None of it knows which car it is in. [Architecture](./architecture.md) shows how the pieces fit; [Framework components](./applications.md) is the inventory.

## What an application provides

An application answers the framework's questions about one vehicle:

- **Which components exist**, as supervised processes: an inverter driver, a brake booster, a steering servo, a BMS.
- **Which CAN buses exist**, their frames, and how logical bus names map to interfaces on the laptop and on the car.
- **Which Arduino controllers exist** and what each pin does.
- **What the dashboards show**: pages, metrics, charts, action buttons.
- **Which Raspberry Pi images to build**, and which bridges to bundle.
- **Who may command the vehicle**: the throttle, steering, gear and direction sources per control level.

That is the whole contract. [Your application package](./vehicle_parameterisation.md) walks through it and shows how `./ovcs new` scaffolds one.

## The reference applications, and what each one teaches

- **OVCS1** ([hardware](./hardware_architecture.md)): a 2007 VW Polo converted to electric. Every side of the framework in use: VMS, infotainment, radio-control and ROS bridges, three controllers, five isolated buses. Multi-manufacturer integration done for real.
- **OVCS Mini** ([simulation](../compose/local/simulation/README.md)): a Traxxas RC car with a VESC-driven motor. One bus, no infotainment, radio-control, ROS and perception bridges. The smallest drivable application, and the one the Gazebo simulator models.
- **OBD2** ([guide](./obd2_diagnostics.md)): no drivetrain. The VMS as an OBD2 / UDS scan tool for any car. How little a vehicle package needs.

All three are ordinary applications. Nothing in the framework treats them specially, and `./ovcs vehicles` lists them next to whatever you add under `vehicles/`.

## How the documentation uses them

Commands are shown on the reference applications because anyone can run them: `./ovcs run ovcs_mini`, `./ovcs build ovcs1 vms`. Every one works the same on your application, with your package's name in their place. Vehicle-specific detail, such as OVCS1's five buses or the Mini's radio channel layout, is labelled as a worked example. [Architecture](./architecture.md), [Framework components](./applications.md), [Hardware](./hardware_architecture.md) and [Toolchain and OTP](./toolchain_and_otp.md) describe what every application inherits.

## Build yours

```sh
./ovcs new my_car --vms-target ovcs_base_can_system_rpi4 --infotainment-target ovcs_base_can_system_rpi5
./ovcs run my_car
```

The scaffold is a working application with an example controller and a vehicle GenServer. Replace the example components with the drivers your hardware needs and fill in the CAN YAMLs.

- [Your application package](./vehicle_parameterisation.md): the contract, the scaffold, the boot flow, control levels.
- [Quickstart](./quickstart.md): boot a reference application first to see what "working" looks like.
