# Running OVCS on Real Hardware

## Supported Hardware

| Component | Hardware Platform | Status |
|-----------|-------------------|--------|
| VMS | Raspberry Pi 4 | Supported |
| Infotainment | Raspberry Pi 5 | Supported |
| Radio Control Bridge | Raspberry Pi 3A | Supported |
| ROS Bridge | Raspberry Pi 4 / 5 | Supported |
| Generic Controller | Arduino R4 Minima | Supported |

## Firmware Overview

### Nerves-based components (VMS, Infotainment, Bridges)

OVCS uses the [Nerves Project](https://nerves-project.org/) to build firmware for the Raspberry Pi targets. Nerves produces a complete Linux system image that boots directly into the Elixir application.

OVCS ships custom Nerves systems for each target that include the necessary CAN bus kernel modules and device tree overlays:

| Target | Custom System | Repository |
|--------|--------------|------------|
| RPi 4 (VMS) | `ovcs_base_can_system_rpi4` | [GitHub](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi4) |
| RPi 5 (Infotainment) | `ovcs_base_can_system_rpi5` | [GitHub](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi5) |
| RPi 3A (Radio Control) | `ovcs_base_can_system_rpi3a` | [GitHub](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi3a) |

### Arduino controllers

The generic controller firmware is built with [PlatformIO](https://platformio.org/) and targets the Arduino R4 Minima. Upload it using the Arduino IDE or PlatformIO CLI.

The controllers do not use the Arduino R4 Minima's internal CAN bus interface, to remain hardware-agnostic. Any Arduino-compatible board with EEPROM read/write capabilities and an external CAN transceiver should work.

## Choosing the Nerves target

The Nerves target is read from the vehicle module — `vms_target/0` for the
VMS, `infotainment_target/0` for the infotainment side, and the `:target`
key on each `bridge_firmwares/0` entry for bridges. To deploy on different
hardware, change those values on the vehicle module (e.g.
`vehicles/ovcs1/lib/ovcs1.ex`) and add the matching system dep to the
firmware project's `mix.exs`. See the
[Nerves custom-systems guide](https://hexdocs.pm/nerves/customizing-systems.html).

## Building and Deploying Firmware

OVCS provides the `ovcs` CLI tool at the repository root for building,
burning, and uploading firmware. The CLI is a Rust release binary built
to `cli/ovcs` via `mise run cli`; the repo-root `./ovcs` is a symlink
to it. The binary is gitignored — each contributor builds it locally.
See [`cli/README.md`](../cli/README.md) for the full command reference
and implementation notes.

### CLI Usage

```
./ovcs <command> <vehicle> <role> [options]
```

- `<vehicle>` is the snake_case directory name under `vehicles/` (e.g. `ovcs1`, `ovcs_mini`, `obd2`).
- `<role>` is `vms`, `infotainment`, or any bridge firmware id declared in the vehicle's `bridge_firmwares/0` callback (e.g. `radio_control`, `ros`).
- Positional args for `build` / `burn` / `clean` / `upload` / `connect` are order-independent. Missing values prompt interactively; on a non-tty stdin the command exits with status 2.
- Run `./ovcs --help` or `./ovcs <command> --help` for the full option list.

### Build

Build a firmware image for a specific (vehicle, role) pair:

```sh
# Build VMS firmware for OVCS1
./ovcs build ovcs1 vms

# Build Infotainment firmware for OVCS1
./ovcs build ovcs1 infotainment

# Build VMS firmware for OVCS Mini
./ovcs build ovcs_mini vms

# Build a bridge firmware declared in the vehicle (e.g. radio_control)
./ovcs build ovcs1 radio_control

# Build every role of a vehicle (vms, infotainment, and each bridge) in
# one go. Stops at the first failing build.
./ovcs build --all ovcs1
```

Before the first build, copy `vehicles/<vehicle>/.env.exs.example` to
`vehicles/<vehicle>/.env.exs` and fill in your SSH public key(s),
Wi-Fi credentials, and Phoenix `SECRET_KEY_BASE` / `SIGNING_SALT`. The
file is gitignored and shared by every firmware of that vehicle (vms,
infotainment, bridges).

### Stable SSH host keys across burns

By default, every fresh SD-card burn regenerates the device's SSH host
key, so each burn triggers OpenSSH's "REMOTE HOST IDENTIFICATION HAS
CHANGED" warning. To avoid that, generate persistent host keys per
firmware role once:

```sh
./ovcs host-keys generate ovcs1
```

This creates one rsa + ed25519 key pair per role (vms, infotainment,
each bridge) under `vehicles/<vehicle>/priv/host_keys/<role>/`. Files
are gitignored — each developer keeps their own. The firmware ships
the keys inside the vehicle's app priv and points
`:nerves_ssh, :system_dir` at them at boot, so the device's SSH
identity stays stable across burns. Re-run with `--force` to rotate
keys; `./ovcs doctor` flags any vehicle missing keys.

The `host-keys` group has three more subcommands:

```sh
# Check every role has a complete key set (exit 1 if not — handy as a
# pre-burn gate).
./ovcs host-keys verify ovcs1

# Share one identity across the team: export bundles the keys into a
# gzip tar (default ./ovcs1-host-keys.tar.gz), import restores them in
# another checkout. The archive holds PRIVATE keys — pass it over a
# trusted channel.
./ovcs host-keys export ovcs1 -o ovcs1-host-keys.tar.gz
./ovcs host-keys import ovcs1 --from ovcs1-host-keys.tar.gz
```

`import` refuses to clobber existing keys unless `--force`.

### Burn to SD card

Write the firmware image to an SD card (requires the SD card to be inserted):

```sh
./ovcs burn ovcs1 vms
./ovcs burn ovcs1 infotainment

# One-shot rebuild + burn — useful while iterating
./ovcs burn --build ovcs1 vms
```

### Upload over the network

Push a firmware update to a running Nerves device over SSH:

```sh
# Upload to the default host
./ovcs upload ovcs1 vms

# Upload to a specific host
./ovcs upload ovcs1 infotainment --host 192.168.1.100

# Upload a custom firmware file
./ovcs upload ovcs1 vms --file path/to/custom.fw
```

## Running and attaching at runtime

### Local run mirrors deployed: one BEAM per firmware

`./ovcs run <vehicle>` boots the full deployed topology on one host:

- One BEAM per role: `<vehicle>-vms`, `<vehicle>-infotainment`, and `<vehicle>-bridge-<id>` per bridge firmware. Each BEAM runs the corresponding firmware project (`vms/firmware`, `infotainment/firmware`, `bridges/firmware`) directly against `MIX_TARGET=host`.
- An Erlang-distribution cluster: each BEAM runs `OvcsBus.Cluster`, which `Node.connect/1`s the siblings at boot. `OvcsBus.broadcast/2` fans messages out cluster-wide — same transport as deployed, no broker required.
- CAN interfaces are shared host-wide (same vcan0/vcan1/… visible to every BEAM), so `./ovcs can setup` once covers all roles.

Output is line-prefixed per role (`[vms] …`, `[infotainment] …`, `[bridge-ros] …`). For the aggregated split-pane TUI, run `./ovcs attach <vehicle>` in another terminal — it auto-detects the local BEAMs via epmd (node snames starting with `<vehicle>-`) and lights up the same multi-node view used for deployed vehicles.

#### Dev add-ons run live too

Unlike a deployed device, a host run does **not** bundle a firmware's dashboard into its image. So `./ovcs run` also starts each firmware's **dev add-ons** — companion processes meant for local development — beside the BEAMs, line-prefixed as `[<firmware>-<addon>] …`.

Add-ons are **declared by the firmware itself**, not hardcoded in the CLI: a firmware's top-level module exposes `dev_addons/0` returning a list of `%{name, dir, run, install, ready_marker, note}` entries (see `VmsFirmware.dev_addons/0`). After compiling each firmware on host, the CLI asks it for its add-ons (the same `mix run -e` metadata probe used for bridges) and launches each generically — it knows nothing about npm, Flutter, or ports. Adding an add-on to a firmware (or a new firmware) needs no CLI change.

Today's only add-on is the **VMS dashboard** (`vms/dashboard`, Vue/Vite) → `npm run dev`. Open the URL it logs (usually `http://localhost:5173`), **not** `:4000` — only the dev server hot-reloads on `.vue` edits; `:4000` serves the last built static bundle.

When `ready_marker` (e.g. `node_modules`) is absent, the CLI runs the add-on's `install` command first. Add-ons are **auxiliary**: a closed window, a missing toolchain, or a failed start is warned about and skipped — the BEAMs keep running, and a BEAM crash still tears the add-ons down with it. Pass `--no-addons` to boot only the BEAMs:

```sh
./ovcs run <vehicle> --no-addons
```

The **infotainment dashboard** (Flutter) is deliberately *not* an add-on: Flutter's hot reload is driven by keypresses on its stdin, which the multiplexed `./ovcs run` can't hand to a child. Run it in its own terminal instead, where it keeps a real TTY and full interactive hot reload (`r` / `R`):

```sh
mise run infotainment-dashboard   # cd infotainment/dashboard && flutter run -d linux
```

It talks to the infotainment API on `:4001`, so keep a `./ovcs run <vehicle>` going alongside. This needs the Flutter Linux desktop toolchain — see [getting_started.md](./getting_started.md).

### `./ovcs run` vs `./ovcs attach`

The CLI separates **booting** a vehicle from **observing / driving** it:

- `./ovcs run <vehicle>` — provisions vcan and spawns one BEAM per firmware. Streams raw stdout (line-prefixed per role) to the tty. No TUI, no IEx. Ctrl-C stops all of them.
- `./ovcs attach <vehicle>` — split-pane TUI that connects to a running vehicle, aggregates logs per node, and exposes an IEx shell on each. Auto-detects:
  - **Deployed** (preferred, if reachable): SSHes to each expected Nerves device via `<vehicle>-vms.local` / `<vehicle>-infotainment.local` / `<vehicle>-bridge-<id>.local`, streams logs via `RingLogger.attach()`, and opens an interactive IEx channel per device.
  - **Local dev BEAMs** (fallback): if no device hostnames resolve, it finds every epmd registration matching `<vehicle>-*` and opens one `iex --remsh` per BEAM, the same TUI layout as deployed.
  - Otherwise: exits with a clear error.

### Typical flow

```sh
# Terminal A (dev host)
./ovcs run ovcs1

# Terminal B (same laptop, or a laptop on the vehicle's LAN when deployed)
./ovcs attach ovcs1
```

### TUI hotkeys

- `Tab` — switch focus between the logs pane (left) and the IEx pane (right).
- `Ctrl-N` / `Ctrl-P` — cycle which device the IEx pane drives (deployed mode, multiple devices).
- `F1` … `F9` — jump directly to the Nth device.
- Logs pane: `↑`/`↓`, `PgUp`/`PgDn`, `g`/`G`, `Home`/`End` — scroll / follow tail.
- IEx pane: `Enter` evaluates, `↑`/`↓` walks command history, `Esc` returns focus to logs.
- `Ctrl-C` or `q` — quit attach (the source BEAM / remote devices keep running).

### Prerequisites for deployed attach

- The host's SSH public key must be in `vehicles/<vehicle>/.env.exs`'s `AUTHORIZED_SSH_KEYS` at firmware build time (same file that powers `./ovcs upload` / `./ovcs connect`). One file per vehicle, picked up by every firmware (`vms`, `infotainment`, every bridge). Copy the gitignored starter from `vehicles/<vehicle>/.env.exs.example`.
- Your private key must be loaded in `ssh-agent`: `attach` and `connect` authenticate through it. `ssh-add -l` to verify.
- Devices must be reachable on the LAN via mDNS (`<vehicle>-<side>.local`). Verify with `ping ovcs1-vms.local` before attaching.
- Non-Nerves bridges (e.g. Arduino generic controllers) have no SSH / IEx — they are skipped automatically.

### `./ovcs connect` — single-device IEx

For ad-hoc debugging when you don't need the full split-pane TUI:

```sh
./ovcs connect ovcs1 vms                  # IEx on the VMS Pi
./ovcs connect ovcs1 infotainment         # IEx on the infotainment Pi
./ovcs connect ovcs1 vms --host 192.168.10.42   # bypass mDNS with a known IP
```

Same SSH-key prerequisite as `attach`. Drops you straight into IEx (Nerves devices boot with IEx as the SSH login shell).

## Customizing CAN Interfaces

The `CAN_NETWORK_MAPPINGS` environment variable maps logical CAN network names to physical or virtual interfaces. This is used both for local development and when building firmware.

### Format

```
CAN_NETWORK_MAPPINGS=network1:interface1,network2:interface2,...
```

### Interface types

| Prefix | Type | Example | Description |
|--------|------|---------|-------------|
| `can` | Physical CAN | `can0` | Hardware CAN interface |
| `vcan` | Virtual CAN | `vcan0` | Software-only CAN interface (for development) |
| `spi` | SPI-to-CAN | `spi0.0` | CAN via SPI (used on the VMS with the CAN hub board) |

### Examples

**Running the VMS locally** with physical CAN on the OVCS bus and virtual CAN for the rest:

```sh
cd vms/api
CAN_NETWORK_MAPPINGS=ovcs:can0,leaf_drive:vcan1,polo_drive:vcan2,orion_bms:vcan3,misc:vcan4 \
  iex -S mix phx.server
```

**Building VMS firmware** with SPI for the OVCS bus and virtual CAN for testing:

```sh
CAN_NETWORK_MAPPINGS=ovcs:spi0.0,leaf_drive:vcan0,polo_drive:vcan1,orion_bms:vcan2,misc:vcan3 \
  ./ovcs build ovcs1 vms
```

### Available CAN networks

| Network | Used by | Description |
|---------|---------|-------------|
| `ovcs` | OVCS1, OVCS Mini | Internal OVCS communication bus |
| `leaf_drive` | OVCS1 | Nissan Leaf drivetrain |
| `polo_drive` | OVCS1 | VW Polo original systems |
| `orion_bms` | OVCS1 | Orion BMS2 + charger |
| `misc` | OVCS1 | iBooster, steering angle sensor |

## Setting Up Physical CAN Interfaces

On Nerves devices, Cantastic configures CAN interfaces at boot via
`setup_can_interfaces: true` in the firmware's Cantastic config — no manual
step needed. For ad-hoc setup while SSH'd into a host, the fallback script is:

```sh
./scripts/setup_can.sh
```

It brings `can0`, `can1`, and `can2` up at 500 kbps. Edit it to adjust
bitrates or add interfaces.

For virtual CAN interfaces (local development), use:

```sh
./ovcs can setup <vehicle>
```

The CLI reads the vehicle's `default_can_mapping(:host)` and creates only the vcan interfaces that vehicle actually needs.

Next: [Testing Generic Controllers](./testing_generic_controllers.md)
