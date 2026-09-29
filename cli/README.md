---
title: CLI reference
description: Every ovcs subcommand, how the CLI finds a vehicle, the attach TUI and its hotkeys, and how the CAN pane decodes frames.
---

`ovcs` is the framework's command-line tool: it scaffolds vehicles, provisions virtual CAN, boots every firmware on your laptop, builds and flashes Nerves images, pushes firmware to a running board over SSH, and watches a running vehicle from a terminal. It is written in Rust with [Ratatui](https://ratatui.rs/) and knows nothing about any particular car: every command works the same on the reference vehicles (`ovcs1`, `ovcs_mini`, `obd2`) and on yours.

## Building the CLI

```sh
mise run cli       # cargo build --release, stripped and copied to cli/ovcs
./ovcs doctor      # verify the toolchain and every vehicle under vehicles/
```

`./ovcs` at the repository root is a symlink to `cli/ovcs`, which is gitignored: every contributor builds it locally. The Rust toolchain (1.90) is pinned in `mise.toml` and `cli/rust-toolchain.toml`. The CLI finds the repository by climbing from the current directory; set `OVCS_ROOT` to run it from elsewhere.

## Commands

| Command | Arguments | What it does |
|---|---|---|
| `vehicles` | | List every vehicle under `vehicles/` with its Nerves targets |
| `doctor` | | Check the toolchain binaries (required: mise, Elixir, Mix, Node, Python, fwup; optional: Ruby, Flutter, can-utils, PlatformIO), the `nerves_bootstrap` archive, the `libsocketcan` headers, each vehicle's Nerves targets and its SSH host keys |
| `new` | `<name> [--vms-target T] [--infotainment-target T] [--no-infotainment] [--no-bridges] [--display-name DN]` | Scaffold a vehicle under `vehicles/<name>/` (targets default to `ovcs_base_can_system_rpi4` and `ovcs_base_can_system_rpi5`) |
| `can setup` | `<vehicle>` | Create and bring up the vcan interfaces the vehicle's host mapping names (sudo; idempotent) |
| `can status` | `<vehicle>` | Report which vcan interfaces the vehicle needs and whether they're up |
| `run` | `<vehicle> [--no-addons]` | `can setup`, compile every firmware for the host, then spawn one BEAM per role |
| `attach` | `<vehicle>` | Split-pane TUI on a running vehicle, deployed or local |
| `connect` | `<vehicle> <role> [--host H]` | Plain IEx over SSH on one deployed board |
| `build` | `<vehicle> <role>` or `--all <vehicle>` | Build a firmware image; `--all` builds every role |
| `burn` | `<vehicle> <role> [--build]` | Write the image to an SD card; `--build` builds first |
| `upload` | `<vehicle> <role> [--build] [--host H] [-f\|--file F]` | Push firmware to a running board over SSH |
| `clean` | `<vehicle> <role>` | Remove build artifacts |
| `host-keys generate` | `<vehicle> [--force]` | Generate stable per-role SSH host keys |
| `host-keys verify` | `<vehicle>` | Check every role has a complete key set (exit 1 if not) |
| `host-keys export` | `<vehicle> [-o FILE]` | Bundle the keys into an archive (default `<vehicle>-host-keys.tar.gz`) |
| `host-keys import` | `<vehicle> -i\|--from FILE [--force]` | Restore keys from an archive |

`./ovcs --help` and `./ovcs <command> --help` print every option. [Running on hardware](../docs/running_hardware.md) walks through build, burn, upload and host keys.

### Arguments

- `<vehicle>` is the snake_case directory name of a vehicle package under `vehicles/`, for example `ovcs_mini` or `my_car`.
- `<role>` is `vms`, `infotainment`, or `bridge-<id>` for any id in the vehicle's `bridge_firmwares/0`, for example `bridge-radio_control`. The `bridge-` prefix is required: a bare id is rejected, and the error lists the valid roles.
- The two positional arguments of `build`, `burn`, `clean`, `upload` and `connect` are order-independent: the resolver picks the vehicle out of the two and treats the other as the role.
- A missing argument opens an interactive picker. On a non-tty stdin the command exits with status 2 instead.

### How it finds a vehicle

