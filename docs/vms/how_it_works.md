---
title: How the VMS works
description: The VMS supervision tree, the component pattern, the managers for the gear and the control levels, and how metrics and actions reach the dashboard.
---

The VMS is one OTP application, `VmsCore`, that supervises the framework's own processes and whatever your vehicle's composer returns from `children/0`. [VMS](./README.md) covers what the VMS is and where it runs.

## Supervision tree

```text
VmsCore.Application                          (framework)
├── VmsCore.Repo               SQLite: throttle calibration and other persisted data
├── Ecto.Migrator              applies pending migrations on boot (skipped when RELEASE_NAME is set)
├── VmsCore.Metrics            the last value of every bus message, for the dashboard and API
├── VmsCore.NetworkInterfaces  CAN interface statistics (errors, bus state)
├── OvcsBus.Cluster            connects this BEAM to the vehicle's other firmwares
└── composer children          (your package, selected by VEHICLE)
    ├── VmsCore.Status         VMS heartbeat (0x1A0), ready-to-drive, controller reset (0x1AA)
    ├── Components             hardware drivers (inverter, BMS, brakes, body, …)
    ├── Managers               control level, gear
    └── Generic controllers    Arduino I/O drivers
```

The supervisor is `one_for_one`: a driver that crashes restarts alone. `OvcsBus`'s `Phoenix.PubSub` runs in its own OTP application, `:ovcs_bus`, so every BEAM that depends on the library reaches it by name.

`VmsCore.Status` is in your composer's children rather than the framework's because its sources are yours. It relays the `:vms_status` and `:ready_to_drive` of the components you name into the `vms_status` frame the generic controllers watch. At boot it also resets the generic controllers once, since a VMS reboot always outlasts their heartbeat timeout.

## The component pattern

Every hardware driver is a GenServer with the same recipe:

1. **Subscribes to CAN frames** with `Cantastic.Receiver.subscribe/3`, receiving `{:handle_frame, %Cantastic.Frame{}}`.
2. **Subscribes to internal messages** with `OvcsBus.subscribe/1`, receiving `%OvcsBus.Message{}`.
3. **Runs a periodic loop**, typically every 10 ms, to emit CAN frames and broadcast its metrics.
4. **Exposes actions** through `trigger_action/2`, so a dashboard button can call into it.

Components never import each other. A component that needs the vehicle speed is told which module publishes it, in the init configuration the composer gives it. It matches on `source`:

```elixir
alias OvcsBus, as: Bus

# Broadcasting a metric
Bus.broadcast("messages", %Bus.Message{
  name: :speed,
  value: Decimal.new("45.2"),
  source: VmsCore.Components.Volkswagen.Polo9N.ABS
})

# Receiving it in another component
def handle_info(%Bus.Message{name: :speed, value: speed, source: source}, state)
    when source == state.speed_source do
  {:noreply, %{state | speed: speed}}
end
```

The wiring is in the composer: swap the ABS module for another speed source and only the composer changes.

A message reaches the subscribers of its own node only, so a slow link to another board cannot stall a drivetrain component. [The OVCS bus](../bus/README.md) explains the bus and how its messages leave the VMS. [Add a component](./add_a_component.md) writes one from scratch.

## Managers

Managers hold logic that spans several components. Both are framework modules your composer supervises and configures.

- **`VmsCore.Managers.ControlLevel`** decides who commands the vehicle and routes each actuator's request from that commander. It has its own section below.
- **`VmsCore.Managers.Gear`** turns the requested gear or direction into the selected gear, emits it on `gear_status` (`0x600`) and broadcasts `:selected_gear`. Its rules:
  - With the contact off, it selects parking.
  - Losing ready-to-drive while in drive or reverse drops to neutral.
  - Parking, drive and reverse need the vehicle below 1 km/h and the throttle request below 0.05.
  - Drive and reverse also need ready-to-drive.
  - An unknown speed, a source gone quiet, never counts as stopped.

## Control levels

