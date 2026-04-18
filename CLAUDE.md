# CLAUDE.md

Guidance for Claude Code working in this repository.

## Orient yourself first

Before making changes, read the relevant docs rather than rediscovering the project from the code:

- [README.md](./README.md) — high-level overview and prerequisites.
- [CODE_STYLING.md](./CODE_STYLING.md) — conventions to match when editing: layout, naming, Elixir idioms, config placement, shell scripts, CAN YAML, and anti-patterns to avoid. Read this before non-trivial changes.
- [docs/README.md](./docs/README.md) — index of all guides.
- [docs/getting_started.md](./docs/getting_started.md) — toolchain setup (mise, CAN, Nerves).
- [docs/applications.md](./docs/applications.md) — what each app/library is and how the layers fit together (VMS + Infotainment: firmware / api / core / dashboard).
- [docs/hardware_architecture.md](./docs/hardware_architecture.md) — physical topology, CAN networks, controllers.
- [docs/running_hardware.md](./docs/running_hardware.md) — build/burn/upload via the top-level `ovcs` Node.js/TypeScript CLI (source in `cli/src/`, bundled to `cli/ovcs.js`), runtime env vars (`VEHICLE`, `CAN_NETWORK_MAPPINGS`).
- [docs/testing_can_messages.md](./docs/testing_can_messages.md), [docs/testing_generic_controllers.md](./docs/testing_generic_controllers.md) — CAN + controller testing.
- [vehicles/ovcs1/WIRING.md](./vehicles/ovcs1/WIRING.md) — OVCS1 wiring.

Prefer updating these docs over duplicating their content here.

## Workflow rules

- **Don't commit until the user validates.** Make the edits, run whatever sanity checks are possible locally, and stop. Wait for the user to confirm the change works on their end before running `git commit`. Small follow-up tweaks can be squashed into the eventual commit.

## Repo-specific notes for Claude

- Polyglot **monorepo** (Elixir/Nerves, Phoenix, Vue, Flutter, C++/Arduino, Ruby). Not an Elixir umbrella — each Elixir app is a standalone Mix project with `path:` deps to siblings.
- Strict layer split in `{vms,infotainment}`: `core` (platform + component drivers, no web deps) ← `api` (Phoenix) ← `firmware` (Nerves); `dashboard` talks to `api` over HTTP + Phoenix Channels. Put logic in the layer it belongs to.
- **Vehicles are their own packages under `vehicles/<name>/`** — each bundles a VMS composer, an infotainment composer (optional), and its CAN topology YAMLs. A vehicle's top-level module implements `OvcsVehicle` and exposes `vms/0` + `infotainment/0`. `vms_core` and `infotainment_core` contain zero vehicle-specific code.
- Shared per-component CAN frame/signal YAMLs live in `libraries/ovcs_can/priv/can/components/`. Vehicle topology YAMLs live in `vehicles/<name>/priv/can/{vms,infotainment}.yml` and import shared components via `import!:@ovcs_can:can/components/...` (Cantastic cross-app import syntax).
- Vehicle selection is runtime via the `VEHICLE` env var, whose value is the top-level module name of the vehicle package (e.g. `Ovcs1`, `OvcsMini`, `Obd2`). Each api's `config/runtime.exs` resolves the module and calls `.vms()` / `.infotainment()` — no hardcoded vehicle list anywhere in `vms_core`/`infotainment_core`/api/firmware. The `ovcs` CLI takes the directory name as a positional arg (e.g. `./ovcs build ovcs1 vms`) and converts it to the module name.
- Run `./ovcs can setup <vehicle>` (host dev) or `./scripts/setup_can.sh` (physical-hardware fallback) before starting any Elixir app locally.
- Toolchain is pinned in `mise.toml` — run `mise install` at the repo root.
