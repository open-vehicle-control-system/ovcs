# CLAUDE.md

Guidance for Claude Code working in this repository.

## Orient yourself first

Before making changes, read the relevant docs rather than rediscovering the project from the code:

- [README.md](./README.md) — high-level overview and prerequisites.
- [docs/README.md](./docs/README.md) — index of all guides.
- [docs/getting_started.md](./docs/getting_started.md) — toolchain setup (mise, CAN, Nerves).
- [docs/applications.md](./docs/applications.md) — what each app/library is and how the layers fit together (VMS + Infotainment: firmware / api / core / dashboard).
- [docs/hardware_architecture.md](./docs/hardware_architecture.md) — physical topology, CAN networks, controllers.
- [docs/running_hardware.md](./docs/running_hardware.md) — build/burn/upload via the top-level `ovcs` Ruby CLI, runtime env vars (`VEHICLE`, `CAN_NETWORK_MAPPINGS`).
- [docs/testing_can_messages.md](./docs/testing_can_messages.md), [docs/testing_generic_controllers.md](./docs/testing_generic_controllers.md) — CAN + controller testing.
- [WIRING.md](./WIRING.md) — OVCS1 wiring.

Prefer updating these docs over duplicating their content here.

## Repo-specific notes for Claude

- Polyglot **monorepo** (Elixir/Nerves, Phoenix, Vue, Flutter, C++/Arduino, Ruby). Not an Elixir umbrella — each Elixir app is a standalone Mix project with `path:` deps to siblings.
- Strict layer split in `{vms,infotainment}`: `core` (business logic + CAN, no web deps) ← `api` (Phoenix) ← `firmware` (Nerves); `dashboard` talks to `api` over HTTP + Phoenix Channels. Put logic in the layer it belongs to.
- Shared per-component CAN frame/signal YAMLs live in `libraries/ovcs_can/priv/can/components/`. Per-app vehicle topology YAMLs (and per-vehicle controller wirings) live in each core's `priv/` and import shared components via `import!:@ovcs_can:can/components/...` (a Cantastic cross-app import extension). Add/modify signals in YAML, not in hand-rolled encode/decode.
- Vehicle selection is runtime via `VEHICLE` (`OVCS1` | `OVCSMini` | `OBD2`); each vehicle has a `Composer` module that picks components + CAN configs.
- Run `./scripts/setup_virtual_can.sh` (host dev) or `./scripts/setup_can.sh` (hardware) before starting any Elixir app locally.
- Toolchain is pinned in `mise.toml` — run `mise install` at the repo root.
