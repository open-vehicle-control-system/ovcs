---
title: Hardware you need
description: What to buy at each stage, from a laptop alone to a full vehicle, and which parts the reference vehicles use.
---

You can go a long way with OVCS before you buy anything. This page walks through the stages in the order most builds take them: a laptop alone, a laptop on a real CAN bus, a VMS board, generic controllers, then bridges and extras. For each it says what to get and what the repository configures for it. The last section lists the parts of the three reference vehicles as worked examples. The architecture behind these choices (bus isolation, which Pi plays which role) is in [Hardware](./hardware.md); this page is the shopping-and-wiring entry point.

> [!NOTE]
> The boards, overlays and interface names below are framework-level. Which buses your vehicle has, at what bitrate, and what hangs off them is your vehicle's decision, declared in its `priv/can/vms.yml` and its VMS composer. Everything tied to OVCS1, OVCS Mini or OBD2 is labelled as a worked example.

## Nothing but a laptop

A Linux laptop runs a whole vehicle. `./ovcs run <vehicle>` creates the virtual CAN interfaces the vehicle's `default_can_mapping(:host)` names, compiles every firmware for the host and boots one BEAM per role, joined in an Erlang cluster. The [Quickstart](./quickstart.md) does this with a reference vehicle; the commands are the same for yours.

What works with zero hardware:

- the VMS, the infotainment and the bridges, talking over `vcan` interfaces;
- the Vue dashboard and `./ovcs attach <vehicle>`, which decodes every frame with your vehicle's YAMLs;
- injecting and replaying traffic with `cansend`, `cangen` and `canplayer`, including real captures under `candumps/` ([Testing with CAN](./testing_with_can.md));
- the Gazebo simulator of the OVCS Mini reference vehicle, which needs only Docker ([Simulation](../compose/local/simulation/README.md)).

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

