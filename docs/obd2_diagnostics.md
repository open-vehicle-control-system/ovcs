# OBD2 diagnostic scanner

The `OBD2` vehicle profile turns the VMS into an OBD2 / KWP2000 / UDS
scan tool. It runs on the same VMS hardware as the other vehicles, but
it has no drivetrain to control: every supervised process exists to
read or probe the bus.

## Prerequisites

* The VMS Raspberry Pi 4 with a Waveshare 2-CAN HAT (Pi-side configs in
  `vms/firmware/config/obd2_waveshare_2can_hat`).
* Cantastic checked out on the **`obd2` branch** under
  `libraries/cantastic/`.
  ```bash
  cd libraries/cantastic
  git fetch origin obd2
  git checkout obd2
  ```
  The OBD2 vehicle uses the Mode 09 / 19 / 22 / 14 codecs that only
  exist on that branch.
* An OBDII cable wired so that:
  * pin 6 → CAN-High on the HAT's CAN0 channel
  * pin 14 → CAN-Low
  * pin 4 / 5 → ground
  * pin 16 → 12 V (only needed if the VMS draws power from the OBD2
    port; usually it doesn't).

## Building the firmware

```bash
cd vms/firmware
VEHICLE=OBD2 MIX_TARGET=ovcs_base_can_system_rpi4 mix deps.get
VEHICLE=OBD2 MIX_TARGET=ovcs_base_can_system_rpi4 mix firmware
VEHICLE=OBD2 MIX_TARGET=ovcs_base_can_system_rpi4 mix burn
```

Flash, plug into the OBDII port, power up. The dashboard is reachable
at `http://obd2-vms.local:4000/`.

## What you get

The dashboard exposes five pages:

### 1. Dashboard

A snapshot view: VIN, ECU name, RPM, speed, throttle, engine load,
coolant temperature, control-module voltage, DTC counts and the
supported-PID count, plus an RPM/speed line chart.

### 2. Live data

Mode 01 streamed at 100 ms (RPM, speed, throttle) and 1 s (everything
else). Tables for the Engine, Temperatures and Electrical & Fuel
groups, plus charts for throttle / engine load and the three
temperature sensors.

### 3. DTCs

Two stacked tables:

* **OBD2 emission codes** — Mode 03 (stored), Mode 07 (pending),
  Mode 0A (permanent), with a `Send Mode 04` button that pulses the
  emission-DTC clear request once.
* **UDS DTCs** — Mode 19 sub-function `reportDTCByStatusMask`, with a
  `Send Mode 14` button for the UDS `ClearDiagnosticInformation`
  service. Codes come back with their ISO 14229-1 status byte
  (`P0301 (status 0x09)`).

Negative responses (`0x7F SID NRC`) reach the diagnostic GenServer as
`{:handle_obd2_error, …}` and are logged; the request loop stays
alive, so a refusal is just a log line, not a crash.

### 4. Vehicle info

Mode 09 identification (VIN, ECU name, calibration ID list) and the
UDS extended-session control. `Open` sends Mode 10 with
`session_type: 0x03` and starts a Mode 3E `TesterPresent` keepalive
at 2 s. The ECU's reported `P2 max` and `P2★ max` show up so you can
tell whether the timing your TesterPresent loop uses matches what the
ECU asked for.

### 5. Discovery

Two on-demand probes:

* **Supported Mode 01 PIDs** — the always-on Mode 01 PID 0x00 / 0x20 /
  … walk gets folded into a flat list of PID numbers, plus a count.
  Combine with the SAE J1979 catalog
  (`VmsCore.Vehicles.OBD2.PidCatalog`) for human names.
* **UDS DID scan** — the `Scan` button walks ISO 14229-1's standard
  ECU identification range (DIDs 0xF180–0xF19E) on the powertrain ECU
  pair (`0x7E0` request / `0x7E8` response) at 50 ms / DID. Positive
  responses (`0x62`) are surfaced as printable ASCII + raw hex, so an
  unknown ECU can be fingerprinted (boot SW ID, ECU serial,
  programming date, supplier IDs, …) without putting brand knowledge
  into cantastic itself.
* **Passive bus traffic** — counts every frame ID seen on the OBD2
  bus, with the last-seen raw payload. Useful for spotting unsolicited
  proprietary chatter that the standard request loops never asked
  for.

## Where the wiring lives

* YAML diagnostic catalog: `vms/core/priv/can/components/obd2/*.yml`,
  imported from `vms/core/priv/can/vehicles/obd2.yml`.
* Diagnostic orchestrator:
  `vms/core/lib/vms_core/vehicles/obd2/diagnostics.ex`.
* Discovery + UDS DID probe:
  `vms/core/lib/vms_core/vehicles/obd2/discovery.ex`.
* Dashboard composer:
  `vms/core/lib/vms_core/vehicles/obd2/composer/dashboard/`.

Adding a new live PID is a one-line YAML change (drop a parameter into
`mode01_live_data_*.yml`); the metric flows automatically through the
diagnostic GenServer and onto the dashboard's metrics channel.
