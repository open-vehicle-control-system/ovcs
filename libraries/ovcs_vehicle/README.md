# OvcsVehicle

Shared top-level behaviour for OVCS vehicle packages + helpers the
firmware and composer code use to reach the vehicle at runtime.

A vehicle package is a single Mix app that bundles its VMS side,
optional infotainment side, and optional bridge firmware declarations.
Its top-level module implements `OvcsVehicle`; firmware images never
depend on the vehicle as a Mix dep — they read `VEHICLE` at boot,
prepend the vehicle's compiled ebin to the code path, and dispatch
through the module.

See [`docs/vehicle_parameterisation.md`](../../docs/vehicle_parameterisation.md)
for the end-to-end flow; this README is the library reference.

## The behaviour

```elixir
defmodule Ovcs1 do
  @behaviour OvcsVehicle

  @impl OvcsVehicle
  def name, do: "OVCS1"
  @impl OvcsVehicle
  def vms, do: Ovcs1.Vms.Composer
  @impl OvcsVehicle
  def infotainment, do: Ovcs1.Infotainment.Composer
  @impl OvcsVehicle
  def can_config_otp_app, do: :ovcs1
  @impl OvcsVehicle
  def nerves_target(:vms), do: :ovcs_base_can_system_rpi4
  def nerves_target(:infotainment), do: :ovcs_base_can_system_rpi5

  @impl OvcsVehicle
  def bridge_firmwares do
    %{
      "radio_control" => %{
        target: :ovcs_base_can_system_rpi3a,
        bridges: [RadioControlBridge],
        default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"},
        bus_relay: OvcsVehicle.Bus.relay_opts(__MODULE__, "ovcs1-bridge-radio_control")
      }
    }
  end

  @broker_host (if Mix.target() == :host, do: "localhost", else: "ovcs1-vms.local")
  def broker_host, do: @broker_host
end
```

Callbacks (all required unless noted):

| Callback | Purpose |
|----------|---------|
| `name/0` | Human-readable vehicle name |
| `vms/0` | VMS composer module (implements `VmsCore.Vehicle`) |
| `infotainment/0` _(optional)_ | Infotainment composer module (implements `InfotainmentCore.Vehicle`) |
| `can_config_otp_app/0` | OTP app owning the CAN YAMLs (the vehicle's own app atom) |
| `nerves_target/1` | Nerves target atom per side (`:vms`, `:infotainment`) |
| `bridge_firmwares/0` _(optional)_ | Map of bridge firmware id → target + bridges + can mapping + bus relay opts |

Only `vms/0` sets `:vms_core, :vehicle`; `infotainment/0` sets
`:infotainment_core, :vehicle`. A vehicle that omits `infotainment/0`
simply means the infotainment firmware is never built for it.

The `broker_host/0` convention is a plain public function (not a
behaviour callback) — `OvcsVehicle.Bus` reads it to construct
relay opts. Define it with `Mix.target()` so host dev points at
`localhost` and deployed firmwares point at `<vehicle>-vms.local`.

## Helpers

### `OvcsVehicle.Firmware`

Each firmware's `config/runtime.exs` calls
`OvcsVehicle.Firmware.resolve_vehicle/3` to read `VEHICLE`, prepend
`vehicles/<name>/_build/<env>/lib/<name>/ebin` to the code path, and
return the module atom (or `nil` in `MIX_ENV=test`). Without this
step, the firmware BEAM can't dereference the vehicle module — the
vehicle is not a Mix dep of the firmware.

### `OvcsVehicle.Bus`

`relay_opts/3` builds the `OvcsBus.Mqtt.Relay` opts map from the
vehicle's `broker_host/0` plus a role-specific `client_id` and any
extras (typically `:topics`). Composers and `bridge_firmwares/0`
entries call it instead of restating the broker/topic tuple every
time. See the moduledoc for the full contract (including the optional
`broker_port/0` and `topic_prefix/0` overrides).

## Scaffolding a new vehicle

Use the CLI:

```
./ovcs vehicle new my_car \
  --vms-target ovcs_base_can_system_rpi4 \
  --infotainment-target ovcs_base_can_system_rpi5
```

Under the hood this invokes `OvcsVehicle.Scaffold.generate/3`, which
copies the EEx template at `priv/templates/vehicle/` into
`vehicles/my_car/`, substitutes `{{name}}` in paths, renders
`@module` / `@name` / `@upper` / target atoms in file bodies, and
seeds per-side `priv/firmware/` with defaults from
`vms/firmware/targets/<target>/` +
`infotainment/firmware/targets/<target>/`. The scaffolded package
compiles and runs out of the box — you prune the example
components, fill in CAN YAMLs, and add hardware drivers.

Pass `--no-infotainment` to scaffold a VMS-only vehicle (mirrors
`OvcsMini`).

## Layout

```
lib/
  ovcs_vehicle.ex            — the OvcsVehicle behaviour
  ovcs_vehicle/
    firmware.ex              — resolve_vehicle/3 (for runtime.exs)
    bus.ex                   — relay_opts/3 (for composers + bridges)
    scaffold.ex              — `ovcs vehicle new` template renderer
priv/
  templates/vehicle/         — EEx-rendered new-vehicle template
```