`VmsCore.Managers.ControlLevel` arbitrates between commanders. It reads two independent switches on the radio transmitter, because authority and autonomy are different questions:

| Component | Values | Answers |
|---|---|---|
| `OVCS.RadioControl.RequestedControlLevel` | `:manual` / `:radio` / `:ros` | who has authority |
| `OVCS.RadioControl.RequestedRosCommander` | `:teleop` / `:autonomous` | which ROS node, when ROS does |

`:ros` means the vehicle takes its commands from the ROS bridge, **not** that it drives itself. A human on a gamepad and a planner reach the VMS over the same topics and CAN frames. The commander switch says which of them commands. Only `:ros` consults it, so the second switch has no effect in `:manual` and `:radio`.

Both switches only *request*. The manager refuses unsafe moves: in motion, not ready to drive, or while a fault has forced a lower level. `:ros` is reachable only from `:radio`, so reaching it takes two deliberate moves of the switch, with the middle position in between. A refused request is logged once, with the reason.

Two things drop `:ros` to `:radio`:

- The radio trigger (`radio_braking_source`).
- An optional `rotation_fault_source`. A `OVCS.RotationFusion` whose sources disagree (`:cross_check_fault`) means the odometry, and every costmap cell placed with it, can no longer be trusted. The OVCS Mini reference vehicle wires its motor rotation fusion there.

Either one forces `:radio` until the switch comes back to `:radio` or below, and `:ros` is refused while it lasts.

