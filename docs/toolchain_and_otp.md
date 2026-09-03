# Toolchain and OTP versions

How the host toolchain in [`mise.toml`](../mise.toml) relates to the OTP
version each Nerves target ships, and why that coupling constrains when
the repo can move forward.

## The constraint

Nerves cross-compiles: the BEAM files are produced by the **host**
Elixir/OTP, then packaged with the **target system's** ERTS. Those two
must agree on the OTP major version. Bytecode compiled by a newer OTP
will not load on an older ERTS, so a mismatch produces either a build
failure or — worse — an image that flashes and then fails at boot.

`mix firmware`'s `compiler_check/0` does *not* catch this. It compares
the host's Erlang compiler against the OTP version its Elixir was built
with, both of which come from the same `mise.toml`. Nothing in the
toolchain checks host-vs-target.

The one thing that does check it is building each firmware in CI, which
is why `firmware.yml` runs on pull requests as well as pushes to main.

## Current state

The fleet is on **OTP 28**. Every system tracks upstream v2.0.3
(`nerves_system_br` 1.33.7, Erlang/OTP 28.5), and `mise.toml` pins
Erlang 28.4.1 / Elixir 1.19.5-otp-28 to match:

| Target | Used by | System release |
|---|---|---|
| `ovcs_base_can_system_rpi3a` | `bridges/firmware` (radio control) | v2.0.4 |
| `ovcs_base_can_system_rpi4` | `bridges/firmware` (ros), `vms/firmware` | v2.0.4 |
| `ovcs_base_can_system_rpi5` | `infotainment/firmware` | v2.0.4 |
| `rpi5` (`ovcs_bridges_system_rpi5`) | `bridges/firmware` (perception) | v2.0.8 |

Every one is pinned to a **tag**. They used to be bare `github:`
references tracking each fork's default branch, which is a trap worth
not re-setting: a release on the fork moves the branch, and the next
`mix deps.update` silently changes the OTP major with no warning.

`bridges/firmware` returns only the active target's system from `deps/0`
(`system_deps/1`) rather than listing all of them, so each `MIX_TARGET`
resolves independently. That is still needed: the perception Pi 5 is on
1.33.7 while the base systems are on their own line, and Mix evaluates
the whole dep graph regardless of the `:targets` keyword.

## What the v2.0 move brought with it

Upstream v2.0.0 was not just an OTP bump — it changed the MicroSD/eMMC
layout to A/B firmware slots with automatic rollback, one-way. Two
consequences are now permanent features of this repo, and both are easy
to break by accident:

1. **Firmware marks itself good.** An image that does not call
   `Nerves.Runtime.validate_firmware/0` is reverted on the next boot.
   `OvcsVehicle.FirmwareValidator` does this, wired into `vms_firmware`,
   `bridge_firmware` and `infotainment_firmware` on target only. Remove
   it and every OTA update silently rolls back — including NervesHub's.
2. **Boot overlays come in A/B pairs.** `cmdline-a.txt` (rootfs on
   `mmcblk0p5`) and `cmdline-b.txt` (`p6`) under
   `vehicles/*/priv/firmware/**`. The pairs are not interchangeable
   between roles: infotainment uses `console=tty3` with `logo.nologo`,
   radio-control carries `brcmfmac.feature_disable`. Derive a new pair
   from its own original, never from a template.

The per-target `fwup.conf` files under `<firmware>/targets/<target>/`
encode that partition layout, so they are regenerated from the system's
own v2.0 `fwup.conf` rather than hand-patched. The only OVCS changes on
top are the three `${VEHICLE_FIRMWARE_DIR}` redirects (`cmdline-a.txt`,
`cmdline-b.txt`, `config.txt`) and the CAN/SPI device-tree overlays each
firmware needs. Vehicles no longer carry their own copies — they were
byte-identical duplicates of the target defaults, and
`resolve_firmware_file` falls through to those, keying
`VEHICLE_FIRMWARE_DIR` on `config.txt` rather than `fwup.conf`.

## Migrating a system fork again

The recipe, should a fork need to follow upstream again:

1. Fetch upstream tags into their **own namespace**
   (`git fetch upstream 'refs/tags/*:refs/tags/up/*'`) and take the base
   from `git merge-base main upstream/main`. The forks carry their own
   `v1.29.x`/`v2.0.x` tags, whose names collide with upstream's, and
   `git fetch --tags` will not overwrite an existing tag — so a naive
   `git diff v1.29.3 main` compares fork-to-fork and reports a
   misleading delta.
2. Branch from the upstream tag and re-apply the OVCS delta, which is
   thin: CAN packages in `nerves_defconfig`, CAN/SPI kernel modules in
   `linux-*.defconfig` (renamed between upstream releases, so re-apply
   rather than copy the file), and package identity in `mix.exs`.
3. `release.yml` builds the system with Buildroot on `ubuntu-22.04` and
   attaches the portable tarball to the release for the tag that
   triggered it. Newer runners ship GCC 13+ and CMake 4, which trip
   implicit-function-declaration errors in gnulib-derived host packages.
4. Tag it. Create the tag against an explicit SHA and check it points
   where you think before pushing — with colliding tag names in the
   repo, an unguarded `git tag` failure followed by `git push <tag>` will
   happily publish *upstream's* tag onto the fork.
5. Point the monorepo's system deps at the new tags and let the
   `Firmware` workflow build all four matrix entries.

Then **reflash every affected board.** The partition change cannot be
delivered as an OTA update, and a device left on the old layout cannot
take the new firmware.

## Why the fleet bump rather than per-project toolchains

The alternative was a directory-scoped `mise.toml` keeping OTP 27 for
the rpi3a/rpi4 projects, so only the Pi 5 moved. It avoids reflashing,
at the cost of two toolchains installed, contributors having to know
which shell they are in, and CI having to pick the right one per job —
and it only defers the work. The fleet bump was chosen for a single
toolchain and a single `nerves_system_br` across every target.

The reflash cost was accepted deliberately: the v2.0 partition change
makes it unavoidable regardless of when it happens.

## A gotcha if a fork ever needs its workflow re-added

`workflow_dispatch` only works once the workflow file is on the
repository's **default** branch, so a `release.yml` introduced in a pull
request cannot be dispatched from that pull request. If a fork has no
workflows on `main`, land `release.yml` there on its own first — it
touches nothing the system builds, so merging it unbuilt is safe — then
dispatch it against the migration branch, and merge the migration only
once that run is green.
