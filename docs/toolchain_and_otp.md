---
title: Toolchain and OTP
description: Why the host Elixir/OTP pin is coupled to each Nerves target, what the A/B firmware layout requires of every image, and how to move a system fork forward.
---

The host toolchain pinned in [`mise.toml`](../mise.toml) is not a free choice: each Nerves target ships its own Erlang runtime, and the two have to agree. This guide covers that coupling, the current pins, what the A/B firmware layout demands of every image, and how to follow upstream with a system fork. The toolchain and the Nerves systems belong to the framework, so all of it applies to every application, yours included.

## The constraint

Nerves cross-compiles: the **host** Elixir/OTP produces the BEAM files, which are then packaged with the **target system's** ERTS. Both must be on the same OTP major. Bytecode from a newer OTP won't load on an older ERTS, so a mismatch gives you a build failure or, worse, an image that flashes and then fails at boot.

`mix firmware`'s `compiler_check/0` doesn't catch this. It compares the host's Erlang compiler against the OTP its Elixir was built with, and both come from `mise.toml`. Nothing in the toolchain compares host against target. Building each firmware in CI does, which is why the `firmware.yml` workflow runs on pull requests as well as on pushes to `main`.

## Current pins

Every system is on OTP 28 (`nerves_system_br` 1.33.7), and `mise.toml` pins Erlang 28.4.1 / Elixir 1.19.5-otp-28 to match. Those entries are exact, not minimums.

| Target | Used by | System release |
|---|---|---|
| `ovcs_base_can_system_rpi3a` | `bridges/firmware` (radio control) | v2.0.4 |
| `ovcs_base_can_system_rpi4` | `vms/firmware`, `bridges/firmware` (ROS) | v2.0.4 |
| `ovcs_base_can_system_rpi5` | `infotainment/firmware` | v2.0.4 |
| `rpi5` (`ovcs_bridges_system_rpi5`) | `bridges/firmware` (perception) | v2.0.8 |

Which of these your application builds depends on the targets its `OvcsVehicle` module declares; the reference applications use all four between them.

Every system is pinned to a **tag**, never to a branch. A branch moves with each release on the fork, and the next `mix deps.update` would silently change the OTP major.

`bridges/firmware` returns only the active target's system from `deps/0` (`system_deps/1`). Mix resolves the whole dependency graph regardless of the `:targets` keyword, so listing every system would turn any divergence between their `nerves_system_br` pins into a `mix deps.get` conflict. They agree today, but nothing enforces it, and this keeps each `MIX_TARGET` independent.

## What the A/B layout requires

The v2.0 systems use A/B firmware slots on the MicroSD/eMMC with automatic rollback. Two consequences are easy to break by accident.

> [!WARNING]
> **Firmware must mark itself good.** An image that doesn't call `Nerves.Runtime.validate_firmware/0` is reverted on the next boot. `OvcsVehicle.FirmwareValidator` does this in `vms_firmware`, `infotainment_firmware` and `bridge_firmware`, on target only, so every application gets it for free. Remove it and every OTA update silently rolls back, NervesHub's included.

**Boot overlays come in A/B pairs.** `cmdline-a.txt` (rootfs on `mmcblk0p5`) and `cmdline-b.txt` (`mmcblk0p6`) live next to `config.txt` under each application's `priv/firmware/<role>/` (`priv/firmware/bridges/<id>/` for bridges). The pairs are not interchangeable between roles: infotainment boots with `console=tty3` and `logo.nologo`, radio control with `brcmfmac.feature_disable`. Derive a new pair from its own role's original, never from another role.

The per-target `fwup.conf` under `<firmware>/targets/<target>/` encodes the partition layout. It is regenerated from the system's own `fwup.conf` rather than hand-patched; the OVCS changes on top are the three `${VEHICLE_FIRMWARE_DIR}` redirects (`cmdline-a.txt`, `cmdline-b.txt`, `config.txt`) and the CAN/SPI device-tree overlays each firmware needs. Each firmware's `config/config.exs` picks a file from the application's `priv/firmware/<role>/` when it exists and falls back to the target default otherwise, and points `VEHICLE_FIRMWARE_DIR` at the application directory when it has a `config.txt`. An application only ships a file that genuinely differs from the default.

## Migrating a system fork

When a fork needs to follow upstream again:

1. **Fetch upstream tags into their own namespace**: `git fetch upstream 'refs/tags/*:refs/tags/up/*'`, and take the base from `git merge-base main upstream/main`. The forks carry their own `v1.29.x` / `v2.0.x` tags whose names collide with upstream's, and `git fetch --tags` won't overwrite an existing tag, so a naive `git diff v1.29.3 main` compares fork to fork.
2. **Branch from the upstream tag and re-apply the OVCS delta.** It is thin: CAN packages in `nerves_defconfig`, CAN/SPI kernel modules in `linux-*.defconfig` (the file is renamed between upstream releases, so re-apply the options rather than copy the file), and package identity in `mix.exs`.
3. **Build with the release workflow.** `release.yml` builds the system with Buildroot on `ubuntu-22.04` and attaches the portable tarball to the release of the tag that triggered it. Newer runners ship GCC 13+ and CMake 4, which break gnulib-derived host packages with implicit-function-declaration errors.
4. **Tag against an explicit SHA**, and check the tag points where you think before pushing. With colliding tag names, a failed `git tag` followed by `git push <tag>` publishes *upstream's* tag onto the fork.
5. **Point the firmware projects at the new tags** and let the `firmware.yml` workflow build every matrix entry.

Then **reflash every affected board**, in every application deployed on the old layout. A partition-layout change can't be delivered over the air, and a device left on the old layout can't take the new firmware. The burn flow is in [Running on hardware](./running_hardware.md).

> [!NOTE]
> `workflow_dispatch` only works once the workflow file is on the repository's **default** branch, so a `release.yml` added in a pull request can't be dispatched from it. If a fork has no workflows on `main`, land `release.yml` there alone first (it touches nothing the system builds), dispatch it against the migration branch, and merge the migration once that run is green.

## One toolchain for every target

A directory-scoped `mise.toml` could keep an older OTP for some firmware projects and avoid reflashing their boards. It would cost two installed toolchains, contributors having to know which shell they're in, and CI picking the right one per job, and it only defers the work. OVCS keeps a single toolchain and a single `nerves_system_br` line across every target, and accepts the reflash when a partition change forces one.

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
