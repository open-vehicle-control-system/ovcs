---
title: Hardware
description: What to buy at each stage, from a laptop alone to a full vehicle, the boards and CAN interfaces the framework targets, and the OVCS1, OVCS Mini and OBD2 builds as worked examples.
---

You can go a long way with OVCS before you buy anything. This page walks through the stages in the order most builds take them: a laptop alone, a laptop on a real CAN bus, a VMS board, generic controllers, then bridges and extras. For each it says what to get and what the repository configures for it. Then it describes what the framework targets, and the three reference vehicles' builds as worked examples: OVCS1 with five isolated buses on a full-size car, the OVCS Mini with two buses on an RC car, and the OBD2 scan tool.

> [!NOTE]
> The boards, overlays, CAN interface hardware and generic controllers below are framework-level: your vehicle uses them as they are. Which buses your vehicle has, at what bitrate, and what hangs off them is your vehicle's decision, declared in its `priv/can/vms.yml` and its VMS composer. Everything tied to OVCS1, OVCS Mini or OBD2 is labelled as a worked example. See [Framework and vehicles](./framework.md).

## Nothing but a laptop

A Linux laptop runs a whole vehicle. `./ovcs run <vehicle>` creates the virtual CAN interfaces the vehicle's `default_can_mapping(:host)` names, compiles every firmware for the host and boots one BEAM per role, joined in an Erlang cluster. The [Quickstart](./quickstart.md) does this with a reference vehicle; the commands are the same for yours.

What works with zero hardware:

- the VMS, the infotainment and the bridges, talking over `vcan` interfaces;
- the Vue dashboard and `./ovcs attach <vehicle>`, which decodes every frame with your vehicle's YAMLs;
- injecting and replaying traffic with `cansend`, `cangen` and `canplayer`, including real captures under `candumps/` ([Testing with CAN](./testing_with_can.md));
- the Gazebo simulator, with Docker: the OVCS Mini reference vehicle's VMS drives its model over the same `vcan` interfaces ([Simulation](../compose/local/simulation/README.md)).

The one requirement is the `vcan` kernel module: it ships in standard Linux kernels, not in WSL2's or most cloud kernels, so on macOS or Windows use a full Linux VM. [Getting started](./getting_started.md) covers the setup.

## A laptop on a real bus

The next step is a USB CAN adapter that Linux exposes as a SocketCAN interface (`can0`, `can1`, …). The repository doesn't name a specific adapter; anything that shows up in `ip link` as a `can` device works, since Cantastic binds raw SocketCAN sockets.

Bring the interfaces up at the bus bitrate. [`scripts/setup_can.sh`](../scripts/setup_can.sh) sets `can0`, `can1` and `can2` to 500 kbps with a 10000-frame transmit queue:

```sh
sudo ip link set can0 type can bitrate 500000
sudo ip link set can0 txqueuelen 10000
sudo ip link set up can0
```

Edit it to match the bitrates in your vehicle's `vms.yml` and the interfaces you actually have.

Then point the host VMS at the adapter instead of a `vcan` with `CAN_NETWORK_MAPPINGS`, which replaces the composer's mapping at boot. Cantastic refuses a mapping that names a network the side's YAML doesn't declare. With the OVCS Mini reference vehicle, putting `ovcs` on the adapter and leaving `misc` virtual:

```sh
CAN_NETWORK_MAPPINGS=ovcs:can0,misc:vcan1 ./ovcs run ovcs_mini
```

Watch the bus with `candump`:

```sh
candump can0                  # everything
candump can0,701:7FF          # one id, exact match
candump -L can0 > capture.log # record for canplayer
```