The manual brake, or losing ready-to-drive, forces `:manual` from any level. The full list of what the framework enforces is in [Safety mechanisms](../architecture.md#safety-mechanisms-in-the-framework).

### Channel layout

Which transmitter channel each component reads is a vehicle decision. The [radio control bridge](../bridges/radio_control.md) copies the receiver's channels 1 to 8 onto `0x2A0` and `0x2A1` unchanged, and each composer names the channel every component reads. The two reference vehicles with radio control use:

| Purpose | OVCS Mini | OVCS1 |
|---|---|---|
| Steering | 1 | 1 |
| Throttle (and `radio_braking`, the human takeover) | 2 | 2 |
| Control level | 6 | 3 |
| Direction (the reverse button, through `Managers.Gear`) | 7 | 4 |
| ROS commander | 5 | not wired |

Switch positions are 1000, 1500 and 2000 µs with a margin of 100. A position outside every margin falls back to the safe one: `:manual` for the level, `:teleop` for the commander, `:forward` for direction.

The Mini's link is ExpressLRS in MAVLink mode, which forces Hybrid switch mode. Channel 5 is the link's arm channel and only carries 1000 or 2000. Channels 6 to 8 are 3-position and reach the bus. That is why the three-position level is on 6 and the two-position commander on 5.

### Source maps

Each `requested_*_sources` map in a composer is keyed by level. The `:ros` entry is itself keyed by commander:

```elixir
requested_throttle_sources: %{
  manual: OVCS.ThrottlePedal,
  radio: OVCS.RadioControl.Throttle,
  ros: %{teleop: OVCS.RosActuatorCommand.Throttle, autonomous: OVCS.RosVelocityCommand}
}
```

A hand's throttle usually goes through an `OVCS.InputCurve` first, and the map names the curve. Dead zone and expo belong to the hand, one curve per hand; the actuator only applies its caps. In the OVCS Mini reference vehicle:

```elixir
{OVCS.InputCurve,
 %{
   process_name: Vms.RadioThrottleInputCurve,
   throttle_source: OVCS.RadioControl.Throttle,
   deadzone: @throttle_deadzone,
   expo: @throttle_expo
 }},
...
requested_throttle_sources: %{
  manual: nil,
  radio: Vms.RadioThrottleInputCurve,
  ros: %{teleop: Vms.TeleopThrottleInputCurve, autonomous: OVCS.RosVelocityCommand}
},
radio_braking_source: OVCS.RadioControl.Throttle
```

A velocity is a physical quantity and is named directly, as is the takeover: `radio_braking` reads the raw trigger. A hand wired to an actuator without a curve gets no dead zone, and a trigger that drifts at rest makes the vehicle creep.

An actuator acts only while its map names a source on the selected level, so the map, not the actuator, decides which levels drive it. OVCS1's steering column steers under `:radio` and `:ros` because its `requested_steering_sources` gives `manual: nil`. A brake actuator follows the optional `requested_braking_sources`, whose sources publish `:requested_braking`, a request in [0, 1]. `OVCS.RadioControl.Throttle` and `OVCS.RosActuatorCommand.Throttle` publish one, the travel of their axis into reverse; a source that publishes none brakes nothing. OVCS1's iBooster brakes on the radio's and on teleop's.

A missing key resolves to `nil`: nothing commands that actuator. That is the safe direction. A vehicle without a planner is expressed that way: `ros: %{teleop: ...}` leaves the autonomous position commanding nothing. Such a vehicle also omits `requested_ros_commander_source`, which pins the commander to `:teleop`.

### Driving on the host bench

On the host there is no radio receiver and no controller. The level starts at `default_control_level` (`:manual` in the OVCS Mini reference vehicle, where every source is `nil`). Nothing emits `0x2A0`/`0x2A1`, and nothing emits the pulse counter frame `0x709`. Without that frame the speed is unknown, and the manager refuses every mode change with `:speed_unknown`. A bench session synthesises both.

First, emit the speed as a stream in its own terminal. The frame watcher needs several on-time frames to declare `0x709` alive and drops it as soon as they stop. A count and frequency of zero is a stationary vehicle:

```sh
cangen vcan0 -I 709 -L 4 -D 00000000 -g 10
```

Then send the switches, in the Mini's channel layout. `0x2A0` carries channels 1 to 4 as little-endian `uint16`, two bytes each. `0x2A1` carries 5 to 8. 1500 is `DC05`, 2000 is `D007`, 1000 is `E803`:

```sh
# Steering and throttle centred (channels 1 and 2)
cansend vcan0 2A0#DC05DC0500000000

# Level -> :radio (channel 6 = 1500; channel 5 = 1000 keeps :teleop)
cansend vcan0 2A1#E803DC0500000000

# Level -> :ros (channel 6 = 2000). Two steps, in this order.
cansend vcan0 2A1#E803D00700000000

# Optional: hand it to the planner (channel 5 = 2000). Needs a standstill.
cansend vcan0 2A1#D007D00700000000
```

Channels 7 and 8 read as 0 here, outside every margin, so they take the safe fallback. `ready_to_drive` is hardcoded `true` in the Mini (`OvcsMini.Vms`). Where it comes from contactors or an inverter, it has to be true as well. For your vehicle, substitute the channels your composer names. [Testing with CAN](../testing_with_can.md) covers `cansend`, `cangen` and replaying captures.

## Metrics and actions

The dashboard never talks to a component directly.

- **Metrics.** `VmsCore.Metrics` subscribes to every message on the VMS's bus and keeps the last value per source and name, with the unit its publisher gave. The API's `metrics` channel streams the module and key pairs a client subscribes to. Every value a component broadcasts is therefore already a metric: a [dashboard row](./dashboard_pages.md#how-a-row-finds-its-metric) only names it.
- **Actions.** A dashboard button posts to `/api/actions` with a module, an action name and parameters. The API calls that module's `trigger_action/2`, which must return `:ok`. The throttle pedal's `"calibrate_boundaries"` and a generic controller's adoption are actions. See [How an action reaches your code](./dashboard_pages.md#how-an-action-reaches-your-code).
- **Network interfaces.** `VmsCore.NetworkInterfaces` reports each CAN interface Cantastic is configured with, and its `ip` link statistics with the detailed error counters, for the `network-interfaces` channel.

## Where next

- [Add a component](./add_a_component.md): the recipe above, end to end.
- [Dashboard pages](./dashboard_pages.md): the pages, blocks and rows your composer returns.
- [Drivers](./drivers.md): the components the framework ships.
- [The OVCS bus](../bus/README.md): messages, scope and the mesh.
