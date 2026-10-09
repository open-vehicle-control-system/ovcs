# Code Styling

Conventions for contributing to this repo. These are the rules the existing
codebase follows; diverging from them is fine when it's deliberate, but please
match what you see unless you have a reason to do otherwise.

## Layout principles

- **Cores are platform libraries.** `vms/core` and `infotainment/core` hold
  generic hardware drivers, behaviours, and infrastructure. They **do not**
  contain vehicle-specific code.
- **APIs are thin.** `vms/api` and `infotainment/api` are Phoenix shells that
  call into their core. Business logic belongs in core, not in controllers.
- **Vehicles are packages.** Each vehicle is a standalone Mix app under
  `vehicles/<name>/` that bundles its VMS composer, infotainment composer
  (optional), CAN topology YAMLs, and per-vehicle firmware assets. Adding a
  new vehicle means dropping a directory under `vehicles/` — never editing
  the cores, APIs, firmware, or CLI to "register" it.
- **Firmware is shared per side.** `vms/firmware` and `infotainment/firmware`
  are the deployment shells; they pull in whatever vehicle `VEHICLE` points at
  via dynamic `path:` deps in the api's `mix.exs`.

## Naming

- **Vehicle directory name:** `snake_case` (`ovcs1`, `ovcs_mini`, `obd2`).
- **Vehicle top-level module:** `UpperCamelCase`, no separators, matches
  `Macro.camelize(dir)` (`Ovcs1`, `OvcsMini`, `Obd2`).
- **Side composers:** `<Vehicle>.Vms.Composer`, `<Vehicle>.Infotainment.Composer`.
- **`VEHICLE` env var** takes the **module** name (`Ovcs1`), not the directory
  name. The `ovcs` CLI converts the positional `ovcs1` argument to `VEHICLE=Ovcs1`.

## Elixir

- Use `@behaviour` + `@impl <Behaviour>` on every callback implementation.
  `@impl` above a `defdelegate` is allowed and encouraged.
- Prefer `defdelegate` over wrapper functions when a composer just forwards to
  a sub-module (`Composer.Dashboard`, `Composer.GenericController`).
- Group aliases at the top with braces: `alias VmsCore.{Bus, Status}`.
- Specs live on public behaviour callbacks (`@callback`), not on every
  private function.
- Avoid calling vehicle-package functions from `config/config.exs` or
  `config/target.exs` — those run before deps are compiled. Put anything that
  needs a compiled vehicle module in `config/runtime.exs`.
- CAN YAMLs reference shared component specs via
  `import!:@ovcs_can:can/components/...`; per-vehicle imports stay relative.
- New behaviour callbacks that aren't universal go under
  `@optional_callbacks [...]`.

## Names, docs and comments

- **Names say what things do.** A function's name states what it does,
  a variable's what it holds, with its unit when it has one
  (`min_speed_m_s`, `timeout_ms`). When code needs a comment to be
  understood, first rename, or extract a function whose name says it.
- **No vague names.** No single-letter variables outside a short
  anonymous function (`&(&1 * 2)`, `fn x -> x * 2 end`), and no names
  that fit anything: `data`, `value`, `result`, `res`, `tmp`, `info`,
  `item`, `obj`, `handle/1`, `process/1`, `do_stuff/1`. Say which data:
  `frame`, `speed_m_s`, `decode_frame/1`.
- **No acronyms or abbreviations.** Spell words out: `controller`, not
  `ctrl`; `message`, not `msg`; `configuration`, not `cfg`. The
  exceptions are a domain's standard names, which readers know better
  than their expansion (`can`, `ros`, `vms`, `vesc`, `imu`), and units
  (`_ms`, `_m_s`).
- **`@moduledoc`** says what a module is for and how it fits in. Every
  module has one, or `@moduledoc false` when it is internal.
- **`@doc`** documents a public function: what it does, its options, what
  it returns. Never a comment block above a `def`.
- **`#` comments** are for a non-obvious *why*, an invariant or a trap,
  at most three lines. A private function gets at most one line above
  it; if it needs more, rename or split it.
- **Configuration** (composer options, YAML, shell): one line on why a
  value is what it is. Longer explanations go in the module's docs or a
  guide.
- Python uses docstrings where Elixir uses `@moduledoc` and `@doc`.
- Credo enforces the Elixir part: `ModuleDoc` and the custom checks in
  `.credo/checks/` (comment blocks, and comment lines at most a quarter
  of code lines). Files not cleaned up yet are listed in each check's
  `excluded` in `.credo.exs`; a cleaned file leaves the list.

## Configuration

- Runtime config that depends on the vehicle goes in `runtime.exs` of the
  runnable app (the api or firmware), not in the core's `config.exs`.
- Dispatch on `VEHICLE` convention, never a hardcoded `case` of vehicle
  names. The only exceptions are the vehicle package's own `mix.exs` and
  top-level module.
- Cantastic's `otp_app` and `priv_can_config_path` come from the composer
  (`can_config_otp_app/0`, `can_config_path/0`) — don't set them to hardcoded
  strings in shared code.

## Shell scripts (firmware build/burn/upload/clean)

- `#!/usr/bin/env bash` shebang.
- `set -euo pipefail` at the top.
- `cd "$(dirname "$0")"` so the script works regardless of invoker cwd.
- Required env vars declared with `: "${VAR:?msg}"`.
- Optional env vars default with `: "${VAR:=default}"`, then `export VAR`.
- Announce phases with a `step()` helper and cyan `==>` banners.
- Keep the output friendly — print the resulting artifact path at the end.

## CAN YAML

- Shared per-component specs live in `libraries/ovcs_can/priv/can/components/`.
- Vehicle topology files are `vehicles/<name>/priv/can/{vms,infotainment}.yml`.
- Per-vehicle controller frames sit next to the topology in
  `vehicles/<name>/priv/can/generic_controller/`.
- Import shared components with `import!:@ovcs_can:can/components/...`.
- Import sibling files with plain relative paths
  (`import!:generic_controller/0x701_...yml`).

## Commits

- One focused change per commit. Use the title line to say what, the body
  (when needed) to say why and note non-obvious trade-offs.
- Don't commit build artifacts (`_build/`, `deps/`, `.elixir_ls/`, `*.ez`,
  `cli/ovcs` — all gitignored).
- Use `git mv` when moving files so rename detection works.

## Things not to introduce

- Vehicle-name lists in `vms_core`, `vms_api`, `infotainment_core`,
  `infotainment_api`, `vms/firmware`, `infotainment/firmware`, or the
  `ovcs` CLI. The discovery is always directory-driven.
- Hardcoded paths to another app's `priv/`. Use `:code.priv_dir/1` or the
  `@<otp_app>:...` Cantastic import syntax.
- Tests that mock Cantastic. Exercise the real configuration store with
  virtual CAN (`./ovcs can setup <vehicle>`).
- Docs that restate `CODE_STYLING.md`.
  Link to them instead.
