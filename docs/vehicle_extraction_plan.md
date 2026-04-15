# Vehicle extraction plan

Goal: make each vehicle (OVCS1, OVCS Mini, OBD2, and any future one) a **standalone, pluggable package** so that creating or modifying a vehicle does not require touching `vms/core` or `infotainment/core`. External contributors should be able to ship a vehicle as its own repo, pulled in as a `path:` / `git:` / Hex dep.

## Target layout

Vehicles become first-class top-level apps in the monorepo, peers of `vms/`, `infotainment/`, `bridges/`, `controllers/`, `libraries/`. A vehicle package is a single Mix app that bundles *both* its VMS side and its infotainment side — the two are linked through a top-level entry module so they cannot drift:

```
ovcs/
├── vehicles/
│   ├── ovcs1/
│   │   ├── mix.exs                              # app: :ovcs1
│   │   ├── lib/
│   │   │   ├── ovcs1.ex                         # @behaviour OvcsVehicle — links the two sides
│   │   │   ├── ovcs1/vms.ex                     # @behaviour VmsCore.Vehicle
│   │   │   ├── ovcs1/vms/composer.ex            # children/0, dashboard_configuration/0, ...
│   │   │   ├── ovcs1/vms/dashboard/*.ex         # per-page modules
│   │   │   ├── ovcs1/infotainment.ex            # @behaviour InfotainmentCore.Vehicle
│   │   │   └── ovcs1/infotainment/composer.ex
│   │   └── priv/can/
│   │       ├── vms.yml                          # full CAN topology (VMS reads this)
│   │       ├── infotainment.yml                 # narrow CAN topology (infotainment reads this)
│   │       └── generic_controller/*.yml         # per-controller wirings, shared
│   ├── ovcs_mini/
│   └── obd2/
├── libraries/
│   ├── cantastic/
│   ├── ovcs_can/
│   └── vms_components/   # (optional) shared hardware drivers extracted from vms/core
├── vms/          # core, api, dashboard, firmware — no vehicle-specific code
├── infotainment/ # core, api, dashboard, firmware — no vehicle-specific code
├── bridges/
└── controllers/
```

External vehicle packages live outside this repo and are wired in at the consumer's level (`vms/firmware` or a deployment project).

## Current coupling (what has to change)

A "vehicle" today is compile-time bound to the atom `OVCS1` / `OVCSMini` / `OBD2` across these touchpoints:

1. **Composer module** — `VmsCore.Vehicles.<Name>.Composer`, resolved via `Module.concat(VmsCore.Vehicles, VEHICLE) |> Module.concat(Composer)` in `vms/core/lib/vms_core/application.ex`.
2. **Top-level vehicle GenServer** — `VmsCore.Vehicles.<Name>` ready-to-drive state machine.
3. **Dashboard pages** — `.../vehicles/<name>/composer/dashboard/*.ex`, compiled Elixir.
4. **CAN entry-point YAML** — `priv/can/vehicles/<name>.yml` + `vehicles/<name>/generic_controller/*.yml`.
5. **Infotainment twin** — parallel `InfotainmentCore.Vehicles.<Name>` module + narrow YAMLs.
6. **Hardcoded cross-references** — e.g. `VmsCore.Vehicles.OVCS1.FrontController` is aliased inside generic components like `Inverter`. This is the only real refactor.

## Four load-bearing changes to `vms_core`

### 1. Define three behaviours — one per side, plus one that links them

**`OvcsVehicle`** (lives in a shared lib, e.g. `libraries/ovcs_vehicle/`) is the entry point for a vehicle package. It binds the VMS side and the infotainment side into a single artifact so the two always ship together:

```elixir
defmodule OvcsVehicle do
  @callback name() :: String.t()
  @callback vms() :: module()            # returns the VmsCore.Vehicle implementation
  @callback infotainment() :: module()   # returns the InfotainmentCore.Vehicle implementation
  @callback can_config_otp_app() :: atom()
  @callback nerves_target(:vms | :infotainment) :: atom()  # e.g. :rpi4, :rpi5
end
```

**`VmsCore.Vehicle`** — what the VMS side of a vehicle must implement:

```elixir
@callback children() :: [Supervisor.child_spec()]
@callback dashboard_configuration() :: map()
@callback generic_controllers() :: map()
@callback can_config_path() :: String.t()   # relative to the vehicle package's priv dir
@optional_callbacks [dashboard_configuration: 0, generic_controllers: 0]
```

**`InfotainmentCore.Vehicle`** — same shape on the infotainment side.

Example from a vehicle package:

```elixir
defmodule Ovcs1 do
  @behaviour OvcsVehicle
  def name, do: "OVCS1"
  def vms, do: Ovcs1.Vms
  def infotainment, do: Ovcs1.Infotainment
  def can_config_otp_app, do: :ovcs1
  def nerves_target(:vms), do: :rpi4
  def nerves_target(:infotainment), do: :rpi5
end

defmodule Ovcs1.Vms do
  @behaviour VmsCore.Vehicle
  def children, do: [...]
  def can_config_path, do: "can/vms.yml"
  # ...
end

defmodule Ovcs1.Infotainment do
  @behaviour InfotainmentCore.Vehicle
  def children, do: [...]
  def can_config_path, do: "can/infotainment.yml"
  # ...
end
```

Consumers (`vms/core`, `infotainment/core`) are configured with the *top-level* vehicle module and dispatch through it — they never reference `Ovcs1.Vms` or `Ovcs1.Infotainment` directly:

