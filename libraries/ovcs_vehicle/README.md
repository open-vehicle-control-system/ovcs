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
  def vms_target, do: :ovcs_base_can_system_rpi4
  @impl OvcsVehicle
  def infotainment_target, do: :ovcs_base_can_system_rpi5

  @impl OvcsVehicle
  def bridge_firmwares do
    %{
      "radio_control" => %{
        target: :ovcs_base_can_system_rpi3a,
        bridges: [RadioControlBridge],
        default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"}
      }
    }
  end
end
```

Callbacks (all required unless noted):

| Callback | Purpose |
|----------|---------|
| `name/0` | Human-readable vehicle name |
| `vms/0` | VMS composer module (implements `VmsCore.Vehicle`) |
| `infotainment/0` _(optional)_ | Infotainment composer module (implements `InfotainmentCore.Vehicle`) |
| `can_config_otp_app/0` | OTP app owning the CAN YAMLs (the vehicle's own app atom) |
| `vms_target/0` | Nerves target atom for the VMS firmware |
| `infotainment_target/0` _(optional)_ | Nerves target atom for the infotainment firmware |
| `bridge_firmwares/0` _(optional)_ | Map of bridge firmware id → target + bridges + can mapping |

Only `vms/0` sets `:vms_core, :vehicle`; `infotainment/0` sets
`:infotainment_core, :vehicle`. A vehicle that omits `infotainment/0`
simply means the infotainment firmware is never built for it.

## Helpers

### `OvcsVehicle.Firmware`

Each firmware's `config/runtime.exs` calls
`OvcsVehicle.Firmware.resolve_vehicle/3` to read `VEHICLE`, prepend
`vehicles/<name>/_build/<env>/lib/<name>/ebin` to the code path, and
return the module atom (or `nil` in `MIX_ENV=test`). Without this
step, the firmware BEAM can't dereference the vehicle module — the
vehicle is not a Mix dep of the firmware.

Cross-firmware messaging uses `OvcsBus.Cluster` (in `ovcs_bus`) —
each firmware's `Application` supervises one at boot and the BEAMs
form a distributed Erlang mesh. No per-vehicle wiring is needed in
the vehicle module.

## Scaffolding a new vehicle

Use the CLI:

```
./ovcs new my_car \
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
    scaffold.ex              — `ovcs new` template renderer
priv/
  templates/vehicle/         — EEx-rendered new-vehicle template
```
