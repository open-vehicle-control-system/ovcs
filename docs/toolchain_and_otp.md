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

Each target system pins its own `nerves_system_br`, which fixes its OTP
version. Every system currently on main locks **1.29.3**:

| Target | Used by | `nerves_system_br` |
|---|---|---|
| `ovcs_base_can_system_rpi3a` | `bridges/firmware` (radio control) | 1.29.3 |
| `ovcs_base_can_system_rpi4` | `bridges/firmware` (ros), `vms/firmware` | 1.29.3 |
| `ovcs_base_can_system_rpi5` | `infotainment/firmware` | 1.29.3 |

`mise.toml` on main pins Erlang 27.3, and the `Firmware` workflow builds
all of these green — so 1.29.3 is the OTP 27 line, and the host matches
every target today.

The perception work (PR #26) adds a fourth: the `rpi5` target, backed by
`ovcs_bridges_system_rpi5` v2.0.8, which locks `nerves_system_br`
1.33.7. Per that branch's own `mise.toml` note, upstream
`nerves_system_rpi5` v2.0.x ships OTP 28 and Elixir 1.19, and the branch
raises the host pin to match.

The perception bridge needs the Pi 5 system's OTP 28 line: it is rebased
on upstream `nerves_system_rpi5` v2.0.x, which is what ships libcamera
with PISP pipeline support — the whole point of Camera Module 3 stereo
capture on the Pi 5.

`bridges/firmware` handles the resulting `nerves_system_br` conflict by
returning only the active target's system from `deps/0`
(`system_deps/1`), so each `MIX_TARGET` resolves independently instead
of Mix trying to satisfy 1.29.3 and 1.33.7 at once.

That solves *dependency resolution*. It does not solve the host pin:
`mise.toml` can only name one Erlang/Elixir, so raising it to OTP 28 for
the Pi 5 leaves the rpi3a/rpi4 firmwares built by a host newer than the
ERTS they ship.

## The decision: bump the fleet

All three base systems move to upstream **v2.0.3** (`nerves_system_br`
1.33.7, Erlang/OTP 28.5), and the whole repo runs one OTP 28 toolchain.
v2.0.3 is chosen rather than the newest tag because it is exactly the
base `ovcs_bridges_system_rpi5` v2.0.8 already sits on — so the fleet
ends up on a single `nerves_system_br`, not two.

The alternative considered and rejected was per-project toolchains (a
directory-scoped `mise.toml` keeping OTP 27 for the rpi3a/rpi4
projects). It avoids reflashing, at the cost of two toolchains, and it
only defers this work.

### This is a partition-layout migration, not just an OTP bump

Upstream v2.0.0 is a **breaking, one-way** change: the MicroSD/eMMC
layout gains A/B firmware slots with automatic rollback. Quoting the
upstream changelog:

> **IMPORTANT** This is a one way upgrade. Going back to the old
> partitioning requires manually reflashing of the RPi's storage.

Two consequences land squarely on this repo, and both are easy to miss:

1. **Firmware must mark itself good.** From v2.0.0, an image that does
   not call `Nerves.Runtime.validate_firmware/0` is reverted to the
   previous version on the next boot. Nothing in this repo calls it
   today. Miss this and *every* OTA update silently rolls back —
   including NervesHub updates, which makes this a hard prerequisite
   for the NervesHub work rather than a follow-up to it.
2. **Every per-vehicle boot overlay needs an A/B pair.** Upstream
   replaced `cmdline.txt` with `cmdline-a.txt` + `cmdline-b.txt`
   (rootfs on `mmcblk0p5` vs `p6`). Ten of the eleven overlays under
   `vehicles/*/priv/firmware/**` are still single-slot; only the
   perception bridge's has been converted.

### The OVCS delta each fork re-applies

The forks are thin, which is what makes this tractable. Ignoring
`LICENSES/`, `REUSE.toml` and `README.md` boilerplate, the functional
delta over upstream is:

| File | What OVCS adds |
|---|---|
| `nerves_defconfig` | `LIBSOCKETCAN`, `CAN_UTILS`, `SOCKETCAND`, `IPROUTE2`, `IPTABLES`, eudev for dynamic device nodes; `BR2_NERVES_SYSTEM_NAME` rename |
| `linux-*.defconfig` | `CAN`, `CAN_VCAN`, `CAN_MCP251X`, `CAN_MCP251XFD`, `SERIAL_SC16IS7XX` (SPI variant on, I²C off) |
| `mix.exs`, `VERSION`, `README.md`, `.gitignore` | package identity |

Measured on `rpi4`: thirteen config lines plus identity. The PWM
device-tree overlays, the `config.txt` PWM hint and the NVMe kernel
option used to be carried here and are **upstream's own** as of v2.0.x —
re-adding them would be duplication.

Three traps, all of which produce a plausible-looking but wrong result:

- **The forks carry their own `v1.29.x` tags**, which collide with
  upstream's tag names. `git fetch upstream --tags` will not overwrite
  an existing tag, so `git diff v1.29.3 main` silently compares
  fork-to-fork and reports an empty or misleading delta. Fetch upstream
  tags into their own namespace
  (`git fetch upstream 'refs/tags/*:refs/tags/up/*'`) and take the base
  from `git merge-base main upstream/main`. Getting this wrong is how
  the PWM/NVMe rows above came to be attributed to OVCS.
- The kernel defconfig is renamed upstream (`linux-6.6.defconfig` →
  `linux-6.12.defconfig`). The delta has to be re-applied to the new
  file, not carried over wholesale — the surrounding config moved.
- `fwup.conf` is **generated** from `fwup.conf.eex` by a mix task in
  v2.0.3. Nothing in the OVCS delta touches it, but if that ever
  changes, edit the template — the output is overwritten.

### These build in CI

`ovcs_bridges_system_rpi5` already carries a `release.yml` that builds
the system with Buildroot on `ubuntu-22.04` (90-minute timeout, Nerves
toolchain artifacts cached) and attaches the portable tarball to the
release for the tag that triggered it. Copy it into each base system —
no local Buildroot run or bench build is needed to produce a release.

It pins `ubuntu-22.04` deliberately: newer runners ship GCC 13+ and
CMake 4, which trip implicit-function-declaration errors in
gnulib-derived host packages.

### Order of work

Per system repo, `rpi4` first as the pilot (it carries both `vms` and
the `ros` bridge, so it exercises the most):

1. Branch from upstream `v2.0.3`.
2. Re-apply the delta in the table above, porting the kernel options
   onto `linux-6.12.defconfig`.
3. Restore the fork's identity: `VERSION`, `mix.exs` package name,
   `BR2_NERVES_SYSTEM_NAME`, `LICENSES/`, `REUSE.toml`, `README.md`.
4. Add `release.yml` from `ovcs_bridges_system_rpi5`, with a
   `pull_request` trigger added — see the note below on why
   `workflow_dispatch` alone is not enough.
5. Tag `v2.0.3-ovcs.1` (or continue the fork's own series) and let CI
   build and publish the tarball.
6. Repeat for `rpi3a` and the infotainment `rpi5`.

Then in this repo, in one PR:

7. Point the three system deps at the new tags.
8. Add `Nerves.Runtime.validate_firmware/0` to `vms_firmware`,
   `bridge_firmware` and `infotainment_firmware` — see prerequisite 1
   above.
9. Convert the ten remaining `cmdline.txt` overlays to `-a`/`-b` pairs,
   following the perception bridge's.
10. Keep `mise.toml` on OTP 28 and confirm the `Firmware` workflow is
    green for all four matrix entries.

Finally: **reflash every deployed rpi3a/rpi4/rpi5 device.** The
partition change cannot be delivered as an OTA update, and a device
left on the old layout cannot take the new firmware.

## Getting a system built the first time

`workflow_dispatch` only works once the workflow file is on the
repository's **default** branch, so a `release.yml` introduced in a pull
request cannot be dispatched from that pull request. The base branches of
these forks have no workflows at all today, and no Actions run has ever
happened in them.

The way out, in order:

1. Land `release.yml` on the fork's `main` on its own. It touches nothing
   the system builds, so merging it unbuilt is safe.
2. Then `workflow_dispatch` it against the migration branch — dispatch
   can target any branch once the file is on the default branch.
3. Only merge the migration once that run is green.

A `pull_request` trigger is also worth keeping, so later changes are
built before merge rather than after.
