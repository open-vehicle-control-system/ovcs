---
title: "Writing a component"
description: The GenServer recipe every OVCS driver follows (CAN in, CAN out, bus messages, metrics, actions) and where your component's code goes.
---

A component is a supervised process, almost always a GenServer, that your VMS composer's `children/0` starts. It subscribes to the CAN frames it cares about, emits frames on a period, exchanges `%OvcsBus.Message{}` with other components, publishes the metrics your dashboard reads, and answers actions from dashboard buttons. Every driver in `vms_core` follows that recipe, and your vehicle's own components follow it too. This guide walks through each part with snippets taken from the framework drivers and the reference vehicles, then lists the drivers the framework ships.

[Architecture](./architecture.md#the-component-pattern) has the short version of the pattern; this page is the one to keep open while you write code.

## Where a component lives

Two places, and the choice is about scope, not size:

- **In your vehicle**, under `vehicles/<vehicle>/lib/<vehicle>/vms/`. Anything specific to your hardware, your wiring or your data goes here. The reference vehicles do this: OVCS1's [`Ovcs1.Vms.OVCSCANForwarder`](../vehicles/ovcs1/lib/ovcs1/vms/ovcs_can_forwarder.ex) republishes body state on the OVCS bus, and OBD2's [`Obd2.Vms.Diagnostics`](../vehicles/obd2/lib/obd2/vms/diagnostics.ex) and [`Obd2.Vms.Discovery`](../vehicles/obd2/lib/obd2/vms/discovery.ex) are a complete vehicle-local feature set built from components. Its frames go in your vehicle's `priv/can/vms.yml`.
- **In the framework**, under `vms/core/lib/vms_core/components/<manufacturer>/`, as a `VmsCore.Components.*` module. A driver for a part other vehicles could use belongs here, with its frame specs in [`libraries/ovcs_can/priv/can/components/`](../libraries/ovcs_can/priv/can/components). The rule from [Community](./community.md#contributing): the cores stay free of vehicle-specific code, and something your vehicle needs that the framework cannot express is a separate framework pull request.

Start in your vehicle. Moving a module into `vms_core` later is a rename; the recipe is the same.

The composer starts a component with a `{Module, args}` tuple, which uses the `child_spec/1` that `use GenServer` generates. Its id is the module name, so a module you run twice needs a distinct id: either the explicit map form OVCS1 uses for its three `OVCS.GenericController` children, or a `child_spec/1` keyed on `:process_name`, as [`OVCS.InputCurve`](../vms/core/lib/vms_core/components/ovcs/input_curve.ex) does:

```elixir
def child_spec(%{process_name: process_name} = args) do
  %{id: process_name, start: {__MODULE__, :start_link, [args]}}
end

def start_link(%{process_name: process_name} = args) do
  GenServer.start_link(__MODULE__, args, name: process_name)
end
```

A single-instance component registers under `__MODULE__`, and that name is the `source` of everything it publishes.

## The skeleton

[`OVCS.WaterPump`](../vms/core/lib/vms_core/components/ovcs/water_pump.ex) is the smallest real driver and has every structural piece: options from the composer, a bus subscription, a periodic loop, a handler gated on a configured source, a catch-all, and a generic controller output.

```elixir
defmodule VmsCore.Components.OVCS.WaterPump do
  use GenServer
  alias OvcsBus, as: Bus
  alias VmsCore.Components.OVCS.GenericController

  @loop_period 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{
        controller: controller,
        power_relay_pin: power_relay_pin,
        selected_gear_source: selected_gear_source
      }) do
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    Bus.subscribe("messages")

    {:ok,
     %{
       loop_timer: timer,
       controller: controller,
       power_relay_pin: power_relay_pin,
       selected_gear: :parking,
       selected_gear_source: selected_gear_source,
       enabled: false
     }}
  end

  @impl true
  def handle_info(:loop, state), do: {:noreply, toggle_waterpump(state)}

  def handle_info(%Bus.Message{name: :selected_gear, value: selected_gear, source: source}, state)
      when source == state.selected_gear_source do
    {:noreply, %{state | selected_gear: selected_gear}}
  end

  def handle_info(%Bus.Message{}, state), do: {:noreply, state}

  defp toggle_waterpump(state) do
    case {state.enabled, state.selected_gear} do
      {true, :parking} ->
        :ok = GenericController.set_digital_value(state.controller, state.power_relay_pin, false)
        %{state | enabled: false}

      {false, gear} when gear == :drive or gear == :reverse ->
        :ok = GenericController.set_digital_value(state.controller, state.power_relay_pin, true)
        %{state | enabled: true}

      _ ->
        state
    end
  end
end
```

OVCS1 wires it with `{OVCS.WaterPump, %{controller: Vms.FrontController, power_relay_pin: 4, selected_gear_source: Managers.Gear}}`. The pattern-matched map in `init/1` is the component's option list: a missing key fails at boot, not at runtime.

The catch-all `handle_info(%Bus.Message{}, state)` is required. Every subscriber to `"messages"` receives every message on the bus, and without it the first unrelated message crashes the process.

For a vehicle-level state machine rather than a driver, start from your vehicle's own `Vms` module: the scaffold generates it from [`priv/templates/vehicle/lib/`](../libraries/ovcs_vehicle/priv/templates/vehicle/lib) with the same shape, deciding `ready_to_drive` and `vms_status` on a 20 ms loop.

## Receiving frames

Declare the frame in your topology YAML under the network's `received_frames`, then subscribe to it by name:

```elixir
alias Cantastic.{Frame, Receiver, Signal}

# in init/1, from Nissan.LeafAZE0.Inverter
Receiver.subscribe(self(), :leaf_drive, ["inverter_status", "inverter_temperatures"])
```

`Receiver.subscribe/4` takes one frame name or a list, and an optional `%{errors: true}` (below). The name must exist on that network: the receiver matches it against its specifications and an unknown name takes the network's receiver process down.

Each decoded frame arrives as `{:handle_frame, %Cantastic.Frame{}}`. `name` is the YAML name and `signals` is a map from signal name to `%Cantastic.Signal{}`, whose `value` is already scaled:

```elixir
def handle_info({:handle_frame, %Frame{name: "inverter_status", signals: signals}}, state) do
  %{
    "inverter_output_voltage" => %Signal{value: inverter_output_voltage},
    "effective_torque" => %Signal{value: effective_torque},
    "rotations_per_minute" => %Signal{value: rotation_per_minute}
  } = signals

  {:noreply,
   %{
     state
     | rotation_per_minute: abs(rotation_per_minute),
       effective_torque: effective_torque,
       inverter_output_voltage: inverter_output_voltage
   }}
end
```

Store the values in state and publish them on the loop, or publish as the frame arrives when a consumer needs every sample (the VESC driver does this for rotation).

### Noticing a missing frame

Cantastic runs one `ReceivedFrameWatcher` per received frame. It compares arrival times with the frame's `frequency` and marks the frame dead after too many late ones. Its thresholds come from the frame YAML; the defaults are in Cantastic's [`frame_specification.ex`](https://github.com/open-vehicle-control-system/cantastic/blob/main/lib/cantastic/frame_specification.ex):

| Key | Default | Meaning |
|---|---|---|
| `frequency` | none, required to watch | expected period, ms |
| `allowed_frequency_leeway` | `10` | ms of lateness tolerated per frame |
| `allowed_missing_frames` | `5` | late frames before the frame is declared missing |
| `allowed_missing_frames_period` | `5000` | ms after which the late count resets |
| `required_on_time_frames` | `5` | on-time frames before a dead frame is alive again |

Watching is off until you call `ReceivedFrameWatcher.enable/2`. Then read the result in one of two ways, both used in the framework:

```elixir
# Poll it on the loop, as Orion.Bms2 and OVCS.GenericController do
:ok = ReceivedFrameWatcher.enable(:orion_bms, "bms_status_1")
{:ok, is_alive} = ReceivedFrameWatcher.is_alive?(:orion_bms, "bms_status_1")

# Or be told, as Vesc.MotorController is
:ok = Receiver.subscribe(self(), network, [frames.status, frames.status_5], %{errors: true})
:ok = ReceivedFrameWatcher.enable(network, frames.status)

def handle_info({:handle_missing_frame, network, name}, state)
    when network == state.network and name == state.frames.status do
  broadcast(state, :rotation_per_minute, nil, Units.revolution_per_minute())
  {:noreply, state}
end
```

When a source goes quiet, publish `nil` (the VESC driver) or an `:is_alive` flag (the BMS and generic controllers) rather than holding the last value. A stale reading that looks live is worse than no reading.

## Emitting frames

Declare the frame under the network's `emitted_frames` with a `frequency`. Cantastic starts one emitter process per frame; your component configures it once and then only changes its data. The emitter sends on its own timer at the YAML frequency, whatever your loop does.

```elixir
alias Cantastic.Emitter

# from Ovcs1.Vms.OVCSCANForwarder
:ok =
  Emitter.configure(:ovcs, "drivetrain_status", %{
    parameters_builder_function: :default,
    initial_data: %{"speed" => @zero, "rotation_per_minute" => @zero},
    enable: true
  })

# later, when the value changes
:ok =
  Emitter.update(:ovcs, "drivetrain_status", fn data ->
    %{data | "speed" => state.speed}
  end)
```

`Emitter.configure/3` takes the network, the frame name and a map:

- `initial_data`: the emitter's data, usually one key per signal.
- `parameters_builder_function`: `:default` sends the data as the signal values. A function receives the data before each send and returns `{:ok, parameters, data}`, which is how a rolling counter or checksum is computed per frame. From the Leaf inverter:

  ```elixir
  defp torque_frame_parameters_builder(data) do
    counter = data["counter"]

    parameters = %{
      "requested_torque" => data["requested_torque"],
      "counter" => Util.shifted_counter(counter),
      "crc" => &Util.crc8/1
    }

    {:ok, parameters, %{data | "counter" => Util.counter(counter + 1)}}
  end
  ```

- `enable`: `true` starts sending immediately; omitted, the emitter waits.

`Emitter.enable/2` and `Emitter.disable/2` take one frame name or a list, so a driver can stop talking to a part it has powered down. The inverter enables its three frames when the ignition contact goes `:on` and disables them when it goes `:off`. `Emitter.send_frame/2` sends a configured frame once, and `Emitter.forward/2` re-emits a received `%Frame{}` on another network.

## Talking to other components

Components never call each other's modules for data. Each publishes on the `"messages"` topic and names itself as `source`; each consumer is told, by the composer, which source to listen to. That is what the `*_source` options are: `speed_source: Polo9N.ABS` in OVCS1, `speed_source: OVCS.VehicleMotion` in OVCS Mini, same manager code.

```elixir
Bus.broadcast("messages", %Bus.Message{
  name: :rotation_per_minute,
  value: state.rotation_per_minute,
  source: __MODULE__
})
```

`%OvcsBus.Message{}` enforces `:name` and `:source`, and `OvcsBus.broadcast/2` rejects a `nil` source. `:unit` is optional and comes from [`OvcsBus.Units`](../libraries/ovcs_bus/lib/ovcs_bus/units.ex) (`Units.volt()`, `Units.revolution_per_minute()`, …), one function per unit so a typo fails to compile. The broadcast reaches every BEAM in the vehicle's mesh; [`libraries/ovcs_bus/README.md`](../libraries/ovcs_bus/README.md) has the transport.

An actuator adds one step: it does not follow a fixed commander, it follows whichever one `Managers.ControlLevel` currently names. The manager publishes `:requested_throttle_source` (and the steering, direction and gear equivalents); the actuator stores it, then gates the request on it. From the Leaf inverter:

```elixir
def handle_info(
      %Bus.Message{name: :requested_throttle_source, value: requested_throttle_source, source: source},
      state
    )
    when source == state.selected_control_level_source do
  # A level that commands nothing: zero, or the last request would be held.
  requested = if is_nil(requested_throttle_source), do: @zero, else: state.requested_throttle
  {:noreply, %{state | requested_throttle_source: requested_throttle_source, requested_throttle: requested}}
end

def handle_info(%Bus.Message{name: :requested_throttle, value: requested_throttle, source: source}, state)
    when source == state.requested_throttle_source do
  {:noreply, %{state | requested_throttle: requested_throttle}}
end
```

Copy the zeroing. With a `nil` source no request matches the second clause, and without it the last throttle would stay applied after a switch to a level that commands nothing. [`throttle_source_switching_test.exs`](../vms/core/test/components/throttle_source_switching_test.exs) checks it for every throttle consumer. [Control levels](./vehicle_package.md#control-levels-who-commands-and-which-ros-node) explains the source maps.

## Metrics the dashboard shows

There is no separate metrics API: publishing on the bus is publishing a metric. [`VmsCore.Metrics`](../vms/core/lib/vms_core/metrics.ex) subscribes to `"messages"` and keeps the last `value` and `unit` of every message, keyed by `source` and `name`. The dashboard's `MetricsChannel` subscribes to `%{module:, key:}` pairs and pushes those values on its interval.

A dashboard row therefore names the publisher and the message name, as in the scaffold's [`dashboard_page.ex`](../libraries/ovcs_vehicle/priv/templates/vehicle/lib/{{name}}/vms/composer/dashboard/dashboard_page.ex):

```elixir
rows: [
  %{type: :metric, name: "Status", module: Vms, key: :vms_status},
  %{type: :metric, name: "Ready to drive", module: Vms, key: :ready_to_drive}
]
```

`module:` is the `source`, not necessarily a module: for a component started with `process_name: Vms.MainController`, the row reads `module: Vms.MainController`. The channel resolves both with `String.to_existing_atom/1`, so a key must already exist as an atom in the VMS, which it does once your component's code mentions it.

Publish metrics on the loop even when they have not changed: a dashboard opened later then shows a value at once. [Dashboard pages](./dashboard_pages.md) has every block and row type.

## Actions

A dashboard button calls `POST /api/actions`. [`VmsApiWeb.Api.ActionsController`](../vms/api/lib/vms_api_web/controllers/api/actions_controller.ex) turns `params["module"]` into an existing atom and calls `module.trigger_action(action, params)`, matching the result against `:ok`. Return exactly `:ok`; anything else is a server error.

The call runs in the HTTP request process, not your component's, so real drivers forward it with a `GenServer.call`. From [`OVCS.SteeringColumn`](../vms/core/lib/vms_core/components/ovcs/steering_column.ex):

```elixir
def trigger_action("set_pid_parameter", %{"parameter" => parameter, "value" => value})
    when parameter in ["kp", "ki", "kd"] do
  GenServer.call(__MODULE__, {:set_pid_parameter, parameter, value})
end
```

The params are the row's `module` and `action`, its `extra_parameters` merged in, and `value` as a string when the row has an input. The matching row, from OVCS1's steering column page:

```elixir
%{
  type: :action,
  name: "Kp",
  input_type: :number,
  step: "0.01",
  input_name: "Set",
  module: SteeringColumn,
  action: "set_pid_parameter",
  extra_parameters: %{"parameter" => "kp"},
  status_metric_key: :kp
}
```

`input_type` is `:button`, `:number` or `:toggle`; `status_metric_key` names one of the module's metrics that the row displays next to the control. Parse `value` yourself: it arrives as a string.

## Driving generic controller pins

Relays, PWM outputs and analog inputs on an Arduino [generic controller](./generic_controllers.md) go through the `OVCS.GenericController` process the composer started for that board. Pass its process name to your component as an option (`controller: Vms.FrontController`) and call:

```elixir
:ok = GenericController.set_digital_value(state.controller, state.power_relay_pin, true)
{:ok, on?} = GenericController.get_digital_value(state.controller, state.power_relay_pin)
{:ok, raw} = GenericController.get_analog_value(state.controller, state.throttle_a_pin)
:ok = GenericController.set_external_pwm(state.controller, state.external_pwm_id, true, duty_cycle_percentage, frequency)
```

These are the four calls the shipped drivers use. The controller must be started with `control_digital_pins: true` for digital outputs, and list the PWM in `enabled_external_pwms` for `set_external_pwm/5`; the pin must be configured in your composer's `generic_controllers/0` map, which the board receives when it is adopted. The digital value is sent on the controller's request frame at its YAML frequency, not immediately.

## Timing

The shipped drivers loop every 10 ms (`@loop_period 10`), with a few exceptions: `OVCS.GenericController` and `OVCS.VehicleMotion` at 50 ms, OVCS1's `OVCSCANForwarder` at 100 ms, the scaffold's vehicle module at 20 ms. Pick the slowest period that serves the consumer; emitted frames keep their own YAML period regardless.

The loop is `:timer.send_interval/2` delivering `:loop` to your mailbox. It is handled after whatever messages are already queued, so the BEAM gives you soft real-time: fast and regular, with no hard deadline. Keep `handle_info/2` short, never block in it, and put work that takes longer in its own process. Each network's `Receiver` process runs at `:high` priority. Anything that must hold when the VMS stalls, such as a controller dropping its outputs, lives in the part's firmware, not in a component.

## Framework drivers and their networks

Most `vms_core` drivers hard-code the network name they talk on, the name OVCS1 uses for that bus. To use one, your topology YAML and `default_can_mapping/1` must declare a network with that name, carrying the frames the driver subscribes to and emits. `Vesc.MotorController` is the exception and takes `network:`.

Sources are the `*_source` options; "controller" means a generic controller process plus the pin options named.

| Driver | Network | Options | Publishes |
|---|---|---|---|
| `Nissan.LeafAZE0.Inverter` | `leaf_drive` | control level, gear, contact sources; `controller`, `power_relay_pin` | rpm, torques, output voltage, temperatures, `:ready_to_drive` |
| `Nissan.LeafAZE0.Charger` (no reference vehicle) | `leaf_drive` | `maximum_power_for_charger_source` | charge power, AC voltage, charging state |
| `Orion.Bms2` | `orion_bms` | `controller`, `ready_relay_pin` | pack voltage, current, SoC, temperatures, relay states, `:is_alive` |
| `Evpt.Evpt23Charger` | `orion_bms` | none | output voltage and current, protection flags |
| `Volkswagen.Polo9N.ABS`, `.IgnitionLock`, `.PassengerCompartment` | `polo_drive` | none | `:speed` and wheel speeds; `:contact`; door, beam and handbrake states |
| `Volkswagen.Polo9N.Dashboard` | `polo_drive` | contact, rpm sources | nothing (drives the cluster) |
| `Volkswagen.Polo9N.PowerSteeringPump` | `misc` | gear source | nothing |
| `Bosch.IBoosterGen2` | `misc` | control level, contact sources; `controller`, `power_relay_pin` | rod position, flow rate, `:manual_breaking`, `:status` |
| `OVCS.SteeringColumn` | `misc` | control level source; `power_relay_controller`, `power_relay_pin`, `actuation_controller`, `direction_pin`, `external_pwm_id` | angle, angular speed, calibration, PID gains |
| `OVCS.GenericController` | `ovcs` | `process_name`, `control_digital_pins`, `control_other_pins`, `enabled_external_pwms` | `:is_alive`, `:status`, `received_*` / `requested_*` pins |
| `OVCS.RadioControl.*` | `ovcs` | `radio_control_channel` | the `requested_*` value of its channel |
| `OVCS.RosActuatorCommand.*`, `OVCS.RosVelocityCommand` | `ovcs` | none; `wheelbase`, `steering_limit`, `max_speed` | `:requested_throttle`, `:requested_steering`, `:requested_direction` |
| `OVCS.Infotainment` | `ovcs` | none | `:requested_gear` |
| `OVCS.VehicleMotion` | `ovcs` | rotation and control level sources, ratio, wheel radius, `steering_limit` | `:speed`, `:wheel_rotation_per_minute` |
| `OVCS.Status`, `VmsCore.Status` | `ovcs` | BMS source; ready-to-drive and VMS status sources | pack and VMS status frames, `:resetting` |
| `Managers.ControlLevel`, `Managers.Gear` | `ovcs` (Gear) | the source maps; see [Your vehicle package](./vehicle_package.md) | selected level and sources; `:selected_gear` |
| `Vesc.MotorController` | `network:` | `process_name`, control level source, `max_rotation_per_minute`, `pole_pairs`, caps | rpm, direction, motor current, input voltage |
| `OVCS.HighVoltageContactors`, `OVCS.WaterPump`, `OVCS.ThrottlePedal`, `Polo9N.FakeOilPressureSensor`, `Traxxas.Steering`, `Traxxas.MotorController` (no reference vehicle) | none, through a controller | a controller and its pins, plus sources | `:ready_to_drive`; nothing; `:requested_throttle` and calibration; nothing; nothing; throttle, pulse width |
| `Matek.PM12S3` | none, through a controller | `controller`, `voltage_pin`; `current_pin` with the sensor's `current_scale` and `current_offset` | `:voltage`, `:current` |
| `OVCS.PulseRotationSensor`, `OVCS.RotationFusion`, `OVCS.InputCurve` | none, bus only | controller or sources, see the moduledoc | `:rotation_per_minute`; fused rpm; shaped `:requested_throttle` |

The composers in [OVCS1](../vehicles/ovcs1/lib/ovcs1/vms/composer.ex) and [OVCS Mini](../vehicles/ovcs_mini/lib/ovcs_mini/vms/composer.ex) are worked examples of every option; the moduledoc of each driver is the reference.

## Testing it on vcan

Boot your vehicle with `./ovcs run <vehicle>`, inject the frames your component receives with `cansend` on the interface your host mapping gives that network, and watch its output with `candump` or the CAN pane of `./ovcs attach <vehicle>`. [Testing with CAN](./testing_with_can.md) has the commands and the replay workflow. Your metrics appear on the dashboard as soon as a row names them.

For logic, test the handlers without the CAN stack. The `vms_core` tests call `handle_info/2` directly with a hand-built state and a `%OvcsBus.Message{}`, then assert on the returned state; [`throttle_source_switching_test.exs`](../vms/core/test/components/throttle_source_switching_test.exs) is a short example.

## Next steps

- [Your vehicle package](./vehicle_package.md): the composer that starts your component, and the control-level source maps.
- [Testing with CAN](./testing_with_can.md): drive your component from `cansend` and captures.
- [Generic controllers](./generic_controllers.md): flash and adopt the boards your component switches.
- [VESC drivetrain](./vesc_drivetrain.md): a complete framework driver with its frames and settings.
