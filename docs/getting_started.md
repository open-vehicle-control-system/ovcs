# Getting Started with OVCS

This guide covers setting up your development environment to run OVCS applications locally. No hardware is required for local development -- virtual CAN interfaces simulate the CAN bus.

## Prerequisites

OVCS is developed on Linux. macOS users need a Linux VM (see [macOS setup](#local-environment-vm-setup-macos--linux) below).

### Required Software

| Tool | Version | Purpose | Managed by |
|------|---------|---------|------------|
| [mise](https://mise.jdx.dev/) | Latest | Version manager for language runtimes | you (one-time install) |
| Erlang/OTP | 27.3+ | Runtime for Elixir | mise |
| Elixir | 1.17+ | Primary programming language | mise |
| Node.js | 24+ | VMS debug dashboard (Vue.js) | mise |
| Ruby | 3.3+ | historical scripts | mise |
| Python | 3.12+ | PlatformIO + misc tooling | mise |
| [Flutter](https://flutter.dev/docs/get-started/install) | 3.32.8 | Infotainment dashboard | mise |
| can-utils | Latest | CAN bus utilities (`cansend`, `candump`, `canplayer`) | system package |
| `fwup` | Latest | Nerves firmware image packager | system package |
| `libsocketcan-dev` | Latest | Cantastic native CAN bindings | system package (firmware builds only) |
| `nerves_bootstrap` | Latest | Nerves Mix archive | `mise run bootstrap` |
| [PlatformIO](https://platformio.org/) | Latest | Arduino controller firmware | mise (via pipx + uv) |

## Linux Setup

### 1. Install mise

```sh
curl https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc   # or bash/fish
exec $SHELL
```

See the [mise installation docs](https://mise.jdx.dev/getting-started.html) for other shells and package-manager installs.

### 2. Install build dependencies

Erlang and Ruby are built from source by mise, so the system needs the usual C toolchain and dev headers. On Debian/Ubuntu:

```sh
sudo apt install -y build-essential autoconf m4 \
  libncurses-dev libssl-dev libffi-dev libyaml-dev zlib1g-dev \
  libwxgtk3.2-dev libgl1-mesa-dev libglu1-mesa-dev libpng-dev \
  libssh-dev unixodbc-dev xsltproc fop libxml2-utils
```

### 3. Install language runtimes

The repo ships a `mise.toml` pinning every required runtime (Erlang, Elixir, Node, Ruby, Flutter, Python). From the repo root:

```sh
mise trust
mise install
```

From now on, `cd`-ing into the project activates the pinned versions automatically.

### 4. Install system-level tools

```sh
sudo apt install -y can-utils libsocketcan-dev
```

- `can-utils` provides `cansend`, `candump`, `canplayer`, and the rest. The Linux kernel modules `can` and `can_raw` are required and are included in standard (non-cloud) kernels.
- `libsocketcan-dev` is only needed when building for physical CAN targets (i.e. the Pi firmwares); it supplies the native headers Cantastic links against.

`fwup` is the firmware image packager Nerves calls during `mix firmware`. It is **not** in the Debian/Ubuntu repos — install the latest `.deb` from the project's GitHub releases:

```sh
curl -L -o /tmp/fwup.deb "https://github.com/fwup-home/fwup/releases/download/v1.15.0/fwup_1.15.0_$(dpkg --print-architecture).deb"
sudo dpkg -i /tmp/fwup.deb
```

On macOS: `brew install fwup can-utils` (`fwup` is in homebrew; there's no `libsocketcan` on macOS — firmware builds happen inside the Linux VM).

### 5. Clone the repository

```sh
git clone https://github.com/open-vehicle-control-system/ovcs.git
cd ovcs
```

### 6. Build the CLI and verify

Once inside the repo:

```sh
mise install         # installs language runtimes + runs the bootstrap hook
                     # (hex, rebar, nerves_bootstrap) automatically
mise run cli         # builds the `./ovcs` CLI escript
./ovcs doctor        # verify everything
```

The `mise install` postinstall hook runs `mise run bootstrap` for you — hex, rebar, and the `nerves_bootstrap` Mix archive get installed against whichever Elixir mise has just put in place. If you ever reinstall Elixir (`mise install elixir@...`) the same hook fires, so the archive stays in sync.

`./ovcs doctor` checks every required binary, the `nerves_bootstrap` archive, `libsocketcan` headers, and each vehicle package's metadata. Green across the board means you're ready.

### 7. Install custom Nerves systems (only for firmware builds)

If you plan to build and deploy firmware to physical hardware, follow the [Nerves installation guide](https://hexdocs.pm/nerves/installation.html) for the additional tooling (e.g. `squashfs-tools`, `fakeroot`) and clone the OVCS Nerves systems — see the [System Images](#setting-up-system-images-for-firmware-builds) section below.

## macOS / VM Setup

OVCS relies on the `vcan` kernel module to create virtual CAN interfaces. This is a Linux-only kernel module available only in non-cloud-image kernels. To develop on macOS, you need a full Linux VM.

### Using Multipass (recommended)

1. Install [Multipass](https://canonical.com/multipass/install).

2. Create a VM with sufficient resources:

```sh
multipass launch --name primary --disk 40G --cpus 2 --memory 8G
```

> Adjust parameters to your needs. If you plan to compile Nerves firmware images, you need significant disk space. Disk size cannot be changed after creation.

3. Access the VM:

```sh
multipass shell
```

4. Set the ubuntu user password:

```sh
sudo passwd ubuntu
```

5. **(macOS only)** To avoid permission and symlink issues when building Nerves images, clone the OVCS repository inside the VM. You can then set up an NFS share with the macOS host to use your preferred editor.

6. Follow the Linux setup steps above inside the VM.

## Setting Up System Images (for firmware builds)

OVCS firmware targets use custom Nerves system images that include CAN bus support. These are maintained in separate repositories and should be cloned alongside the main OVCS repo.

### Recommended directory structure

```
ovcs_base/
+-- ovcs/                          # This repository
+-- ovcs_base_can_system_rpi4/     # Custom Nerves system for RPi 4 (VMS)
+-- ovcs_base_can_system_rpi5/     # Custom Nerves system for RPi 5 (Infotainment)
+-- ovcs_base_can_system_rpi3a/    # Custom Nerves system for RPi 3A (Radio Control Bridge)
```

### Clone the system repositories

```sh
cd ovcs_base
git clone https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi4
git clone https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi5
git clone https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi3a
```

These system images are only needed if you want to build and deploy firmware to physical hardware. For local development, you can skip this step entirely.

## Verifying Your Setup

### 1. Set up virtual CAN interfaces

```sh
./ovcs can setup ovcs1        # or ovcs_mini, obd2
./ovcs can status ovcs1       # check which interfaces are up
```

The CLI reads the vehicle's `default_can_mapping(:host)` and creates only the vcan interfaces that vehicle actually needs. It's idempotent: a second run on the same vehicle is a no-op. You'll be prompted for your sudo password the first time; `scripts/setup_virtual_can.sh` remains as a non-CLI fallback that creates `vcan0..vcan5` unconditionally.

### 2. Test the VMS

```sh
cd vms/api
VEHICLE=Ovcs1 mix deps.get
VEHICLE=Ovcs1 mix phx.server
```

The VMS API should start and be accessible at `http://localhost:4000`. The `VEHICLE` env var is mandatory — it selects which vehicle package's composer wires the supervision tree and CAN topology. Use `Ovcs1`, `OvcsMini`, or `Obd2` (the top-level module name of the vehicle package).

### 3. Test the VMS dashboard

```sh
cd vms/dashboard
npm install
npm run dev
```

The Vue.js dashboard should start and be accessible at `http://localhost:5173`.

### 4. Test CAN communication

In a separate terminal, send a test CAN message:

```sh
cansend vcan0 280#0000881300000000
```

You should see the RPM value change on the dashboard (if running with the correct vehicle and CAN mappings).

## Next Steps

- [Applications](./applications.md) -- Understand the application structure and run each component locally.
- [Testing CAN Messages](./testing_can_messages.md) -- Simulate CAN traffic for development.
- [Hardware Architecture](./hardware_architecture.md) -- Understand the hardware design.

Next: [Applications](./applications.md)
