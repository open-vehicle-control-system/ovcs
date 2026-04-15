# <%= @upper %>

OVCS vehicle package for `<%= @upper %>`. This directory is a standalone
Mix app implementing the [`OvcsVehicle`][ovcs_vehicle] behaviour — the
contract consulted by `vms_core`<%= if @infotainment do %> and
`infotainment_core`<% end %> at runtime. Select this vehicle by setting
`VEHICLE=<%= @module %>` before starting any OVCS app.

[ovcs_vehicle]: ../../libraries/ovcs_vehicle

## Quick start

```sh
../../ovcs build <%= @name %> vms            # build VMS firmware<%= if @infotainment do %>
../../ovcs build <%= @name %> infotainment   # build infotainment firmware<% end %>
../../ovcs can setup <%= @name %>            # provision host vcan interfaces
```

See [`docs/running_hardware.md`](../../docs/running_hardware.md) for burn
+ OTA upload flows.

## What the scaffold gave you

| Path | What it is | You will edit |
|------|-----------|---------------|
| `lib/<%= @name %>.ex` | `OvcsVehicle` impl — name, composers, Nerves targets | Rarely |
| `lib/<%= @name %>/vms.ex` | VMS-side vehicle GenServer (ready-to-drive, status) | Per-vehicle state machine |
| `lib/<%= @name %>/vms/composer.ex` | `VmsCore.Vehicle` impl — supervision children, CAN config | **Heavily** — prune components |
| `lib/<%= @name %>/vms/composer/dashboard*` | VMS dashboard pages + blocks | Match what you kept in `children/0` |<%= if @infotainment do %>
| `lib/<%= @name %>/infotainment.ex` | Infotainment-side GenServer | Per-vehicle UI state |
| `lib/<%= @name %>/infotainment/composer*` | Infotainment pages + blocks | Match what your head unit shows |<% end %>
| `priv/can/vms.yml` | VMS CAN topology (Cantastic) | Add hardware buses |<%= if @infotainment do %>
| `priv/can/infotainment.yml` | Infotainment CAN topology | |<% end %>
| `priv/can/generic_controller/` | Per-controller frame YAMLs | Rename/duplicate per real controller |
| `priv/firmware/vms/{fwup.conf,config.txt,cmdline.txt}` | Nerves firmware + boot config for VMS, copied from `vms/firmware/targets/<%= @vms_target %>/` | Only if your board needs a different overlay |<%= if @infotainment do %>
| `priv/firmware/infotainment/{fwup.conf,config.txt,cmdline.txt}` | Nerves firmware + boot config for infotainment, copied from `infotainment/firmware/targets/<%= @infotainment_target %>/` | Only if your head unit needs a different overlay |<% end %>

## Things to customize next

### 1. Vehicle components (VMS composer)

`lib/<%= @name %>/vms/composer.ex` `children/0` ships minimal — one
generic_controller stub plus `VmsCore.Status` and the vehicle's
GenServer. **Add a child spec for each physical component your
vehicle has**: inverter, BMS, brake booster, steering column, body
bus, radio-control / ROS bridges, etc. Drivers live under
`VmsCore.Components.*`. Mirror each component with a matching
dashboard page under `lib/<%= @name %>/vms/composer/dashboard/` so
the UI surfaces its state — see
[`docs/applications.md`](../../docs/applications.md).

### 2. Generic controllers (CAN)

The scaffold ships with one `example_controller` at `0x7E1` / `0x7E2` /
`0x7E4`. Rename and duplicate the files in
`priv/can/generic_controller/` for each physical controller you run
(e.g. `front_controller`, `rear_controller`, `bms_controller`), then
update the `import!:` references in `priv/can/vms.yml`<%= if @infotainment do %>
and `priv/can/infotainment.yml`<% end %>.

ID convention (fixed by `ovcs_can`):

| Offset | Frame |
|--------|-------|
| `0x7X1` | alive heartbeat |
| `0x7X2` | digital pin request (VMS → controller) |
| `0x7X3` | other pin request |
| `0x7X4` | digital + analog pin status (controller → VMS) |
| `0x7X5`–`0x7X8` | external PWM requests |

