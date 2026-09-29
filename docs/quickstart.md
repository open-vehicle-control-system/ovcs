---
title: Quickstart
description: Boot the OVCS Mini reference vehicle on your laptop with virtual CAN, open the dashboard, attach the TUI and feed it its first frames.
---

You need no car, Raspberry Pi or CAN adapter to see OVCS work. A whole vehicle boots on a Linux laptop: one BEAM per firmware, joined in an Erlang cluster, talking over virtual CAN. This page runs the OVCS Mini reference vehicle end to end. It assumes you completed [Getting started](./getting_started.md): `./ovcs doctor` is green and `./ovcs can status ovcs_mini` reports `All interfaces up.`

> [!NOTE]
> The OVCS Mini is a worked example, used because it is ready to run and small. Every command here takes any vehicle under `vehicles/`, including one you scaffold with `./ovcs new`: replace `ovcs_mini` with its name, and the frames with ones its `priv/can/` YAMLs declare. See [Framework and vehicles](./framework.md).

> [!TIP]
> No Linux at hand? [Simulation](../compose/local/simulation/README.md) needs only Docker: a Gazebo model of the OVCS Mini.

## Boot the vehicle

The OVCS Mini is a Traxxas RC car with a VESC-driven motor: two CAN buses (`ovcs`, and `misc` for the VESC), no infotainment side, three bridges.

```sh
./ovcs run ovcs_mini
```

The CLI:

1. Loads the `vcan` kernel module and creates the virtual CAN interfaces the vehicle declares, if they aren't up already. On the host the Mini maps `ovcs` to `vcan0` and `misc` to `vcan1`.
2. Compiles, for the host, each framework firmware project the vehicle uses (`build.sh` with `MIX_TARGET=host`), in parallel: `vms/firmware`, and `bridges/firmware` once for all three bridges.
3. Spawns one BEAM per role from that firmware's directory: `vms`, then `bridge-radio_control`, `bridge-ros` and `bridge-ros_perception`.

The first run takes a while. It fetches and builds every dependency of both firmware projects, the ROS bridge's native ones (`evision`, `zenohex`) among them, and installs the VMS dashboard's Node packages. Later runs only recompile what changed.

Output is prefixed per role (`[vms] …`, `[bridge-ros] …`). The VMS API is on `http://localhost:4000`. `Ctrl+C` stops everything. The BEAMs find each other with no broker, the same way they do on a deployed vehicle: see [One Erlang mesh, no broker](./architecture.md#one-erlang-mesh-no-broker).

## Open the dashboard

`./ovcs run` also starts each firmware's dev add-ons. For the VMS that is the Vue debug dashboard under Vite, with hot reload:

```text
http://localhost:5173
```

`:4000` serves the last prebuilt bundle from `vms/api/priv/static/` and does not hot-reload. `--no-addons` boots only the BEAMs.

The dashboard renders the pages the vehicle's VMS composer declares. The Mini's are **Dashboard**, **Drivetrain**, **Radio Control**, **ROS Control** and **Generic Controllers**: metric tables, live charts, and action buttons that call into components. Open **Drivetrain**: the motor's rpm and the vehicle's speed are empty, because nothing on the virtual buses reports them yet.

## Attach the TUI

In a second terminal:

```sh
./ovcs attach ovcs_mini
```

It first looks for deployed boards (`<vehicle>-<role>.local`, port 22); when none answers, it discovers the local BEAMs through `epmd`, and shows four panes: merged **logs** from every node, the **bus** (`OvcsBus.Message`s), every **CAN** frame decoded into named signals, and an **IEx** shell on the node picked in its tab strip.

| Key | Action |
|---|---|
| `Tab` | Cycle focus: logs, bus, CAN, IEx |
| `Ctrl+N` / `Ctrl+P`, `F1`–`F9` | Choose the node the IEx pane drives |
| `Space` or `p` | Freeze the focused bus or CAN pane; messages arriving while frozen are dropped |
| `Alt+Enter` | Maximise the focused pane |
| `Ctrl+Y`, or mouse drag | Copy a pane to the clipboard |
| `q` (read-only panes) or `Ctrl+C` | Quit attach; the BEAMs keep running |

The CAN pane decodes every frame on the vehicle's interfaces, the ones the VMS emits as well as the ones you are about to send. The rest of the TUI is in the [CLI reference](../cli/README.md).

## Send your first frames

On the bench nothing plays the part of the Mini's sensors. You synthesise them with `cangen`, which repeats a frame at a fixed gap. Use streams, not single `cansend` frames: the VMS watches the freshness of each frame it receives and treats one that stops arriving as unknown again.

### The speed sensor

The Mini's generic controller reports a magnet on the spur gear as a pulse counter frame, `0x709` on `ovcs` (`vcan0`). A count and a frequency of zero is a stationary car. In a third terminal:

```sh
cangen vcan0 -I 709 -L 4 -D 00000000 -g 10
```

- The CAN pane shows `ovcs` / `main_controller_pulse_counter_status` arriving every 10 ms.
- On **Drivetrain**, **Spur Sensor** reads 0, **Motor Rotation** names `PulseRotationSensor` as its active source, and **Vehicle Motion** shows a speed of 0 km/h.
- The **Speed & RPM** chart on **Dashboard** starts plotting.

A known speed is also what lets the VMS change control level: every mode change needs a proven standstill. [Driving on the host bench](./vehicle_package.md#driving-on-the-host-bench) continues from here with the radio switch frames.

### The motor controller

The VESC reports its telemetry on `misc` (`vcan1`) with extended ids: `0x0901` carries the electrical rpm as a big-endian signed 32-bit integer, then the motor current and the duty cycle. Leave the first stream running, and in a fourth terminal report 2000 erpm (`0x000007D0`):

```sh
cangen vcan1 -e -I 901 -L 8 -D 000007D000000000 -g 20
```

- The CAN pane shows `misc` / `vesc_status` with `erpm=2000`.
- On **Drivetrain**, **Motor Controller (VESC)** fills in. The Mini's motor has two pole pairs, so **Motor RPM** reads 1000 and **Direction** reads `forward`.
- **Motor Rotation** switches its active source to `Vesc`, the higher-priority sensor. **Vehicle Motion** turns that rotation into the wheel's through the Mini's gearing and wheel radius: about 85 wheel rpm, about 1.75 km/h.
- After 1.5 s, **Cross-check Fault** turns true. The spur sensor still reports zero while the VESC reports 1000 rpm on the same shaft, and the VMS flags the disagreement.

Stop the VESC stream with `Ctrl+C`. Its metrics go empty, **Motor Rotation** falls back to the spur sensor, and the fault clears. [VESC drivetrain](./vesc_drivetrain.md) explains the motor controller and its frames.

For your vehicle, pick frames its VMS **receives**, as declared in its `priv/can/vms.yml`, and follow the same pattern. [Testing with CAN](./testing_with_can.md) covers single frames, `candump` and replaying recorded traffic.

## Override the CAN mapping

`CAN_NETWORK_MAPPINGS` in `./ovcs run`'s environment moves networks to other interfaces, such as a real adapter, for the VMS and the infotainment BEAM; bridges keep the host mapping from `bridge_firmwares/0`. See [Custom CAN mappings](./components.md#custom-can-mappings).

## Next steps

- [Your first vehicle](./first_vehicle.md): scaffold your own vehicle with `./ovcs new` and make it do something.
- [Architecture](./architecture.md): bus isolation, the vehicle contract, the Erlang mesh.
- [Generic controllers](./generic_controllers.md): flash an Arduino and adopt it.
- [Running on hardware](./running_hardware.md): build, burn and upload Nerves firmware.
