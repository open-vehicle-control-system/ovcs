# ovcs CLI

Rust + Ratatui CLI that orchestrates OVCS vehicle firmware builds, burns,
OTA uploads, CAN provisioning, and local boots.

## Build

```sh
cd cli
cargo build --release
```

This produces a stripped static binary at `cli/target/release/ovcs`
(~2.8 MB). `mise run cli` does the build and copies the binary to
`cli/ovcs`, which is what the root-level `./ovcs` symlink points at.

Toolchain is pinned in the repo's `mise.toml` — `mise install` at the
repo root pulls rustc 1.90, the only runtime dependency. Contributors
who don't need to rebuild the CLI can use the committed `cli/ovcs`
binary directly.

## Commands

```sh
./ovcs vehicles                    # list discovered vehicles + nerves targets
./ovcs doctor                      # verify toolchain + vehicle packages
./ovcs build   <vehicle> <app>     # build firmware (order-independent)
./ovcs burn    <vehicle> <app>     # burn to SD card
./ovcs clean   <vehicle> <app>     # remove build artifacts
./ovcs upload  <vehicle> <app> [--host H] [-f|--file F]
./ovcs can setup  <vehicle>        # create + bring up vcan interfaces (sudo)
./ovcs can status <vehicle>        # report vcan interface state
./ovcs vehicle new <name> [--vms-target T] [--infotainment-target T] [--no-infotainment]
./ovcs run <vehicle>               # `can setup` + spawn one BEAM per firmware, line-prefixed stdout
./ovcs attach <vehicle>            # split-pane TUI (merged logs | iex) over SSH or local remsh
```

Where:

- `<vehicle>` is the snake_case directory name under `vehicles/` (e.g.
  `ovcs1`, `ovcs_mini`, `obd2`).
- `<app>` is `vms`, `infotainment`, or any bridge firmware id declared in
  the vehicle's `bridge_firmwares/0` callback.
- Positional args for build/burn/clean/upload are order-independent.
  Missing values prompt interactively via a Ratatui picker; non-tty
  stdin exits code 2.

The CLI resolves the top-level vehicle module (e.g. `Ovcs1`) by
converting the directory name to UpperCamelCase, then queries the
vehicle's `OvcsVehicle.nerves_target/1`, `default_can_mapping/1`, and
`bridge_firmwares/0` callbacks via short `mix run --no-start` spawns.
The resolved `VEHICLE` and `MIX_TARGET` (and `BRIDGE_FIRMWARE_ID` for
bridge firmwares) are passed to the shared firmware build scripts in
`vms/firmware/`, `infotainment/firmware/`, and `bridges/firmware/`.

`vehicle new` shells out to `OvcsVehicle.Scaffold.generate/3` in
`libraries/ovcs_vehicle/` — EEx templates stay in Elixir.

## Layout

```
cli/
├── Cargo.toml            # package + dep list
├── Cargo.lock            # committed
├── rust-toolchain.toml   # pin to stable 1.90
├── ovcs                  # committed release binary (gitignore-exempt)
└── src/
    ├── main.rs           # clap command enum + dispatch
    ├── repo_root.rs      # OVCS_ROOT env or climb from cwd
    ├── shell.rs          # run() inherits stdio; run_capture() for mix probes
    ├── vehicles.rs       # discovery + mix run -e metadata probes
    ├── firmware.rs       # static-vs-bridge application resolution
    ├── resolve_args.rs   # order-independent (vehicle, app) argv resolution
    ├── prompt.rs         # ratatui single-select picker
    └── commands/         # one file per subcommand
```

`./ovcs run` and `./ovcs attach` split booting a vehicle from observing
it. `run` provisions vcan, spawns one `elixir --sname <vehicle>-<role>
-S mix run --no-halt` per firmware role from its own project directory,
and line-prefixes each child's stdout/stderr (`[vms] …`, `[bridge-ros]
…`) to the tty. It's the canonical local dev boot. `attach` is
terminal-independent — from another shell or machine it discovers the
running nodes (first by probing `<vehicle>-<side>.local:22` for
deployed Nerves devices; falling back to `epmd -names` for local
dev BEAMs) and drives a Ratatui split-pane view: merged per-node log
stream on the left, focused IEx shell on the right, hotkeys to cycle
which node the shell targets.

Ratatui also backs the one-off vehicle/app picker used when an
argument is missing. One-shot views (`vehicles`, `doctor`, `can
status`) use plain `println!` + `owo-colors`.
