# ovcs CLI

Elixir escript that orchestrates OVCS vehicle firmware builds, burns,
OTA uploads, and introspection.

## Build

```sh
cd cli
mix deps.get
mix escript.build
```

This produces a self-contained `ovcs` binary in `cli/`. The repo-root
`./ovcs` symlink points at it.

## Usage

```sh
./ovcs vehicles
./ovcs build  <vehicle-dir> <application>
./ovcs burn   <vehicle-dir> <application>
./ovcs upload <vehicle-dir> <application> [--host H] [--file F]
```

Where:

- `<vehicle-dir>` is the snake_case directory name under `vehicles/`
  (e.g. `ovcs1`, `ovcs_mini`, `obd2`).
- `<application>` is `vms`, `infotainment`, `radio-control-bridge`, or
  `ros-bridge`.

The CLI resolves the top-level vehicle module (e.g. `Ovcs1`) by
converting the directory name to UpperCamelCase, then queries the
vehicle's `OvcsVehicle.nerves_target/1` callback via a short
`mix run --no-start` spawn to set `MIX_TARGET`. `VEHICLE` and
`MIX_TARGET` are passed to the shared firmware build scripts in
`vms/firmware/`, `infotainment/firmware/`, etc.

## Why Elixir

Keeping the CLI in the project's primary language means later commands
can introspect the running BEAM (e.g. `Node.connect/1` + `:rpc.call/4`
against a live Nerves device) without shelling out.
