# SimulatorCore

The parts of the simulator that know nothing about ROS: simulated pieces of hardware, each the inverse of the VMS component that drives it, the motion model they act on, and the loop that runs them against a VMS over CAN.

| Module | Role |
|---|---|
| `SimulatorCore.SimulatedComponent` | The behaviour of one piece of a vehicle's hardware emulated on CAN: it reads the frames the VMS sends it, acts on the motion model, and reports what the real hardware would |
| `SimulatorCore.SimulatedComponents.*` | The simulated components, named after the VMS components they stand in for: `OVCS.GenericController`, `OVCS.RadioControl`, `Vesc.MotorController`, `Traxxas.Steering` |
| `SimulatorCore.Vehicle` | The simulated vehicle's motion: commanded speed, steering, and how far and how fast the wheels turned. Pure |
| `SimulatorCore.Efforts` | What simulated actuators ask of the vehicle in one tick: drive and brake torques at the wheels, the front wheels' angle, the driveline's inertia. Pure |
| `SimulatorCore.WorldState` | What a simulated world reports of the vehicle: each wheel's angle, spin and contact with the ground, and the body's motion. Pure |
| `SimulatorCore.FlatGround` | A world for when no external simulator owns the vehicle's dynamics: efforts move one rigid body on wheels that never slip, on flat ground. Pure |
| `SimulatorCore.Hardware` | The loop: every tick it collects the simulated components' actuations, advances the motion model, lets them report, and hands the motion to the world |
| `SimulatorCore.World` | The behaviour of what moves the vehicle: it takes the motion and reports how far the wheels turned. Gazebo's is `RosBridge.Simulator.World`, in the [ROS bridge](../../bridges/ros_bridge/README.md) |

A simulated component's callbacks are pure: a test drives one by calling `init/1`, `handle_frame/4`, `actuations/3` and `report/3` with signals and a `SimulatorCore.Vehicle`, with no CAN bus. The loop is tested against a test world the same way. [Simulate a component](../../docs/simulator/simulate_a_component.md) writes one and wires it into a vehicle; [Simulation](../../compose/local/simulation/README.md) runs a vehicle against Gazebo.

## Testing

```sh
mix test --no-start
```
