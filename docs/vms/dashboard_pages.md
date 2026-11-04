---
title: Dashboard pages
description: The page, block and row model your composers return, every block and row type the dashboards render, and how a row finds its metric or action.
---

Both dashboards in OVCS are generic: neither the React VMS dashboard nor the Flutter infotainment app knows anything about your vehicle. Your composers return a map of pages and blocks, the API serves it as JSON, and the dashboard renders whatever it finds. This guide covers the exact shape of that map, every block and row type each dashboard renders, how a row finds the value it shows, and how a button reaches your code. Everything here is framework behaviour and applies to your vehicle as it is; snippets come from the scaffold template and the reference vehicles, labelled as worked examples.

## Two dashboards, one pattern

| | VMS dashboard | Infotainment dashboard |
|---|---|---|
| Composer callback | `dashboard_configuration/0` on `<Vehicle>.Vms.Composer` | `infotainment_configuration/0` on `<Vehicle>.Infotainment.Composer` |
| Behaviour | [`VmsCore.Vehicle`](../../vms/core/lib/vms_core/vehicle.ex) | [`InfotainmentCore.Vehicle`](../../infotainment/core/lib/infotainment_core/vehicle.ex) |
| API | `vms/api`, port `4000` | `infotainment/api`, port `4001` in development |
| Renderer | React in [`vms/dashboard/`](../../vms/dashboard/) | Flutter in [`infotainment/dashboard/`](../../infotainment/dashboard/) |
| Layout | blocks dealt to three columns | fixed grid, blocks placed by cell |
| Metric values from | the VMS bus, via `VmsCore.Metrics` | `status/0` of the module named in each metric |

Both APIs expose these four routes; the VMS also serves `GET /api/firmware`, which its dashboard's top bar reads:

```text
GET  /api/vehicle                         vehicle name, colour, refresh interval
GET  /api/vehicle/pages                   pages, sorted by order
GET  /api/vehicle/pages/:page_id/blocks   blocks of one page, sorted by order
POST /api/actions                         calls trigger_action/2 on a module
```

