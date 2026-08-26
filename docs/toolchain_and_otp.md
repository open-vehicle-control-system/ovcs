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

## The two exits

Both are viable; the choice hasn't been made.

**Bump the fleet.** Raise `nerves_system_br` to `~> 1.33` in
`ovcs_base_can_system_rpi3a` and `…_rpi4`, cut releases of each, and
move the whole repo to OTP 28. One toolchain, no special cases. Cost:
two external repos to update and release, and every deployed rpi3a/rpi4
device needs reflashing rather than an incremental OTA — a device on an
OTP 27 ERTS cannot take an OTP 28 update.

**Per-project toolchains.** Let the projects that build for OTP 27
targets keep an OTP 27 host, via a directory-scoped `mise.toml` under
`bridges/` or per-target. Cost: two toolchains installed, contributors
have to know which shell they're in, and CI has to be careful that each
job picks up the right one.

## Which one to pick

The fleet bump is the simpler end state and the one the code comments
already assume. Prefer it unless reflashing deployed rpi3a/rpi4 devices
is unacceptable — in which case the per-project split buys time.

Until one lands, `mise.toml` should stay on the OTP version matching the
majority of targets, and any branch that raises it needs its firmware
builds checked before merge, not after.