The CLI converts the directory name to UpperCamelCase (`ovcs_mini` becomes `OvcsMini`) and asks that module, through short `mix run --no-start` spawns, for the `OvcsVehicle` callbacks every vehicle implements: `vms_target/0`, `infotainment_target/0`, `bridge_firmwares/0`, and the composers' `default_can_mapping/1`. It then passes `VEHICLE` and `MIX_TARGET` (plus `BRIDGE_FIRMWARE_ID` for bridges) to the firmware projects' `build.sh` scripts in `vms/firmware/`, `infotainment/firmware/` and `bridges/firmware/`.

`build --all` builds the firmware projects in parallel, one lane per project directory. Roles sharing a directory (every bridge lives in `bridges/firmware`) build one after another, since they share its `deps/` and `mix.lock`. A failure skips the rest of its lane; the other lanes finish, and the first failure's log is printed at the end.

`new` runs `OvcsVehicle.Scaffold.generate/3` from `libraries/ovcs_vehicle/`, so the templates stay in Elixir. [Your vehicle package](../docs/vehicle_package.md) explains what the callbacks mean.

## `run` versus `attach`

The CLI separates **booting** a vehicle from **observing** it.

`./ovcs run <vehicle>` provisions vcan, compiles each firmware project for the host, then spawns `elixir --sname <vehicle>-<role> --cookie ovcs -S mix run --no-halt` per role from its project directory (every underscore, in the vehicle and in the role, becomes a dash: `ovcs-mini-bridge-radio-control`, the name `OvcsBus.Cluster` dials), with `VEHICLE` (and `BRIDGE_FIRMWARE_ID` plus the bridge's host CAN mapping for bridges) in its environment. `OvcsBus.Cluster` joins the BEAMs into one Erlang cluster, as on the vehicle. Each child's output is line-prefixed (`[vms] …`, `[bridge-ros] …`). There is no TUI and no IEx; `Ctrl-C` stops everything.

`run` also starts each firmware's **dev add-ons**, declared by the firmware in `dev_addons/0` and prefixed `[<firmware>-<addon>] …`. The only one today is the VMS dashboard's Vite dev server, on `http://localhost:5173`; use it rather than `:4000`, which serves the last prebuilt bundle and doesn't hot-reload. When the add-on's `node_modules` is missing, `run` installs it first. A missing toolchain or a failed start is a warning, not an error. `--no-addons` boots only the BEAMs.

The Flutter infotainment dashboard isn't an add-on: its hot reload reads keypresses on stdin, which a multiplexed `run` can't forward. Start it in its own terminal alongside `run`; it talks to the infotainment API on `:4001`:

```sh
mise run infotainment-dashboard   # cd infotainment/dashboard && flutter run -d linux
```

`./ovcs attach <vehicle>` works from any shell, or another machine. It looks for deployed boards first, probing `<vehicle>-<role>.local` on port 22 for each role (underscores become dashes: `ovcs-mini-vms.local`), and opens an SSH session per board. When none answers, it falls back to the local BEAMs registered in `epmd` under `<vehicle>-*` (hyphenated, e.g. `ovcs-mini-*`) and opens an `iex --remsh` per BEAM. Both transports reconnect on their own: an `epmd` poll locally, SSH retries with exponential backoff when deployed.

```sh
./ovcs run ovcs1       # terminal A
./ovcs attach ovcs1    # terminal B
```

## The attach TUI

Four panes:

- **Logs**: the merged per-node log stream, from `RingLogger.attach`, each node in its own colour.
- **Bus**: every `OvcsBus.Message`, subscribed on the VMS node only, since `OvcsBus.Cluster` already fans messages out cluster-wide.
- **CAN**: every frame on every interface each node declares, decoded into named signals ([below](#can-decoding)).
- **IEx**: an interactive shell. The tab strip above it picks which node it drives; the other panes aggregate every node.

### Hotkeys

| Key | Where | Action |
|---|---|---|
| `Tab` | anywhere | Move focus: Logs → Bus → CAN → IEx |
| `Ctrl-N` / `Ctrl-P` | anywhere | Cycle the node the IEx pane drives |
| `F1` … `F9` | anywhere | Jump to the Nth node |
| `Alt-Enter` | anywhere | Maximise the focused pane, or restore it |
| `Ctrl-Y` | anywhere | Copy the focused pane ([Clipboard](#clipboard)) |
| `Ctrl-C` | anywhere | Quit; the BEAMs or boards keep running |
| `↑`/`↓` or `k`/`j`, `PgUp`/`PgDn` | Logs, Bus, CAN | Scroll |
| `g` / `Home`, `G` / `End` | Logs, Bus, CAN | Jump to the top; follow the tail again |
| `y`, `c` | Logs, Bus, CAN | Copy the pane |
| `q`, `Esc` | Logs, Bus, CAN | Quit |
| `Space` or `p` | Bus, CAN | Freeze the pane; new messages are dropped until you unfreeze |
| `o` | Bus, CAN | Toggle the observer view: one row per message or frame, showing its latest value |
| `/` | Bus, CAN | Filter; `Enter` keeps the filter, `Esc` clears it |
| `i` | CAN | Cycle decoded + raw, decoded only, raw only |
| `Enter`, `↑`/`↓` | IEx | Evaluate the line; walk the history |
| `Esc` | IEx | Return focus to Logs |

### Clipboard

Mouse drag or `Ctrl-Y` copies to the system clipboard. The CLI tries helpers in order and stops at the first that works: `wl-copy` (Wayland), `xclip -selection clipboard`, `xsel --clipboard --input`, `pbcopy` (macOS), and finally the OSC 52 escape sequence. Install one native helper on Linux: tmux, gnome-terminal and konsole drop OSC 52 by default, so the copy would reach the terminal but not the clipboard. The footer names the path used. Every copy also writes the full pane to `/tmp/ovcs_attach_copy_<pane>.txt`, since the clipboard payload is capped at 64 KB.

### CAN decoding

The CAN pane shows signals, not bytes:

```text
[vms|ovcs/vms_status]        status="OK" ready_to_drive=false counter=42 | raw=00 00 2A 00 …
[bridge-ros|ovcs/0x1A0]      raw=00 00 2A 00 …
```

Decoding happens **inside each running BEAM**; the CLI never parses signal layouts, and neither the vehicle packages nor Cantastic need any change for it.

1. On each node, `attach` opens an `iex --remsh` session and feeds it a chunk of Elixir (`MONITOR_SNIPPET` in `src/commands/attach.rs`). Running in that node, the code has every module the firmware compiled in, Cantastic included.
2. At startup it walks `Cantastic.ConfigurationStore.networks()` and rebuilds each network's frame specifications from the YAML Cantastic loaded, with `Cantastic.FrameSpecification.from_yaml/3`, caching them in `:persistent_term`.
3. It spawns one `candump -tz <iface>` port per declared interface and parses each line into id, length and bytes.
4. It looks the frame's spec up by id and hands the frame to `Cantastic.Frame.interpret/2`, Cantastic's own decoder, then streams the signals back as `name=value` pairs.
5. An id the node's YAML doesn't declare skips decoding and renders as `0x<ID> raw=<hex>`.

It uses `candump` rather than Cantastic's receiver because the receiver only forwards frames a network lists under `received_frames`: whatever the node emits itself would be missing, and on the host that is most of the traffic. The consequence: when several nodes share `vcan0`, one frame shows up once per observing node, decoded by the nodes that declare it and raw on the others. The `[<node>|<network>/<frame>]` prefix tells them apart.

## Source layout

```text
cli/
├── Cargo.toml            # package and dependencies
├── Cargo.lock            # committed
├── rust-toolchain.toml   # pinned to 1.90
├── ovcs                  # built binary (gitignored; `mise run cli` rebuilds it)
└── src/
    ├── main.rs           # clap command enum and dispatch
    ├── repo_root.rs      # OVCS_ROOT, or climb from the cwd
    ├── vehicles.rs       # vehicle discovery and `mix run -e` metadata probes
    ├── firmware.rs       # role → firmware project and environment
    ├── resolve_args.rs   # order-independent (app, role) argument resolution
    ├── build_runner.rs   # parallel build.sh lanes for `build --all` and `run`
    ├── shell.rs          # run() inherits stdio; run_capture() for mix probes
    ├── prompt.rs         # Ratatui single-select picker
    ├── ui.rs             # shared status-line helpers
    ├── ansi.rs           # strips ANSI escapes from streamed BEAM output
    └── commands/         # one file per subcommand; run_ui.rs is the attach TUI
```
