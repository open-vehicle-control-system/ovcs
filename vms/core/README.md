# VMS Core

VMS Core is the central application of the Open Vehicle Control System. It manages all vehicle components, processes CAN bus communication, enforces safety logic, and provides a metrics/actions interface for the dashboard and API.

## Architecture

VMS Core is built around four key patterns:

### 1. Vehicle Composer

Vehicles live outside `vms_core` in their own Mix packages under `vehicles/`. Each vehicle's VMS side implements the `VmsCore.Vehicle` behaviour:

```
VmsCore.Vehicle (behaviour)
├── children/0                → List of child specs for the OTP supervisor
├── generic_controllers/0     → Pin configurations for Arduino controllers (optional)
├── dashboard_configuration/0 → UI layout for the web dashboard (optional)
├── can_config_otp_app/0      → OTP app owning the CAN YAMLs
└── can_config_path/0         → Path to the YAML inside that app's priv/
```

The `VEHICLE` environment variable selects which vehicle package's composer is wired in at startup. Supported vehicles:

| `VEHICLE` value | Package | VMS Composer module |
|----------------|---------|---------------------|
| `Ovcs1` | `vehicles/ovcs1` | `Ovcs1.Vms.Composer` |
| `OvcsMini` | `vehicles/ovcs_mini` | `OvcsMini.Vms.Composer` |
| `Obd2` | `vehicles/obd2` | `Obd2.Vms.Composer` |

### 2. Component Pattern

Every hardware driver is a GenServer that follows the same pattern:

1. **Subscribes to CAN frames** via `Cantastic.Receiver.subscribe/3`
2. **Subscribes to internal messages** via `OvcsBus.subscribe/1`
3. **Runs a periodic loop** (typically every 10ms) to emit CAN frames and broadcast metrics
4. **Exposes actions** via `trigger_action/2` for dashboard control

Components receive CAN data as `{:handle_frame, %Cantastic.Frame{}}` messages and internal data as `%OvcsBus.Message{}` messages.

### 3. Bus System

[`OvcsBus`](../../libraries/ovcs_bus) (shared across VMS, infotainment, and bridge firmwares) is a Phoenix PubSub-based message bus for inter-component communication. Components broadcast metrics and listen for messages from other components:

```elixir
alias OvcsBus, as: Bus

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

Cross-firmware traffic is automatic: every BEAM in the vehicle (VMS, infotainment, each bridge) is joined into a distributed Erlang mesh by `OvcsBus.Cluster`, so `OvcsBus.broadcast/2` reaches subscribers on every node. See [`OvcsBus`](../../libraries/ovcs_bus) for details.

### 4. Manager Pattern

Managers orchestrate cross-component logic:

- **`Managers.ControlLevel`** — Selects the active control source (`:manual`, `:radio`, or `:autonomous`) and routes throttle, steering, gear, and direction inputs from the appropriate source
- **`Managers.Gear`** — Enforces gear shift safety constraints (speed near zero, throttle released, ready-to-drive status)

## Supervision Tree

```
VmsCore.Application
├── VmsCore.Repo (SQLite - throttle calibration data)
├── Ecto.Migrator (applies pending migrations on boot)
├── VmsCore.Metrics (aggregates all Bus messages for dashboard/API)
├── VmsCore.NetworkInterfaces (CAN interface statistics)
├── OvcsBus.Cluster (connects this BEAM to the vehicle's other firmwares via Erlang distribution)
└── Vehicle Composer children (dynamic, based on VEHICLE env var):
    ├── VmsCore.Status (VMS heartbeat, ready-to-drive, controller reset)
    ├── Components (hardware drivers)
    ├── Managers (control level, gear)
    └── Generic Controllers (Arduino I/O drivers)
```

`OvcsBus`'s own `Phoenix.PubSub` lives under its own OTP application
(`:ovcs_bus`) and is reachable by name from every BEAM that depends on
the library.

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
| `VmsCore.PID` | `pid.ex` | Proportional-Integral-Derivative controller using Decimal arithmetic |
| `VmsCore.Repo` | `repo.ex` | Ecto SQLite3 repository for persistent data |
| `VmsCore.NetworkInterfaces` | `network_interfaces.ex` | CAN interface statistics (TX/RX errors, bus state) |

## CAN Configuration

Vehicle CAN topology files live in each vehicle package's `priv/can/`:

```
vehicles/<name>/priv/can/
├── vms.yml                 # read by vms_core
├── infotainment.yml        # read by infotainment_core (optional)
└── generic_controller/     # per-vehicle controller frame wirings
```

Shared per-component frame and signal definitions live in the [`ovcs_can`](../../libraries/ovcs_can) library under `priv/can/components/`. Vehicle topology YAMLs import components from the library via Cantastic's cross-app import syntax:

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
VEHICLE=Ovcs1 iex -S mix phx.server
```

The VMS Core starts as a dependency of the VMS API (Phoenix). The `VEHICLE` env var (the top-level vehicle module name, e.g. `Ovcs1`) is required; `CAN_NETWORK_MAPPINGS` defaults to whatever `default_can_mapping(:host)` returns on the vehicle's VMS composer and only needs to be set to override it.

## Key Safety Features

- **HV contactor precharge sequence** — Prevents inrush current damage by following negative → precharge → (wait for voltage equalization) → positive → disable precharge
- **VMS heartbeat watchdog** — Arduino controllers shut down all outputs if the VMS heartbeat (`0x1A0`) is missing for too long
- **Gear shift safety** — Gear manager enforces speed and throttle constraints before allowing shifts
- **Manual brake override** — Pressing the brake pedal in radio/autonomous mode can override to manual control
- **5-second boot grace period** — Controller status checks are skipped during initial boot to allow hardware initialization

## License

MIT License - Copyright (c) 2024 Spin42 SRL
