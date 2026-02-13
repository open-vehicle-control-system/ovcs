# OVCS Hardware Architecture

## Design Principles

OVCS hardware is designed around three core principles:

1. **CAN bus isolation** -- Components from different manufacturers may use conflicting CAN message IDs. OVCS isolates each manufacturer's bus and bridges them through the VMS.
2. **Off-the-shelf components** -- OVCS deliberately uses affordable, widely available hardware (Raspberry Pi, Arduino) to keep the development kit accessible.

## Hardware Components

### Computing Devices

| Device | Role | CAN Connectivity |
|--------|------|------------------|
| **Raspberry Pi 4** | Vehicle Management System (VMS) | Connected to all CAN buses via custom SPI CAN hub |
| **Raspberry Pi 5** | Infotainment system | Connected to the OVCS CAN bus |
| **Raspberry Pi 3A** | Radio control bridge | Connected to the OVCS CAN bus |
| **Raspberry Pi 4/5** | ROS2 bridge | Connected to the OVCS CAN bus |
| **Arduino R4 Minima** (x3 for OVCS1) | Generic controllers (front, rear, controls) | Connected to the OVCS CAN bus |

### CAN Bus Interface Hardware

- **Custom Raspberry Pi CAN bus HATs** -- SPI-to-CAN interface boards for connecting the Raspberry Pi to CAN networks.
- **Custom multi-CAN SPI board** -- A hub board that provides the VMS access to multiple CAN buses over a single SPI interface, enabling the VMS to communicate with all isolated bus segments.

### Vehicle-Specific Components (OVCS1)

| Component | Manufacturer | Purpose |
|-----------|-------------|---------|
| Leaf AZE0 Inverter + Motor | Nissan | Electric drivetrain (motor control, regenerative braking) |
| NV200 Battery Cells | Nissan | High-voltage battery pack (custom aluminum enclosures) |
| iBooster Gen2 | Bosch | Electronic brake booster (replaces vacuum-assisted brakes) |
| LWS Steering Angle Sensor | Bosch | Steering position feedback |
| BMS2 | Orion | Battery management system (cell monitoring, balancing, protection) |
| EVPT23 | EVPT | On-board charger |
| Polo 9N Systems | Volkswagen | ABS, dashboard/cluster, ignition lock, power steering pump |

## High-Level Architecture

The VMS sits at the center of the architecture, connected to all CAN buses. Each bus segment is isolated to prevent message ID conflicts between components from different manufacturers.

```
                                +-------------------+
                                |   Infotainment    |
                                |   RPi 5 + Screen  |
                                +--------+----------+
                                         |
                                    OVCS CAN Bus (1 Mbps)
                                         |
+------------------+         +-----------+-----------+         +------------------+
| Radio Control    |         |                       |         | ROS Bridge       |
| Bridge (RPi 3A) +---------+    VMS (RPi 4)        +---------+ (RPi 4/5)       |
+------------------+         |                       |         +------------------+
                             +-+---+---+---+---+---+-+
                               |   |   |   |   |
           +-------------------+   |   |   |   +-------------------+
           |                       |   |   |                       |
      Leaf Drive CAN          Polo Drive  Orion BMS CAN       Misc CAN
      (500 kbps)              CAN         (500 kbps)          (500 kbps)
           |                (500 kbps)         |                   |
    +------+------+              |        +----+----+      +------+------+
    | Leaf Inverter|       +-----+----+   | Orion   |      | iBooster   |
    | Leaf Charger |       | Polo ABS |   | BMS2    |      | LWS Sensor |
    +--------------+       | Polo     |   | EVPT23  |      +------------+
                           | Dashboard|   | Charger |
                           | Ignition |   +---------+
                           +----------+

                                    OVCS CAN Bus
                                         |
                   +---------------------+---------------------+
                   |                     |                     |
            +------+------+      +------+------+      +------+------+
            |    Front     |      |    Rear     |      |  Controls   |
            |  Controller  |      |  Controller |      |  Controller |
            | (Arduino R4) |      | (Arduino R4)|      | (Arduino R4)|
            +------+-------+      +------+------+      +------+------+
                   |                     |                     |
            Relays, sensors,       Relays, sensors,      Steering PWM,
            contactors, etc.       water pump, etc.      throttle DAC, etc.
```

![OVCS architecture](./assets/ovcs_architecture.png)

## CAN Bus Network Topology

OVCS1 uses five isolated CAN bus segments:

| Network | Bitrate | Purpose | Connected Components |
|---------|---------|---------|---------------------|
| `ovcs` | 1 Mbps | Internal OVCS communication | VMS, Infotainment, Controllers, Radio Control Bridge, ROS Bridge |
| `leaf_drive` | 500 kbps | Nissan Leaf drivetrain | Leaf Inverter, Leaf Charger |
| `polo_drive` | 500 kbps | Original VW Polo systems | ABS, Dashboard, Ignition Lock, Airbag |
| `orion_bms` | 500 kbps | Battery management | Orion BMS2, EVPT23 Charger |
| `misc` | 500 kbps | Additional components | Bosch iBooster, Bosch LWS Steering Sensor |

The OVCS CAN bus runs at 1 Mbps to accommodate the higher traffic volume from all OVCS-internal components (controllers, bridges, infotainment). External buses run at the standard 500 kbps required by their respective components.

### CAN Bus Configuration

CAN frame specifications are defined in YAML files under `vms/core/priv/can/`:

```
priv/can/
+-- vehicles/
|   +-- ovcs1.yml                    # OVCS1 vehicle CAN topology (which frames on which bus)
|   +-- ovcs_mini.yml                # OVCS Mini CAN topology
|   +-- obd2.yml                     # OBD2 mode CAN topology
|   +-- ovcs1/generic_controller/    # OVCS1-specific controller frame definitions
|   +-- ovcs_mini/generic_controller/
+-- components/
    +-- bosch/i_booster_gen2/        # iBooster frame definitions
    +-- bosch/lws/                   # Steering angle sensor frames
    +-- evpt/evpt23/                 # Charger frames
    +-- nissan/leaf_aze0/            # Leaf inverter and charger frames
    +-- orion/bms2/                  # Battery management frames
    +-- ovcs/                        # OVCS internal frames and generic controller templates
    +-- ovcs/generic_controller/     # Shared signal definitions (alive, digital pins, analog, PWM)
    +-- volkswagen/polo_9n/          # Polo ABS, dashboard, key, lock, wheels frames
    +-- obd2/                        # OBD2 diagnostic frames
```

Vehicle YAML files (e.g., `ovcs1.yml`) define the complete CAN topology: which CAN networks exist, their bitrate, and which frames are emitted and received on each network. Frame definitions are imported from the component-level YAML files.

## Generic Controllers

OVCS uses Arduino R4 Minima boards as generic, configurable I/O controllers. They are "generic" because a single firmware runs on all controllers -- the specific pin assignments and behavior are configured over the CAN bus via an **adoption process**.

### OVCS1 Controllers

| Controller | CAN ID Range | Purpose |
|-----------|-------------|---------|
| Front Controller (`0x70x`) | `0x701`-`0x704` | High-voltage contactors, front sensors and relays |
| Rear Controller (`0x71x`) | `0x711`-`0x714` | Water pump, rear sensors and relays |
| Controls Controller (`0x72x`) | `0x721`-`0x725` | Steering column PWM, throttle pedal DAC, control inputs |
| Test Controller (`0x73x`) | `0x731`-`0x738` | Development and testing (all pin types) |

### Adoption Process

1. A new (unconfigured) controller connects to the OVCS CAN bus and broadcasts its status as `ADOPTION_REQUIRED`.
2. The VMS initiates an adoption by sending a configuration frame (`0x700`) with pin assignments.
3. The operator presses the physical adoption button on the Arduino to confirm.
4. The controller stores its configuration in EEPROM and begins normal operation.
5. On subsequent boots, the controller loads its configuration from EEPROM and starts immediately.

### Supported Pin Types

| Pin Type | Description | CAN Frame |
|----------|-------------|-----------|
| Digital Output | On/off control (relays, contactors) | `0x7X2` (request) / `0x7X4` (status) |
| Analog Input | Sensor readings (0-16383 range, 14-bit) | `0x7X4` (status) |
| PWM Output | Variable duty cycle (0-4095, 12-bit) | `0x7X3` (request) |
| DAC Output | Analog voltage output (0-4095, 12-bit) | `0x7X3` (request) |
| External PWM | PWM via SPI expansion boards (16-bit duty, 24-bit freq) | `0x7X5`-`0x7X8` (request) |

## OVCS Mini Hardware

The OVCS Mini uses the same software stack on a Traxxas 4WD RC car chassis:

| Component | Hardware |
|-----------|----------|
| VMS | Raspberry Pi 4 |
| Controller | Arduino R4 Minima (single "main" controller) |
| Motor | Traxxas brushless motor (controlled via external PWM) |
| Steering | Traxxas servo (controlled via external PWM) |
| Radio Control | ExpressLRS receiver via Radio Control Bridge (RPi 3A) |

The OVCS Mini uses a single CAN bus (`ovcs` at 500 kbps) since there are no third-party automotive components requiring isolation.

Next: [Running on Hardware](./running_hardware.md)
