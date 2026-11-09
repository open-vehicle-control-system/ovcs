---
title: Infotainment
description: The optional in-car touchscreen role, what it shows, how its core, API, Flutter app and firmware fit together, how your vehicle opts in, and the pages and blocks it declares.
---

The infotainment is the in-car touchscreen: gear selection, speed, battery, door and status overviews, and settings, on a touchscreen driven by a Raspberry Pi 5 (a 10-inch one in the OVCS1 reference vehicle). It is an optional role. A vehicle opts in by declaring it; a vehicle without a head unit omits it and nothing is built for it. The OVCS1 and OBD2 reference vehicles have one; the OVCS Mini does not.

> [!NOTE]
> Everything on this page holds for any vehicle. OVCS1 appears as the worked example. See [Framework and vehicles](../framework.md).

## What it does

The infotainment is a display and an input, never a controller. It sits on the `ovcs` bus only, reads the status frames the VMS emits (VMS status, gear, drivetrain, passenger compartment, battery) and shows them; what the driver asks for on the screen, such as a gear, goes back to the VMS as a CAN frame, `infotainment_status` (`0x201`), which the VMS's `OVCS.Infotainment` component reads. The VMS decides whether to honour it, under the same [gear rules](../vms/how_it_works.md#managers) as any other request.

## Where it runs

On the vehicle, the infotainment is a Nerves image for the Raspberry Pi 5 on the [`ovcs_base_can_system_rpi5`](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi5) system, with CAN and display support. The Flutter app is cross-compiled during the firmware build and bundled into the image, so the Pi runs no Flutter tooling:

```sh
./ovcs build <vehicle> infotainment
./ovcs burn <vehicle> infotainment
```

On your workstation, `./ovcs run <vehicle>` starts it as the `<vehicle>-infotainment` BEAM for any vehicle that declares the role, with the API on `http://localhost:4001`. The Flutter app needs its own terminal, because its hot reload is keyboard-driven:

```sh
mise run infotainment-dashboard   # cd infotainment/dashboard && flutter run -d linux
```

The app talks to `localhost:4001`, which on the vehicle is the Phoenix endpoint on the same Pi. On the firmware that endpoint listens on localhost only; to reach it from another host, for example the app running on your workstation against the vehicle, set `INFOTAINMENT_API_ON_ALL_INTERFACES` to `true` in the vehicle's `.env.exs`.

## Four layers

The infotainment has the same layered shape as the [VMS](../vms/README.md): each layer is its own project, depending on the one below, with no vehicle code.