```elixir
# vms/core/config/config.exs
config :vms_core, :vehicle, Ovcs1
# vms_core then calls Ovcs1.vms().children() internally

# infotainment/core/config/config.exs
config :infotainment_core, :vehicle, Ovcs1
# infotainment_core calls Ovcs1.infotainment().children()
```

This is what "each vehicle links to its VMS and infotainment" means concretely: one package, one top-level module, two linked behaviours. You cannot ship an OVCS1 with an Ovcs Mini infotainment by accident.

### 2. Composer resolution comes from config, not env-var concatenation

In the deployment's `config.exs`:

```elixir
config :vms_core, :vehicle, Ovcs1     # module, not atom/string
```

`VmsCore.Application.start/2` calls `composer_mod.children()` — no `Module.concat`, no assumed namespace. The `VEHICLE` env var becomes a top-level switch (a small string→module map) in the *deployment's* config, not in `vms_core`.

### 3. Cantastic's YAML path comes from the vehicle

The `@ovcs_can:…` cross-app import syntax is already in place. Generalise the top-level Cantastic config so the vehicle package owns it. Each core asks the top-level vehicle module for the side-specific YAML path:

```elixir
# vms/core — at boot
vehicle = Application.fetch_env!(:vms_core, :vehicle)
config :cantastic,
  otp_app: vehicle.can_config_otp_app(),
  priv_can_config_path: vehicle.vms().can_config_path()

# infotainment/core — same, but .infotainment()
```

No more hardcoded `can/vehicles/#{vehicle}.yml` in `vms/core/config/config.exs`.

### 4. Break the `VmsCore.Vehicles.OVCS1.FrontController` leak

Generic components (`Inverter`, etc.) currently alias vehicle-specific controller modules directly. They must accept the controller module/pid as a start argument — inversion of control. The vehicle package wires up concrete controllers in its `Composer.children/0`. This is the only substantive refactor; everything else is mostly moving files.

## What stays in `vms/core`

- `lib/vms_core/components/**` — generic hardware drivers (Bosch iBooster, Leaf inverter, Orion BMS, Polo, Traxxas, OVCS generic controller). Reusable across vehicles; stays in `vms_core`. Vehicle packages depend on `vms_core` to use them.
- `lib/vms_core/managers/**`, `bus.ex`, `metrics.ex`, `pid.ex` — infrastructure.
- `priv/can/vehicles/*.yml` — **moves out** to each vehicle package.
- `lib/vms_core/vehicles/**` — **moves out** to each vehicle package.

## Migration steps (each independently commitable)

1. **Define `VmsCore.Vehicle` behaviour.** Make the three existing composers `@behaviour VmsCore.Vehicle`. No moves yet — just types.
2. **Move composer resolution to config.** `config :vms_core, :vehicle, <module>`. Drop the `VEHICLE` env-var string switch; deployments set the module directly.
3. **Refactor cross-references.** `Inverter` (and any other component aliasing vehicle-specific controllers) takes the controller module as an init arg. Vehicle composer passes it.
4. **Move CAN YAML path config.** Path and `otp_app` come from `composer_mod.can_config_*`, not hardcoded in `vms/core/config/config.exs`.
5. **Extract OVCS1 to `vehicles/ovcs1/`.** Create the Mix app, move `lib/vms_core/vehicles/ovcs1/**` and `priv/can/vehicles/ovcs1.yml` + `vehicles/ovcs1/generic_controller/*`, add as a `path:` dep of `vms/core`. Keep OVCSMini and OBD2 in place to validate.
6. **Extract OVCSMini and OBD2.** Same shape. Delete the residual `vms/core/lib/vms_core/vehicles/` directory.
7. **Define `InfotainmentCore.Vehicle` behaviour and repeat steps 1–6** on the infotainment side.
8. **Publish or pin as external deps.** Update the `ovcs` Ruby CLI and `vms/firmware` / `infotainment/firmware` to let deployments choose a vehicle package.

## Known trade-offs

- **Infotainment twin.** The package bundles both sides via `OvcsVehicle` (behaviour) + `VmsCore.Vehicle` + `InfotainmentCore.Vehicle`, so they can't drift. The VMS and infotainment state machines remain separate GenServers — a long-term cleanup (demoting infotainment to a pure UI consumer that subscribes to VMS state over CAN) is orthogonal and can happen later without changing the package shape.
- **Dashboard pages as compiled `.ex`** is flexible but recompile-bound. If you want dashboards editable without recompile, move page definitions to YAML/JSON under the vehicle's `priv/`. Orthogonal to the extraction; do it separately.
- **Vehicle packages depend on `vms_core` by design.** `vms_core` is the shared platform + hardware component catalogue (iBooster, Leaf inverter, Orion BMS, Polo parts, Traxxas, generic controller). Vehicles compose existing drivers rather than reinventing them, so a vehicle package's `mix.exs` has `{:vms_core, path: "../../vms/core"}`. External vehicles published outside the repo depend on `vms_core` via git or Hex the same way. Dep direction is `vehicle → vms_core`; `vms_core` never knows which vehicle it will be wired into.

## Nerves target selection

Each vehicle picks its own Nerves target per side via `OvcsVehicle.nerves_target/1`. For example, OVCS1 runs the VMS on an RPi 4 and the infotainment on an RPi 5; OVCS Mini might run both sides on an RPi 3 or 4.

`vms/firmware` and `infotainment/firmware` read the target from the configured vehicle module rather than having a hardcoded `:target` in their `mix.exs`. The `ovcs` Ruby CLI (`./ovcs -c build -a vms -v ovcs1`) resolves the target through the vehicle package, so operators never pass `MIX_TARGET=...` manually.

## Out of scope for this plan

- Rewriting dashboards to read YAML configs (can be a follow-up).