This is enough to adopt and test a generic controller from your desk, or to capture a car's traffic before writing its frame YAMLs. Mapping rules and the override's limits are in [Running on hardware](./running_hardware.md#can-interfaces).

## A VMS: a Raspberry Pi 4 and a CAN interface

The VMS runs on a Raspberry Pi 4 with the `ovcs_base_can_system_rpi4` Nerves system, which carries the CAN kernel modules and device-tree overlays. You need one SPI CAN controller per bus the VMS owns.

The OVCS1 and OVCS Mini reference vehicles use a custom multi-CAN SPI hub with MCP2517FD controllers, and custom single-channel HATs on the other Pis ([CAN interface hardware](#can-interface-hardware)). Their schematics and BOMs are not published in this repository: there are no KiCad, Gerber or BOM files in it. The off-the-shelf path is a commercial SPI CAN HAT with an MCP2515 or an MCP251xFD controller.

### The `config.txt` line

The Pi learns about the controller from a device-tree overlay in `config.txt`. The VMS firmware takes `vehicles/<vehicle>/priv/firmware/vms/config.txt` when your vehicle ships one and falls back to [`vms/firmware/targets/ovcs_base_can_system_rpi4/config.txt`](../vms/firmware/targets/ovcs_base_can_system_rpi4/config.txt) otherwise ([`vms/firmware/config/config.exs`](../vms/firmware/config/config.exs)). The default is the five-controller hub, so with an off-the-shelf HAT, add your own file.

An **MCP2515** HAT with 16 MHz crystals, such as the Waveshare 2-CH CAN HAT the OBD2 reference vehicle uses: CAN0 on SPI0 chip select 0 with its interrupt on GPIO 23, CAN1 on chip select 1 with its interrupt on GPIO 25 ([`vehicles/obd2/priv/firmware/vms/config.txt`](../vehicles/obd2/priv/firmware/vms/config.txt)). A single-channel HAT needs only the `mcp2515-can0` line:

```text
dtparam=spi=on
dtoverlay=mcp2515-can0,oscillator=16000000,interrupt=23
dtoverlay=mcp2515-can1,oscillator=16000000,interrupt=25
dtoverlay=spi-bcm2835-overlay
```

An **MCP251xFD** controller with a 40 MHz oscillator. The OVCS Mini reference vehicle has two, on SPI0 and SPI1 ([`vehicles/ovcs_mini/priv/firmware/vms/config.txt`](../vehicles/ovcs_mini/priv/firmware/vms/config.txt)):

```text
dtoverlay=spi0-2cs
dtoverlay=spi1-3cs

dtoverlay=mcp251xfd,spi0-0,oscillator=40000000,interrupt=4 # cs_pin=8
dtoverlay=mcp251xfd,spi1-0,oscillator=40000000,interrupt=5 # cs_pin=18
```

OVCS1 adds three more on the same pattern: `spi0-1` (interrupt 14), `spi1-1` (interrupt 6) and `spi1-2` (interrupt 12) ([`vehicles/ovcs1/priv/firmware/vms/config.txt`](../vehicles/ovcs1/priv/firmware/vms/config.txt)). The `oscillator=` and `interrupt=` values belong to the board, not the framework: the reference numbers are the custom hub's. Take the crystal frequency and the INT GPIO from your HAT's documentation.

### The mapping must match the overlays

On target, the VMS composer's `default_can_mapping(:target)` names each network's SPI device as `spiB.C`, bus B, chip select C. That is the device the overlay's `spiB-C` parameter creates. At boot, [`VmsFirmware.Util.NetworkMapper`](../vms/firmware/lib/vms_firmware/util/network_mapper.ex) waits for `/sys/bus/spi/devices/spiB.C/net` and binds the network to whichever `canN` the kernel attached there. If the overlay created nothing, the boot aborts with `SPI interface 'spiB.C' to be used for '<network>' not ready within 5 seconds`.

The OVCS Mini's composer declares its two buses against the two overlays above:

```elixir
def default_can_mapping(:host), do: "ovcs:vcan0,misc:vcan1"
def default_can_mapping(:target), do: "ovcs:spi0.0,misc:spi1.0"
```

A vehicle generated from the template starts with `ovcs:spi0.0`. One MCP251xFD on `spi0-0`, or an MCP2515 through `mcp2515-can0` (SPI0, chip select 0), satisfies it. Each extra bus is one more overlay and one more `network:spiB.C` pair. Bitrates come from `vms.yml`; Cantastic sets them at boot, with no manual step.

Building and flashing the image is in [Running on hardware](./running_hardware.md).

## Generic controllers

A generic controller is an Arduino R4 Minima running the framework firmware in [`controllers/generic_controller/`](../controllers/generic_controller/README.md). It doesn't use the board's built-in CAN peripheral. Per board, you need:

| Part | Connection | Source |
|---|---|---|
| Arduino R4 Minima | any Arduino-compatible board with EEPROM should work | [Generic controllers](./generic_controllers/README.md#what-it-does) |
| MCP2517FD SPI CAN controller, 40 MHz oscillator | CS on D10, INT on D3, SPI on D11 (COPI), D12 (CIPO), D13 (SCK) | `SPI_CAN_CS`, `SPI_CAN_INT`, `CAN_OSCILLATOR` in [`lib/Can/Can.h`](../controllers/generic_controller/lib/Can/Can.h) |
| CAN transceiver | between the MCP2517FD and the bus | [Generic controllers](./generic_controllers/README.md#what-it-does) |
| Adoption push button | D2 | [Pin mapping](./generic_controllers/README.md#pin-mapping) |
| Up to two MCP23008 I2C expanders (optional) | A4 (SDA), A5 (SCL), addresses `0x20` and `0x21` | [`src/main.cpp`](../controllers/generic_controller/src/main.cpp) |
| PWM hat (optional) | UART on D0/D1, 115200 baud | `Controller::initializeSerialTransfer` in [`lib/Controller/Controller.cpp`](../controllers/generic_controller/lib/Controller/Controller.cpp) |

The expanders give 16 more digital pins (OVCS pins 3–18). The PWM hat drives the four external PWM outputs (`0x7X5`–`0x7X8`). The repository describes it only by its interface: the Arduino sends it duty and frequency packets over the UART with SerialTransfer, resending every 100 ms. Its hardware and firmware are not in this repository, and neither is a transceiver part number.

The firmware runs CAN at 500 kbps by default (`CAN_BITRATE` in `Can.h`), and the bus a controller joins must run at that rate. For another bitrate, set `CAN_BITRATE` as a build flag and reflash ([Generic controllers](./generic_controllers/README.md#bus-bitrate)). Flashing, adoption and `candump` checks are in [Generic controllers](./generic_controllers/README.md).

## Bridges and extras

Each of these is optional. On the reference vehicles each runs in a bridge firmware on its own Pi; [Why every bridge firmware is its own Pi](#why-every-bridge-firmware-is-its-own-pi) explains why. A bridge firmware Pi with a CAN connection needs one CAN controller on the `ovcs` bus. The reference bridges use `mcp251xfd,spi0-0,oscillator=40000000,interrupt=4`, mapped as `ovcs:spi0.0` in the vehicle's `bridge_firmwares/0`.

| Extra | Hardware | What the repository configures |
|---|---|---|
| Radio control (`RadioControlBridge`) | Raspberry Pi 3A, an ExpressLRS receiver that outputs MAVLink, an ExpressLRS handset | The reference `config.txt` loads `sc16is75x-spi` for the SC16IS752; the vehicle's `radio_control_bridge_config(:target)` reads the receiver on `ttySC0` at 460800 baud ([`vehicles/ovcs_mini/lib/ovcs_mini.ex`](../vehicles/ovcs_mini/lib/ovcs_mini.ex), [radio control bridge](./bridges/radio_control.md)) |
| ROS (`RosBridge`) | Raspberry Pi 4 (or 5), optional BNO085 IMU on I2C, optional SLAMTEC RPLIDAR C1 and DFRobot A02YYUW ultrasonic sensors on USB serial adapters | `{:imu_publisher, driver: BNO085.I2C}`, `{:lidar_publisher, driver: RPLidar.UART}` and one `{:range_publisher, driver: A02YYUW.UART}` per sensor on target, `OvcsDrivers.Imu.Dummy` on the host ([ROS bridge](./bridges/ros.md)) |
| Perception (`RosBridge` components) | Raspberry Pi 5, two cameras on `cam0` and `cam1`, a Hailo-8 on a Hailo hat | No CAN controller: it maps `ovcs:vcan0` and reaches the vehicle over Zenoh ([Perception](./bridges/perception.md)) |
| Vision unit (`vision` role) | Raspberry Pi 5 with two cameras on `cam0` and `cam1` and, for detection, a Hailo-8 on a Hailo hat; or an OKdo Nano C100 with two Camera Module 3 (IMX708), powered from a dedicated supply rather than over USB | No CAN controller: it reaches the vehicle over Zenoh. On the Pi 5, the default [`config.txt`](../vision/firmware/targets/rpi5/config.txt) detects the cameras (`camera_auto_detect=1`). The OVCS Mini reference vehicle runs one with two Camera Module 3 (IMX708) and a Hailo-8, declared in its own [`config.txt`](../vehicles/ovcs_mini/priv/firmware/vision/config.txt) ([Vision unit](./vision/README.md)) |
| ROS compute node | Raspberry Pi 5 (8 GB), NVMe SSD in a USB enclosure, Intel AX210 on M.2, Pi 5 RTC battery | balenaOS, not Nerves; no CAN ([ROS compute node](./ros2/compute_node.md#hardware)) |
| Infotainment | Raspberry Pi 5, a touchscreen (10-inch in OVCS1), one CAN controller on `ovcs` | The reference `config.txt` loads `mcp251xfd,spi0-0,oscillator=40000000,interrupt=25`; the composer maps `ovcs:can0` ([Infotainment](./infotainment/README.md)) |

The infotainment firmware has no SPI device lookup: it binds `can0` directly, which is the name the kernel gives the only CAN controller on the board.

The Nerves system each role builds against is listed in [Supported hardware and Nerves systems](#supported-hardware-and-nerves-systems).

### Why every bridge firmware is its own Pi

- **Failure isolation.** A misbehaving radio link or ROS publisher can hang its own BEAM without taking the VMS supervision tree down.
- **Cabling.** RC receivers live near the antenna and the ROS sensors ride with the autonomy stack; both are far from the VMS bay.
- **Targets.** The Pi 3A is cheap and adequate for the radio control bridge; the ROS bridge needs the memory of a Pi 4 or 5.

The BEAMs still join one Erlang cluster through `OvcsBus.Cluster`, so at the application level they talk as if they were processes in one VM. Any vehicle can make the same choice, or bundle several bridges into one image through `bridge_firmwares/0`.

## Power, ground and termination

The repository documents a few specifics and no general wiring rules. What it says:

- **VESC drivetrain.** The VESC has no termination resistor of its own, so the bus keeps its existing terminations. Its CAN ground is the vehicle ground. It stays powered from the traction battery; the VMS doesn't switch it ([VESC](./vms/drivers.md#wiring)).
- **OBD2 cable.** Pin 6 is CAN-High, pin 14 CAN-Low, pins 4 and 5 ground; pin 16 carries 12 V, used only if the VMS draws its power from the port ([OBD2](./obd2.md#prerequisites)). Continuous polling keeps the car's ECUs awake and drains a parked car's 12 V battery.
- **Compute node supply.** A Pi 5 booting from USB behind a DC-DC converter needs `PSU_MAX_CURRENT=5000` in its bootloader EEPROM, and the converter must then deliver 5 A at 5 V, or boot failures turn into brownouts under load ([Boot media](./ros2/compute_node.md#boot-media)).
- **OVCS1 harnesses.** [`vehicles/ovcs1/WIRING.md`](../vehicles/ovcs1/WIRING.md) lists the Leaf inverter's ignition relay, ground and 12 V pins, and the CAN-High/CAN-Low pins of the iBooster, steering pump and Polo drive bus connectors. It is marked work in progress: the 12 V distribution and the OVCS controller looms are not captured yet.

For termination, grounding and supply on your own buses, follow the documentation of your transceivers and components.

## What the framework targets

The framework targets off-the-shelf boards: Raspberry Pis for the Elixir firmwares, with an OKdo Nano C100 as the vision unit's other board, and Arduino R4 Minimas for I/O, joined by CAN interface boards. Every vehicle shares that. Two principles shape it: each manufacturer's CAN bus stays isolated, bridged only through the VMS ([Architecture](./architecture.md#bus-isolation)), and the parts stay off the shelf, so the kit is affordable and accessible.

### Computing devices

| Device | Framework role | CAN connectivity |
|---|---|---|
| Raspberry Pi 4 | Vehicle Management System (VMS) | All of the vehicle's CAN buses, through the multi-CAN SPI hub |
| Raspberry Pi 5 | Infotainment (optional) | The `ovcs` bus |
| Raspberry Pi 3A | Bridge firmware running the radio control bridge (optional) | The `ovcs` bus |
| Raspberry Pi 4 or 5 | Bridge firmware running the ROS bridge (optional) | The `ovcs` bus (one running only perception may have none and reach the vehicle over Zenoh) |
| Raspberry Pi 5, or OKdo Nano C100 | Vision unit (optional) | None; it reaches the vehicle over Zenoh |
| Raspberry Pi 5 (8 GB) | ROS compute node: balenaOS, not Nerves (optional) | None; it runs the Zenoh router the bridges peer with |
| Arduino R4 Minima | Generic controllers, as many as the vehicle declares | The `ovcs` bus |

A vehicle declares which roles it uses, and on which boards, in its `OvcsVehicle` module (`vms_target/0`, `infotainment/0` and `infotainment_target/0`, `vision/0` and `vision_target/0`, the `bridge_firmwares/0` map) and in its VMS composer's `generic_controllers/0`.

### CAN interface hardware

- **Custom Raspberry Pi CAN HATs**: SPI-to-CAN boards connecting a Pi to one CAN network. Used on the infotainment and bridge Pis.
- **Custom multi-CAN SPI hub**: fans the VMS Pi 4's SPI out to MCP2517FD CAN controllers, one per bus, each with its own transceiver. Cantastic addresses them as `spiN.M` interfaces (`spi0.0`, `spi1.0`, …); a vehicle maps its network names onto them in `default_can_mapping(:target)`.

The framework's `ovcs` bus carries controller adoption, heartbeats, infotainment and bridge commands. Vehicles with many nodes on it run it at 1 Mbps; manufacturer buses run at the stock bitrate their components require.

### Supported hardware and Nerves systems

| Framework role | Platform | Nerves target |
|---|---|---|
| VMS | Raspberry Pi 4 | [`ovcs_base_can_system_rpi4`](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi4) |
| Infotainment | Raspberry Pi 5 | [`ovcs_base_can_system_rpi5`](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi5) |
| Bridge firmware running the radio control bridge | Raspberry Pi 3A | [`ovcs_base_can_system_rpi3a`](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi3a) |
| Bridge firmware running the ROS bridge | Raspberry Pi 4 or 5 | `ovcs_base_can_system_rpi4`, or `rpi5` (the `ovcs_bridges_system_rpi5` system) |
| Vision unit | Raspberry Pi 5, or OKdo Nano C100 | `rpi5` (the `ovcs_bridges_system_rpi5` system), or `okdo_c100` (the [`nerves_system_okdo_c100`](https://github.com/Spin42/nerves_system_okdo_c100) system) |
| Generic controller | Arduino R4 Minima | PlatformIO, not Nerves |

The OVCS systems add the CAN kernel modules and device-tree overlays the SPI CAN boards need. They matter only when building firmware for physical hardware; local development never touches them. Each role's Nerves target comes from the vehicle's module (`vms_target/0`, `infotainment_target/0`, `vision_target/0`, the `:target` key of each `bridge_firmwares/0` entry), so moving a vehicle to different boards means changing those values and adding the matching system dependency to the framework firmware's `mix.exs`, plus a `targets/<target>/fwup.conf` in that firmware (the vision firmware falls back to the system's own), and for bridges a `system_deps/1` clause and the bridge library's `targets:` list. Why the host Elixir/OTP pin is tied to these systems is in [Toolchain and OTP](./toolchain_and_otp.md).

## Worked example: the OVCS1 reference vehicle

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

Every vehicle CAN bus terminates on the VMS Pi 4, so components on different buses never see each other's traffic and identifier collisions can't happen. The `ovcs` bus connects the VMS to the infotainment Pi, the two bridge firmwares and the Arduino controllers. The VMS, infotainment and bridge firmware BEAMs also form one Erlang-distribution mesh.

```text
                 ExpressLRS handset       ROS 2 / Foxglove        Vue dashboard (laptop)
                        | MAVLink UART         | Zenoh                 | HTTP + WebSocket
                        v                      v                       |
               radio_control firmware     ros firmware                 |
               (Pi 3A)                    (Pi 4, BNO085 IMU)           |
                        |                      |                       |
  ovcs (1 Mbps) ========+======================+==========+============+=========
       |                |                  |              |            |
  Infotainment     Front controller   Rear controller  Controls      VMS (Pi 4)
  (Pi 5)           0x70x              0x71x            controller    |
                                                       0x72x         +-- leaf_drive (500 kbps): Leaf inverter        
                                                                     +-- polo_drive (500 kbps): ABS, cluster, ignition, airbag
                                                                     +-- orion_bms  (500 kbps): Orion BMS2, EVPT23 charger
                                                                     +-- misc       (500 kbps): Bosch iBooster, LWS sensor
```

| Network | Bitrate | Purpose | Connected components |
|---|---|---|---|
| `ovcs` | 1 Mbps | Framework-internal communication | VMS, infotainment, controllers, `radio_control` and `ros` bridge firmwares |
| `leaf_drive` | 500 kbps | Nissan Leaf drivetrain | Leaf inverter |
| `polo_drive` | 500 kbps | Original VW Polo systems | ABS, dashboard, ignition lock, airbag |
| `orion_bms` | 500 kbps | Battery management | Orion BMS2, EVPT23 charger |
| `misc` | 500 kbps | Additional components | Bosch iBooster, Bosch LWS steering sensor |

The hub gives OVCS1's VMS five MCP2517FD controllers: `spi0.0` (`ovcs`), `spi0.1` (`leaf_drive`), `spi1.0` (`polo_drive`), `spi1.1` (`orion_bms`), `spi1.2` (`misc`). Network names and bitrates are your vehicle's own, declared in its `vms.yml` and mapped to interfaces in `default_can_mapping/1`. A driver for a part on one of these networks takes its name as a `network:` option; only the framework's own components expect `ovcs`.

### Controllers

| Controller | CAN ID range | Purpose |
|---|---|---|
| Front controller (`0x70x`) | `0x701`–`0x704` | High-voltage contactors, front sensors and relays |
| Rear controller (`0x71x`) | `0x711`–`0x714` | Water pump, rear sensors and relays |
| Controls controller (`0x72x`) | `0x721`–`0x725` | Steering column PWM, throttle pedal DAC, control inputs |
| Test controller (`0x73x`) | `0x731`–`0x738` | Development and testing, all pin types |

### Parts

| Role | Part |
|---|---|
| VMS | Raspberry Pi 4 with the custom hub: five MCP2517FD, `spi0.0` `ovcs` (1 Mbps), `spi0.1` `leaf_drive`, `spi1.0` `polo_drive`, `spi1.1` `orion_bms`, `spi1.2` `misc` (500 kbps each) |
| Infotainment | Raspberry Pi 5 with a touchscreen |
| Bridges | Radio control on a Pi 3A; ROS on a Pi 4 with a BNO085 IMU |
| Controllers | Three Arduino R4 Minima: front (id 0), rear (id 1), controls (id 2) |
| Drivetrain | Nissan Leaf AZE0 inverter and motor; NV200 cells in custom enclosures |
| Battery and charging | Orion BMS2; EVPT23 charger |
| Braking and steering | Bosch iBooster Gen2; Bosch LWS steering angle sensor; Polo power steering pump |
| Donor systems | Polo 9N ABS, instrument cluster, ignition lock |

## Worked example: the OVCS Mini reference vehicle

The OVCS Mini reference vehicle runs the same framework on a Traxxas 4WD chassis, with no infotainment side.

| Role | Hardware |
|---|---|
| VMS | Raspberry Pi 4, two MCP2517FD: `spi0.0` `ovcs`, `spi1.0` `misc` |
| Controller | One Arduino R4 Minima ("main") with a PWM hat |
| Motor | Hobbywing Xerun AXE540 R2 sensored brushless motor, driven by a Flipsky Mini FSESC 6.7 Pro (VESC, id 1) on `misc`; see [VESC](./vms/drivers.md#vesc) |
| Steering | Traxxas servo on PWM hat output 0, 100 Hz |
| Spur rotation | Hall-effect sensor on the main controller's A1, counted by interrupt and reported as a frequency on `0x709` |
| Radio control | ExpressLRS receiver on a Pi 3A running the `radio_control` bridge firmware |
| ROS 2 | The `ros` bridge firmware on a Pi 4 |
| Vision | The vision unit on a Pi 5 with two IMX708 cameras and a Hailo-8 |
| Compute node | Raspberry Pi 5 running balenaOS from an NVMe SSD in a USB enclosure: Zenoh router, Foxglove bridge, Nav2, the vehicle's Wi-Fi access point. The bootloader EEPROM needs `PSU_MAX_CURRENT=5000` to boot from USB on the vehicle's supply; see [ROS compute node, Boot media](./ros2/compute_node.md#boot-media) |

The Mini's VMS has two buses:

| Network | Bitrate | Interface | Connected components |
|---|---|---|---|
| `ovcs` | 500 kbps | `spi0.0` | Main controller, `radio_control` and `ros` bridge firmwares |
| `misc` | 500 kbps | `spi1.0` | Third-party components: the traction motor's VESC (id 1) |

The bridge firmwares sit only on `ovcs`; `misc` is the VMS's alone, so third-party traffic and identifiers never mix with the controller and bridge frames. The VESC is a CAN node of its own, commanded with closed-loop speed and reporting motor rpm, current and battery voltage. Its frames use 29-bit extended identifiers, which coexist with standard frames on the same bus.

## Worked example: the OBD2 reference vehicle

A scan tool with no drivetrain and no bridges ([OBD2](./obd2.md)).

| Role | Part |
|---|---|
| VMS | Raspberry Pi 4 with a Waveshare 2-CH CAN HAT (two MCP2515, 16 MHz): CAN0 `spi0.0` `obd2` (interrupt GPIO 23), CAN1 `spi0.1` `ovcs` (interrupt GPIO 25) |
| Car connection | An OBD-II cable to the HAT's CAN0 channel: pin 6 CAN-High, pin 14 CAN-Low, pins 4 and 5 ground |
| Infotainment (optional) | Raspberry Pi 5, one CAN controller on `ovcs` |

## Where next

- [Running on hardware](./running_hardware.md): build, burn and upload firmware to the boards.
- [Generic controllers](./generic_controllers/README.md): flash an Arduino and adopt it from the VMS.
- [Your vehicle package](./vehicle_package.md): declare your buses, mapping and controllers.
- [OVCS1 wiring reference](../vehicles/ovcs1/WIRING.md): the Leaf harness, iBooster, steering pump and Polo CAN bus.
