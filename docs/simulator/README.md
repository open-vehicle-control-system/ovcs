---
title: "Simulator"
description: How OVCS runs your vehicle's VMS unchanged against simulated hardware on virtual CAN, and what the simulator is made of.
---

The simulator runs your vehicle's VMS as it runs on the vehicle, against simulated hardware instead of real parts. The VMS sends its usual CAN frames on virtual CAN interfaces. Simulated hardware answers them with the frames the real parts would send, and moves a model of the vehicle.

You need your vehicle's VMS running on the host first: see [Quickstart](../quickstart.md) and [Testing with CAN](../testing_with_can.md).

## What it is made of

| Part | Module | What it does |
|---|---|---|
| Simulated components | `SimulatorCore.SimulatedComponent` | One per piece of hardware the VMS drives. Each reads the frames the VMS sends that part, acts on the vehicle's motion, and emits the frames the part would send. |
| Motion model | `SimulatorCore.Vehicle` | The vehicle's speed, steering angle and wheel turns, from the simulated components' actuations. It knows no hardware. |
| Loop | `SimulatorCore.Hardware` | Every 20 ms: collects the actuations, steps the motion model, lets each simulated component report, and hands the motion to the world. |
| World | `SimulatorCore.World` | What moves the vehicle and measures its wheels. The Gazebo world is `RosBridge.Simulator.World`. |

Everything except the Gazebo world lives in `simulator/core/`, which knows nothing about ROS.

A simulated component is the inverse of the VMS component that drives the same part. The VMS component sends a torque request and reads a status; the simulated component reads that request and sends that status. Both use the same frame names.

## Where it runs

The simulator runs in your vehicle's `ros` bridge, on the host only. The bridge's host configuration lists a `:simulated_hardware` component, and its host CAN topology declares the simulated hardware's frames. On the vehicle, neither exists. The OVCS Mini reference vehicle selects this configuration when `OVCS_SIM=1` is set; your vehicle can use the same switch.

[Simulation](../../compose/local/simulation/README.md) runs the OVCS Mini reference vehicle against Gazebo. [Command paths](../ros2/commands.md) follows one 20 ms tick through the loop.

## Pages

- [Simulate a component](./simulate_a_component.md): write the simulated component for a part your VMS drives, declare its frames and wire it into your vehicle.
