---
title: Hardware
description: The boards the framework targets and the generic Arduino controllers, with the OVCS1 and OVCS Mini builds as worked examples.
---

The framework targets off-the-shelf boards: Raspberry Pis for the Elixir firmwares and Arduino R4 Minimas for I/O, joined by custom CAN interface boards. Every application shares that. Which CAN buses exist, at what bitrate, and which manufacturer components hang off them is the application's decision. This page describes what the framework targets, then walks through two reference applications: OVCS1 with five isolated buses on a full-size car, and the OVCS Mini with two buses on an RC car.

> [!NOTE]
> The boards, the CAN interface hardware and the generic controllers are framework-level: your application uses them as they are. Bus layouts, manufacturer components and controller roles belong to the OVCS1 and OVCS Mini reference applications; yours declares its own in its CAN topology YAMLs and composers. See [Framework and applications](./framework.md).

## Design principles

1. **CAN bus isolation.** Components from different manufacturers may use conflicting CAN identifiers, so the framework keeps each manufacturer's bus separate and bridges them through the VMS. See [Architecture](./architecture.md).
2. **Off-the-shelf components.** Raspberry Pi and Arduino boards keep the kit affordable and accessible.

## What the framework targets

### Computing devices

| Device | Framework role | CAN connectivity |
|---|---|---|
| Raspberry Pi 4 | Vehicle Management System (VMS) | All of the application's CAN buses, through the multi-CAN SPI hub |
| Raspberry Pi 5 | Infotainment (optional) | The `ovcs` bus |
| Raspberry Pi 3A | Radio control bridge (optional) | The `ovcs` bus |
| Raspberry Pi 4 or 5 | ROS 2 bridge (optional) | The `ovcs` bus |
| Raspberry Pi 5 (8 GB) | ROS compute node: balenaOS, not Nerves (optional) | None; it runs the Zenoh router the bridges peer with |
| Arduino R4 Minima | Generic controllers, as many as the application declares | The `ovcs` bus |

An application declares which roles it uses in its `OvcsVehicle` module (`vms_target/0`, `infotainment_target/0`, the `bridge_firmwares/0` map) and in its VMS composer's `generic_controllers/0`.

### CAN interface hardware

- **Custom Raspberry Pi CAN HATs**: SPI-to-CAN boards connecting a Pi to one CAN network. Used on the infotainment and bridge Pis.
- **Custom multi-CAN SPI hub**: fans the VMS Pi 4's SPI out to MCP2517FD CAN controllers, one per bus, each with its own transceiver. Cantastic addresses them as `spiN.M` interfaces (`spi0.0`, `spi1.0`, …); an application maps its network names onto them in `default_can_mapping(:target)`.

The framework's `ovcs` bus carries controller adoption, heartbeats, infotainment and bridge commands. Applications with many nodes on it run it at 1 Mbps; manufacturer buses run at the stock bitrate their components require.

## Generic Controllers

Arduino R4 Minima boards serve as configurable I/O controllers. They are generic because one framework firmware runs on every board in every application; pin assignments and behaviour are configured over CAN through an **adoption** process, driven by the pinout map the application's VMS composer declares. The boards don't use the R4 Minima's built-in CAN peripheral: any Arduino-compatible board with EEPROM and an external CAN transceiver should work.

### Adoption

1. A new, unconfigured controller joins the `ovcs` bus and broadcasts its status as `ADOPTION_REQUIRED`.
2. The VMS sends a configuration frame (`0x700`) with the pin assignments from the application's `generic_controllers/0`.
3. You press the physical adoption button on the Arduino to confirm.
4. The controller stores the configuration in EEPROM and starts normal operation.
5. On later boots it loads the configuration from EEPROM and starts immediately.

### Supported pin types

| Pin type | Description | CAN frame |
|---|---|---|
| Digital output | On/off control for relays and contactors | `0x7X2` request / `0x7X4` status |
| Analog input | Sensor readings, 14-bit (0–16383) | `0x7X4` status |
| PWM output | Variable duty cycle, 12-bit (0–4095) | `0x7X3` request |
| DAC output | Analog voltage, 12-bit (0–4095) | `0x7X3` request |
| External PWM | PWM through a PWM hat on the Arduino's UART, 16-bit duty and 24-bit frequency | `0x7X5`–`0x7X8` request |
| Pulse counter | Rising edges on A1: count and frequency | `0x7X9` status |

Controller frame ids follow `0b111AAAABBBB`: `AAAA` is the controller id (up to 16 per bus), `BBBB` the frame. Flashing, adoption and verification with `candump` are in [Generic controllers](./testing_generic_controllers.md).

## CAN Bus Configuration

