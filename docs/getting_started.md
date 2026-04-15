# Getting Started with OVCS

This guide covers setting up your development environment to run OVCS applications locally. No hardware is required for local development -- virtual CAN interfaces simulate the CAN bus.

## Prerequisites

OVCS is developed on Linux. macOS users need a Linux VM (see [macOS setup](#local-environment-vm-setup-macos--linux) below).

### Required Software

| Tool | Version | Purpose |
|------|---------|---------|
| [mise](https://mise.jdx.dev/) | Latest | Version manager for Erlang, Elixir, Node.js, Ruby, Flutter, Python |
| Erlang/OTP | 27.3+ | Runtime for Elixir |
| Elixir | 1.17+ | Primary programming language |
| Node.js | 24+ | VMS debug dashboard (Vue.js) |
| Ruby | 3.3+ | CLI build tool (`ovcs` script) |
| can-utils | Latest | CAN bus utilities (`cansend`, `candump`, `canplayer`) |
| [Nerves](https://hexdocs.pm/nerves/installation.html) | Latest | Required only for building firmware images |
| [Flutter](https://flutter.dev/docs/get-started/install) | 3.27.4 | Required only for the infotainment dashboard |
| [PlatformIO](https://platformio.org/) | Latest | Required only for building Arduino controller firmware |

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

### 4. Install CAN utilities

```sh
sudo apt install can-utils
```

The `can-utils` package provides `cansend`, `candump`, `canplayer`, and other tools for working with CAN bus interfaces. The Linux kernel modules `can` and `can_raw` are required and are included in standard (non-cloud) kernels.

### 5. Install Nerves (optional, for firmware builds)

Follow the [Nerves installation guide](https://hexdocs.pm/nerves/installation.html). This is only needed if you plan to build firmware images for Raspberry Pi targets.

### 6. Clone the repository

```sh
mkdir ovcs_base
cd ovcs_base
git clone https://github.com/open-vehicle-control-system/ovcs.git
```

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
cd ovcs
./scripts/setup_virtual_can.sh
```

This creates virtual CAN interfaces (`vcan0` through `vcan5`) that simulate physical CAN buses.

### 2. Test the VMS

```sh
cd vms/api
mix deps.get
mix phx.server
```

The VMS API should start and be accessible at `http://localhost:4000`.

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
