# Nerves system forks

Local clones of OVCS Nerves system forks, kept here when we need to
hack on them alongside the main project (patching Buildroot configs,
testing kernel/Buildroot changes against a live firmware build).

Each subdirectory is **its own independent Git repo** — not a
submodule, not tracked by the parent OVCS repo. `.gitignore` excludes
everything under `systems/` so day-to-day OVCS commits stay clean.

## Pointing the firmware build at a local clone

By default `bridges/firmware/mix.exs` pins the systems via GitHub
refs. To build against a working copy here, swap the dep:

```elixir
# bridges/firmware/mix.exs
{:ovcs_bridges_system_rpi5,
 path: "../../systems/ovcs_bridges_system_rpi5",
 runtime: false,
 targets: :rpi5,
 nerves: [compile: true]}   # `compile: true` so Buildroot rebuilds
```

(remember to revert before merging — production builds should use the
tagged GitHub release).

## Cloning a fork into this directory

```sh
cd systems
git clone https://github.com/open-vehicle-control-system/ovcs_bridges_system_rpi5.git
```
