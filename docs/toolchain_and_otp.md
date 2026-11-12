---
title: Toolchain and OTP
description: Why the host Elixir/OTP pin is coupled to each Nerves target, what the A/B firmware layout requires of every image, and how to move a system fork forward.
---

The host toolchain pinned in [`mise.toml`](../mise.toml) is coupled to the Nerves targets: each target ships its own Erlang runtime, and the two have to agree. The toolchain and the Nerves systems belong to the framework, so this guide applies to every vehicle, yours included.

## The constraint

Nerves cross-compiles: the **host** Elixir/OTP produces the BEAM files, and the build packages them with the **target system's** ERTS. Both must be on the same OTP major. Bytecode from a newer OTP won't load on an older ERTS. A mismatch gives you a build failure or, worse, an image that flashes and then fails at boot.

Nerves checks the major: a firmware build stops with `Major version mismatch between host and target Erlang/OTP versions` when they differ. It does not check minors, and the error only appears once a build reaches that step. For that reason, the `firmware.yml` workflow builds every firmware on pull requests as well as on pushes to `main`.

The host toolchain comes from `mise.toml` only in a shell where mise is active. Run builds from such a shell, or through `mise exec --`. Otherwise the build uses the system Erlang on `PATH`.

## Current pins

Every system is on OTP 29 (`nerves_system_br` 1.35.3, Linux 6.18, 7.3 on the VENTUNO Q), and `mise.toml` pins Erlang 29.1.2 / Elixir 1.20.4-otp-29 to match. Those entries are exact, not minimums.

| Target | Used by | System release |
|---|---|---|
| `ovcs_base_can_system_rpi3a` | `bridges/firmware` (radio control) | v3.0.0-rc.1 |
| `ovcs_base_can_system_rpi4` | `vms/firmware`, `bridges/firmware` (ROS) | v3.0.0-rc.1 |
| `ovcs_base_can_system_rpi5` | `infotainment/firmware` | v3.0.0-rc.1 |
| `rpi5` (`ovcs_bridges_system_rpi5`) | `vision/firmware`, `bridges/firmware` | v3.0.0-rc.2 |
| `okdo_c100` (`nerves_system_okdo_c100`) | `vision/firmware` | v0.3.0 |
| `arduino_ventuno_q` (`nerves_system_arduino_ventuno_q`) | `vision/firmware` | v0.1.0 |

The Pi 5 system ships the Hailo-8 kernel driver and firmware but not the userspace library: `libraries/hailort` builds `libhailort` from source, at the same HailoRT version as the driver.

Which of these your vehicle builds depends on the targets its `OvcsVehicle` module declares. The reference vehicles use the first four between them, plus `arduino_ventuno_q` for the OVCS1 reference vehicle's vision unit. None builds `okdo_c100`.

Every system is pinned to a **tag**, never to a branch. A branch moves with each release on the fork, and the next `mix deps.update` would silently change the OTP major.

`bridges/firmware` returns only the active target's system from `deps/0` (`system_deps/1`). Mix resolves the whole dependency graph regardless of the `:targets` keyword. Listing every system would therefore turn any divergence between their `nerves_system_br` pins into a `mix deps.get` conflict. The pins agree today, but nothing enforces it, and this keeps each `MIX_TARGET` independent.

## What the A/B layout requires

The systems use A/B firmware slots on the MicroSD/eMMC with automatic rollback. Two consequences are easy to break by accident.