Shared component-level frame and signal specifications live in the framework's [`ovcs_can`](../libraries/ovcs_can/README.md) library. Each application bundles its own topology YAMLs, saying which frames run on which network, inside its package.

```text
libraries/ovcs_can/priv/can/components/        FRAMEWORK: shared frame specs
+-- bosch/i_booster_gen2/        iBooster frames
+-- bosch/lws/                   Steering angle sensor frames
+-- evpt/evpt23/                 Charger frames
+-- nissan/leaf_aze0/            Leaf inverter and charger frames
+-- orion/bms2/                  Battery management frames
+-- ovcs/                        OVCS internal frames and generic controller templates
+-- vesc/                        VESC motor controller frames (29-bit extended ids)
+-- volkswagen/polo_9n/          Polo ABS, dashboard, key, lock, wheel frames
+-- obd2/                        OBD2 diagnostic requests

vehicles/<name>/priv/can/                      APPLICATION: which frames on which network
+-- vms.yml                      full CAN topology read by vms_core
+-- infotainment.yml             narrow topology read by infotainment_core (optional)
+-- generic_controller/          per-application controller frame wirings
```

The VMS topology holds every frame; the infotainment one subscribes only to what the head unit renders. Both import shared specs with Cantastic's cross-app syntax:

```yaml
- import!:@ovcs_can:can/components/ovcs/0x1A0_vms_status.yml
```

The specs under `ovcs_can` exist because the reference applications needed them. If your application uses a component the library doesn't describe yet, add its YAML, ideally to the library so the next application can import it.

## Worked example: the OVCS1 reference application

OVCS1 is a 2007 Volkswagen Polo 9N converted to an electric vehicle. It uses every role the framework offers: VMS, infotainment, two bridges and generic controllers, on five isolated buses. Pin-level notes are in the [OVCS1 wiring reference](../vehicles/ovcs1/WIRING.md).

### Components

| Component | Manufacturer | Purpose |
|---|---|---|
| Leaf AZE0 inverter and motor | Nissan | Electric drivetrain: motor control, regenerative braking |
| NV200 battery cells | Nissan | High-voltage pack in custom aluminium enclosures |
| iBooster Gen2 | Bosch | Electronic brake booster replacing the vacuum-assisted brakes |
| LWS steering angle sensor | Bosch | Steering position feedback |
| BMS2 | Orion | Battery management: cell monitoring, balancing, protection |
| EVPT23 | EVPT | On-board charger |
| Polo 9N systems | Volkswagen | ABS, instrument cluster, ignition lock, power steering pump |

### Topology

Every vehicle CAN bus terminates on the VMS Pi 4, so components on different buses never see each other's traffic and identifier collisions can't happen. The `ovcs` bus connects the VMS to the infotainment Pi, the two bridges and the Arduino controllers. The VMS, infotainment and bridge BEAMs also form one Erlang-distribution mesh.

```text
                 ExpressLRS handset       ROS 2 / Foxglove        Vue dashboard (laptop)
                        | MAVLink UART         | Zenoh                 | HTTP + WebSocket
                        v                      v                       |
               Radio control bridge       ROS bridge                   |
               (Pi 3A)                    (Pi 4, BNO085 IMU)           |
                        |                      |                       |
  ovcs (1 Mbps) ========+======================+==========+============+=========
       |                |                  |              |            |
  Infotainment     Front controller   Rear controller  Controls      VMS (Pi 4)
  (Pi 5)           0x70x              0x71x            controller    |
                                                       0x72x         +-- leaf_drive (500 kbps): Leaf inverter, charger
                                                                     +-- polo_drive (500 kbps): ABS, cluster, ignition, airbag
                                                                     +-- orion_bms  (500 kbps): Orion BMS2, EVPT23 charger
                                                                     +-- misc       (500 kbps): Bosch iBooster, LWS sensor
```

| Network | Bitrate | Purpose | Connected components |
|---|---|---|---|
| `ovcs` | 1 Mbps | Framework-internal communication | VMS, infotainment, controllers, radio control bridge, ROS bridge |
| `leaf_drive` | 500 kbps | Nissan Leaf drivetrain | Leaf inverter, Leaf charger |
| `polo_drive` | 500 kbps | Original VW Polo systems | ABS, dashboard, ignition lock, airbag |
| `orion_bms` | 500 kbps | Battery management | Orion BMS2, EVPT23 charger |
| `misc` | 500 kbps | Additional components | Bosch iBooster, Bosch LWS steering sensor |

The hub gives OVCS1's VMS five MCP2517FD controllers, `spi0.0` to `spi0.4`. These network names are OVCS1's; your application declares its own names and bitrates in its `vms.yml` and maps them to interfaces in `default_can_mapping/1`.

