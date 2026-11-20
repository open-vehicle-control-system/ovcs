---
title: "Simulator"
description: How OVCS runs your vehicle's VMS unchanged against simulated hardware on virtual CAN, and what the simulator is made of.
---

The simulator runs your vehicle's VMS as it runs on the vehicle, against simulated hardware instead of real parts. The VMS sends its usual CAN frames on virtual CAN interfaces. Simulated hardware answers them with the frames the real parts would send, and moves a model of the vehicle.

You need your vehicle's VMS running on the host first: see [Quickstart](../quickstart.md) and [Testing with CAN](../testing_with_can.md).

## What it is made of

| Part | Module | What it does |
|---|---|---|
| Simulated components | `SimulatorCore.SimulatedComponent` | One per piece of hardware the VMS drives. Each reads the frames the VMS sends that part, acts on the vehicle through efforts, and emits the frames the part would send from what the world reports. |
| Efforts | `SimulatorCore.Efforts` | What the simulated components ask of the vehicle each tick: drive torque at the driven wheels, brake torque, the front wheels' angle, the driveline's inertia. |
| World state | `SimulatorCore.WorldState` | What the world reports: each wheel's angle, spin and contact with the ground, and the body's motion. The simulated components measure it as the vehicle's sensors would. |
| Loop | `SimulatorCore.Hardware` | Every 20 ms: combines the simulated components' efforts, hands them to the world, and lets each simulated component report the world's state. |
| World | `SimulatorCore.World` | The behaviour of an external simulator that moves the vehicle from the efforts and reports its state. The Gazebo world is `RosBridge.Simulator.World`. |
| Flat ground | `SimulatorCore.FlatGround` | The model that moves the vehicle when no external simulator does: wheels that never slip, on flat ground. |

Everything except the Gazebo world lives in `simulator/core/`, which knows nothing about ROS.

A simulated component is the inverse of the VMS component that drives the same part. The VMS component sends a torque request and reads a status; the simulated component reads that request and sends that status. Both use the same frame names.

## Where it runs

The simulator runs on the host only, in one of two places:

| Where | Started by | Moves the vehicle |
|---|---|---|
| The simulator runner, `simulator/runner/`, a BEAM of its own | `./ovcs run <vehicle> --simulate` | `SimulatorCore.FlatGround`, with no world |
| Your vehicle's `ros` bridge | your vehicle's own switch, `OVCS_SIM=1` on the OVCS Mini reference vehicle | Gazebo, through `RosBridge.Simulator.World` |

The runner reads your vehicle's `simulator/0`: the vehicle's mass and dimensions, the simulated components, and the CAN topology and host mapping of their frames. `OvcsVehicle` documents its fields. The OVCS Mini reference vehicle's is in `vehicles/ovcs_mini/lib/ovcs_mini.ex`.

In the `ros` bridge, the bridge's host configuration lists a `:simulated_hardware` component, and its host CAN topology declares the simulated hardware's frames. On the vehicle, neither exists.

[Simulation](../../compose/local/simulation/README.md) runs the OVCS Mini reference vehicle against Gazebo. [Command paths](../ros2/commands.md) follows one 20 ms tick through the loop.

## Run your vehicle in simulation

Start your vehicle with its simulated hardware. On the OVCS Mini reference vehicle:

```sh
./ovcs run ovcs_mini --simulate
```

`run` starts the simulator runner first, then asks it over Erlang RPC until its simulated hardware is ready:

```text
Waiting for ovcs-mini-simulator@<host> to be ready before starting the vehicle
```

Only then does it start the VMS and the other BEAMs, so the VMS boots against hardware that already answers, as on the vehicle. A VMS that boots first finds its parts silent and can latch `FAILURE`.

> [!WARNING]
> Don't set your vehicle's `ros` bridge switch with `--simulate`, such as `OVCS_SIM=1` on the OVCS Mini. Both would then answer the VMS's frames.

`run` stops with an error if the runner exits or is not ready within 60 seconds. It refuses a vehicle with no `simulator/0`.

In another terminal, attach to it:

```sh
./ovcs attach ovcs_mini
```

The decoded `vms_status` frame should read `status="OK"`. The runner's output appears only in the `run` terminal, prefixed `[simulator]`.

## Pages

- [Simulate a component](./simulate_a_component.md): write the simulated component for a part your VMS drives, declare its frames and wire it into your vehicle.
