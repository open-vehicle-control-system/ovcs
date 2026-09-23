---
title: Quickstart
description: Boot a reference application on your laptop with virtual CAN, attach the TUI, open the dashboard, send your first frame.
---

You need no car, Raspberry Pi or CAN adapter to see OVCS work. A whole application boots on a Linux laptop: one BEAM per firmware, joined in an Erlang cluster, talking over virtual CAN. This page assumes you completed [Getting started](./getting_started.md) and `./ovcs doctor` is green.

> [!NOTE]
> The commands use the reference applications because they are ready to run. An application you scaffold with `./ovcs new` boots the same way. See [Framework and applications](./framework.md).

> [!TIP]
> No Linux at hand? [Simulation](../compose/local/simulation/README.md) needs only Docker: a Gazebo model of the OVCS Mini.

## Boot a reference application

`./ovcs run <app>` takes any application under `vehicles/`. Start with the OVCS Mini reference application: one CAN bus, no infotainment side.

```sh
./ovcs run ovcs_mini
```

The CLI:

1. Loads the `vcan` kernel module and creates the virtual CAN interfaces the application declares (sudo prompt the first time).
2. Compiles the application package, which pulls in every framework firmware project it needs.
3. Spawns one BEAM per role from that firmware's directory: `vms`, then one per bridge firmware (`bridge-radio_control`, `bridge-ros`, `bridge-ros_perception` for the Mini).

Output is prefixed per role (`[vms] …`, `[bridge-ros] …`). The VMS API is on `http://localhost:4000`. `Ctrl+C` stops everything.

```sh
./ovcs run ovcs1        # OVCS1 reference application: VMS, infotainment (:4001), two bridges
./ovcs run obd2         # OBD2 reference application: VMS and infotainment, no bridges
./ovcs run my_car       # your own application
```

Every BEAM joins one Erlang cluster through `OvcsBus.Cluster`, so a message broadcast on the VMS reaches subscribers in every bridge with no broker. A deployed vehicle uses the same transport, one BEAM per Raspberry Pi.

## Open the dashboard

`./ovcs run` also starts each firmware's dev add-ons. For the VMS that is the Vue debug dashboard under Vite, with hot reload:

```text
http://localhost:5173
```

`:4000` serves the last prebuilt bundle from `vms/api/priv/static/` and does not hot-reload. `--no-addons` boots only the BEAMs.

The dashboard renders the pages the application's VMS composer declares: metric tables, live charts, and action buttons that call into components (adopt a controller, calibrate the throttle, enable contactors).

## Attach the TUI

In a second terminal:

```sh
./ovcs attach ovcs_mini
```

It discovers the local BEAMs through `epmd` and shows four panes: merged **logs** from every node, the **bus** (`OvcsBus.Message`s), every **CAN** frame decoded into named signals, and an **IEx** shell on the node picked in its tab strip.

| Key | Action |
|---|---|
| `Tab` | Cycle focus: logs, bus, CAN, IEx |
| `Ctrl+N` / `Ctrl+P`, `F1`–`F9` | Choose the node the IEx pane drives |
| `Space` | Pause the focused bus or CAN pane without losing live data |
| `Alt+Enter` | Maximise the focused pane |
| `Ctrl+Y`, or mouse drag | Copy a pane to the clipboard |
| `q` (read-only panes) or `Ctrl+C` | Quit attach; the BEAMs keep running |

The rest is in the [CLI reference](../cli/README.md).

## Send your first CAN frame

With the OVCS1 reference application running, pull the original Polo's handbrake and watch it on the dashboard. The frame belongs to the `polo_drive` network, which OVCS1 maps to `vcan2` on the host; your application declares its own frames and mapping.

```sh
cansend vcan2 320#0002000000000000   # handbrake engaged
cansend vcan2 320#0000000000000000   # handbrake released
```

Or replay Polo traffic recorded on the real car, in a loop:

```sh
canplayer -l i -I candumps/candump-standard-test.log vcan2=can0
```

More in [Testing with CAN](./testing_can_messages.md).

## Override the CAN mapping

Each composer declares a default host mapping from network names to interfaces. `CAN_NETWORK_MAPPINGS` overrides it for the VMS, for example to put the `ovcs` bus on a real adapter:

```sh
CAN_NETWORK_MAPPINGS=ovcs:can0,leaf_drive:vcan1,polo_drive:vcan2,orion_bms:vcan3,misc:vcan4 ./ovcs run ovcs1
```

## Where next

- [Architecture](./architecture.md): bus isolation, the application contract, the Erlang mesh.
- [Simulation](../compose/local/simulation/README.md): the same Elixir bridge in front of a Gazebo model, driven by Nav2.
- [Generic controllers](./testing_generic_controllers.md): flash an Arduino and adopt it.
- [Running on hardware](./running_hardware.md): build, burn and upload Nerves firmware.
- [Your application package](./vehicle_parameterisation.md): scaffold your own with `./ovcs new`.
