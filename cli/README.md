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
./ovcs run <vehicle>               # `can setup` + split TUI (logs | iex --remsh)
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

Ratatui drives two interactive views: the vehicle/app picker, and the
split-pane UI for `./ovcs run`. For `run`, the CLI spawns
`elixir --sname ovcs_<v> -S mix run --no-halt` as one child (stdout/stderr
stream into the left log pane) and `iex --sname ... --remsh ovcs_<v>@<host>`
as another (piped stdio — typed input goes to its stdin, responses appear
in the right pane). No terminal emulation, no pty, no tmux — just line-in
/ line-out over pipes, with a minimal input widget and ↑↓ history. A
future `./ovcs stream` will reuse the same architecture for an
`ovcs_bus` + CAN frame dashboard. One-shot views (`vehicles`, `doctor`,
`can status`) use plain `println!` + `owo-colors`.
