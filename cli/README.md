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
./ovcs burn    <vehicle> <app> [--build]   # burn to SD card; --build runs build first
./ovcs clean   <vehicle> <app>     # remove build artifacts
./ovcs upload  <vehicle> <app> [--host H] [-f|--file F]
./ovcs can setup  <vehicle>        # create + bring up vcan interfaces (sudo)
./ovcs can status <vehicle>        # report vcan interface state
./ovcs vehicle new <name> [--vms-target T] [--infotainment-target T] [--no-infotainment]
./ovcs run <vehicle>               # `can setup` + spawn one BEAM per firmware, line-prefixed stdout
./ovcs attach <vehicle>            # split-pane TUI (merged logs | iex) over SSH or local remsh
./ovcs connect <vehicle> <app> [--host H]  # plain IEx shell over SSH on a single deployed device
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
…`) to the tty. It's the canonical local dev boot.

`attach` is terminal-independent — from another shell or machine it
discovers the running nodes (first by probing
`<vehicle>-<side>.local:22` for deployed Nerves devices; falling back
to `epmd -names` for local dev BEAMs) and drives a four-pane Ratatui
view:

- **Logs** (top-left) — merged per-node stream from `RingLogger.attach`.
- **Bus** (top-right, upper) — every `OvcsBus.Message` flowing through
  `Phoenix.PubSub`. Subscribed from the VMS node only since
  `OvcsBus.Cluster` fans messages cluster-wide.
- **CAN** (top-right, lower) — every raw CAN frame on every declared
  vcan interface, decoded into named signals (see below).
- **IEx** (full-width bottom) — interactive shell. A thin tab strip
  directly above it selects which node drives the shell; the read-only
  panes above aggregate across every node.

Reconnection is built in on both transports (local epmd poll + SSH
retry with exponential backoff), and `Space` pauses Bus/Can for
inspection without losing live data. Ratatui also backs the one-off
vehicle/app picker used when an argument is missing. One-shot views
(`vehicles`, `doctor`, `can status`) use plain `println!` +
`owo-colors`.

### Clipboard (Ctrl-Y / mouse drag)

`attach` can copy pane contents to the system clipboard, either by
dragging the mouse across rows or by pressing `Ctrl-Y` (also plain `y`
/ `c` in read-only panes). It probes helpers in this order and stops
at the first that succeeds:

1. `wl-copy` (Wayland) — `wl-clipboard` package.
2. `xclip -selection clipboard` (X11) — `xclip` package.
3. `xsel --clipboard --input` (X11 alternative) — `xsel` package.
4. `pbcopy` (macOS, preinstalled).
5. OSC 52 escape sequence, as a last resort over SSH.

Install at least one of the native helpers on Linux — OSC 52 is
silently dropped by tmux, gnome-terminal, and konsole by default, so
without a helper the copy reaches the terminal but not the clipboard.
The toast footer announces which path was used (`→ clipboard (wl-copy)
+ /tmp/ovcs_attach_copy_<pane>.txt`) so you can tell at a glance. The
full pane is also written to `/tmp/ovcs_attach_copy_<pane>.txt` on
every copy as an overflow fallback (the clipboard payload is capped at
64 KB; the file is never truncated).

### CAN decoding

The CAN pane shows human-readable signals, not raw bytes:

```
[vms|ovcs/vms_status]        status="OK" ready_to_drive=false counter=42 | raw=00 00 2A 00 …
[bridge-ros|ovcs/0x1A0]      raw=00 00 2A 00 …
```

All of that decoding happens **inside the running BEAM** — the CLI
never parses signal layouts itself. The mechanism:

1. On each attached node, `attach` spawns an `iex --remsh` session and
   writes a chunk of Elixir (the `MONITOR_SNIPPET` constant in
   `src/commands/attach.rs`) into its stdin. That code executes in
   the remote BEAM's own VM, so it has access to every module the
   firmware has compiled in — crucially including `cantastic`.
2. At startup the snippet walks `Cantastic.ConfigurationStore.networks()`
   and for every network runs the raw YAML blobs under
   `network_config[:emitted_frames]` and `network_config[:received_frames]`
   back through `Cantastic.FrameSpecification.from_yaml/3`. That
   rebuilds the same `%FrameSpecification{}` structs (with
   `signal_specifications`, checksum info, data length, etc.) that
   Cantastic itself uses on the receive path. They get cached in
   `:persistent_term` keyed by `{:ovcs_attach_specs, iface}`.
3. A `candump -tz <iface>` `Port` is spawned per unique vcan. Its
   output (`(ts) vcan0 1A0 [8] 00 00 2A 00 …`) is parsed line by line
   into `{id, dlc, raw_bytes}`.
4. For each frame, the spec cache is looked up by id. A bare
   `%Cantastic.Frame{raw_data: <<…>>}` is built and handed to
   `Cantastic.Frame.interpret/2` — Cantastic's own decoder. It
   iterates `spec.signal_specifications`, calls
   `Cantastic.Signal.interpret/2` for each, and returns a frame with
   `signals: %{name => %Signal{value: …}}` populated. The snippet
   formats that map as `name=inspect(value)` pairs and sends one
   `OVCS_CAN <network> <frame> <signals> | raw=<hex>` line to its
   stdout, where the Rust side picks it up and pushes it into the
   CAN pane.
5. Unknown IDs (frames this node's YAML doesn't declare) skip the
   decode step and render as `0x<ID> raw=<hex>` so the frame is still
   visible.

Why `candump` rather than subscribing to `Cantastic.Receiver`:
Cantastic's receiver only forwards frames whose id is in a network's
`received_frames` list — anything the node itself emits is silently
dropped. On host dev most traffic comes from local emitters, so the
CAN pane would sit empty. `candump` taps the kernel CAN socket
directly and sees every frame on the bus regardless of YAML
declarations.

Every attached node runs its own `candump` against its own declared
vcan interfaces, and decoding uses only the specs that node's YAML
knows about. On host dev where several nodes share vcan0, a single
frame typically shows up three times — once per observing node —
with whichever nodes declared it rendering the signals and the
others falling back to raw. The `[<node>|<network>/<frame>]` prefix
(coloured with the node's accent) makes the duplicates easy to
disambiguate.

**No changes to any app or to Cantastic itself are required** —
the snippet only calls already-compiled functions already loaded in
the target BEAM.
