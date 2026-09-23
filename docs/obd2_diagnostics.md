---
title: OBD2 reference application
description: An application with no drivetrain that turns the VMS into an OBD2 / KWP2000 / UDS scan tool for any car, and how to extend it for brand-specific data.
---

OBD2 is the smallest of the three reference applications: a vehicle package under `vehicles/obd2/` that turns the framework's VMS into an OBD2 / KWP2000 / UDS scan tool. It has no drivetrain and no bridges; every supervised process reads or probes the diagnostic CAN bus of whatever car you plug into. It runs on the same Raspberry Pi 4 the framework targets for every VMS.

> [!NOTE]
> OBD2 is worth reading even if you never scan a car: it shows how little an application has to contain. Two GenServers, a handful of YAML imports and a composer. Your own application follows the same contract; see [Your application package](./vehicle_parameterisation.md).

## Why this is an application, not a feature

The framework already speaks CAN through Cantastic, ships a Phoenix dashboard with a metrics channel, and loads whatever package `VEHICLE` names at boot. A scan tool is therefore just another composer, one that subscribes to OBD2 and UDS request loops instead of Leaf inverter frames, and the framework's dashboard displays the results without a frontend change. So:

- Adding or changing a probe is a YAML edit plus, optionally, a few lines of Elixir in the application. The framework doesn't change.
- The dashboard the OVCS1 reference application uses for debugging works on any car with an OBD-II port.
- Brand-specific knowledge stays in one application.

Select it with `VEHICLE=Obd2`, or pass `obd2` to the CLI. The package has a VMS and an infotainment composer and declares no bridges; its layout is in the [package README](../vehicles/obd2/README.md).

## What you get out of the box

Five dashboard pages, all running on Cantastic's standard codecs:

| Page | What it shows | Modes used |
|---|---|---|
| Dashboard | VIN, ECU name, headline live metrics, DTC counts, RPM/speed chart | 01, 03, 07, 0A, 09, 19 |
| Live data | Engine / temperature / electrical tables and line charts | 01 |
| DTCs | Stored / pending / permanent / UDS DTCs with Clear buttons | 03, 07, 0A, 19 + 04, 14 |
| Vehicle info | Mode 09 identification + UDS extended-session toggle | 09, 10, 3E |
| Discovery | Supported PIDs, UDS DID scan, passive bus traffic | 01 PID 0x00, 22, raw |

A DTC (Diagnostic Trouble Code) is the standardised five-character code an ECU sets when it detects a fault: what turns on the "check engine" light. The first character names the system: `P` powertrain, `C` chassis, `B` body, `U` network. The dashboard reads four kinds:

- **Stored (Mode 03)**: confirmed faults; the warning light is on because of these.
- **Pending (Mode 07)**: detected once, not yet confirmed.
- **Permanent (Mode 0A)**: emissions faults that deliberately survive a Mode 04 clear; only a successful drive cycle removes them.
- **UDS (Mode 19)**: the modern equivalent of Mode 03, with a status byte per code (confirmed, pending, test-failed-since-last-clear, …). Most post-2010 ECUs only answer Mode 19.

## Architecture

At boot, the application's `priv/can/vms.yml` imports one YAML per request from the framework's `ovcs_can` library, under the `obd2` network's `obd2_requests:` key. Cantastic spawns one `OBD2.Request` GenServer per declared request and polls it at the frequency its YAML sets. Two GenServers in the application consume the answers and broadcast them as ordinary `%OvcsBus.Message{}`s, so the framework's metrics pipeline carries them to the dashboard.

```text
vehicles/obd2/priv/can/vms.yml
  imports per-request YAMLs from libraries/ovcs_can/priv/can/components/obd2/
        │ at boot
        ▼
Cantastic.Interface ── spawns one OBD2.Request GenServer per declared request
        │ handle_obd2_response                 ┆ raw CAN frames
        ▼                                      ▼
Obd2.Vms.Diagnostics                    Obd2.Vms.Discovery
  subscribes to every request             raw socket sniff + Mode 22 DID walk
  pulses on-demand actions                broadcasts metrics on the bus
  broadcasts metrics on the bus
        │                                      │
        └──────────────► VmsCore.Metrics ◄─────┘
                          → VmsApi metrics channel → Vue dashboard
```

Adding a metric is mostly "subscribe to one more Cantastic request, broadcast its decoded value". The dashboard composer then references it by `{module, key}` like any other metric.

## Setup

### Prerequisites