> [!NOTE]
> **Every firmware pins the CPUs to the `performance` governor.** Under `schedutil`, Linux's default, interrupt latency at low clock speeds overruns the FIFO of an SPI-attached UART, such as the radio control bridge's SC16IS752. Control input then arrives late. The OVCS systems' kernels default to `performance` (`CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE`). `OvcsVehicle.CpuGovernor` sets it again at boot in `vms_firmware`, `infotainment_firmware`, `bridge_firmware` and `vision_firmware`, on target only. A system image with another default therefore still runs `performance`. A devfreq GPU without a `performance` governor, such as the VENTUNO Q's Adreno, is pinned at its maximum frequency instead ([On the VENTUNO Q's GPU](./vision/compute.md#on-the-ventuno-qs-gpu)).

> [!WARNING]
> **Firmware must mark itself good.** An image that doesn't call `Nerves.Runtime.validate_firmware/0` is reverted on the next boot. `OvcsVehicle.FirmwareValidator` does this in `vms_firmware`, `infotainment_firmware`, `bridge_firmware` and `vision_firmware`, on target only, so every vehicle gets it. If you remove it, every OTA update silently rolls back, NervesHub's included.

**Boot overlays come in A/B pairs.** `cmdline-a.txt` (rootfs on `mmcblk0p5`) and `cmdline-b.txt` (`mmcblk0p6`) live next to `config.txt`, in two places:

- each firmware's shared `<firmware>/targets/<target>/`;
- a vehicle's `priv/firmware/<role>/` (`priv/firmware/bridges/<id>/` for bridges), when it overrides them.

The pairs are not interchangeable between roles: infotainment boots with `console=tty3` and `logo.nologo`, radio control with `brcmfmac.feature_disable`. Derive a new pair from the same role's pair in `<firmware>/targets/<target>/`, never from another role. Keep the `mmcblk0p5` / `mmcblk0p6` root partitions.

The per-target `fwup.conf` under `<firmware>/targets/<target>/` encodes the partition layout. It is regenerated from the system's own `fwup.conf` rather than hand-patched. The OVCS changes on top are:

- the three `${VEHICLE_FIRMWARE_DIR}` redirects (`cmdline-a.txt`, `cmdline-b.txt`, `config.txt`);
- the CAN/SPI device-tree overlays each firmware needs.

Each firmware's `config/config.exs` resolves the two kinds of file differently:

- `fwup.conf` falls back per file: the vehicle's `priv/firmware/<role>/fwup.conf` when it exists, the target's otherwise.
- The boot files go as a set. `VEHICLE_FIRMWARE_DIR` points at the vehicle's `priv/firmware/<role>/` when it holds a `config.txt`, and at `<firmware>/targets/<target>/` otherwise. `fwup.conf` reads `config.txt`, `cmdline-a.txt` and `cmdline-b.txt` from that one directory.

A vehicle that overrides `config.txt` therefore ships all three. `ovcs new` copies these three from the target defaults and leaves `fwup.conf` shared, so the vehicle keeps following the target's partition layout. A vehicle only ships a `fwup.conf` that genuinely differs from the default.

## Migrating a system fork

When a fork needs to follow upstream again:

1. **Fetch upstream tags into their own namespace**: `git fetch upstream 'refs/tags/*:refs/tags/up/*'`, and take the base from `git merge-base main upstream/main`. The forks carry their own `v1.29.x` / `v2.0.x` tags, whose names collide with upstream's. `git fetch --tags` won't overwrite an existing tag, so a plain `git diff v1.29.3 main` compares fork to fork.
2. **Branch from the upstream tag and re-apply the OVCS delta.** The delta is small: CAN packages in `nerves_defconfig`, CAN/SPI kernel modules in `linux-*.defconfig`, and package identity in `mix.exs`. The `linux-*.defconfig` file is renamed between upstream releases, so re-apply the options rather than copy the file.
3. **Build with the release workflow.** `release.yml` builds the system with Buildroot on `ubuntu-22.04` and attaches the portable tarball to the release of the tag that triggered it. Newer runners ship GCC 13+ and CMake 4, which break gnulib-derived host packages with implicit-function-declaration errors.
4. **Tag against an explicit SHA**, and check that the tag points where you expect before pushing. With colliding tag names, a failed `git tag` followed by `git push <tag>` publishes *upstream's* tag onto the fork.
5. **Point the firmware projects at the new tags** and let the `firmware.yml` workflow build every matrix entry.

Then **reflash every affected board**, in every vehicle deployed on the old layout. A partition-layout change can't be delivered over the air, and a device left on the old layout can't take the new firmware. The burn flow is in [Running on hardware](./running_hardware.md).

> [!NOTE]
> `workflow_dispatch` only works once the workflow file is on the repository's **default** branch, so a `release.yml` added in a pull request can't be dispatched from it. If a fork has no workflows on `main`:
>
> 1. Merge `release.yml` there alone first (it touches nothing the system builds).
> 2. Dispatch it against the migration branch.
> 3. Merge the migration once that run passes.

## One toolchain for every target

A directory-scoped `mise.toml` could keep an older OTP for some firmware projects and avoid reflashing their boards. It would cost two installed toolchains, contributors having to know which shell they're in, and CI picking the right one per job. It would also only defer the work. OVCS keeps a single toolchain and a single `nerves_system_br` line across every target, and accepts the reflash when a partition change forces one.

## Hacking on a system fork locally

`systems/` at the repository root holds local clones of the system forks, for patching Buildroot configs or testing kernel changes against a live firmware build. Each subdirectory is its own Git repository, and `.gitignore` excludes them.

```sh
cd systems
git clone https://github.com/open-vehicle-control-system/ovcs_bridges_system_rpi5.git
```

To build against the clone, swap the dependency in the firmware project:

```elixir
# bridges/firmware/mix.exs
{:ovcs_bridges_system_rpi5,
 path: "../../systems/ovcs_bridges_system_rpi5",
 runtime: false,
 targets: :rpi5,
 nerves: [compile: true]}   # compile: true so Buildroot rebuilds
```

Revert it before merging: production builds use the tagged release.
