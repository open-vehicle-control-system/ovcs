---
title: Glossary
description: One-line definitions of the terms the OVCS documentation uses, each linked to the page that explains it.
---

The guides use a small set of words precisely. Each entry below gives the meaning in one or two sentences and links to the section that explains it; terms are alphabetical within each layer.

## Framework and vehicles

| Term | Definition |
|---|---|
| **`.env.exs`** | The gitignored per-vehicle file under `vehicles/<vehicle>/` holding SSH keys, Wi-Fi networks, Phoenix secrets, `ZENOH_ENDPOINT_IP` and optional NervesHub credentials, shared by every firmware of the vehicle at build time. [Running on hardware](./running_hardware.md#build) |
| **Component** | Two senses. In [Framework components](./components.md) it means a piece of the framework (a core, an API, a firmware shell, a library); in [Architecture](./architecture.md#the-component-pattern) and the composers it means a `vms_core` driver, a GenServer managing one piece of hardware or one input (`VmsCore.Components.*`). |
| **Composer** | The vehicle's module that tells a core what to run: `<Vehicle>.Vms.Composer` implements `VmsCore.Vehicle`, `<Vehicle>.Infotainment.Composer` implements `InfotainmentCore.Vehicle`. It lists the supervised children, the CAN topology and mapping, dashboard pages and controller pinouts. [Your vehicle package](./vehicle_package.md#what-a-composer-contributes) |
| **Framework** | Everything vehicle-agnostic in the monorepo: cores, APIs, dashboards, Nerves firmware shells, bridge libraries, the generic controller firmware, shared libraries and the `ovcs` CLI. It contains no vehicle-specific code. [Framework and vehicles](./framework.md#the-vocabulary) |
| **Geometry** | The optional `geometry/0` callback of a vehicle module: measured wheelbase, track, wheel radius and steering limit in SI units, used by components such as `OVCS.RosVelocityCommand`. [`OvcsVehicle`](../libraries/ovcs_vehicle/lib/ovcs_vehicle.ex) |
| **Infotainment** | The optional in-car touchscreen side: `infotainment_core`, its Phoenix API and a Flutter head unit on a Raspberry Pi 5, on the `ovcs` bus only. A vehicle opts in with `infotainment/0` and `infotainment_target/0`. [Framework components](./components.md#infotainment-system) |
| **`OvcsVehicle`** | The top-level behaviour every vehicle module implements: name, composer pointers, CAN config app, Nerves targets, and optionally bridge firmwares and geometry. [Your vehicle package](./vehicle_package.md#the-four-behaviours) |
| **Reference vehicle** | One of the three vehicles in the repository, OVCS1, OVCS Mini and OBD2: worked examples of the framework on real hardware, never requirements for yours. [Framework and vehicles](./framework.md#the-reference-vehicles-and-what-each-one-teaches) |
| **Role** | One firmware of a vehicle as the CLI addresses it: `vms`, `infotainment`, or `bridge-<id>` for each `bridge_firmwares/0` entry (the `bridge-` prefix is required). Each role is one BEAM on the host and one board when deployed. [Running on hardware](./running_hardware.md#the-ovcs-cli) |
| **Scaffold** | The starting package `./ovcs new <name>` generates from `libraries/ovcs_vehicle/priv/templates/vehicle/`: a working vehicle with an example controller and a vehicle GenServer. [Your vehicle package](./vehicle_package.md#start-from-the-scaffold) |
| **Vehicle** | A Mix package under `vehicles/<name>/` (a *vehicle package*) whose top-level module implements `OvcsVehicle`. It is metadata and composers only, with no `Application`; the firmware shells load it at boot. [Your vehicle package](./vehicle_package.md#what-a-vehicle-is) |
| **`VEHICLE`** | The environment variable naming the vehicle's top-level module (`Ovcs1`, `OvcsMini`, `Obd2`, or yours), case-sensitive. The CLI sets it per BEAM on the host; a deployed release has it baked in at build time. [Framework components](./components.md#environment-variables) |
| **VMS** | Vehicle Management System: the only firmware on every vehicle CAN bus, so all isolation and translation between manufacturers happens there. `vms_core`, its API and dashboard, on a Raspberry Pi 4. [Architecture](./architecture.md#the-roles) |

## Firmware and hardware

| Term | Definition |
|---|---|
| **A/B firmware** | The partition layout of the OVCS Nerves systems: two firmware slots with automatic rollback, so an image that never calls `Nerves.Runtime.validate_firmware/0` is reverted on the next boot. `OvcsVehicle.FirmwareValidator` does that call in every firmware shell. [Toolchain and OTP](./toolchain_and_otp.md#what-the-ab-layout-requires) |
| **Adoption** | How a generic controller receives its pinout: the VMS broadcasts the configuration frame `0x700`, you press the board's adoption button, and the board stores the configuration in EEPROM. [Generic controllers](./generic_controllers.md#adopting-a-controller) |
| **Bridge** | An Elixir library under `bridges/<name>/` implementing `OvcsBridge` that ferries data between the `ovcs` bus and a non-CAN world: `RadioControlBridge` for an ExpressLRS link, `RosBridge` for ROS 2. [Framework components](./components.md#bridges) |
| **Bridge firmware** | One entry of a vehicle's `bridge_firmwares/0` map (target, bridge libraries, CAN mapping), and the `bridges/firmware` Nerves image built once per entry. [Your vehicle package](./vehicle_package.md#bridge-firmwares) |
| **`BRIDGE_FIRMWARE_ID`** | The environment variable a bridge firmware reads at boot to pick its entry from `bridge_firmwares/0`, such as `radio_control` or `ros_perception`. [Framework components](./components.md#bridge-firmware) |
| **CAN HAT, multi-CAN SPI hub** | The custom CAN interface boards: a HAT connects a Pi to one network; the hub fans the VMS Pi 4's SPI out to one MCP2517FD controller per bus, addressed as `spiN.M`. [Hardware](./hardware.md#can-interface-hardware) |
| **Compute node** | The one non-Nerves machine a vehicle may carry: a Raspberry Pi 5 on balenaOS running the Zenoh router, `foxglove_bridge` and Nav2 from `compose/compute/`. The OVCS Mini reference vehicle has one. [ROS compute node](./ros2_compute_node.md#topology) |
| **Controller id** | The 4-bit id a generic controller is assigned during adoption, which fixes every frame id it uses (`0b111AAAABBBB`, so `0x7X1` to `0x7X9`); up to 16 controllers per network. [Generic controllers](./generic_controllers.md#how-can-ids-are-derived) |
| **Firmware shell** | A framework Nerves project (`vms/firmware`, `infotainment/firmware`, `bridges/firmware`) that packages a core or bridges into a bootable image and contains no vehicle code: at boot it reads `VEHICLE` and loads the vehicle package. [Architecture](./architecture.md#three-layers-per-system) |
| **Generic controller** | An Arduino R4 Minima running the one framework firmware in `controllers/generic_controller/`, whose pins are configured over CAN by the VMS rather than hardcoded. A vehicle declares its boards in `generic_controllers/0`. [Generic controllers](./generic_controllers.md) |
| **Host keys** | Stable per-role SSH host keys under `vehicles/<vehicle>/priv/host_keys/`, created by `./ovcs host-keys generate`, so a reburn does not change the board's SSH identity. [Running on hardware](./running_hardware.md#stable-ssh-host-keys-across-burns) |
| **Nerves system** | The package providing a board's kernel, root filesystem and ERTS, such as `ovcs_base_can_system_rpi4`; the OVCS forks add CAN kernel modules and device-tree overlays. Its OTP major must match the host's. [Toolchain and OTP](./toolchain_and_otp.md#the-constraint) |
| **Nerves target** | The Mix target (`MIX_TARGET`) a role builds for, read from `vms_target/0`, `infotainment_target/0` or a bridge entry's `:target`. It usually equals the system's name; `rpi5` for `ovcs_bridges_system_rpi5` is the exception. [Running on hardware](./running_hardware.md#boards-per-role) |
| **NervesHub** | A self-hosted update server the VMS firmware can pull signed firmware from, opt-in per vehicle through `NERVES_HUB_*` variables in `.env.exs`, with one NervesHub product per vehicle. [Running on hardware](./running_hardware.md#ota-updates-via-nerveshub) |
| **OTA** | Updating a deployed board's firmware over the network instead of reburning its SD card. The guides mean NervesHub pulls by "OTA updates"; `./ovcs upload` pushes an image over SSH. [Running on hardware](./running_hardware.md#ota-updates-via-nerveshub) |
| **Perception bridge** | A `RosBridge` firmware running stereo depth and object detection, such as the OVCS Mini's `ros_perception` entry on a Pi 5 with a Hailo-8. [Perception: object detection](./ros2_perception.md) |
| **System fork** | An OVCS fork of an upstream Nerves system, pinned to a tag; `systems/` holds local clones for patching one. [Toolchain and OTP](./toolchain_and_otp.md#hacking-on-a-system-fork-locally) |

## CAN

| Term | Definition |
|---|---|
| **CAN mapping** | Which interface carries each network, written `network:interface,…`. A composer declares it in `default_can_mapping/1` for the `:host` and `:target` arms, and a bridge entry in its `default_can_mapping` key. [Running on hardware](./running_hardware.md#can-interfaces) |
| **`CAN_NETWORK_MAPPINGS`** | Environment variable that replaces a composer's mapping when set at boot, read by each firmware's `config/runtime.exs`. On the host, `./ovcs run` passes it to the VMS and infotainment BEAMs; bridges keep their own mapping. [Running on hardware](./running_hardware.md#overriding-the-mapping) |
| **`candumps/`** | Recorded CAN logs from real vehicles, mostly the OVCS1 Polo, for replay onto virtual interfaces with `canplayer`. [Testing with CAN](./testing_with_can.md#replaying-can-dumps) |
| **Cantastic** | The sideloaded CAN library the cores and bridges use: YAML frame specs, SocketCAN, emitter and receiver, ISO-TP, OBD2, a received-frame watchdog. It sets up CAN interfaces at boot on Nerves. [Framework components](./components.md#shared-libraries) |
| **Emitted and received frames** | The two lists under each network in a topology YAML (`emitted_frames`, `received_frames`): what this node sends, and what its receiver forwards to subscribers. [CLI reference](../cli/README.md#can-decoding) |
| **Frame spec** | The YAML describing one CAN frame: id, frequency and the signals packed in it. Shared specs live in `ovcs_can`; a topology imports them. [Testing with CAN](./testing_with_can.md#reading-frame-definitions) |
| **Heartbeat** | The VMS status frame `0x1A0`, emitted every 100 ms by `VmsCore.Status`; generic controllers cut every output when it goes missing, after a 30 s grace period at power-up. [Architecture](./architecture.md#safety-mechanisms-in-the-framework) |
| **Interface** | The Linux device a network runs on: `vcan0` (virtual), `can0` (physical adapter) or `spi0.0` (a controller behind an SPI CAN board). [Running on hardware](./running_hardware.md#can-interfaces) |
| **Network** | A named CAN bus declared under `can_networks:` in a topology YAML, with its bitrate and frames, such as `ovcs`, `misc` or `leaf_drive`. Components refer to networks by name, never by interface. [Hardware](./hardware.md#can-bus-configuration) |
| **`ovcs` bus** | The framework's internal network, declared by every vehicle: VMS heartbeat, controller adoption, radio and ROS commands, infotainment traffic. [Architecture](./architecture.md#bus-isolation) |
| **`ovcs_can`** | The in-tree library of shared per-component frame YAMLs under `priv/can/components/`, grouped by manufacturer, with no runtime logic. Topologies import from it with `import!:@ovcs_can:…`. [Framework components](./components.md#shared-libraries) |
| **Signal** | A named value inside a frame: a bit range (`value_start`, `value_length`) with a kind and optionally a scale and unit. [Testing with CAN](./testing_with_can.md#reading-frame-definitions) |
| **Topology** | A vehicle's YAML under `priv/can/` saying which frames run on which network for one side: `vms.yml`, `infotainment.yml`, `bridges/<id>.yml`. [Hardware](./hardware.md#can-bus-configuration) |
| **vcan** | A Linux virtual CAN interface (`vcan0`, `vcan1`, …). `./ovcs can setup <vehicle>` creates the ones the vehicle's host mapping names, so everything runs on a laptop without CAN hardware. [Testing with CAN](./testing_with_can.md#prerequisites) |

## Runtime

| Term | Definition |
|---|---|
| **Action** | A command a component exposes through `trigger_action/2`, so a dashboard button (via `POST /api/actions`) or IEx can call into it. [Architecture](./architecture.md#the-component-pattern) |
| **Arm** | The `:host` or `:target` argument that per-environment callbacks such as `default_can_mapping/1` and `radio_control_bridge_config/1` receive. [Your vehicle package](./vehicle_package.md#the-four-behaviours) |
| **Commander** | Two senses. A component that requests throttle, steering or direction (the `OVCS.RadioControl.*` inputs, `OVCS.RosActuatorCommand.*`, `OVCS.RosVelocityCommand`); and, under `:ros`, the requested ROS commander, `:teleop` or `:autonomous`. [Your vehicle package](./vehicle_package.md#control-levels-who-commands-and-which-ros-node) |
| **Control level** | Who has authority over the vehicle: `:manual`, `:radio` or `:ros`, arbitrated by `Managers.ControlLevel`, which refuses unsafe transitions and makes `:ros` reachable only from `:radio`. [Your vehicle package](./vehicle_package.md#control-levels-who-commands-and-which-ros-node) |
| **Dashboard pages and blocks** | The layout a composer declares in `dashboard_configuration/0` (or `infotainment_configuration/0`) and the API serves: pages of metric tables, charts and action buttons. [Framework components](./components.md#vms-api) |
| **Freshness** | The check that a ROS command is new: the bridge increments a `sequence` per ROS sample, and the VMS zeroes the command when it stops changing, since the emitter retransmits stale frames on a timer. [ROS 2 and the simulator](./ros2_simulator.md#the-sequence) |
| **Host versus target** | Host is your machine, where `./ovcs run` spawns one BEAM per role with `MIX_TARGET=host` on vcan; target is a deployed Nerves board on real CAN. [Architecture](./architecture.md#host-development-versus-deployed) |
| **Input curve** | `OVCS.InputCurve`, a component that applies a hand's dead zone and expo to a throttle source; a source map names the curve rather than the raw input. [Your vehicle package](./vehicle_package.md#source-maps) |
| **Manager** | Framework logic spanning several components: `Managers.ControlLevel` and `Managers.Gear`. [Architecture](./architecture.md#managers) |
| **Mesh** | The Erlang-distribution cluster every BEAM of a vehicle joins through `OvcsBus.Cluster`, over loopback on the host and the vehicle LAN when deployed. No broker. [Architecture](./architecture.md#one-erlang-mesh-no-broker) |
| **Metric** | A value a component broadcasts on `OvcsBus`; `VmsCore.Metrics` aggregates them for the dashboard and API. [Architecture](./architecture.md#the-vms-supervision-tree) |
| **Node name** | A BEAM's distribution name: `<vehicle>-<role>@<host>` on the host, `nerves@<vehicle>-<role>.local` deployed. [Your vehicle package](./vehicle_package.md#bus-wiring-and-node-names) |
| **OvcsBus** | The in-tree pub/sub library: `OvcsBus.broadcast/2` sends an `%OvcsBus.Message{}` (`name`, `value`, `source`, `unit`) to subscribers on the local node, or on every node over Erlang distribution when `:cluster_broadcast` is set. [Architecture](./architecture.md#the-component-pattern) |
| **`process_name`** | The option on components that can run more than once in a vehicle (`OVCS.InputCurve`, `OVCS.GenericController`, `OVCS.RotationFusion`, `Vesc.MotorController`): the name the process registers under and the `source` its messages carry. [VESC drivetrain](./vesc_drivetrain.md#wiring-it-into-a-composer) |
| **Ready to drive** | The vehicle-level condition, reported in the VMS heartbeat, that entering `:radio` or `:ros` requires; losing it forces `:manual`. [Architecture](./architecture.md#safety-mechanisms-in-the-framework) |
| **Source** | The publishing module an `OvcsBus.Message` carries. A component is told in its composer config which module publishes what it needs (`speed_source: …`) and matches on it, so components never import each other. [Architecture](./architecture.md#the-component-pattern) |
| **Source map** | A composer's `requested_*_sources` map, keyed by control level and, under `:ros`, by commander; a missing key means nothing commands that actuator. [Your vehicle package](./vehicle_package.md#source-maps) |

## Tooling

| Term | Definition |
|---|---|
| **Attach TUI** | `./ovcs attach <vehicle>`: a split-pane terminal UI (logs, bus, CAN, IEx) on a running vehicle, deployed boards first, local BEAMs otherwise. [CLI reference](../cli/README.md#the-attach-tui) |
| **can-utils** | The Linux tools `cansend`, `candump`, `canplayer` and `cangen` for injecting, watching and replaying frames. [Testing with CAN](./testing_with_can.md) |
| **Dev add-on** | A helper process a firmware declares in `dev_addons/0` and `./ovcs run` starts beside the BEAMs; today only the VMS dashboard's Vite server on `http://localhost:5173`. `--no-addons` skips them. [CLI reference](../cli/README.md#run-versus-attach) |
| **In-tree library** | A library under `libraries/` that is a framework-internal contract and lives in the monorepo: `ovcs_vehicle`, `ovcs_can`, `ovcs_bus`, `ovcs_bridge`, `ovcs_drivers`. [Framework components](./components.md#shared-libraries) |
| **`ovcs` CLI** | The framework's Rust command-line tool, `./ovcs`, built by `mise run cli`: scaffolds, runs, builds, burns, uploads and attaches to any vehicle. [CLI reference](../cli/README.md) |
| **Sideloaded library** | A library reusable outside OVCS with its own repository (Cantastic, `express_lrs`, `msp_osd`, `ovcs_control`), gitignored here and cloned into `libraries/` by `mise run libraries`, which `mise install` runs. [Framework components](./components.md#shared-libraries) |

## ROS 2

| Term | Definition |
|---|---|
| **Actuator command** | The `0x2B0` frame `RosBridge.Consumers.Joy` writes from `/joy/<profile>`: normalised steering and throttle positions, read by `OVCS.RosActuatorCommand.*`. [ROS 2 and the simulator](./ros2_simulator.md#the-actuator-command-0x2b0) |
| **Base station** | The operator's workstation side, `compose/local/`: ROS tooling, the gamepad node and Foxglove Studio, joining the vehicle's router as clients. [ROS 2 and the simulator](./ros2_simulator.md#who-runs-what) |
| **`OVCS_SIM`** | Environment variable (`1` or `true`) that switches the OVCS Mini reference vehicle's ROS bridges to simulator wiring: Zenoh camera input, no odometry publisher. [ROS 2 and the simulator](./ros2_simulator.md#perception-against-the-simulator) |
| **ROS bridge** | `RosBridge`, the bridge that speaks the `rmw_zenoh` wire format natively over Zenoh, turning ROS topics into `ovcs` frames and back; a vehicle configures it in `ros_bridge_config/1` or `/2`. [Framework components](./components.md#ros-bridge) |
| **Stand-in** | A copy of a vehicle service (`zenohd`, `foxglove_bridge`, `nav2`) in `compose/local/base.yml` behind a profile, for when no vehicle is on the LAN; it must not run while one is. [ROS 2 and the simulator](./ros2_simulator.md#who-runs-what) |
| **Velocity command** | The `0x2B1` frame `RosBridge.Consumers.Velocity` writes from a planner `Twist`: linear and angular velocity, turned into steering and throttle by `OVCS.RosVelocityCommand` against the vehicle's geometry. [ROS 2 and the simulator](./ros2_simulator.md#the-velocity-command-0x2b1) |
| **Verifier** | A `mise run verify-*` task that brings a stack up, asserts on it and tears it down, such as `verify-drivetrain` or `verify-perception`. [ROS 2 and the simulator](./ros2_simulator.md#the-verifiers) |
| **Zenoh** | The transport everything ROS-shaped uses instead of DDS; every participant is a client of one router, `zenohd`, which runs on the vehicle's compute node. [ROS 2 and the simulator](./ros2_simulator.md#the-fabric-one-zenoh-router-everything-a-client) |
| **`ZENOH_ENDPOINT_IP`** | The router address a `RosBridge` firmware peers with, set in `.env.exs` and baked into the image at build time; without it the bridge falls back to `127.0.0.1`. [ROS compute node](./ros2_compute_node.md#wiring-it-into-ovcs) |

## Next steps

- [Framework and vehicles](./framework.md): the vocabulary above in context.
- [Architecture](./architecture.md): how the VMS, bridges, controllers and mesh fit together.
- [Your vehicle package](./vehicle_package.md): the contract your vehicle implements.
- [CLI reference](../cli/README.md): every `ovcs` command.