- The VMS Raspberry Pi 4 with an MCP2515 SPI CAN HAT (a Waveshare 2-CAN HAT). The Pi-side configuration, including the `mcp2515-can0` overlay, is in `vehicles/obd2/priv/firmware/vms/config.txt`. The `obd2` network maps to `spi0.0` on target and `vcan0` on the host.
- An OBD-II cable wired so that:
  - pin 6 → CAN-High on the HAT's CAN0 channel;
  - pin 14 → CAN-Low;
  - pins 4 and 5 → ground;
  - pin 16 → 12 V, only if the VMS draws its power from the OBD2 port (it usually doesn't).

### Build and flash

```sh
./ovcs build obd2 vms
./ovcs burn obd2 vms
```

Plug into the OBD-II port and power up. The dashboard is at `http://obd2-vms.local:4000/`. For a dry run without a car, `./ovcs run obd2` boots the VMS and infotainment BEAMs against virtual CAN; see the [Quickstart](./quickstart.md).

## What is safe to do passively

Default polling is read-only: reading live data, codes or the VIN doesn't change ECU state. The dashboard's **Clear** buttons (Mode 04 / Mode 14) and the UDS extended-session toggle (Mode 10 / Mode 3E) are the only things that write to the bus, and only when clicked.

> [!WARNING]
> Continuous polling (the fast live-data loop runs at 10 Hz) keeps every ECU on the bus awake and prevents the usual "30 seconds of quiet, then sleep". On a parked modern car that drains the 12 V battery: unplug the scanner between drives or power the VMS through the ignition.

## Extending the application

Everything below changes the OBD2 application, never the framework. Standardised wire formats live in YAML; brand quirks live in the application's Elixir. If your brand-specific additions grow beyond a module or two, a scan tool for one make is a good application of its own: scaffold it with `./ovcs new` and borrow these patterns.

### 1. Add a live Mode 01 PID

Add a parameter to one of the live-data files, `libraries/ovcs_can/priv/can/components/obd2/mode01_live_data_{fast,slow}.yml`:

```yaml
- name: barometric_pressure
  id: 0x33
  kind: integer
  value_length: 8
  unit: kPa
```

Cantastic packs it into the existing batched Mode 01 request, and `Diagnostics` broadcasts every Mode 01 parameter automatically as `%Bus.Message{name: :barometric_pressure, source: Diagnostics}`. The only Elixir change is referencing it from a dashboard page:

```elixir
%{type: :metric, name: "Barometric pressure",
  module: Diagnostics, key: :barometric_pressure, unit: "kPa"}
```

The fast file (100 ms) is for values that move with every driver input; the slow one (1 s) for everything else.

### 2. Add a brand-specific UDS DID (Mode 22)

Manufacturer data sits behind 16-bit DIDs read with Mode 22. Cantastic stays brand-agnostic by exposing the raw payload as a `kind: bytes` parameter and letting your handler decode it. For a Nissan Leaf battery cell-voltage block:

```yaml
# libraries/ovcs_can/priv/can/components/obd2/leaf_battery_cells.yml
name: leaf_battery_cells
request_frame_id: 0x79B
response_frame_id: 0x7BB
frequency: 1000
mode: 0x22
parameters:
  - name: cells
    id: 0x0002
    kind: bytes
    value_length: 1536          # 96 cells × 16 bits
```

Import it under `obd2_requests:` in `vehicles/obd2/priv/can/vms.yml`:

```yaml
      - import!:@ovcs_can:can/components/obd2/leaf_battery_cells.yml
```

Decode it in a small module of its own, keeping brand code out of `Diagnostics`:

```elixir
defmodule Obd2.Vms.Brands.NissanLeaf do
  use GenServer
  alias Cantastic.OBD2
  alias OvcsBus, as: Bus

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    OBD2.Request.subscribe(self(), :obd2, "leaf_battery_cells")
    OBD2.Request.enable(:obd2, "leaf_battery_cells")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:handle_obd2_response,
                   %OBD2.Response{request_name: "leaf_battery_cells",
                                  parameters: %{"cells" => p}}},
                  state) do
    voltages = decode_cell_voltages(p.value)
    Bus.broadcast("messages", %Bus.Message{
      name: :leaf_cell_voltages, value: voltages, source: __MODULE__
    })
    {:noreply, state}
  end

  defp decode_cell_voltages(<<>>), do: []
  defp decode_cell_voltages(<<v::big-unsigned-integer-size(16), rest::bitstring>>) do
    [v / 1000 | decode_cell_voltages(rest)]
  end
end
```

Supervise it from the composer alongside `Diagnostics` and `Discovery`:

```elixir
# vehicles/obd2/lib/obd2/vms/composer.ex
def children do
  [
    {Vms, []},
    {Vms.Diagnostics, []},
    {Vms.Discovery, []},
    {Vms.Brands.NissanLeaf, []}
  ]
end
```

The pattern is the same for every brand: declare the wire format in YAML with `kind: bytes`, put the bit-twiddling in a brand-named module, broadcast the result on the bus. The dashboard then shows it through `%{module: NissanLeaf, key: :leaf_cell_voltages}`.

### 3. KWP2000 ECUs (Mode 21)

Older Toyota, Mitsubishi and some Hyundai platforms answer Mode 0x21 (ReadDataByLocalIdentifier) instead of Mode 01, and Mode 0x1A (ReadECUIdentification) instead of Mode 09. The wire format mirrors Mode 01 with 8-bit local identifiers, so the YAML has the same shape:

```yaml
name: toyota_engine_data
request_frame_id: 0x7E0
response_frame_id: 0x7E8
frequency: 200
mode: 0x21
parameters:
  - name: engine_load
    id: 0x05
    kind: integer
    value_length: 8
    unit: "%"
  - name: throttle_position
    id: 0x07
    kind: integer
    value_length: 8
    unit: "%"
```

`Diagnostics` doesn't decode Mode 0x21 (it would over-fit to one platform): add a handler as for Mode 22 above.

### 4. UDS routines (Mode 31)

Forced DPF regeneration, ABS bleed, throttle adaptation reset, calibration writes: all sit behind Mode 0x31 RoutineControl, which Cantastic treats as manufacturer-specific:

```yaml
name: vw_throttle_adapt_reset
request_frame_id: 0x7E0
response_frame_id: 0x7E8
frequency: 5000
mode: 0x31
options:
  routine_id: 0x0203
  sub_function: 0x01      # startRoutine (the default)
```

Fire it on demand the way `Diagnostics.pulse/2` handles Mode 04 and Mode 14. Routines almost always need an extended session first: open it from the dashboard's Vehicle info page, then trigger the routine.

### 5. Probe brand-specific DID ranges

`Obd2.Vms.Discovery.start_did_scan/1` takes `:dids`, `:request_id` and `:response_id`, so you can probe non-standard ranges or other ECUs without touching the GenServer. It defaults to the ISO 14229-1 identification range `0xF180`–`0xF19E` on the powertrain pair `0x7E0` / `0x7E8`. From IEx on the device:

```elixir
# Sweep VW long-coding bytes on the gateway ECU
Obd2.Vms.Discovery.start_did_scan(
  dids: Enum.to_list(0x0100..0x017F),
  request_id: 0x710,
  response_id: 0x77A
)
```

A per-brand dashboard button is a `trigger_action/2` clause calling `start_did_scan/1` with a preset range.

### 6. Read the bus for proprietary chatter

The Discovery sniffer counts every frame id it sees on the `obd2` network and republishes a per-id summary every second. That is the starting point for reverse-engineering vehicle-specific broadcasts: spot a recurring id that isn't standard OBD2 (not `0x7DF` or `0x7E0`–`0x7EF`), watch how its bytes change while you exercise the car, then declare it under the network's `received_frames:` in `vms.yml` and add a component module to decode it. It is the same pattern the framework uses for the Leaf inverter, the EVPT charger and the Polo body modules; OBD2 gives you a place to do that work without a drivetrain.

## Negative responses

When an ECU rejects a request (`0x7F SID NRC`), the subscribing GenServer receives `{:handle_obd2_error, {:nrc, sid, code, name}}` instead of a response. `Diagnostics` logs it and keeps polling; the request process never crashes. Common ones:

| NRC | Name | What to do |
|---|---|---|
| 0x11 | `service_not_supported` | The ECU doesn't speak this mode (Mode 19 on a 2005 car, say): drop the request from the YAML or accept the silence. |
| 0x12 | `sub_function_not_supported` | Try a different `sub_function:` in `options:`. |
| 0x22 | `conditions_not_correct` | The vehicle isn't in the state the ECU wants: engine off, ignition on, P or N, … |
| 0x33 | `security_access_denied` | The service needs Mode 0x27 security access (seed/key). Cantastic doesn't implement it; do it by hand through `Cantastic.Socket`. |
| 0x7E | `sub_function_not_supported_in_active_session` | Open the extended session first (Mode 10 0x03). |

## Where things live

| What | Where |
|---|---|
| Standard OBD2 / UDS request YAMLs | `libraries/ovcs_can/priv/can/components/obd2/` |
| Application topology (imports) | `vehicles/obd2/priv/can/vms.yml` |
| Diagnostic orchestrator | `vehicles/obd2/lib/obd2/vms/diagnostics.ex` |
| PID name catalogue | `vehicles/obd2/lib/obd2/vms/pid_catalog.ex` |
| Discovery (passive + DID probe) | `vehicles/obd2/lib/obd2/vms/discovery.ex` |
| Composer and dashboard pages | `vehicles/obd2/lib/obd2/vms/composer/` |
| Multi-line metric rendering | `vms/dashboard/src/components/tables/RealTimeTable.vue` |

The Cantastic reference for every supported service, its YAML options and the negative-response table is the `Cantastic.OBD2` moduledoc in the [Cantastic repository](https://github.com/open-vehicle-control-system/cantastic).