The OVCS1 and OVCS Mini reference vehicles use a custom multi-CAN SPI hub with MCP2517FD controllers, and custom single-channel HATs on the other Pis ([Hardware](./hardware.md#can-interface-hardware)). Their schematics and BOMs are not published in this repository: there are no KiCad, Gerber or BOM files in it. The off-the-shelf path is a commercial SPI CAN HAT with an MCP2515 or an MCP251xFD controller.

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
| Arduino R4 Minima | any Arduino-compatible board with EEPROM should work | [Hardware](./hardware.md#generic-controllers) |
| MCP2517FD SPI CAN controller, 40 MHz oscillator | CS on D10, INT on D3, SPI on D11 (COPI), D12 (CIPO), D13 (SCK) | `SPI_CAN_CS`, `SPI_CAN_INT`, `CAN_OSCILLATOR` in [`lib/Can/Can.h`](../controllers/generic_controller/lib/Can/Can.h) |
| CAN transceiver | between the MCP2517FD and the bus | [Hardware](./hardware.md#generic-controllers) |
| Adoption push button | D2 | [README pin mapping](../controllers/generic_controller/README.md#pin-mapping) |
| Up to two MCP23008 I2C expanders (optional) | A4 (SDA), A5 (SCL), addresses `0x20` and `0x21` | [`src/main.cpp`](../controllers/generic_controller/src/main.cpp) |
| PWM hat (optional) | UART on D0/D1, 115200 baud | `Controller::initializeSerialTransfer` in [`lib/Controller/Controller.cpp`](../controllers/generic_controller/lib/Controller/Controller.cpp) |

The expanders give 16 more digital pins (OVCS pins 3–18). The PWM hat drives the four external PWM outputs (`0x7X5`–`0x7X8`). The repository describes it only by its interface: the Arduino sends it duty and frequency packets over the UART with SerialTransfer, resending every 100 ms. Its hardware and firmware are not in this repository, and neither is a transceiver part number.

The firmware runs CAN at 500 kbps by default (`CAN_BITRATE` in `Can.h`), and the bus a controller joins must run at that rate. For another bitrate, set `CAN_BITRATE` as a build flag and reflash ([Generic controllers](./generic_controllers.md#bus-bitrate)). Flashing, adoption and `candump` checks are in [Generic controllers](./generic_controllers.md).

## Bridges and extras

Each of these is optional and gets its own Pi on the reference vehicles; [Hardware](./hardware.md#why-every-bridge-is-its-own-pi) explains why. A bridge Pi with a CAN connection needs one CAN controller on the `ovcs` bus. The reference bridges use `mcp251xfd,spi0-0,oscillator=40000000,interrupt=4`, mapped as `ovcs:spi0.0` in the vehicle's `bridge_firmwares/0`.

| Extra | Hardware | What the repository configures |
|---|---|---|
| Radio control bridge | Raspberry Pi 3A, an ExpressLRS receiver that outputs MAVLink, an ExpressLRS handset | The reference `config.txt` loads `sc16is752-spi1`; the vehicle's `radio_control_bridge_config(:target)` reads the receiver on `ttySC0` at 460800 baud ([`vehicles/ovcs_mini/lib/ovcs_mini.ex`](../vehicles/ovcs_mini/lib/ovcs_mini.ex), [radio control bridge](../bridges/radio_control_bridge/README.md)) |
| ROS bridge | Raspberry Pi 4 (or 5), optional BNO085 IMU on I2C, optional SLAMTEC RPLIDAR C1 on USB | `{:imu_publisher, driver: BNO085.I2C}` and `{:lidar_publisher, driver: RPLidar.UART}` on target, `OvcsDrivers.Imu.Dummy` on the host ([ROS bridge](../bridges/ros_bridge/README.md)) |
| Perception bridge | Raspberry Pi 5, two Camera Module 3 (IMX708) on `cam0` and `cam1`, a Hailo-8 on a Hailo hat | No CAN controller: it maps `ovcs:vcan0` and reaches the vehicle over Zenoh ([Perception](./ros2_perception.md), [`ros_perception/config.txt`](../vehicles/ovcs_mini/priv/firmware/bridges/ros_perception/config.txt)) |
| ROS compute node | Raspberry Pi 5 (8 GB), NVMe SSD in a USB enclosure, Intel AX210 on M.2, Pi 5 RTC battery | balenaOS, not Nerves; no CAN ([ROS compute node](./ros2_compute_node.md#hardware)) |
| Infotainment | Raspberry Pi 5, a 10-inch touchscreen, one CAN controller on `ovcs` | The reference `config.txt` loads `mcp251xfd,spi0-0,oscillator=40000000,interrupt=25`; the composer maps `ovcs:can0` ([Framework components](./components.md)) |

The infotainment firmware has no SPI device lookup: it binds `can0` directly, which is the name the kernel gives the only CAN controller on the board.

The Nerves system each role builds against is listed in [Hardware](./hardware.md#supported-hardware-and-nerves-systems).

## Power, ground and termination

The repository documents a few specifics and no general wiring rules. What it says:

- **VESC drivetrain.** The VESC has no termination resistor of its own, so the bus keeps its existing terminations. Its CAN ground is the vehicle ground. It stays powered from the traction battery; the VMS doesn't switch it ([VESC drivetrain](./vesc_drivetrain.md#wiring)).
- **OBD2 cable.** Pin 6 is CAN-High, pin 14 CAN-Low, pins 4 and 5 ground; pin 16 carries 12 V, used only if the VMS draws its power from the port ([OBD2](./obd2.md#prerequisites)). Continuous polling keeps the car's ECUs awake and drains a parked car's 12 V battery.
- **Compute node supply.** A Pi 5 booting from USB behind a DC-DC converter needs `PSU_MAX_CURRENT=5000` in its bootloader EEPROM, and the converter must then deliver 5 A at 5 V, or boot failures turn into brownouts under load ([Boot media](./ros2_compute_node.md#boot-media)).
- **OVCS1 harnesses.** [`vehicles/ovcs1/WIRING.md`](../vehicles/ovcs1/WIRING.md) lists the Leaf inverter's ignition relay, ground and 12 V pins, and the CAN-High/CAN-Low pins of the iBooster, steering pump and Polo drive bus connectors. It is marked work in progress: the 12 V distribution and the OVCS controller looms are not captured yet.

For termination, grounding and supply on your own buses, follow the documentation of your transceivers and components.

## Reference vehicles' parts lists

These are worked examples: what each reference vehicle runs, not what yours must.

### OVCS1

A 2007 Volkswagen Polo 9N converted to electric, five buses ([Hardware](./hardware.md#worked-example-the-ovcs1-reference-vehicle), [README](../vehicles/ovcs1/README.md)).

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

### OVCS Mini

A Traxxas 4WD RC chassis, two buses, no infotainment ([Hardware](./hardware.md#ovcs-mini-hardware), [VESC drivetrain](./vesc_drivetrain.md)).

| Role | Part |
|---|---|
| VMS | Raspberry Pi 4, two MCP2517FD: `spi0.0` `ovcs`, `spi1.0` `misc`, both 500 kbps |
| Controller | One Arduino R4 Minima ("main") with a PWM hat |
| Motor | Hobbywing Xerun AXE540 R2 sensored brushless, on a Flipsky Mini FSESC 6.7 Pro (VESC, id 1) on `misc` |
| Steering | Traxxas servo on PWM hat output 0, 100 Hz |
| Speed sensing | Hall-effect sensor on the spur gear, on the controller's A1 |
| Radio control | ExpressLRS receiver on a Pi 3A |
| ROS | ROS bridge on a Pi 4; perception bridge on a Pi 5 with two IMX708 cameras and a Hailo-8 |
| Compute node | Raspberry Pi 5 on balenaOS from NVMe over USB |

### OBD2

A scan tool with no drivetrain and no bridges ([OBD2](./obd2.md)).

| Role | Part |
|---|---|
| VMS | Raspberry Pi 4 with a Waveshare 2-CH CAN HAT (two MCP2515, 16 MHz): CAN0 `spi0.0` `obd2` (interrupt GPIO 23), CAN1 `spi0.1` `ovcs` (interrupt GPIO 25) |
| Car connection | An OBD-II cable to the HAT's CAN0 channel: pin 6 CAN-High, pin 14 CAN-Low, pins 4 and 5 ground |
| Infotainment (optional) | Raspberry Pi 5, one CAN controller on `ovcs` |

## Next steps

- [Hardware](./hardware.md): the architecture these parts serve, bus by bus.
- [Running on hardware](./running_hardware.md): build, burn and upload firmware to the boards.
- [Generic controllers](./generic_controllers.md): flash an Arduino and adopt it from the VMS.
- [Your vehicle package](./vehicle_package.md): declare your buses, mapping and controllers.
