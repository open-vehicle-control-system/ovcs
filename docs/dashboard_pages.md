---
title: Dashboard pages
description: The page, block and row model your composers return, every block and row type the dashboards render, and how a row finds its metric or action.
---

Both dashboards in OVCS are generic: neither the Vue VMS dashboard nor the Flutter infotainment app knows anything about your vehicle. Your composers return a map of pages and blocks, the API serves it as JSON, and the dashboard renders whatever it finds. This guide covers the exact shape of that map, every block and row type each dashboard renders, how a row finds the value it shows, and how a button reaches your code. Everything here is framework behaviour and applies to your vehicle as it is; snippets come from the scaffold template and the reference vehicles, labelled as worked examples.

## Two dashboards, one pattern

| | VMS dashboard | Infotainment dashboard |
|---|---|---|
| Composer callback | `dashboard_configuration/0` on `<Vehicle>.Vms.Composer` | `infotainment_configuration/0` on `<Vehicle>.Infotainment.Composer` |
| Behaviour | [`VmsCore.Vehicle`](../vms/core/lib/vms_core/vehicle.ex) | [`InfotainmentCore.Vehicle`](../infotainment/core/lib/infotainment_core/vehicle.ex) |
| API | `vms/api`, port `4000` | `infotainment/api`, port `4001` in development |
| Renderer | Vue 3 in [`vms/dashboard/`](../vms/dashboard/) | Flutter in [`infotainment/dashboard/`](../infotainment/dashboard/) |
| Layout | three-column flow of blocks | fixed grid, blocks placed by cell |
| Metric values from | the VMS bus, via `VmsCore.Metrics` | `status/0` of the module named in each metric |

Both APIs expose the same four routes:

```text
GET  /api/vehicle                         vehicle name, colour, refresh interval
GET  /api/vehicle/pages                   pages, sorted by order
GET  /api/vehicle/pages/:page_id/blocks   blocks of one page, sorted by order
POST /api/actions                         calls trigger_action/2 on a module
```

