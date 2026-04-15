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
- [docs/vehicle_extraction_plan.md](./docs/vehicle_extraction_plan.md) — layout and contract for vehicle packages.
- [docs/testing_can_messages.md](./docs/testing_can_messages.md), [docs/testing_generic_controllers.md](./docs/testing_generic_controllers.md) — CAN + controller testing.
- [WIRING.md](./WIRING.md) — OVCS1 wiring.

Prefer updating these docs over duplicating their content here.

## Repo-specific notes for Claude

- Polyglot **monorepo** (Elixir/Nerves, Phoenix, Vue, Flutter, C++/Arduino, Ruby). Not an Elixir umbrella — each Elixir app is a standalone Mix project with `path:` deps to siblings.
- Strict layer split in `{vms,infotainment}`: `core` (platform + component drivers, no web deps) ← `api` (Phoenix) ← `firmware` (Nerves); `dashboard` talks to `api` over HTTP + Phoenix Channels. Put logic in the layer it belongs to.
- **Vehicles are their own packages under `vehicles/<name>/`** — each bundles a VMS composer, an infotainment composer (optional), and its CAN topology YAMLs. A vehicle's top-level module implements `OvcsVehicle` and exposes `vms/0` + `infotainment/0`. `vms_core` and `infotainment_core` contain zero vehicle-specific code.
- Shared per-component CAN frame/signal YAMLs live in `libraries/ovcs_can/priv/can/components/`. Vehicle topology YAMLs live in `vehicles/<name>/priv/can/{vms,infotainment}.yml` and import shared components via `import!:@ovcs_can:can/components/...` (Cantastic cross-app import syntax).
- Vehicle selection is runtime via `VEHICLE` (`OVCS1` | `OVCSMini` | `OBD2`). Each core's `config.exs` maps the env var to a composer module and Cantastic priv path.
- Run `./scripts/setup_virtual_can.sh` (host dev) or `./scripts/setup_can.sh` (hardware) before starting any Elixir app locally.
- Toolchain is pinned in `mise.toml` — run `mise install` at the repo root.