### 3. Hardware CAN buses

`priv/can/vms.yml` ships with just the mandatory `ovcs` bus (VMS ↔
infotainment + VMS ↔ generic_controllers). Add extra networks at the
same indent level for each physical bus your vehicle has — drivetrain
inverter, BMS, brake booster, body CAN, etc. See
[`docs/testing_can_messages.md`](../../docs/testing_can_messages.md) for
how to exercise frames.

### 4. Bridge firmwares (optional)

Bridges (radio-control, ROS, …) are opt-in per vehicle. To add one,
uncomment the `bridge_firmwares/0` callback in `lib/<%= @name %>.ex`
and list the bridges you want bundled into each image:

```elixir
def bridge_firmwares do
  %{
    "radio_control" => %{
      target: :ovcs_base_can_system_rpi3a,
      bridges: [RadioControlBridge],
      default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"}
    }
  }
end
```

Each map key becomes its own build target:

```sh
../../ovcs build <%= @name %> radio_control
```

Each bridge firmware needs a CAN topology YAML — by convention at
`priv/can/bridges/<firmware_id>.yml` (override the path with
`:can_config_path` in the entry). The shared `bridges/firmware` image
reads `VEHICLE` + `BRIDGE_FIRMWARE_ID` at boot and only supervises
the bridges listed in that entry, so one vehicle can run several
bridge firmwares in parallel on different SoCs.

### 5. Bus relay (optional)

The VMS, infotainment, and each bridge firmware each run their own
local `OvcsBus` (Phoenix.PubSub). To stitch them into a single logical
bus across the vehicle LAN, declare `bus_relay/0` on each composer:

```elixir
# lib/<%= @name %>/vms/composer.ex
@impl VmsCore.Vehicle
def bus_relay do
  %{
    broker: [host: "<%= @name %>-vms.local", port: 1884],
    client_id: "<%= @name %>-vms",
    topic_prefix: "ovcs/<%= @name %>/bus",
    topics: [:ready_to_drive, :vms_status]
  }
end
```

Identical shape on `lib/<%= @name %>/infotainment/composer.ex`
(different `:client_id`) and inside each `bridge_firmwares/0` entry
as `:bus_relay`. All sides point at the same broker + topic prefix
so a message published locally on one bus arrives on every subscribed
peer. Stand up an MQTT broker (Mosquitto, EMQX, …) on the VMS box;
the commented-out stubs in the scaffold are ready to uncomment once
the broker is reachable.

Echo loops are avoided by tagging inbound messages with
`:relay_origin` — the relay skips forwarding messages it just
injected.

### 6. Nerves targets

Set at scaffold time:

- `vms` → `:<%= @vms_target %>`
<%= if @infotainment do %>- `infotainment` → `:<%= @infotainment_target %>`
<% end %>
Change the `nerves_target/1` clauses in `lib/<%= @name %>.ex` if you
move to different boards. Bridge firmware targets are declared inside
each entry of `bridge_firmwares/0` (see section 4).

Shared firmware defaults for each Nerves target live in
[`vms/firmware/targets/<target>/`](../../vms/firmware/targets)<%= if @infotainment do %>
and [`infotainment/firmware/targets/<target>/`](../../infotainment/firmware/targets)<% end %>.
At scaffold time the per-target files were copied into this vehicle's
`priv/firmware/vms/`<%= if @infotainment do %> and `priv/firmware/infotainment/`<% end %> so you can edit them in
place. The firmware build prefers `priv/firmware/<side>/<file>` over
the shared default when both exist, so deleting a file falls back to
the current shared version.

## Further reading

- [`docs/applications.md`](../../docs/applications.md) — how
  `core` / `api` / `firmware` / `dashboard` fit together.
- [`docs/hardware_architecture.md`](../../docs/hardware_architecture.md)
  — physical topology, CAN networks, controller boards.