Both callbacks are optional in their behaviours, but the API calls them on every request: a vehicle without `dashboard_configuration/0` has no working VMS dashboard. [Your vehicle package](./vehicle_package.md#what-a-composer-contributes) covers the rest of each composer.

## The VMS configuration

`dashboard_configuration/0` returns a single map under `:vehicle`. The [scaffold template](../libraries/ovcs_vehicle/priv/templates/vehicle/) generates this in `lib/my_car/vms/composer/dashboard.ex` for `./ovcs new my_car`; `my_car` and `MyCar` stand for your vehicle throughout this guide:

```elixir
def dashboard_configuration do
  %{
    vehicle: %{
      name: "My Car",
      main_color: "blue",
      refresh_interval: 100,
      pages: %{
        "status" => Dashboard.DashboardPage.definition(order: 0)
      }
    }
  }
end
```

The API reads fields with either dot access (the key must exist, or the request raises) or bracket access (optional). The tables below follow that split, from the views in [`vms/api/lib/vms_api_web/views/api/`](../vms/api/lib/vms_api_web/views/api/).

| Vehicle key | Required | Effect |
|---|---|---|
| `name` | yes | Sidebar heading and browser title (`<name> VMS`). |
| `main_color` | yes | Tailwind colour for the sidebar and buttons. Only `orange`, `red`, `blue`, `indigo`, `gray`, `green`, `amber`, `rose` and `teal` are safelisted in [`tailwind.config.js`](../vms/dashboard/tailwind.config.js); any other name renders unstyled. |
| `refresh_interval` | yes | Milliseconds between metric pushes on the websocket, and the time step of every line chart. |
| `pages` | yes | Map of page id to page. The id is the URL segment and the `:page_id` in the API. |

| Page key | Required | Effect |
|---|---|---|
| `name` | yes | Sidebar entry and page heading. |
| `order` | yes | Sort position. The first page is served at `/`, the others at `/<page_id>`. |
| `icon` | no | A component name from `@heroicons/vue/24/outline` (`"HomeIcon"`, `"CogIcon"`, `"ArrowPathIcon"`). Defaults to `GlobeAltIcon`. |
| `blocks` | yes | Map of block id to block. |

The dashboard appends a **Network** page after yours; it shows the board's network interfaces and needs no configuration.

Every block carries `order` (required), `name` (required), `type` (required) and `full_width` (optional). Blocks flow into a three-column grid; `full_width: true` makes one span all three. [`DynamicView.vue`](../vms/dashboard/src/views/DynamicView.vue) renders exactly two block types, `"table"` and `"lineChart"`. The API has a JSON view for those two only, so a block of any other type makes the whole page's blocks request fail.

## Table blocks and rows

A `"table"` block has a `rows` list. Each row is a metric (show a value) or an action (send a command), picked by `type:`.

| Metric row key | Required | Effect |
|---|---|---|
| `type: :metric` | yes | |
| `module` | yes | The bus source that publishes the value (see below). |
| `key` | yes | The message name. |
| `name` | no | Row label. |
| `unit` | no | Overrides the unit the publisher attached. |
| `placeholder` | no | Shown while the value is `nil`. Defaults to `—`. |

[`RealTimeTable.vue`](../vms/dashboard/src/components/tables/RealTimeTable.vue) renders a value by its type: `true` and `false` become a check or a cross, numbers (including decimals, which arrive as strings) are rounded to two places and followed by the unit, lists are joined with commas, and a string containing a newline is shown as a monospace block. The unit `"fraction"` is shown as a percentage.

An action row has `type: :action` and one of three `input_type` values:

| `input_type` | Renders | Sends |
|---|---|---|
| `:button` | a button labelled `input_name` | `module`, `action`, `extra_parameters` |
| `:number` | a number field, a "now" badge and a button | the same, plus `"value"` as a string |
| `:toggle` | a switch | `module`, `action`, `extra_parameters` |

| Action row key | Required | Effect |
|---|---|---|
| `type: :action` | yes | |
| `name` | yes | Row label, and button label when `input_name` is absent. |
| `input_type` | yes | `:button`, `:number` or `:toggle`. |
| `module` | yes | The module whose `trigger_action/2` is called. |
| `action` | yes | The action string passed as its first argument. |
| `input_name` | no | Button label. |
| `extra_parameters` | no | Map merged into the request body, for one action shared by several rows. |
| `status_metric_key` | no | A key on the same `module` the row subscribes to. A `:number` row shows it as the current value and seeds the field from it; a `:toggle` row draws its position from it and needs it to render at all. |
| `hint` | no | Small text under the label. |
| `step` | no | Increment of a `:number` field. Defaults to `"0.01"`. |

The OVCS1 steering column page is the worked example of `:number` rows: three rows share one action and differ only by `extra_parameters`, from [`steering_column_page.ex`](../vehicles/ovcs1/lib/ovcs1/vms/composer/dashboard/steering_column_page.ex):

```elixir
%{
  type: :action,
  name: "Kp",
  hint: "Proportional — strength of immediate correction",
  input_type: :number,
  step: "0.01",
  input_name: "Set",
  module: SteeringColumn,
  action: "set_pid_parameter",
  extra_parameters: %{"parameter" => "kp"},
  status_metric_key: :kp
}
```

## Line chart blocks

A `"lineChart"` block plots metrics against time with ECharts. It takes `serie_max_size` (required: points kept per series; 300 in every reference vehicle) and `y_axis`, a list of axes. Each axis has `min`, `max` and `label` (all required) and a `series` list; each series is a `name` (legend entry) and a `metric` map with `module` and `key`, resolved like a metric row. From the OVCS Mini reference vehicle's [`dashboard_page.ex`](../vehicles/ovcs_mini/lib/ovcs_mini/vms/composer/dashboard/dashboard_page.ex):

```elixir
"speed-and-rpm" => %{
  order: 2,
  name: "Speed & RPM",
  type: "lineChart",
  serie_max_size: 300,
  y_axis: [
    %{
      min: -10,
      max: 10,
      label: "km/h",
      series: [%{name: "Speed", metric: %{module: OVCS.VehicleMotion, key: :speed}}]
    },
    %{
      min: 0,
      max: 500,
      label: "RPM",
      series: [
        %{
          name: "Wheel RPM",
          metric: %{module: OVCS.VehicleMotion, key: :wheel_rotation_per_minute}
        }
      ]
    }
  ]
}
```

The chart appends one point per series every `refresh_interval`, so the visible window is `serie_max_size × refresh_interval`: 300 × 70 ms is 21 seconds on the Mini. Axes are emitted with only `min`, `max`, `label` and `series`; other keys, such as the `position: "right"` some reference pages set, are not forwarded by the API.

## How a row finds its metric

Every component on the VMS publishes values on the internal bus as `OvcsBus.Message` structs. `VmsCore.Metrics` subscribes to the `"messages"` topic and keeps the last value of each message, keyed by `source` and then `name`, plus the last unit each publisher gave. A row's `module:` is matched against `source` and its `key:` against `name`. From [`vehicle_motion.ex`](../vms/core/lib/vms_core/components/ovcs/vehicle_motion.ex):

```elixir
Bus.broadcast("messages", %Bus.Message{
  name: :speed,
  value: speed,
  unit: Units.kilometre_per_hour(),
  source: __MODULE__
})
```

That message is what `%{type: :metric, module: OVCS.VehicleMotion, key: :speed}` displays, with `km/h` appended because the publisher set a unit. Units come from [`OvcsBus.Units`](../libraries/ovcs_bus/lib/ovcs_bus/units.ex), one function per unit.

`source` is usually `__MODULE__`, but it can be any atom. Components started several times publish under their process name: `OVCS.InputCurve` uses `source: process_name`, and the OVCS Mini's [`throttle_input_curve.ex`](../vehicles/ovcs_mini/lib/ovcs_mini/vms/composer/dashboard/blocks/throttle_input_curve.ex) passes that name as `module:`. When a row shows `—` forever, the `module`/`key` pair doesn't match anything published; `VmsCore.Metrics.metrics()` in the VMS IEx shell lists every source and name the bus has carried.

On the wire, the dashboard joins the `metrics` channel on `/sockets/dashboard` with the vehicle's refresh interval and pushes `subscribe` for each metric row, series and `status_metric_key` on the page. The channel converts `module` and `key` with `String.to_existing_atom/1` and then pushes the filtered values every interval ([`metrics_channel.ex`](../vms/api/lib/vms_api_web/channels/metrics_channel.ex)).

## How an action reaches your code

An action row posts a JSON body to `POST /api/actions`:

```json
{"module": "Elixir.VmsCore.Components.OVCS.SteeringColumn", "action": "set_pid_parameter", "parameter": "kp", "value": "0.12"}
```

[`ActionsController`](../vms/api/lib/vms_api_web/controllers/api/actions_controller.ex) converts `module` to an existing atom and runs `:ok = module.trigger_action(action, params)`, where `params` is the whole body with string keys. Two rules follow:

- An action's `module` must be a real module that defines `trigger_action/2`. Unlike a metric source, a process name does not work.
- `trigger_action/2` must return `:ok`. Anything else fails the match and the request returns an error. A `:number` value arrives as a string; convert it yourself.

The OBD2 reference vehicle's [`diagnostics.ex`](../vehicles/obd2/lib/obd2/vms/diagnostics.ex) shows the usual shape, one clause per action string:

```elixir
def trigger_action("clear_dtcs", _params) do
  pulse("clear_dtcs")
  :ok
end

def trigger_action("open_extended_session", _params) do
  GenServer.call(__MODULE__, :open_extended_session)
end
```

The second clause relies on its `handle_call` replying `:ok`. For a parametrised action, match the keys you declared in `extra_parameters` alongside `"value"`, as `SteeringColumn` does with `%{"parameter" => parameter, "value" => value}` in [`steering_column.ex`](../vms/core/lib/vms_core/components/ovcs/steering_column.ex). The framework's `VmsCore.Status` defines `trigger_action("reset_status", _)`, which every vehicle can put on a button.

## A complete page

This page combines the scaffold's status table, the reset button from the OVCS Mini dashboard and the Mini's speed chart. `Vms` is your vehicle's VMS GenServer, which the template publishes `:vms_status` and `:ready_to_drive` from; `OVCS.VehicleMotion` exists only if your composer starts it, so replace that chart's metrics with one of your own components if it doesn't.

```elixir
defmodule MyCar.Vms.Composer.Dashboard.DashboardPage do
  alias MyCar.Vms
  alias VmsCore.Components.OVCS
  alias VmsCore.Status

  def definition(order: order) do
    %{
      name: "Status",
      icon: "HomeIcon",
      order: order,
      blocks: %{
        "vms-status" => %{
          order: 0,
          name: "VMS",
          type: "table",
          rows: [
            %{
              type: :action,
              name: "Reset Status",
              input_type: :button,
              module: Status,
              action: "reset_status"
            },
            %{type: :metric, name: "Status", module: Vms, key: :vms_status},
            %{type: :metric, name: "Ready to drive", module: Vms, key: :ready_to_drive}
          ]
        },
        "speed" => %{
          order: 1,
          name: "Speed",
          type: "lineChart",
          full_width: true,
          serie_max_size: 300,
          y_axis: [
            %{
              min: 0,
              max: 50,
              label: "km/h",
              series: [%{name: "Speed", metric: %{module: OVCS.VehicleMotion, key: :speed}}]
            }
          ]
        }
      }
    }
  end
end
```

Register it in `dashboard_configuration/0` under a page id, `"status" => Dashboard.DashboardPage.definition(order: 0)`. The reference vehicles keep one module per page and one per reusable block under `vms/composer/dashboard/blocks/`, which keeps each page readable; [OVCS1's pages](../vehicles/ovcs1/lib/ovcs1/vms/composer/dashboard/) are the largest set to copy from.

## Infotainment pages

The infotainment configuration has the same `vehicle → pages → blocks` shape, but blocks sit on a fixed grid and each block type is a purpose-built widget. From the OVCS1 reference vehicle's [`infotainment.ex`](../vehicles/ovcs1/lib/ovcs1/infotainment/composer/infotainment.ex), the vehicle map carries, in addition to `name`, `main_color`, `refresh_interval` and `pages`:

- `module` (required by the Flutter app, which reads it as a non-null string) and `grid_columns` / `grid_rows` (required; 24 × 8 in every reference vehicle);
- `background_image` (an asset path in the Flutter bundle, overridable per page), `sidebar` (`width`, `background_color`) and `block_style` (`background_color`, `border_radius`, `padding`, `margin`), all optional. Colours are hex strings, `AARRGGBB` or `RRGGBB`.

A page's `icon` is a key of `_iconMap` in [`launcher_screen.dart`](../infotainment/dashboard/lib/components/launcher_screen.dart) (`"dashboard"`, `"settings"`, `"battery"`, `"car"`, …); unknown names fall back to a generic icon. A block carries `order`, `name`, `type`, `columns` and `rows` (all required), `column` and `row` (0-indexed position, default 0), and optionally `metrics` (`module`, `key`, `label`), `actions` (`module`, `action`) and `config`. [`block_renderer.dart`](../infotainment/dashboard/lib/components/blocks/block_renderer.dart) knows six types:

| `type` | Reads | Actions |
|---|---|---|
| `speedGauge` | the first metric; `config.unit` (default `km/h`) and `config.max` (default 180). The scale starts at 0. | none |
| `gearSelector` | the first metric, a gear string (`parking`, `reverse`, `neutral`, `drive`) | the first action, posted with `"gear"` |
| `carOverview` | metrics by key: `front_left_door_open`, `front_right_door_open`, `rear_left_door_open`, `rear_right_door_open`, `trunk_door_open`, `beam_active`, `handbrake_engaged`, `ready_to_drive` | none |
| `batteryOverview` | metrics by key: `pack_voltage`, `pack_state_of_charge`, `pack_average_temperature`, `pack_current`, `pack_is_charging`, `j1772_plug_state` | none |
| `statusGrid` | every metric, titled by `label` (or the key); `"OK"`/`true` and `"MISSING"`/`false` get their own colours, anything else is shown as a fault | none |
| `timeSettings` | metrics `timezone`, `time_format`, `date_format` | `set_timezone`, `set_time_format`, `set_date_format`, matched by action name |

`carOverview`, `batteryOverview` and `timeSettings` look metrics up by exact key, so your `status/0` map must use those names. Any other `type` renders as "Unknown block".

Infotainment metrics don't come from the bus. The infotainment API's [`metrics_channel.ex`](../infotainment/api/lib/infotainment_api_web/channels/metrics_channel.ex) calls `module.status()` for each subscribed module, expects `{:ok, map}`, and reads each `key` from that map. A block's `module` is therefore a module with a `status/0`, typically your `<Vehicle>.Infotainment` GenServer, which the template gives a `handle_call(:status, …)` replying `{:reply, {:ok, state}, state}`. Actions go through the same `POST /api/actions` and `trigger_action/2` contract as on the VMS; OVCS1's gear selector lands in `Ovcs1.Infotainment.trigger_action("request_gear", %{"gear" => gear})`. `InfotainmentCore.TimeSettings` is a framework module that serves the `timeSettings` block on any vehicle.

A worked example block, OVCS1's speed gauge, from [`speed_gauge_block.ex`](../vehicles/ovcs1/lib/ovcs1/infotainment/composer/infotainment/blocks/speed_gauge_block.ex):

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

The grid has no automatic flow, so two blocks can overlap or run off the screen. [`InfotainmentCore.LayoutValidator`](../infotainment/core/lib/infotainment_core/layout_validator.ex) catches both: `validate!/4` raises when a block's `column + columns` or `row + rows` exceeds the grid, or when two blocks' rectangles intersect. It needs `column` and `row` set explicitly on every block. The template and both reference composers call it from `infotainment_configuration/0`, and the composer runs on every API request, so a bad layout makes every request raise with a message naming the blocks:

```elixir
defp validate_pages!(pages) do
  Enum.each(pages, fn {page_id, page} ->
    InfotainmentCore.LayoutValidator.validate!(page_id, page.blocks, @grid_columns, @grid_rows)
  end)
end
```

Keep that call when you edit the composer. OVCS1's dashboard page is a worked example of a full 24 × 8 grid: a 4-column gear selector, a 10-column gauge and a 10-column car overview on rows 0 to 4, then battery and status grid at 12 columns each on rows 5 to 7.

## Check what the API serves

Boot your vehicle locally; the reference vehicles work the same way:

```sh
./ovcs run ovcs_mini
```

Then read the layout back from the VMS API. A key missing from your map shows up here as an error rather than as a blank dashboard:

```sh
curl -s http://localhost:4000/api/vehicle
curl -s http://localhost:4000/api/vehicle/pages
curl -s http://localhost:4000/api/vehicle/pages/dashboard/blocks
```

Pages come back as `{"type": "page", "id": …, "attributes": {"name", "icon"}}` and blocks as `{"type": "block", "id": …, "attributes": {"name", "subtype", "fullWidth", …}}`, with `subtype` carrying your block's `type`. To try an action without the UI, post the body the dashboard would send:

```sh
curl -s -X POST http://localhost:4000/api/actions \
  -H 'Content-Type: application/json' \
  -d '{"module": "Elixir.VmsCore.Status", "action": "reset_status"}'
```

A `201` means `trigger_action/2` returned `:ok`. For the infotainment side, use port `4001` on a vehicle with an infotainment composer (`./ovcs run obd2` or `./ovcs run ovcs1`), and start the Flutter app in its own terminal as the [CLI reference](../cli/README.md) describes. Open the VMS dashboard on the Vite dev server at `http://localhost:5173`, which hot-reloads; `:4000` serves the last prebuilt bundle.

## Next steps

- [Your vehicle package](./vehicle_package.md): the composers these callbacks live in, and the rest of the vehicle contract.
- [Framework components](./components.md): the VMS and infotainment APIs and dashboards as components, and the drivers whose metrics your rows display.
- [Testing with CAN](./testing_with_can.md): inject frames on virtual CAN and watch your rows change.
- [Generic controllers](./generic_controllers.md): the Generic Controllers page OVCS1 and OVCS Mini carry, and the adoption button on it.
