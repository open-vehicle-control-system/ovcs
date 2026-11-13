---
title: "Simulate a component"
description: Write the simulated component for a part your VMS drives, declare its CAN frames, wire it into your vehicle and test it.
---

Your vehicle runs in simulation once every part its VMS drives has a simulated component. This page writes one, declares its frames, wires it into your vehicle and tests it. The worked example is the OVCS Mini reference vehicle's steering servo, `SimulatorCore.SimulatedComponents.Traxxas.Steering`.

You need two things first:

- a VMS component for the part: see [Add a component](../vms/add_a_component.md);
- a `ros` bridge firmware in your vehicle's `bridge_firmwares/0`, which runs the simulator on the host: see [ROS bridge](../bridges/ros.md).

[Simulator](./README.md) explains the parts the simulated component plugs into.

## What the VMS expects from the part

Start from the VMS component, not from the hardware's datasheet. A simulated component answers exactly what its VMS component reads, and reads exactly what it sends. List three things from the VMS component and its frame YAMLs:

| Question | Where to look | Steering servo |
|---|---|---|
| Which frames does the VMS send the part? | the frames it emits | `main_controller_external_pwm0_request`, a duty cycle |
| Which frames does the VMS wait on, and how often? | the frames it subscribes to, their `frequency`, which ones are watched | none: the servo reports nothing |
| What must those frames say before the VMS is ready? | the readiness check of the component and of your vehicle's VMS | nothing |

Most parts report a status. A part whose status the VMS watches must send it from the start, at its frequency. A part that gates readiness must report the values that gate it.

## Write the module

Put the module where its part belongs:

- **A part other vehicles could use** goes in the framework, at `simulator/core/lib/simulator_core/simulated_components/<manufacturer>/`, with its tests in `simulator/core/test/`.
- **A part only your vehicle has** goes in your vehicle, under `vehicles/<vehicle>/lib/`, with its tests in your vehicle's `test/`.

Name it after the VMS component it inverts: `VmsCore.Components.Traxxas.Steering` becomes `SimulatorCore.SimulatedComponents.Traxxas.Steering`.

A simulated component implements the `SimulatorCore.SimulatedComponent` behaviour. Its callbacks are pure: they take values and return values, and `SimulatorCore.Hardware` does the CAN work.

| Callback | Called | Returns |
|---|---|---|
| `init/1` | once, with the options your vehicle gives | its state, the frames it reads, and the frames it emits with their first signal values |
| `handle_frame/4` | for each frame it reads | its new state |
| `actuations/3` | every 20 ms tick | how it acts on the vehicle's motion |
| `report/3` | every tick, after the motion steps | its new state, and signal values to merge into its emitted frames |

`actuations/3` and `report/3` are optional. `handle_frame/4` is required as soon as `init/1` lists a frame to read.

### Declare the frames in `init/1`

`init/1` names the frames by network and frame name, as your vehicle's CAN topology names them. The servo reads its generic controller's PWM request and emits nothing:

```elixir
def init(opts) do
  opts = Map.new(opts)
  controller = Map.get(opts, :controller, "main_controller")
  network = Map.get(opts, :network, :ovcs)

  state = %{
    steering_limit_rad: Map.fetch!(opts, :steering_limit_rad),
    steering_sign: Map.fetch!(opts, :steering_sign),
    neutral: Map.get(opts, :neutral, 0.0),
    angle: 0.0
  }

  {state, [{network, "#{controller}_external_pwm#{Map.get(opts, :pwm, 0)}_request"}], []}
end
```

An emitted frame is a `{network, frame_name, signals}` tuple. Cantastic sends it at its YAML `frequency` from the moment the simulator starts, with these values, until `report/3` changes them. Give a value for every signal except `static` and `checksum` ones, fillers included: `SimulatorCore.SimulatedComponents.OVCS.GenericController` gives its `"filler0"` a `0`.

Take each frame-name prefix as an option, as `:controller` does here. Your vehicle can then run the same simulated component more than once, as the OVCS1 reference vehicle runs three generic controllers.

### Read the VMS's frames in `handle_frame/4`

`handle_frame/4` receives the frame name and its decoded signals, `%Cantastic.Signal{}` values keyed by signal name. Keep what the frame commands in the state:

```elixir
def handle_frame(_name, %{"enabled" => %Signal{value: true}, "duty_cycle" => duty}, state, _now),
  do: %{state | angle: angle(duty.value / @duty_cycle_range, state)}

def handle_frame(_name, _signals, state, _now_ms), do: state
```

Recover the command with the arithmetic the VMS component used to build it, reversed. `SimulatorCore.SimulatedComponent.float/2` reads a scaled signal as a float, whichever way Cantastic decoded it.

### Act on the motion in `actuations/3`

Every tick, each simulated component returns how it acts on `SimulatorCore.Vehicle`:

| Actuation | Meaning |
|---|---|
| `{:acceleration, m_s2}` | a drive, signed along the vehicle's forward axis: a motor's torque over the vehicle's mass |
| `{:deceleration, m_s2}` | a brake, a magnitude that stops at standstill |
| `{:speed, m_s}` | a speed controller's setpoint, signed |
| `{:steering, rad}` | the front wheels' angle, positive to the left |

The servo turns the wheels:

```elixir
def actuations(state, _vehicle, _now_ms), do: [{:steering, state.angle}]
```

`SimulatorCore.Vehicle` documents how actuations from several simulated components combine.

### Report what the part measures in `report/3`

`report/3` receives the vehicle after the tick. Derive what the part would measure from two of its fields:

