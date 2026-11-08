# SimulatorCore

The parts of the simulator that know nothing about ROS: simulated pieces of hardware, each the inverse of the VMS component that drives it, and the motion model they act on.

| Module | Role |
|---|---|
| `SimulatorCore.SimulatedComponent` | The behaviour of one piece of a vehicle's hardware emulated on CAN: it reads the frames the VMS sends it, acts on the motion model, and reports what the real hardware would |
| `SimulatorCore.SimulatedComponents.*` | The simulated components, named after the VMS components they stand in for: `OVCS.GenericController`, `OVCS.RadioControl`, `Vesc.MotorController`, `Traxxas.Steering` |
| `SimulatorCore.Vehicle` | The simulated vehicle's motion: commanded speed, steering, and how far and how fast the wheels turned. Pure |

A simulated component's callbacks are pure: a test drives one by calling `init/1`, `handle_frame/4`, `actuations/3` and `report/3` with signals and a `SimulatorCore.Vehicle`, with no CAN bus. The loop that runs them against a VMS over CAN, `RosBridge.Simulator.Hardware`, lives in the [ROS bridge](../../bridges/ros_bridge/README.md); the guide, [Simulation](../../compose/local/simulation/README.md), explains how a vehicle runs against it.

## Testing

```sh
mix test --no-start
```
