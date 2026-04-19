# Infotainment Core

Platform library for the in-car touchscreen UI. Mirrors [`vms_core`](../../vms/core)'s
role on the infotainment side: defines the vehicle contract, holds the
infotainment-only supporting modules, and owns the page/block model the
Flutter dashboard renders.

No vehicle-specific code lives here — each vehicle that ships an
infotainment head unit plugs into this library via its own composer
(`<Vehicle>.Infotainment.Composer`) implementing `InfotainmentCore.Vehicle`.

## Vehicle behaviour

```elixir
defmodule Ovcs1.Infotainment.Composer do
  @behaviour InfotainmentCore.Vehicle

  @impl true
  def children, do: [ ... ]                         # supervision tree
  @impl true
  def infotainment_configuration, do: %{ ... }      # pages + blocks
  @impl true
  def can_config_otp_app, do: :ovcs1
  @impl true
  def can_config_path, do: "can/infotainment.yml"
  @impl true
  def default_can_mapping(:host),   do: "ovcs:vcan0"
  def default_can_mapping(:target), do: "ovcs:spi0.0"
end
```

Callbacks (all required unless noted):

| Callback | Purpose |
|----------|---------|
| `children/0` | Supervision children wired into the infotainment tree |
| `infotainment_configuration/0` _(optional)_ | Page/block layout consumed by `infotainment_api` |
| `can_config_otp_app/0` | OTP app owning the CAN YAMLs (the vehicle's app atom) |
| `can_config_path/0` | Relative path under that app's `priv/` to the infotainment CAN topology |
| `default_can_mapping/1` | `CAN_NETWORK_MAPPINGS` used when `:host` / `:target` isn't overridden |
| `bus_relay/0` _(optional)_ | `OvcsBus.Mqtt.Relay` opts for sharing bus messages with peer firmwares |

The composer is resolved at runtime from the `VEHICLE` env var — the
top-level vehicle module's `infotainment/0` points at this composer. See
[`CLAUDE.md`](../../CLAUDE.md) and
[`docs/applications.md`](../../docs/applications.md) for the end-to-end
wiring.

## Modules

| Module | File | Purpose |
|--------|------|---------|
| `InfotainmentCore.Application` | `application.ex` | Starts the PubSub, Repo, CAN interfaces, and the active vehicle's `children/0` |
| `InfotainmentCore.Vehicle` | `vehicle.ex` | Behaviour shown above |
| `InfotainmentCore.LayoutValidator` | `layout_validator.ex` | Validates page/block layout maps before they hit the API |
| `InfotainmentCore.Temperature` | `temperature.ex` | Cabin temperature GenServer (sensor read + broadcast) |
| `InfotainmentCore.TimeSettings` | `time_settings.ex` | Persists display-time preferences in SQLite |
| `InfotainmentCore.Repo` | `repo.ex` | Ecto SQLite3 repository for persisted settings |

## Page/block layout

`infotainment_configuration/0` returns the same shape consumed by
`infotainment_api`:

```elixir
%{
  vehicle: %{
    name: "OVCS1",
    refresh_interval: 100,
    pages: %{
      "gears" => %{
        name: "Gears", icon: "dashboard", order: 0,
        blocks: [
          %{type: "gear_selector", ...}
        ]
      }
    }
  }
}
```

Block types are rendered by the Flutter dashboard (`../dashboard`). Adding
a new block type means updating both sides.

## Running

`infotainment_core` isn't started directly — it's a dep of
[`infotainment_api`](../api), which is itself pulled in by
`infotainment/firmware`. Use `./ovcs run <vehicle>` to spawn the full
set of firmware BEAMs for a vehicle, or `cd infotainment/api && VEHICLE=Ovcs1
mix phx.server` to run just this side.
