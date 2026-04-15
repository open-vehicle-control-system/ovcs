# VMS Core

VMS Core is the central application of the Open Vehicle Control System. It manages all vehicle components, processes CAN bus communication, enforces safety logic, and provides a metrics/actions interface for the dashboard and API.

## Architecture

VMS Core is built around four key patterns:

### 1. Vehicle Composer

Each supported vehicle has a **Composer** module that defines which components to start:

```
VmsCore.Vehicles.<VEHICLE>.Composer
├── children/0          → List of child specs for the OTP supervisor
├── generic_controllers/0 → Pin configurations for Arduino controllers
└── dashboard_configuration/0 → UI layout for the web dashboard
```

The `VEHICLE` environment variable selects the composer at startup. Supported vehicles:

| Vehicle | Module | Description |
|---------|--------|-------------|
| `OVCS1` | `VmsCore.Vehicles.OVCS1.Composer` | Full-size VW Polo EV conversion |
| `OVCSMini` | `VmsCore.Vehicles.OVCSMini.Composer` | Traxxas RC car platform |
| `OBD2` | `VmsCore.Vehicles.OBD2.Composer` | Read-only OBD-II diagnostic mode |

### 2. Component Pattern

Every hardware driver is a GenServer that follows the same pattern:

1. **Subscribes to CAN frames** via `Cantastic.Receiver.subscribe/3`
2. **Subscribes to internal messages** via `VmsCore.Bus.subscribe/1`
3. **Runs a periodic loop** (typically every 10ms) to emit CAN frames and broadcast metrics
4. **Exposes actions** via `trigger_action/2` for dashboard control

Components receive CAN data as `{:handle_frame, %Cantastic.Frame{}}` messages and internal data as `%VmsCore.Bus.Message{}` messages.

### 3. Bus System

`VmsCore.Bus` is a Phoenix PubSub-based message bus for inter-component communication. Components broadcast metrics and listen for messages from other components:

```elixir
# Broadcasting a metric
Bus.broadcast("messages", %Bus.Message{
  name: :speed,
  value: 45.2,
  source: VmsCore.Components.Volkswagen.Polo9N.ABS
})

# Receiving in another component's handle_info
def handle_info(%Bus.Message{name: :speed, value: speed, source: source}, state)
    when source == state.abs_source do
  {:noreply, %{state | speed: speed}}
end
```

The `source` field enables decoupling: components don't import each other directly. Instead, they receive source module atoms through their init configuration from the Composer.

### 4. Manager Pattern

Managers orchestrate cross-component logic:

- **`Managers.ControlLevel`** — Selects the active control source (`:manual`, `:radio`, or `:autonomous`) and routes throttle, steering, gear, and direction inputs from the appropriate source
- **`Managers.Gear`** — Enforces gear shift safety constraints (speed near zero, throttle released, ready-to-drive status)

## Supervision Tree

```
VmsCore.Application
├── VmsCore.Repo (SQLite - throttle calibration data)
├── Phoenix.PubSub (internal message bus)
├── VmsCore.Status (VMS heartbeat, ready-to-drive state, controller reset)
├── VmsCore.Metrics (aggregates all Bus messages for dashboard/API)
├── VmsCore.NetworkInterfaces (CAN interface statistics)
└── Vehicle Composer children (dynamic, based on VEHICLE env var):
    ├── Components (hardware drivers)
    ├── Managers (control level, gear)
    └── Generic Controllers (Arduino I/O drivers)
```

## Components

### OVCS Custom Hardware

| Module | File | Purpose |
|--------|------|---------|
| `Components.OVCS.GenericController` | `components/ovcs/generic_controller.ex` | Arduino R4 Minima I/O driver (digital, analog, PWM, DAC, external PWM) |
| `Components.OVCS.HighVoltageContactors` | `components/ovcs/high_voltage_contactors.ex` | HV contactor precharge sequence (negative → precharge → positive) |
| `Components.OVCS.ThrottlePedal` | `components/ovcs/throttle_pedal.ex` | Dual-channel analog throttle with calibration (persisted to SQLite) |
| `Components.OVCS.SteeringColumn` | `components/ovcs/steering_column.ex` | Stepper motor steering with PID controller |
| `Components.OVCS.WaterPump` | `components/ovcs/water_pump.ex` | Cooling water pump relay control |
| `Components.OVCS.Infotainment` | `components/ovcs/infotainment.ex` | Infotainment CAN bridge (music control, turn signals) |

### Radio Control

| Module | Purpose |
|--------|---------|
| `Components.OVCS.RadioControl.Steering` | Steering input from RC transmitter |
| `Components.OVCS.RadioControl.Throttle` | Throttle input from RC transmitter |
| `Components.OVCS.RadioControl.Direction` | Forward/reverse from RC transmitter |
| `Components.OVCS.RadioControl.RequestedControlLevel` | Control mode switch from RC transmitter |

### ROS Control (Autonomous)

| Module | Purpose |
|--------|---------|
| `Components.OVCS.RosControl.Steering` | Steering commands from ROS2 |
| `Components.OVCS.RosControl.Throttle` | Throttle commands from ROS2 |
| `Components.OVCS.RosControl.Direction` | Direction commands from ROS2 |

### Nissan Leaf AZE0

| Module | Purpose |
|--------|---------|
| `Components.Nissan.LeafAZE0.Inverter` | Motor control, torque requests, speed feedback, regenerative braking |
| `Components.Nissan.LeafAZE0.Charger` | AC charging control and monitoring |