- `wheel_turns_step`, how far the wheels turned this tick, for counters such as a tachometer;
- `measured_speed_m_s`, how fast they turn, for rates such as an rpm.

Return signal values to merge into the frames you declared in `init/1`. `SimulatorCore.SimulatedComponents.Vesc.MotorController` reports both, through its gear ratio. `SimulatorCore.SimulatedComponent.decimal/2` encodes a float the way Cantastic encodes a scaled signal.

## Declare the frames in your vehicle's topology

The simulated hardware runs in your vehicle's `ros` bridge on the host, so the bridge's host topology declares its frames. The direction is the VMS's, reversed:

- a frame the VMS **receives** is one the bridge **emits**;
- a frame the VMS **emits** is one the bridge **receives**.

> [!WARNING]
> Cantastic refuses to start on an emitted frame without a `frequency`, or whose signals leave a gap or are out of order. Declare a filler signal for each unused bit range, as the frame YAMLs under `libraries/ovcs_can/priv/can/components/` do.

Keep these frames in a file of their own, `vehicles/<vehicle>/priv/can/bridges/ros_simulated_components.yml`, and import the same frame YAMLs your `vms.yml` imports. The OVCS Mini reference vehicle's file declares the servo's request:

```yaml
can_networks:
  ovcs:
    bitrate: 500000
    received_frames:
      - import!:../generic_controller/0x705_main_controller_external_pwm0_request.yml
```

> [!WARNING]
> Cantastic opens only the networks the CAN mapping names. List every network the simulated hardware uses in the bridge's host mapping, on the interface the VMS uses for it.

Merge the file into the bridge's topology on the host only. In your vehicle's `bridge_firmwares/0`, give the `ros` entry a `can_config_path` with a host and a target arm:

```elixir
"ros" => %{
  target: :ovcs_base_can_system_rpi4,
  bridges: [RosBridge],
  can_config_path: %{
    host: ["can/bridges/ros.yml", "can/bridges/ros_simulated_components.yml"],
    target: "can/bridges/ros.yml"
  },
  default_can_mapping: %{host: "ovcs:vcan0,misc:vcan1", target: "ovcs:spi0.0"}
}
```

[CAN frames and topology](../can_frames.md) describes the YAML format.

## Wire it into your vehicle

The simulated hardware must run only when you ask for it. Give your vehicle's `ros` bridge a second host configuration, used only in simulation, and select it in `ros_bridge_config(:host)`. The OVCS Mini reference vehicle reads `OVCS_SIM`:

```elixir
def ros_bridge_config(:host) do
  if simulation?(), do: ros_bridge_simulation_config(), else: ros_bridge_host_config()
end

defp simulation?, do: System.get_env("OVCS_SIM") in ["1", "true"]
```

List the simulated component in the `:simulated_hardware` component of that simulation configuration, with the options its module documents. Take the values from where your vehicle already keeps them, rather than repeating numbers. The OVCS Mini reference vehicle reads its geometry from `geometry/0`, and binds `drivetrain` to `OvcsMini.Vms.Composer.drivetrain/0`:

```elixir
{:simulated_hardware,
 [
   vehicle: %{wheelbase_m: geometry().wheelbase, wheel_radius_m: geometry().wheel_radius},
   wheel_joints: ~w(front_left_wheel_joint front_right_wheel_joint
                    rear_left_wheel_joint rear_right_wheel_joint),
   simulated_components: [
     {SimulatorCore.SimulatedComponents.Traxxas.Steering,
      steering_limit_rad: geometry().steering_limit,
      steering_sign: drivetrain.steering_sign,
      neutral: drivetrain.steering_trim}
   ]
 ]}
```

`wheel_joints` names the joints of your vehicle's Gazebo model whose turns the simulator measures. `vehicles/ovcs_mini/lib/ovcs_mini.ex` holds the complete configuration, with the Mini's four simulated components.

## Test it

Test the callbacks directly, with no CAN bus: build the signals the VMS would send, call `handle_frame/4`, and check what the part does. The servo's test feeds it a 20 % duty cycle. Its `servo` comes from a `setup` block that calls `init/1`, and `signals/1` wraps each value in a `%Cantastic.Signal{}`:

```elixir
test "reads the duty cycle as the VMS sends it, an integer share of 65 535", %{servo: servo} do
  frame = signals(%{"enabled" => true, "duty_cycle" => round(0.20 * 65_535)})
  steered = Steering.handle_frame("main_controller_external_pwm0_request", frame, servo, 0)
  assert_in_delta steered.angle, -(1 - 0.05) * 0.52, 1.0e-3
end
```

Restate in the test the arithmetic the VMS component applies, so a change on either side fails it. `simulator/core/test/simulator_core/simulated_components_test.exs` holds the framework's simulated component tests. Run them in `simulator/core/`:

```sh
mix test --no-start
```

You should see every test pass, with no CAN interface needed.

## Run your vehicle against it

Start your vehicle with its simulated configuration. On the OVCS Mini reference vehicle, against Gazebo:

```sh
OVCS_SIM=1 ZENOH_ENDPOINT_IP=127.0.0.1 ./ovcs run ovcs_mini
```

The same command runs your vehicle with its own name, once it reads `OVCS_SIM` as above. `./ovcs run` creates the vcan interfaces your VMS's host mapping names. In another terminal, attach to it:

```sh
./ovcs attach ovcs_mini
```

The CAN pane should show the simulated hardware's frames at their frequencies, and the decoded `vms_status` frame should read `status="OK"`. [Simulation](../../compose/local/simulation/README.md) starts Gazebo and drives the vehicle.