| Layer | Path | What it is |
|---|---|---|
| Core | [`infotainment/core/`](../../infotainment/core/README.md) | `InfotainmentCore`: the `InfotainmentCore.Vehicle` behaviour, the layout validator, the board temperature, time settings persisted in SQLite. Depends on `cantastic`, `ovcs_can`, `ovcs_bus`, `ecto_sqlite3` |
| API | [`infotainment/api/`](../../infotainment/api/README.md) | `InfotainmentApi`: a Phoenix JSON API with the VMS API's page and block routes, and a `metrics` channel |
| Dashboard | [`infotainment/dashboard/`](../../infotainment/dashboard/README.md) | A Flutter app for Linux (Flutter pinned in `mise.toml`) that renders the pages your composer declares, over `phoenix_socket` |
| Firmware | [`infotainment/firmware/`](../../infotainment/firmware/README.md) | `InfotainmentFirmware`: the Nerves shell for the Pi 5, bundling the Flutter app with [`nerves_flutter_support`](https://hex.pm/packages/nerves_flutter_support) |

## How it works

`InfotainmentCore.Application` supervises the framework's processes, then your composer's children:

```text
InfotainmentCore.Application                 (framework)
├── InfotainmentCore.Repo          SQLite: display settings
├── Ecto.Migrator                  applies pending migrations on boot
├── InfotainmentCore.Temperature   the board's temperature, read on request
├── InfotainmentCore.TimeSettings  time zone and formats, persisted
├── OvcsBus.Cluster                connects this BEAM to the vehicle's other firmwares
└── composer children              (your package, selected by VEHICLE)
```

Your vehicle's infotainment GenServer, `Ovcs1.Infotainment` in the OVCS1 reference vehicle, does the vehicle-specific work: it subscribes to the VMS's status frames on `ovcs` with Cantastic, keeps the decoded values in its state, answers `status/0` with them, and emits `infotainment_status` with what the driver requested. It follows the same CAN-in, CAN-out recipe as a [VMS component](../vms/how_it_works.md#the-component-pattern).

The Flutter app boots by fetching `/api/vehicle` and `/api/vehicle/pages`, builds the screen from them, then joins the `metrics` channel on `/sockets/dashboard`. Its values come from each block's module rather than from the bus, as [Pages](#pages) explains. A button posts to `/api/actions`, which calls the module's `trigger_action/2`, the same contract as on the VMS.

## Opting in

Your vehicle's top-level module declares the role with two callbacks of `OvcsVehicle`: `infotainment/0` returns your `<Vehicle>.Infotainment.Composer`, and `infotainment_target/0` names the Nerves target, `:ovcs_base_can_system_rpi5` in every reference vehicle. The composer implements [`InfotainmentCore.Vehicle`](../../infotainment/core/lib/infotainment_core/vehicle.ex): the children to supervise, where the infotainment CAN topology lives (usually `priv/can/infotainment.yml`) and how its networks map to interfaces, and optionally the pages. `./ovcs new` scaffolds all of it; `--no-infotainment` leaves it out. [Your vehicle package](../vehicle_package.md) shows where each file goes.

## Pages

The infotainment configuration has the same `vehicle → pages → blocks` shape, but blocks sit on a fixed grid and each block type is a purpose-built widget. From the OVCS1 reference vehicle's [`infotainment.ex`](../../vehicles/ovcs1/lib/ovcs1/infotainment/composer/infotainment.ex), the vehicle map carries, in addition to `name`, `main_color`, `refresh_interval` and `pages`:

- `module` (required by the Flutter app, which reads it as a non-null string) and `grid_columns` / `grid_rows` (required; 24 × 8 in every reference vehicle);
- `background_image` (an asset path in the Flutter bundle, overridable per page), `sidebar` (`width`, `background_color`) and `block_style` (`background_color`, `border_radius`, `padding`, `margin`), all optional. Colours are hex strings, `AARRGGBB` or `RRGGBB`.

A page's `icon` is a key of `_iconMap` in [`launcher_screen.dart`](../../infotainment/dashboard/lib/components/launcher_screen.dart) (`"dashboard"`, `"settings"`, `"battery"`, `"car"`, …); unknown names fall back to a generic icon. A block carries `order`, `name`, `type`, `columns` and `rows` (all required), `column` and `row` (0-indexed position, default 0), and optionally `metrics` (`module`, `key`, `label`), `actions` (`module`, `action`) and `config`. [`block_renderer.dart`](../../infotainment/dashboard/lib/components/blocks/block_renderer.dart) knows six types:

| `type` | Reads | Actions |
|---|---|---|
| `speedGauge` | the first metric; `config.unit` (default `km/h`) and `config.max` (default 180). The scale starts at 0. | none |
| `gearSelector` | the first metric, a gear string (`parking`, `reverse`, `neutral`, `drive`) | the first action, posted with `"gear"` |
| `carOverview` | metrics by key: `front_left_door_open`, `front_right_door_open`, `rear_left_door_open`, `rear_right_door_open`, `trunk_door_open`, `beam_active`, `handbrake_engaged`, `ready_to_drive` | none |
| `batteryOverview` | metrics by key: `pack_voltage`, `pack_state_of_charge`, `pack_average_temperature`, `pack_current`, `pack_is_charging`, `j1772_plug_state` | none |
| `statusGrid` | every metric, titled by `label` (or the key); `"OK"`/`true` and `"MISSING"`/`false` get their own colours, anything else is shown as a fault | none |
| `timeSettings` | metrics `timezone`, `time_format`, `date_format` | `set_timezone`, `set_time_format`, `set_date_format`, matched by action name |

`carOverview`, `batteryOverview` and `timeSettings` look metrics up by exact key, so your `status/0` map must use those names. Any other `type` renders as "Unknown block".

Infotainment metrics don't come from the bus. The infotainment API's [`metrics_channel.ex`](../../infotainment/api/lib/infotainment_api_web/channels/metrics_channel.ex) calls `module.status()` for each subscribed module, expects `{:ok, map}`, and reads each `key` from that map. A block's `module` is therefore a module with a `status/0`, typically your `<Vehicle>.Infotainment` GenServer, which the template gives a `handle_call(:status, …)` replying `{:reply, {:ok, state}, state}`. Actions go through the same `POST /api/actions` and `trigger_action/2` contract as on the VMS: [`InfotainmentApiWeb.Api.ActionsController`](../../infotainment/api/lib/infotainment_api_web/controllers/api/actions_controller.ex) calls `module.trigger_action(action, params)` only for a `module` and `action` pair a block's `actions` declares, and answers `404` otherwise; return `:ok`, or `{:error, reason}` to answer `422`. OVCS1's gear selector lands in `Ovcs1.Infotainment.trigger_action("request_gear", %{"gear" => gear})`. `InfotainmentCore.TimeSettings` is a framework module that serves the `timeSettings` block on any vehicle.

A worked example block, OVCS1's speed gauge, from [`speed_gauge_block.ex`](../../vehicles/ovcs1/lib/ovcs1/infotainment/composer/infotainment/blocks/speed_gauge_block.ex):

```elixir
%{
  order: order,
  name: "Speed",
  type: "speedGauge",
  column: column,
  row: row,
  columns: columns,
  rows: rows,
  metrics: [%{module: Infotainment, key: :speed}],
  config: %{unit: "km/h", min: 0, max: 180}
}
```

### Layout validation

The grid has no automatic flow, so two blocks can overlap or run off the screen. [`InfotainmentCore.LayoutValidator`](../../infotainment/core/lib/infotainment_core/layout_validator.ex) catches both: `validate!/4` raises when a block's `column + columns` or `row + rows` exceeds the grid, or when two blocks' rectangles intersect. It needs `column` and `row` set explicitly on every block. The template and both reference composers call it from `infotainment_configuration/0`, and the composer runs on every API request, so a bad layout makes every request raise with a message naming the blocks:

```elixir
defp validate_pages!(pages) do
  Enum.each(pages, fn {page_id, page} ->
    InfotainmentCore.LayoutValidator.validate!(page_id, page.blocks, @grid_columns, @grid_rows)
  end)
end
```

Keep that call when you edit the composer. OVCS1's dashboard page is a worked example of a full 24 × 8 grid: a 4-column gear selector, a 10-column gauge and a 10-column car overview on rows 0 to 4, then battery and status grid at 12 columns each on rows 5 to 7.

## Reference

```text
GET  /api/vehicle                         vehicle metadata
GET  /api/vehicle/pages                   the screen's pages
GET  /api/vehicle/pages/:page_id/blocks   the blocks of one page
POST /api/actions                         call an action on a module
```

The socket at `/sockets/dashboard` carries one channel, `metrics`. The API listens on port `4001` on a workstation, so it runs next to the VMS API on `4000`.

## Where next

- [Dashboard pages](../vms/dashboard_pages.md): the page and block model shared with the VMS dashboard.
- [Your vehicle package](../vehicle_package.md): the composers and the boot flow.
- [Running on hardware](../running_hardware.md): build, burn and update the infotainment image.