Both callbacks are optional in their behaviours, but the API calls them on every request: a vehicle without `dashboard_configuration/0` has no working VMS dashboard. [Your vehicle package](../vehicle_package.md#what-a-composer-contributes) covers the rest of each composer.

## The VMS configuration

`dashboard_configuration/0` returns a single map under `:vehicle`. The [scaffold template](../../libraries/ovcs_vehicle/priv/templates/vehicle/) generates this in `lib/my_car/vms/composer/dashboard.ex` for `./ovcs new my_car`; `my_car` and `MyCar` stand for your vehicle throughout this guide:

```elixir
def dashboard_configuration do
  %{
    vehicle: %{
      name: "My Car",
      refresh_interval: 100,
      pages: %{
        "status" => Dashboard.DashboardPage.definition(order: 0)
      }
    }
  }
end
```

The API reads fields with either dot access (the key must exist, or the request raises) or bracket access (optional). The tables below follow that split, from the views in [`vms/api/lib/vms_api_web/views/api/`](../../vms/api/lib/vms_api_web/views/api/).

| Vehicle key | Required | Effect |
|---|---|---|
| `name` | yes | Returned by `GET /api/vehicle`. The VMS dashboard's top bar and browser title name the vehicle with your vehicle module's `name/0`, from `GET /api/firmware`. |
| `refresh_interval` | yes | Milliseconds between metric pushes on the websocket, and the time step of every line chart. |
| `pages` | yes | Map of page id to page. The id is the URL segment and the `:page_id` in the API. |

| Page key | Required | Effect |
|---|---|---|
| `name` | yes | Menu entry and page heading. |
| `order` | yes | Sort position. The first page is served at `/`, the others at `/<page_id>`. |
| `blocks` | yes | Map of block id to block. |

The menu lists your pages under **Pages**, then the dashboard's own **Network** page under **System**: it shows the board's network interfaces and needs no configuration. A page with the id `network` is hidden behind it. The dashboard uses the `@ovcs/ui` frame and colours shared by the OVCS dashboards, in a light or a dark theme.

Every block carries `order` (required), `name` (required), `type` (required) and `full_width` (optional). Each block is a card under its name. The cards are dealt in order to three columns, each column stacking its own cards, so a short card never waits below a tall neighbour; `full_width: true` gives a card its own row across the three, and the cards after it are dealt from the first column again. On a narrow screen every card stacks in one column, in order. [`DynamicPage.jsx`](../../vms/dashboard/src/pages/DynamicPage.jsx) renders exactly two block types, `"table"` and `"lineChart"`. The API has a JSON view for those two only, so a block of any other type makes the whole page's blocks request fail.

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
| `hint` | no | Small text under the label. |

[`format.js`](../../vms/dashboard/src/format.js) renders a value by its type: `true` and `false` become a check or a cross, numbers (including decimals, which arrive as strings) are rounded to two places and followed by the unit, lists are joined with commas, and a string containing a newline is shown as a monospace block. The unit `"fraction"` is shown as a percentage.

An action row has `type: :action` and one of three `input_type` values:

| `input_type` | Renders | Sends |
|---|---|---|
| `:button` | a button labelled `input_name` | `module`, `action`, `extra_parameters` |
| `:number` | a number field, a "now" badge and a button | the same, plus `"value"` as a string |
| `:toggle` | a switch, on while its `status_metric_key` is true | `module`, `action`, `extra_parameters` |

| Action row key | Required | Effect |
|---|---|---|
| `type: :action` | yes | |
| `name` | yes | Row label, and button label when `input_name` is absent. |
| `input_type` | yes | `:button`, `:number` or `:toggle`. |
| `module` | yes | The module whose `trigger_action/2` is called. |
| `action` | yes | The action string passed as its first argument. |
| `input_name` | no | Button label. |
| `extra_parameters` | no | Map merged into the request body, for one action shared by several rows. |
| `status_metric_key` | no | A key on the same `module` the row subscribes to. A `:number` row shows it as the current value and seeds the field from it; a `:toggle` row is on while it is true and needs it to render at all. Clicking the switch only posts the action: the switch moves when the metric does. |
| `hint` | no | Small text under the label. |
| `step` | no | Increment of a `:number` field. Defaults to `"0.01"`. |

The OVCS1 steering column page is the worked example of `:number` rows: three rows share one action and differ only by `extra_parameters`, from [`steering_column_page.ex`](../../vehicles/ovcs1/lib/ovcs1/vms/composer/dashboard/steering_column_page.ex):

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

A `"lineChart"` block plots metrics against time with ECharts. It takes `serie_max_size` (required: points kept per series; 300 in every reference vehicle) and `y_axis`, a list of axes. Each axis has `min`, `max` and `label` (all required) and a `series` list; each series is a `name` (legend entry) and a `metric` map with `module` and `key`, resolved like a metric row. From the OVCS Mini reference vehicle's [`dashboard_page.ex`](../../vehicles/ovcs_mini/lib/ovcs_mini/vms/composer/dashboard/dashboard_page.ex):

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

The chart appends one point per series every `refresh_interval`, so the visible window is `serie_max_size × refresh_interval`: 300 × 70 ms is 21 seconds on the Mini, labelled in seconds up to "now". An axis keeps its `min` and `max` unless a value goes beyond them; it then grows to show that value. An axis may also set `position: "left"` or `"right"`; without it, ECharts puts the first axis on the left and the next on the right. Series take ECharts' default colours.

## How a row finds its metric

Every component on the VMS publishes values on the internal bus as `OvcsBus.Message` structs. `VmsCore.Metrics` subscribes to the `"messages"` topic and keeps the last value of each message, keyed by `source` and then `name`, plus the last unit each publisher gave. A row's `module:` is matched against `source` and its `key:` against `name`. From [`vehicle_motion.ex`](../../vms/core/lib/vms_core/components/ovcs/vehicle_motion.ex):

```elixir
Bus.broadcast("messages", %Bus.Message{
  name: :speed,
  value: speed,
  unit: Units.kilometre_per_hour(),
  source: __MODULE__
})
```

That message is what `%{type: :metric, module: OVCS.VehicleMotion, key: :speed}` displays, with `km/h` appended because the publisher set a unit. Units come from [`OvcsBus.Units`](../../libraries/ovcs_bus/lib/ovcs_bus/units.ex), one function per unit.

`source` is usually `__MODULE__`, but it can be any atom. Components started several times publish under their process name: `OVCS.InputCurve` uses `source: process_name`, and the OVCS Mini's [`throttle_input_curve.ex`](../../vehicles/ovcs_mini/lib/ovcs_mini/vms/composer/dashboard/blocks/throttle_input_curve.ex) passes that name as `module:`. When a row shows `—` forever, the `module`/`key` pair doesn't match anything published; `VmsCore.Metrics.metrics()` in the VMS IEx shell lists every source and name the bus has carried.

On the wire, the dashboard joins the `metrics` channel on `/sockets/dashboard` with the vehicle's refresh interval and pushes `subscribe` for each metric row, series and `status_metric_key` on the page. The channel converts `module` and `key` with `String.to_existing_atom/1` and then pushes the filtered values every interval ([`metrics_channel.ex`](../../vms/api/lib/vms_api_web/channels/metrics_channel.ex)).

## How an action reaches your code

An action row posts a JSON body to `POST /api/actions`:

```json
{"module": "Elixir.VmsCore.Components.OVCS.SteeringColumn", "action": "set_pid_parameter", "parameter": "kp", "value": "0.12"}
```

[`ActionsController`](../../vms/api/lib/vms_api_web/controllers/api/actions_controller.ex) converts `module` to an existing atom and runs `module.trigger_action(action, params)`, where `params` is the whole body with string keys. Two rules follow:

- An action's `module` must be a real module that defines `trigger_action/2`. Unlike a metric source, a process name does not work.
- `trigger_action/2` returns `:ok`, or `{:error, reason}` to refuse: the request then answers `422` and the dashboard shows the reason under the row. Anything else fails the request. A `:number` value arrives as a string; convert it yourself.

The OBD2 reference vehicle's [`diagnostics.ex`](../../vehicles/obd2/lib/obd2/vms/diagnostics.ex) shows the usual shape, one clause per action string:

```elixir
def trigger_action("clear_dtcs", _params) do
  pulse("clear_dtcs")
  :ok
end

def trigger_action("open_extended_session", _params) do
  GenServer.call(__MODULE__, :open_extended_session)
end
```

The second clause relies on its `handle_call` replying `:ok`. For a parametrised action, match the keys you declared in `extra_parameters` alongside `"value"`, as `SteeringColumn` does with `%{"parameter" => parameter, "value" => value}` in [`steering_column.ex`](../../vms/core/lib/vms_core/components/ovcs/steering_column.ex). The framework's `VmsCore.Status` defines `trigger_action("reset_status", _)`, which every vehicle can put on a button.

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

Register it in `dashboard_configuration/0` under a page id, `"status" => Dashboard.DashboardPage.definition(order: 0)`. The reference vehicles keep one module per page and one per reusable block under `vms/composer/dashboard/blocks/`, which keeps each page readable; [OVCS1's pages](../../vehicles/ovcs1/lib/ovcs1/vms/composer/dashboard/) are the largest set to copy from.

## Infotainment pages

The infotainment's pages have the same `vehicle → pages → blocks` shape, on a fixed grid of purpose-built widgets, and read their metrics from a module's `status/0` rather than from the bus. [Infotainment](../infotainment/README.md#pages) lists its block types and the layout validator.

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

Pages come back as `{"type": "page", "id": …, "attributes": {"name"}}` and blocks as `{"type": "block", "id": …, "attributes": {"name", "subtype", "fullWidth", …}}`, with `subtype` carrying your block's `type`. To try an action without the UI, post the body the dashboard would send:

```sh
curl -s -X POST http://localhost:4000/api/actions \
  -H 'Content-Type: application/json' \
  -d '{"module": "Elixir.VmsCore.Status", "action": "reset_status"}'
```

A `201` means `trigger_action/2` returned `:ok`. For the infotainment side, use port `4001` on a vehicle with an infotainment composer (`./ovcs run obd2` or `./ovcs run ovcs1`), and start the Flutter app in its own terminal as the [CLI reference](../../cli/README.md) describes. Open the VMS dashboard on the Vite dev server at `http://localhost:5173`, which hot-reloads; `:4000` serves the last prebuilt bundle.

## Next steps

- [Your vehicle package](../vehicle_package.md): the composers these callbacks live in, and the rest of the vehicle contract.
- [VMS](./README.md) and [Infotainment](../infotainment/README.md): the APIs and dashboards that serve these pages.
- [Drivers](./drivers.md): the components whose metrics your rows display.
- [Testing with CAN](../testing_with_can.md): inject frames on virtual CAN and watch your rows change.
- [Generic controllers](../generic_controllers/README.md): the Generic Controllers page OVCS1 and OVCS Mini carry, and the adoption button on it.
