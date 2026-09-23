---
title: Getting started
description: Set up a Linux workstation (or a VM on macOS) with mise, the system packages and the ovcs CLI, then check it with ./ovcs doctor.
---

OVCS runs on your workstation without any hardware: virtual CAN interfaces stand in for the buses, and every firmware boots as a plain BEAM. This guide takes a fresh machine to a green `./ovcs doctor`. From there, the [Quickstart](./quickstart.md) boots a whole application in one command.

> [!NOTE]
> Linux is the development platform. The virtual CAN driver (`vcan`) is a Linux kernel module that only ships in standard, non-cloud kernels. On macOS, develop inside a Linux VM ([below](#macos-multipass-vm)). WSL2's stock kernel has no `vcan` either, so use a full VM on Windows too.

## What you install

Most of the toolchain is pinned in [`mise.toml`](../mise.toml) and installed by [mise](https://mise.jdx.dev/) in one go. A few system packages come from your distribution.

| Tool | Version | Purpose | Installed by |
|---|---|---|---|
| mise | latest | Version manager for every runtime below | you, once |
| Erlang/OTP | 28.4.1 | Runtime for Elixir | mise |
| Elixir | 1.19.5-otp-28 | The primary language | mise |
| Rust | 1.90 | Compiles the `ovcs` CLI | mise |
| Node.js | 24 | VMS debug dashboard (Vue) | mise |
| Ruby | 3.3 | Utility scripts under `scripts/` | mise |
| Python | 3.12 | PlatformIO | mise |
| Flutter | 3.32.8 | Infotainment dashboard | mise |
| PlatformIO | latest | Generic controller firmware (Arduino) | mise (pipx + uv) |
| balena CLI | 25.x | Deploys the ROS compute node's containers | mise |
| Docker + Compose v2 | latest | Simulator, ROS base station, compute node images | system package |
| can-utils | latest | `cansend`, `candump`, `canplayer` | system package |
| fwup | 1.15+ | Nerves firmware image packager | `.deb` from GitHub releases |
| libsocketcan-dev | latest | Cantastic's native CAN bindings (firmware builds only) | system package |
| libmnl-dev | latest | Host-compiles `nerves_uevent` | system package |
| nerves_bootstrap | latest | Nerves Mix archive | `mise install` hook |

> [!WARNING]
> The Erlang and Elixir versions are exact, not minimums. Every Nerves target ships the OTP 28 line, and Mix refuses to cross-compile across OTP majors: a host on OTP 27 builds nothing for hardware, and an Elixir older than 1.19 does not compile the tree. [Toolchain and OTP](./toolchain_and_otp.md) explains the coupling.

## Set up your machine

Every step is the same on any system except step 2, the system packages.

### 1. Install mise

```sh
curl https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc   # or bash / fish
exec $SHELL
```

Other shells and package-manager installs are in the [mise installation docs](https://mise.jdx.dev/getting-started.html).

### 2. Install system packages

#### Debian / Ubuntu

mise builds Erlang and Ruby from source, so the C toolchain and dev headers have to be present:

```sh
sudo apt install -y build-essential autoconf m4 \
  libncurses-dev libssl-dev libffi-dev libyaml-dev zlib1g-dev \
  libwxgtk3.2-dev libgl1-mesa-dev libglu1-mesa-dev libpng-dev \
  libssh-dev unixodbc-dev xsltproc fop libxml2-utils pkg-config
```

Then the tools OVCS calls:

```sh
sudo apt install -y git can-utils libsocketcan-dev libmnl-dev kmod
```

- `git` clones the sideloaded `cantastic`, `express_lrs`, `msp_osd` and `ovcs_control` libraries (step 4).
- `kmod` provides `lsmod` and `modprobe`, which `./ovcs can setup` and `./ovcs run` use to load `vcan`. Minimal container images lack it.
- `libsocketcan-dev` is only needed to build firmware for physical CAN targets.
- `libmnl-dev` host-compiles `nerves_uevent`, a transitive firmware dependency.

`fwup` is not in the Debian/Ubuntu repositories. Install the `.deb` from its releases:

```sh
curl -L -o /tmp/fwup.deb "https://github.com/fwup-home/fwup/releases/download/v1.15.0/fwup_1.15.0_$(dpkg --print-architecture).deb"
sudo dpkg -i /tmp/fwup.deb
```

To run the Flutter infotainment dashboard on your desktop (`mise run infotainment-dashboard`), add the Linux desktop toolchain and check that `flutter doctor` ticks the **Linux toolchain** line:

```sh
sudo apt install -y clang cmake ninja-build libgtk-3-dev
```

#### Bluefin / atomic Fedora

On an immutable Fedora (Bluefin, Silverblue, Kinoite, Bazzite, uBlue) `/usr` is read-only, so you develop inside an **Ubuntu distrobox**: a rootless container that shares your home directory, display and devices. The Debian / Ubuntu commands above then apply verbatim inside it.

**CAN kernel and network setup must happen on the host.** A rootless container can't `modprobe` (it needs real root) or create interfaces (it needs `CAP_NET_ADMIN` over the host network namespace), and `--privileged` doesn't change that. The symptom is `./ovcs can setup` running its sudo block, then failing with `modprobe: Operation not permitted` or `RTNETLINK answers: Operation not permitted`. Create the interfaces once on the host, so the CLI finds them already up:

```sh
# Load the vcan module now and on every boot.
sudo modprobe vcan
echo vcan | sudo tee /etc/modules-load.d/vcan.conf

# Create vcan0..vcan4 now and on every boot via a systemd one-shot.
sudo tee /etc/systemd/system/ovcs-vcan.service >/dev/null <<'EOF'
[Unit]
Description=Create virtual CAN interfaces for OVCS
After=systemd-modules-load.service
Requires=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for i in 0 1 2 3 4; do ip link add dev vcan$$i type vcan 2>/dev/null || true; ip link set up vcan$$i; done'

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now ovcs-vcan.service
```

`ip -br link show | grep vcan` lists five interfaces in `UP` state. Five covers the OVCS1 reference application, the largest; widen the loop if your application declares more networks. Then create and enter the container:

```sh
distrobox create --name ovcs --image ubuntu:24.04
distrobox enter ovcs
```

From here on, **every command in this guide runs inside the container**. The clone lives in your shared home, so nothing moves, and `sudo` is passwordless.

The host's mise (usually a Homebrew binary) isn't mounted into the container: re-run step 1 inside it, then wire mise into the container's bash:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
echo 'eval "$(mise activate bash)"' >> ~/.bashrc
exec bash
```

Run the Debian / Ubuntu `apt` commands and the `fwup` install inside the container. To burn SD cards from inside it, you may need `--additional-flags "--device /dev/bus/usb"` at create time. To call a container binary from the host shell, export it once:

```sh
distrobox-export --bin /usr/local/bin/fwup --export-path ~/.local/bin
```

#### macOS (Multipass VM)

You need a full Linux VM. [Multipass](https://canonical.com/multipass/install) is the simplest:

```sh
multipass launch --name primary --disk 40G --cpus 2 --memory 8G
multipass shell
sudo passwd ubuntu
```

Size the disk for Nerves builds up front: it can't grow after creation. Clone the repository **inside the VM** to avoid permission and symlink problems in Nerves builds; share it back to macOS over NFS if you want your usual editor. Then follow the Debian / Ubuntu instructions inside the VM.

### 3. Clone the repository

```sh
git clone https://github.com/open-vehicle-control-system/ovcs.git
cd ovcs
```

### 4. Install the runtimes

```sh
mise trust
mise install
```

`mise install` installs every pinned runtime, then runs a hook that does two more things:

- `mise run bootstrap`: installs hex, rebar and the `nerves_bootstrap` archive.
- `mise run libraries`: clones `cantastic`, `express_lrs`, `msp_osd` and `ovcs_control` into `libraries/`. Existing clones are left alone, so your local edits there survive.

From now on, entering the directory activates the pinned versions. Reinstalling Elixir later fires the same hook.

### 5. Build the CLI and check everything

```sh
mise run cli      # cargo build --release, stripped and copied to cli/ovcs
./ovcs doctor
```

`./ovcs` at the repository root is a symlink to `cli/ovcs`, which is gitignored: every contributor builds it. `doctor` checks the required binaries (mise, Elixir, Node, Ruby, Python, Flutter, fwup, can-utils, PlatformIO), the `nerves_bootstrap` archive, the `libsocketcan` headers, each application's Nerves targets under `vehicles/`, and their SSH host keys. Missing host keys are a warning: you only need them before burning firmware.

### 6. Optional: firmware builds

Skip this if you only develop on the host. Building images for the Raspberry Pis additionally needs the host packages from the [Nerves installation guide](https://hexdocs.pm/nerves/installation.html) (`squashfs-tools`, `ssh-askpass`, …). You don't clone the OVCS Nerves systems: each firmware project pins its system to a release tag and Mix fetches it, prebuilt, on the first build. Clone a system into `systems/` only to modify it ([Toolchain and OTP](./toolchain_and_otp.md#hacking-on-a-system-fork-locally)).

Before your first burn, generate stable SSH host keys for your application, so reflashes don't trip OpenSSH's "REMOTE HOST IDENTIFICATION HAS CHANGED" warning:

```sh
./ovcs host-keys generate <app>   # once per application, e.g. ovcs1
```

The build, burn and upload flow is in [Running on hardware](./running_hardware.md).

## Verify the setup

These steps run the OVCS1 reference application. `ovcs_mini`, `obd2` and an application you scaffolded with `./ovcs new` work the same way.

Provision the virtual CAN interfaces. The CLI reads the application's `default_can_mapping(:host)` and creates only the interfaces it needs; you're prompted for sudo the first time, and a second run is a no-op:

```sh
./ovcs can setup ovcs1
./ovcs can status ovcs1
```

Boot the application. This provisions vcan if needed, compiles every firmware for the host, and spawns one BEAM per firmware role, joined into one Erlang cluster:

```sh
./ovcs run ovcs1
```

The VMS API answers on `http://localhost:4000`; open the dashboard on the dev server `./ovcs run` starts alongside it, `http://localhost:5173`.

In a second terminal, attach the TUI: merged logs, the message bus, decoded CAN frames and an IEx shell across every running BEAM.

```sh
./ovcs attach ovcs1
```

In a third, send the VMS a Nissan Leaf inverter status reporting 5000 rpm. OVCS1 maps its `leaf_drive` network to `vcan1` on the host:

```sh
cansend vcan1 1DA#0000000013880000
```

The CAN pane shows it decoded as `leaf_drive/inverter_status` with `rotations_per_minute=5000`.

> [!TIP]
> Something doesn't line up? [Troubleshooting](./troubleshooting.md) lists the setup failures people hit most, each with the check that names the cause.

## Next steps

- [Quickstart](./quickstart.md): boot a reference application, open the dashboard, attach the TUI, send your first frame.
- [Framework and applications](./framework.md): what the framework provides and what an application is.
- [Simulation](../compose/local/simulation/README.md): drive a Gazebo model of the OVCS Mini reference application with nothing but Docker.
- [Framework components](./applications.md): each core, API, firmware shell and library.
- [Hardware](./hardware_architecture.md): the Raspberry Pis, the CAN hub and the Arduino controllers.