### Controllers

| Controller | CAN ID range | Purpose |
|---|---|---|
| Front controller (`0x70x`) | `0x701`–`0x704` | High-voltage contactors, front sensors and relays |
| Rear controller (`0x71x`) | `0x711`–`0x714` | Water pump, rear sensors and relays |
| Controls controller (`0x72x`) | `0x721`–`0x725` | Steering column PWM, throttle pedal DAC, control inputs |
| Test controller (`0x73x`) | `0x731`–`0x738` | Development and testing, all pin types |

### Why every bridge is its own Pi

- **Failure isolation.** A misbehaving radio link or ROS publisher can hang its own BEAM without taking the VMS supervision tree down.
- **Cabling.** RC receivers live near the antenna and the ROS bridge rides with the autonomy stack; both are far from the VMS bay.
- **Targets.** The Pi 3A is cheap and adequate for the RC bridge; ROS needs the memory of a Pi 4 or 5.

The BEAMs still join one Erlang cluster through `OvcsBus.Cluster`, so at the application level they talk as if they were processes in one VM. Any application can make the same choice, or bundle several bridges into one image through `bridge_firmwares/0`.

## OVCS Mini Hardware

The OVCS Mini reference application runs the same framework on a Traxxas 4WD chassis, with no infotainment side.

| Component | Hardware |
|---|---|
| VMS | Raspberry Pi 4 |
| Controller | One Arduino R4 Minima ("main") |
| Motor | Hobbywing Xerun AXE540 R2 sensored brushless motor, driven by a Flipsky Mini FSESC 6.7 Pro (VESC) on `misc`; see [VESC drivetrain](./vesc_drivetrain.md) |
| Steering | Traxxas servo, driven through external PWM |
| Spur rotation | Hall-effect sensor on the main controller's A1, counted by interrupt and reported as a frequency on `0x709` |
| Radio control | ExpressLRS receiver through the radio control bridge on a Pi 3A |
| ROS 2 | ROS bridge on a Pi 4; perception bridge (stereo cameras and Hailo-8) on a Pi 5 |
| Compute node | Raspberry Pi 5 running balenaOS from an NVMe SSD in a USB enclosure: Zenoh router, Foxglove bridge, Nav2, the vehicle's Wi-Fi access point. The bootloader EEPROM needs `PSU_MAX_CURRENT=5000` to boot from USB on the vehicle's supply; see [ROS compute node, Boot media](./ros_compute_node.md#boot-media) |

The Mini's VMS has two buses:

| Network | Bitrate | Interface | Connected components |
|---|---|---|---|
| `ovcs` | 500 kbps | `spi0.0` | Main controller, radio control bridge, ROS bridge |
| `misc` | 500 kbps | `spi1.0` | Third-party components: the traction motor's VESC (id 1) |

The bridges sit only on `ovcs`; `misc` is the VMS's alone, so third-party traffic and identifiers never mix with the controller and bridge frames. The VESC is a CAN node of its own, commanded with closed-loop speed and reporting motor rpm, current and battery voltage. Its frames use 29-bit extended identifiers, which coexist with standard frames on the same bus.

## Supported hardware and Nerves systems

| Framework role | Platform | Nerves target |
|---|---|---|
| VMS | Raspberry Pi 4 | [`ovcs_base_can_system_rpi4`](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi4) |
| Infotainment | Raspberry Pi 5 | [`ovcs_base_can_system_rpi5`](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi5) |
| Radio control bridge | Raspberry Pi 3A | [`ovcs_base_can_system_rpi3a`](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi3a) |
| ROS bridge | Raspberry Pi 4 or 5 | `ovcs_base_can_system_rpi4`, or `rpi5` (the `ovcs_bridges_system_rpi5` system) |
| Generic controller | Arduino R4 Minima | PlatformIO, not Nerves |

The custom systems add the CAN kernel modules and device-tree overlays the SPI CAN boards need. They matter only when building firmware for physical hardware; local development never touches them. Each role's Nerves target comes from the application's module (`vms_target/0`, `infotainment_target/0`, the `:target` key of each `bridge_firmwares/0` entry), so moving an application to different boards means changing those values and adding the matching system dependency to the framework firmware's `mix.exs`. Why the host Elixir/OTP pin is tied to these systems is in [Toolchain and OTP](./toolchain_and_otp.md).

## Where next

- [Running on hardware](./running_hardware.md): build, burn and upload firmware to these boards.
- [Generic controllers](./testing_generic_controllers.md): flash an Arduino and adopt it from the VMS.
- [OVCS1 wiring reference](../vehicles/ovcs1/WIRING.md): the Leaf harness, iBooster, steering pump and Polo CAN bus.
