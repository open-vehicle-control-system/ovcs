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
| Rust | 1.90+ | Compiles the top-level `ovcs` CLI (native binary at `cli/ovcs`) | mise |
| Node.js | 24+ | VMS debug dashboard (Vue.js) | mise |
| Ruby | 3.3+ | Utility scripts under `scripts/` (e.g. `bind_remote_can.rb`, `faker.rb`) | mise |
| Python | 3.12+ | PlatformIO + misc tooling | mise |
| [Flutter](https://flutter.dev/docs/get-started/install) | 3.32.8 | Infotainment dashboard | mise |
| can-utils | Latest | CAN bus utilities (`cansend`, `candump`, `canplayer`) | system package |
| `fwup` | Latest | Nerves firmware image packager | system package |
| `libsocketcan-dev` | Latest | Cantastic native CAN bindings | system package (firmware builds only) |
| `libmnl-dev` | Latest | Host-compile `nerves_uevent` native | system package |
| `nerves_bootstrap` | Latest | Nerves Mix archive | `mise run bootstrap` |
| [PlatformIO](https://platformio.org/) | Latest | Arduino controller firmware | mise (via pipx + uv) |

## Linux Setup

Steps 1, 4, 5, 6, and 7 are OS-agnostic. Steps 2 and 3 (system packages) are written for Debian/Ubuntu; if you're on an **atomic Fedora (Bluefin, Silverblue, Kinoite, Bazzite, …)**, skip to [Bluefin / Fedora Silverblue (atomic)](#bluefin--fedora-silverblue-atomic) — it replaces steps 2 and 3 with a toolbox-based flow.

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
  libssh-dev unixodbc-dev xsltproc fop libxml2-utils pkg-config
```

### 3. Install system-level tools

```sh
sudo apt install -y git can-utils libsocketcan-dev libmnl-dev kmod
```

- `git` is needed by `mise run libraries` to clone the sideloaded `cantastic` / `express_lrs` / `msp_osd` / `ovcs_control` repos. Most host distros ship it already; fresh containers (distrobox, VMs) do not.
- `kmod` provides `lsmod` / `modprobe`, which `./ovcs can setup` and `./ovcs run` call to load the `vcan` kernel module. Standard on host distros; not included in the minimal Ubuntu container image.
- `can-utils` provides `cansend`, `candump`, `canplayer`, and the rest. The Linux kernel modules `can` and `can_raw` are required and are included in standard (non-cloud) kernels.
- `libsocketcan-dev` is only needed when building for physical CAN targets (i.e. the Pi firmwares); it supplies the native headers Cantastic links against.
- `libmnl-dev` is needed to host-compile `nerves_uevent` (transitively pulled in by firmware deps).

`fwup` is the firmware image packager Nerves calls during `mix firmware`. It is **not** in the Debian/Ubuntu repos — install the latest `.deb` from the project's GitHub releases:

```sh
curl -L -o /tmp/fwup.deb "https://github.com/fwup-home/fwup/releases/download/v1.15.0/fwup_1.15.0_$(dpkg --print-architecture).deb"
sudo dpkg -i /tmp/fwup.deb
```

On macOS: `brew install fwup can-utils` (`fwup` is in homebrew; there's no `libsocketcan` on macOS — firmware builds happen inside the Linux VM).

### Bluefin / Fedora Silverblue (atomic)

> This subsection replaces steps 2 and 3 above when you're on an immutable Fedora variant (Bluefin, Silverblue, Kinoite, Bazzite, uBlue, …). Continue with step 4 once you're done here.

Atomic Fedora images are read-only at `/usr`, so do all development work inside an **Ubuntu distrobox** — a rootless podman container that shares your `$HOME`, display, and devices with the host. Using an Ubuntu image (instead of a Fedora toolbox) means the `apt` commands in steps 2 and 3 above, plus the `fwup` `.deb` install, apply verbatim.

**All CAN kernel/network setup must happen on the host** — a rootless distrobox can't do any of it, and `--privileged` doesn't change that. Module insertion (`modprobe`) needs true root, not user-namespace caps. Interface creation (`ip link add … type vcan`) needs `CAP_NET_ADMIN` over the host net namespace, which rootless "fake root" doesn't grant even though the container shares the host net namespace. Once the host has loaded `vcan` and created the interfaces, the container just *uses* them — CAN socket I/O from inside the distrobox works against host-created `vcan` interfaces without any extra privileges.

That's why the OVCS CLI's `./ovcs can setup` and `./ovcs run` will *appear* to run their sudo block but then fail with `modprobe: Operation not permitted` or `RTNETLINK answers: Operation not permitted` on Bluefin. The fix is to provision the interfaces up-front on the host so the CLI's "already up — nothing to do" branch hits.

Run this on the host, **once**, as a one-time persistent setup:

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

`ip -br link show | grep vcan` should now show five `vcan0`…`vcan4` interfaces in `UP` state. Adjust the loop range if a future vehicle needs more interfaces.

The container itself needs no special flags — CAN socket I/O, `mix`, `fwup`, `mise`, and `cargo` all work in a plain rootless distrobox:

```sh
distrobox create --name ovcs --image ubuntu:24.04
distrobox enter ovcs
```

> If you later run firmware burns from inside the container (`fwup` writing to an SD card / USB), you may need to pass device access with e.g. `--additional-flags "--device /dev/bus/usb"` at create time — revisit when you get there.

From this point on, every command in this guide runs **inside the container** — `mise install`, `./ovcs …`, `mix`, `npm`, CAN tooling, everything. The repo clone lives in your shared `$HOME`, so no files move. `sudo` is passwordless inside distrobox.

**mise must be (re)installed inside the container.** On Bluefin the host `mise` is typically a Homebrew binary at `/home/linuxbrew/.linuxbrew/bin/mise`, and that path is not mounted into distroboxes. Run the step-1 installer again inside the container so a container-local binary lands at `~/.local/bin/mise` (the host still uses its own Homebrew `mise` — they don't conflict because the host shell resolves `mise` as a function pointing to `$__MISE_EXE`). After installing, wire the activation hook into the container's bash init so runtimes (Elixir, Node, Python, …) are on `PATH` automatically:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
echo 'eval "$(mise activate bash)"' >> ~/.bashrc
exec bash
```

`mise activate` is preferred over a raw shims-on-`PATH` export because it also picks up `[env]` blocks in `mise.toml`, handles per-directory tool-version switches, and surfaces auto-install hints. If you'd rather keep things minimal (e.g. you never use `mise use`), `export PATH="$HOME/.local/share/mise/shims:$PATH"` on its own is enough to make `./ovcs doctor` pass.

> `distrobox enter` drops you into bash by default when your host login shell (e.g. zsh) isn't present in the Ubuntu image. Add the same lines to `~/.zshrc` only if you install and use zsh inside the container — otherwise the host's `~/.zshrc` (which activates Homebrew `mise`) is irrelevant here.

Now go back and run steps 2, 3, 4, 5, 6 (and 7 if you need firmware builds) as written.

If you want any binary produced by these steps (e.g. `fwup`, `cansend`, `./ovcs`) callable from the host shell, export it once:

```sh
distrobox-export --bin /usr/local/bin/fwup --export-path ~/.local/bin
```

Continue with [step 4 (Clone the repository)](#4-clone-the-repository) — inside the container.

### 4. Clone the repository

```sh
git clone https://github.com/open-vehicle-control-system/ovcs.git
cd ovcs
```

### 5. Install language runtimes

The repo ships a `mise.toml` pinning every required runtime (Erlang, Elixir, Node, Ruby, Flutter, Python). From inside the repo:

```sh
mise trust
mise install        # installs language runtimes and runs the postinstall hook:
                    # - bootstrap: hex, rebar, nerves_bootstrap Mix archive
                    # - libraries: clones cantastic, express_lrs, msp_osd,
                    #              ovcs_control into libraries/ (skipped
                    #              if already present)
```

From now on, `cd`-ing into the project activates the pinned versions automatically. The `mise install` postinstall hook runs `mise run bootstrap && mise run libraries` for you. If you ever reinstall Elixir (`mise install elixir@...`) the same hook fires, so the archive and the sideloaded libraries stay in sync — existing clones are left alone, so local edits in `libraries/cantastic/`, etc. are preserved.

### 6. Build the CLI and verify

```sh
mise run cli         # builds ./ovcs (Rust release binary via `cargo build --release`)
./ovcs doctor        # verify everything
```

`./ovcs doctor` checks every required binary, the `nerves_bootstrap` archive, `libsocketcan` headers, and each vehicle package's metadata. Green across the board means you're ready.

### 7. Install custom Nerves systems (only for firmware builds)

If you plan to build and deploy firmware to physical hardware, follow the [Nerves installation guide](https://hexdocs.pm/nerves/installation.html) for the additional tooling (e.g. `squashfs-tools`, `fakeroot`) and clone the OVCS Nerves systems — see the [System Images](#setting-up-system-images-for-firmware-builds) section below.

Before your first burn, generate stable per-role SSH host keys for the
vehicle so SD-card reflashes don't trip the "REMOTE HOST IDENTIFICATION
HAS CHANGED" warning:

```sh
./ovcs vehicle host-keys <vehicle>          # one-time per vehicle
```

See [`docs/running_hardware.md`](./running_hardware.md#stable-ssh-host-keys-across-burns)
for the full flow.

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

The CLI reads the vehicle's `default_can_mapping(:host)` and creates only the vcan interfaces that vehicle actually needs. It's idempotent: a second run on the same vehicle is a no-op. You'll be prompted for your sudo password the first time.

### 2. Boot the vehicle locally

```sh
./ovcs run ovcs1              # provisions vcan + spawns one BEAM per firmware
```

This is the shortcut for "set up CAN, then start everything." `./ovcs run` spawns one BEAM per declared firmware (VMS, infotainment, each bridge) from its own project directory. `OvcsBus.Cluster` stitches them into an Erlang-distribution cluster on boot — cross-BEAM messages fan out through `OvcsBus.broadcast/2` with no broker needed. Attach a merged log + IEx TUI from another terminal with `./ovcs attach ovcs1`. Use `Ctrl-C` to stop.

If you prefer running pieces separately:

```sh
cd vms/api
VEHICLE=Ovcs1 mix deps.get
VEHICLE=Ovcs1 mix phx.server
```

Either way the VMS API lands at `http://localhost:4000`. The `VEHICLE` env var is mandatory for the split form — it selects which vehicle package's composer wires the supervision tree and CAN topology. Use `Ovcs1`, `OvcsMini`, or `Obd2` (the top-level module name of the vehicle package).

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

### 5. (Optional) Attach the multi-node TUI

In another terminal, see the merged log / bus / CAN / IEx view across
every running BEAM:

```sh
./ovcs attach ovcs1
```

`Tab` switches focus between panes; `Ctrl-N` / `Ctrl-P` (or `F1`–`F9`)
selects which node drives the IEx pane. See
[`docs/running_hardware.md`](./running_hardware.md#tui-hotkeys) for the
full hotkey reference.

## Next Steps

- [Applications](./applications.md) -- Understand the application structure and run each component locally.
- [Testing CAN Messages](./testing_can_messages.md) -- Simulate CAN traffic for development.
- [Hardware Architecture](./hardware_architecture.md) -- Understand the hardware design.

Next: [Applications](./applications.md)
