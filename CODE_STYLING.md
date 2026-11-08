# Code Styling

Conventions for contributing to this repo. Match them unless you have a
stated reason not to; a reviewer asks for that reason. Where a rule here and
a language's own idiom disagree, the idiom wins and the rule gets fixed.

The process that produces a change (a task in the backlog, a failing test
first, evidence before a claim, small reviewed PRs) is in
[CLAUDE.md](./CLAUDE.md#development-process).

## Layout principles

- **Only `vehicles/` is vehicle-specific.** Everything else (cores, APIs,
  firmware, bridges, libraries, `compose/`, the CLI, scripts) works for
  any vehicle and takes what differs from the vehicle package:
  dimensions, tuning, calibration, network names. A reference vehicle
  may appear outside `vehicles/` only as an example in docs or tests.
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
- **Predicates and fetchers follow Elixir.** `ready?/1`, not `is_ready/1`
  (`is_` is for guards); `fetch_*` returns `{:ok, value}` or `:error`,
  `get_*` returns the value or `nil`; a trailing `!` raises.
- **Constants are named.** A literal whose meaning is not obvious becomes a
  module attribute with its unit: `@precharge_timeout_ms 3_000`.

## Design

- **A process is runtime state, concurrency or fault isolation.** Logic
  that only transforms data is a plain module the process calls, so it is
  tested without starting anything.
- **One module owns a process's interface.** Other modules call its
  public functions, never `GenServer.call/cast` on it directly.
- **Dependencies come in explicitly**, as arguments or options, from the
  composition root: the vehicle's composer and the supervision tree.
  Libraries (`libraries/`, Cantastic) take options and never read their own
  application env.
- **A behaviour is a contract its caller owns.** Add one when there is a
  second implementation or a real test boundary (hardware, CAN, network);
  not for a single implementation "just in case". Hardware sits behind one
  so the logic runs on the host.
- **No speculative generality.** No option, hook or callback without a
  current user. Delete dead code and unused parameters.
- **A `case` on a closed set in one place is fine.** The same switch in
  several places becomes a behaviour or protocol.
- **Assertive code.** Match what must be there (`state.speed`, pattern
  matches) instead of `map[:key]` and truthiness; let malformed data crash.
  Never create atoms from external input (`String.to_atom/1`).

## Functions

- **One thing, at one level of abstraction**, that its name states without
  "and". An orchestrating function reads as a list of steps; detail lives
  in named helpers below it.
- **The subject comes first**, so the function pipes; options come last as
  a keyword list checked with `Keyword.validate!/2`.
- **No boolean flags that fork the body.** Two functions, or clauses on a
  meaningful atom (`:drive` / `:reverse`).
- **Flatten with clauses, guards and `with`**, not nested `if`/`case`.
- **Side effects show in the name.** A query does not also write; a
  function that broadcasts or sends a frame says so.
- **Lengths and argument counts are signals, not limits.** Split along
  meaning, not line count.

## Errors

- **Expected failures are values**, `{:ok, value}` / `{:error, reason}`,
  with enough context to diagnose them (`{:frame_unknown, network, name}`,
  not `:error`). Bugs and broken invariants crash and the supervisor
  restarts the process.
- **No `try`/`rescue` for control flow**, only at a boundary with code that
  raises. Never swallow an error: no empty `rescue`, no ignored
  `{:error, _}`.
- **Translate at the boundary.** The module that wraps a library or device
  returns its own reasons; callers never match on the library's.
- **Handle and log an error once**, where something is done about it.

## Safety-relevant code

Code is safety-relevant when its failure can move, stop, steer or
energise the vehicle against what its operator commanded. It is kept
apart from the rest (dashboards, metrics, infotainment, bridges'
non-actuating paths). These rules are firm, not preferences.

- **Each module says whether it is safety-relevant.** Every module in
  `vms/core/lib/vms_core/` (its managers, components and top-level
  modules), in a vehicle's `lib/<vehicle>/vms.ex` and
  `lib/<vehicle>/vms/`, and in `bridges/radio_control_bridge/` declares
  it in its module documentation, next to `@moduledoc`:
  `@moduledoc safety: :relevant` or `@moduledoc safety: :none`. A module
  without the declaration is treated as safety-relevant, never as "not
  safety", and the declaration moves with the file. A module that reads an input a safety
  decision uses (speed, standstill, battery state) is safety-relevant.
  The generic controller firmware (`controllers/generic_controller/`) is
  safety-relevant as a whole, and so are the CAN frames a
  safety-relevant module sends or receives.
- **Decisions live in pure modules.** A safety decision (a torque
  limit, an override, a freshness check, an interlock, ready-to-drive)
  is a plain module that takes inputs and returns a decision: no
  process, IO, Repo, Bus or Logger. The driver around it does the CAN
  and process work and calls it. The pure module is what gets
  table-driven tests and measured branch coverage.
- **Dependencies point one way.** Safety-relevant modules never depend
  on non-safety ones: `vms/api`, dashboards, `VmsCore.Metrics`,
  `VmsCore.Repo`, the bus gateway, infotainment. Non-safety code reaches
  safety code only through a narrow, allowlisted API, never by calling
  its internals or its process directly.
- **Safety processes run in their own supervision subtree**, with a
  restart strategy chosen on purpose, and a restarted process starts in
  its safe state whatever it last commanded.
- **Unknown is never healthy.** A missing, stale or `nil` input reads as
  unknown and leads to the safe reaction: zero torque, brake held, relay
  open, fault latched. Never default it to `0`, `false` or the last value.
- **Fail-safe defaults.** A safety mechanism is on unless the vehicle
  turns it off, and a timeout or threshold that depends on the vehicle's
  hardware is set by the vehicle's composer, not hidden in a framework
  default.
- **Every safety mechanism has a test that injects its fault** (a frame
  that stops, a process that stalls, a value out of range) at the
  component's boundary and asserts the safe reaction.
- **Existing code moves under these rules as it is touched.** A change
  to a safety-relevant module brings the decision it touches into a pure
  module; there is no separate "rewrite every driver" change.

## Tests

- **Test first.** Write the test, watch it fail for the expected reason,
  then write the minimal code that passes. A test that never failed proves
  nothing; for a characterization test, break the code once to see it fail.
- **Test behaviour through the public boundary**: messages and frames in,
  messages and frames out. Not private functions, not internal state.
- **One behaviour per test, named after it**: `test "zeroes torque when the
  brake is pressed"`. Group with `describe "function/arity"` or by
  situation. Arrange, act, assert, visibly separated.
- **Keep the values a test depends on in the test.** Pass tuning values
  explicitly instead of relying on a component's defaults.
- **No sleeping.** Wait with `assert_receive` or a polling helper, never
  `Process.sleep`. Inject time where a deadline is tested.
- **`async: true` unless the test touches global state** (named processes,
  application env). Fix shared state rather than turning async off.
- **Start processes with `start_supervised!/1`**; capture logs with
  `capture_log/1`.
- **A known, unmet requirement is a skipped test**:
  `@tag skip: "not met: <the missing behaviour>"`, asserting the correct
  outcome. The PR that meets it removes the tag. Cite the behaviour, not a
  file line.
- **Table-driven tests for many input/output cases**, properties for
  invariants (round-trips, monotonicity). Coverage finds untested paths; it
  is not a target.

## Refactoring

- **Only on green, and never mixed with a behaviour change.** If a change
  needs a new structure, refactor in its own commit or PR first.
- **Clean what you touch.** Fix smells in code the change edits; leave
  stable code alone.
- **Small steps**, the full suite green after each. Renames go everywhere,
  including `apply/3`, config files and YAML that name the module.

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

## Commits and pull requests

- One focused change per commit. Use the title line to say what, the body
  (when needed) to say why and note non-obvious trade-offs.
- **A PR is one logical change a reviewer reads in one sitting**: aim for
  under 400 changed lines. Split larger work into a sequence of PRs that
  each build, pass and ship on their own, even if a later PR replaces an
  intermediate step.
- A PR names the backlog task it closes, and its docs change describes
  the behaviour it ships.
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