### Bosch

| Module | Purpose |
|--------|---------|
| `Components.Bosch.IBoosterGen2` | Electronic brake booster with PID-controlled rod position |

### Orion BMS

| Module | Purpose |
|--------|---------|
| `Components.Orion.BMS2` | Battery management: cell voltages, temperatures, SOC, charge limits |

### EVPT

| Module | Purpose |
|--------|---------|
| `Components.EVPT.EVPT23Charger` | On-board charger control and monitoring |

### Volkswagen Polo 9N

| Module | Purpose |
|--------|---------|
| `Components.Volkswagen.Polo9N.ABS` | ABS module: wheel speeds, brake pressure |
| `Components.Volkswagen.Polo9N.Dashboard` | Original dashboard cluster communication |
| `Components.Volkswagen.Polo9N.IgnitionLock` | Ignition key position detection |
| `Components.Volkswagen.Polo9N.PassengerCompartment` | Turn signal stalk, wiper stalk |
| `Components.Volkswagen.Polo9N.PowerSteeringPump` | Electric power steering pump control |
| `Components.Volkswagen.Polo9N.FakeOilPressureSensor` | Simulated oil pressure signal (suppresses dashboard warning) |

### Traxxas (OVCS Mini)

| Module | Purpose |
|--------|---------|
| `Components.Traxxas.Motor` | Brushless motor monitoring |
| `Components.Traxxas.Steering` | Servo steering via external PWM |
| `Components.Traxxas.Throttle` | ESC throttle via external PWM |

## Infrastructure Modules

| Module | File | Purpose |
|--------|------|---------|
| `VmsCore.Status` | `status.ex` | Emits VMS heartbeat (`0x1A0`), manages ready-to-drive state, controller reset command (`0x1AA`) |
| `VmsCore.Metrics` | `metrics.ex` | Subscribes to all Bus messages, stores latest values, exposes `metrics/0` for the API |
| `VmsCore.Bus` | `bus.ex` | Phoenix PubSub wrapper for inter-component messaging |
| `VmsCore.Bus.Message` | `bus/message.ex` | `%Message{name: atom, value: any, source: module}` |
| `VmsCore.PID` | `pid.ex` | Proportional-Integral-Derivative controller using Decimal arithmetic |
| `VmsCore.Repo` | `repo.ex` | Ecto SQLite3 repository for persistent data |
| `VmsCore.NetworkInterfaces` | `network_interfaces.ex` | CAN interface statistics (TX/RX errors, bus state) |

## CAN Configuration

Vehicle CAN topology files live in `priv/can/vehicles/`:

```
priv/can/vehicles/
├── ovcs1.yml          # OVCS1 network topology
├── ovcs_mini.yml      # OVCS Mini topology
└── obd2.yml           # OBD2 diagnostic topology
```

Shared per-component frame and signal definitions live in the [`ovcs_can`](../../libraries/ovcs_can) library under `priv/can/components/`. Per-vehicle controller wirings stay here under `vehicles/<vehicle>/generic_controller/`. Vehicle topology YAMLs import components from the library via Cantastic's cross-app import syntax:

```yaml
- import!:@ovcs_can:can/components/ovcs/0x1A0_vms_status.yml
```

## Dashboard System

Each vehicle's Composer defines a declarative dashboard configuration consumed by the VMS API and rendered by the VMS Dashboard (Vue.js):

```elixir
%{
  vehicle: %{
    name: "OVCS1",
    main_color: "#1a73e8",
    refresh_interval: 100,
    pages: %{
      "drivetrain" => %{
        name: "Drivetrain",
        icon: "bolt",
        order: 0,
        blocks: [
          %{type: "table", rows: [
            %{type: :metric, label: "Speed", module: SomeModule, key: :speed, unit: "km/h"},
            %{type: :action, label: "Enable", module: SomeModule, action: "enable"}
          ]},
          %{type: "lineChart", y_axis: [
            %{label: "Torque", module: SomeModule, key: :torque, unit: "Nm"}
          ]}
        ]
      }
    }
  }
}
```

**Block types:**
- `"table"` — Key-value metrics and action buttons
- `"lineChart"` — Time-series charts with multiple Y-axis series

**Action handling:** Components implement `trigger_action(action_name, params)` to handle dashboard button presses (e.g., "adopt" a controller, "calibrate" throttle, "enable" contactors).

## Running Locally

```sh
cd vms/api
VEHICLE=OVCS1 CAN_NETWORK_MAPPINGS=ovcs:vcan0,leaf_drive:vcan1,polo_drive:vcan2,orion_bms:vcan3,misc:vcan4 iex -S mix phx.server
```

The VMS Core starts as a dependency of the VMS API (Phoenix). The `VEHICLE` env var is required.

## Key Safety Features

- **HV contactor precharge sequence** — Prevents inrush current damage by following negative → precharge → (wait for voltage equalization) → positive → disable precharge
- **VMS heartbeat watchdog** — Arduino controllers shut down all outputs if the VMS heartbeat (`0x1A0`) is missing for too long
- **Gear shift safety** — Gear manager enforces speed and throttle constraints before allowing shifts
- **Manual brake override** — Pressing the brake pedal in radio/autonomous mode can override to manual control
- **5-second boot grace period** — Controller status checks are skipped during initial boot to allow hardware initialization

## License

MIT License - Copyright (c) 2024 Spin42 SRL
