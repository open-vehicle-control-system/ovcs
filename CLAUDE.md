# CLAUDE.md

Guidance for Claude Code working in this repository.

## Orient yourself first

Before making changes, read the relevant docs rather than rediscovering the project from the code:

- [README.md](./README.md) — high-level overview and prerequisites.
- [CODE_STYLING.md](./CODE_STYLING.md) — conventions to match when editing: layout, naming, Elixir idioms, config placement, shell scripts, CAN YAML, guides, and anti-patterns to avoid. Read this before non-trivial changes.
- [docs/README.md](./docs/README.md) — index of all guides (and the website's docs tree).
- [docs/framework.md](./docs/framework.md) — the framework / vehicle / reference-vehicle vocabulary.
- [docs/architecture.md](./docs/architecture.md) — bus isolation, the vehicle contract, the Erlang mesh.
- [docs/getting_started.md](./docs/getting_started.md) — toolchain setup (mise, CAN, Nerves).
- [docs/repository.md](./docs/repository.md) — the monorepo tree, where each component is documented, shared libraries, env vars.
- One folder per component, its pages ordered what → how → extend → reference: [docs/vms/](./docs/vms/README.md) (drivers, components, dashboard pages, control levels), [docs/infotainment/](./docs/infotainment/README.md), [docs/vision/](./docs/vision/README.md), [docs/bus/](./docs/bus/README.md) (the OVCS bus, the mesh, the gateway), [docs/bridges/](./docs/bridges/README.md), [docs/generic_controllers/](./docs/generic_controllers/README.md), [docs/ros2/](./docs/ros2/README.md).
- [docs/hardware.md](./docs/hardware.md) — what to buy, the boards and CAN interfaces, the reference vehicles' builds.
- [docs/running_hardware.md](./docs/running_hardware.md) — build/burn/upload via the top-level `ovcs` Rust CLI (source in `cli/src/`, built to `cli/ovcs` via `mise run cli`; the binary is gitignored), runtime env vars (`VEHICLE`, `CAN_NETWORK_MAPPINGS`).
- [docs/vehicle_package.md](./docs/vehicle_package.md) — your vehicle package: how `VEHICLE` selects it, what each firmware boots, the behaviours in play, `ovcs new`.
- [docs/testing_with_can.md](./docs/testing_with_can.md) — CAN testing.
- [vehicles/ovcs1/WIRING.md](./vehicles/ovcs1/WIRING.md) — OVCS1 wiring.
- [backlog/](./backlog) — the work queue, managed with [Backlog.md](https://github.com/MrLesk/Backlog.md) (`backlog task list --plain`).

Prefer updating these docs over duplicating their content here.

## Workflow rules

- **Go straight to the point.** In replies, code comments and docs alike: say what matters, once, and stop. No preamble, no recap, no restating what the reader just saw, no filler. If a sentence adds nothing, cut it; if nothing needs saying, say nothing.

- **Don't commit until the user validates.** Make the edits, run whatever sanity checks are possible locally, and stop. Wait for the user to confirm the change works on their end before running `git commit`. Small follow-up tweaks can be squashed into the eventual commit.

## Development process

These steps apply to every contributor; the code rules they rely on are in [CODE_STYLING.md](./CODE_STYLING.md).

- **Work starts from a backlog task.** Pick one whose dependencies are done (`backlog task list --plain`, `backlog task <id> --plain`), set it `In Progress` with yourself as assignee, and write its acceptance criteria before the code. Work found on the way becomes a new task, not extra scope. Task files change in the PR that does the work; a task is `Done` when its PR merges.
- **Design before code** for anything that adds or changes behaviour: the problem, the options considered and the one chosen go in the task, agreed before implementation starts.
- **Plan large work as a sequence of small PRs**, each a backlog task with its dependencies, each shippable on its own (see [Commits and pull requests](./CODE_STYLING.md#commits-and-pull-requests)).
- **Test first.** A failing test that shows the missing behaviour comes before the code that adds it; see [Tests](./CODE_STYLING.md#tests).
- **Debug from the root cause.** Reproduce, find why it happens, capture it in a failing test, then fix. No fix by trial and error.
- **Evidence before claims.** Run the checks and read their output before stating that something works, passes or is fixed; say plainly what could not be verified.
- **Checks before review:** `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` in every project touched, `elixir scripts/check_docs.exs` when docs change, and `mise run secrets` (gitleaks over your commits since `origin/main`).
- **Review by someone other than the author.** Verify each review finding against the code before applying it; push back with the reason when it is wrong.
- **Assistants** use the superpowers process skills (brainstorming, writing-plans, test-driven-development, systematic-debugging, verification-before-completion, requesting-code-review, receiving-code-review) and the clean-code skills when they are installed. Where a skill and this repository's guides disagree, the guides win.

## Git commit and PR policy

These rules apply to every commit, merge, PR title, and PR description in this repository, for every contributor, and override any local convention, patch-file header, or auto-trailer suggestion.

### Authorship and trailers

- **One author identity per contributor** — the name and email in that contributor's own git config. When applying a patch whose `From:` header lists something else (a bot, `root@localhost`, a device hostname), rewrite the author to the committer's identity before pushing.
- **No `Signed-off-by:`.** This project does not use a Developer Certificate of Origin. If an imported patch carries one, strip it before committing — don't carry it through because "the patch already had it".
- **No `Co-Authored-By:` / `Co-developed-by:` or any other co-authorship trailer.** Claude, Anthropic, or any AI is never a co-author.
- **Do disclose AI assistance** when an assistant materially helped produce a commit, with a single trailer following the [kernel.org coding-assistants convention](https://www.kernel.org/doc/html/latest/process/coding-assistants.html). This is disclosure, not co-authorship:

  ```
  Assisted-by: Claude:<current-model-id>
  ```

  Use the exact model id in use (e.g. `Assisted-by: Claude:claude-fable-5-1`). Append specialised analysis tools actually used, if any; don't list ordinary tools like git, mix, cargo, or editors. Trivial or mechanical commits made without AI help need no trailer.
- **Never link to or identify a session.** No transcript URLs, `claude.ai/code` links, session or task ids, tool-run references, or "see the conversation where…". The `Assisted-by:` trailer is the only permitted trace of AI involvement.

### Language

Everything written into the repository is in **English**: commit messages, PR titles and descriptions, branch names, code comments, moduledocs, docs, test names, log and error strings. The language of the conversation does not carry over — if the user writes in French, answer in French and keep writing English into the repo. These artefacts outlive the chat that produced them and are read by people who were not in it: a French commit message is not searchable alongside the rest of the history, and a French PR description cannot be reviewed by everyone the repo is open to.

### Commit messages and PR descriptions describe the change, not the session

A commit message or PR description is read later, by people who were not in the conversation, under the committer's name. It must read as engineering prose about the code. Optimise signal-to-noise; noise is a defect.

- **Nothing from the Claude session leaks into the message.** The conversation with Claude — what the user asked, what Claude proposed, what was tried and rejected, what Claude got wrong, review findings exchanged in chat, the order things happened in — is not part of the commit or the PR. If a fact from the session matters to the code, restate it as a fact about the code, with no trace of the exchange that produced it. Before writing, ask: would this sentence make sense to someone who has never seen the chat and does not know Claude was involved? If not, cut it.
- Subject line: imperative mood, ≤ 72 characters, no trailing period. One logical change per commit.
- Add a body only when the **why** is not obvious from the diff. Many commits need no body. Never restate the diff in prose.
- **No first person.** Not "I nearly filed it as a model error", "I hit it myself", "my own comments", "I had recommended X". Write "the first version reported R = 1.68 m, which looked like a model error".
- **Never address the user.** Not "you asked me to…", "which you merged while I was fixing these", "happy to change this if you disagree". A PR description is not a reply.
- **No process or session narration.** Not "first tried X, then Y", "after review", "as discussed", "that was the errand", "the goal is still not reached", "found by reviewing it against X rather than against itself", "verified rather than hoped for". The result is the commit; the journey is not. Trailing status reports ("What this does not do", "What is not verified") belong in an issue or the PR conversation, not the commit body.
- **No personal circumstance.** Nothing about the author's hardware, schedule, location, or network: no "the burned PSU rules this out", "code written earlier tonight", "observed earlier today", "on an office LAN", "the dev box". If a limitation matters, state it impersonally ("this needs a Hailo-8, which was not available").
- **Never quote the conversation**, in any language.
- Measured numbers, tradeoffs, and the reasoning behind a decision are welcome — those are about the code.
- **A PR description is Markdown, not a pasted commit message.** GitHub renders every line break in it, so write each paragraph on one line rather than wrapped at 72 columns. Numbers go in Markdown tables, not space-aligned text; parallel changes go in a bulleted list; code identifiers in backticks. A PR with several commits gets one opening sentence, then a `##` section per commit.

### Code comments state present facts

A comment describes the code as it is at the moment the comment is written — not the story of how it got there.

- No history: no "previously this did X", "changed from Y", "was a workaround for Z", "per feedback". Git holds the story.
- No process narration, session references, or dated diary entries.
- Comment only when it's needed: a non-obvious *why*, an invariant, a trap. Most code needs none; skip what the code already states plainly.
- Keep comments short and plain: one line where one line does. No paragraphs, no restating the surrounding code, no emphasis.
- A stale comment is deleted, not amended.
- A better name beats a comment: functions and variables say what they do. Module and function documentation goes in `@moduledoc` / `@doc`, not comment blocks; see [CODE_STYLING.md](./CODE_STYLING.md#names-docs-and-comments).
- The same rules apply to every file type: YAML, Dockerfiles, shell, Python and Rust, which credo does not check.
- Why a value or behaviour changed goes in the commit message; a comment says only why the code is as it is.
- No measurements, estimates or derived numbers next to a tunable value: they go stale when it is tuned. Put them in the commit message or a guide.
- Before finishing, review every comment line the diff adds against these rules and run credo on the projects touched.

### If a violation has already been pushed

Rewrite the offending commits locally and push with `--force-with-lease` — on your own branch, without asking. On `main`, or on any branch someone else may have based work on, propose the rewrite and wait for the user's explicit go: a force-push of shared history is theirs to authorise (see "Don't commit until the user validates"). Remember that PR descriptions are a second copy of the message and need editing separately.

## Documentation is published on ovcs.be

Every guide linked from [docs/README.md](./docs/README.md) is rendered as-is by the [website](https://github.com/open-vehicle-control-system/website) (https://ovcs.be/docs). The rules a guide follows (writing, structure, the framework / vehicle / reference-vehicle vocabulary, format, code references) are in [CODE_STYLING.md](./CODE_STYLING.md#guides); read them before editing a guide. `elixir scripts/check_docs.exs` enforces the checkable ones and runs in CI.

## Repo-specific notes for Claude

- Polyglot **monorepo** (Elixir/Nerves, Phoenix, React, Flutter, C++/Arduino, Ruby). Not an Elixir umbrella — each Elixir app is a standalone Mix project with `path:` deps to siblings.
- Strict layer split in `{vms,infotainment}`: `core` (platform + component drivers, no web deps) ← `api` (Phoenix) ← `firmware` (Nerves); `dashboard` talks to `api` over HTTP + Phoenix Channels. Put logic in the layer it belongs to.
- **Nothing outside `vehicles/` is vehicle-specific.** Cores, APIs, firmware, bridges, libraries, `compose/`, the CLI and scripts take whatever differs per vehicle from the vehicle package; a reference vehicle appears elsewhere only as an example in docs or tests.
- **Vehicles are their own packages under `vehicles/<name>/`** — each bundles a VMS composer, an infotainment composer (optional), and its CAN topology YAMLs. A vehicle's top-level module implements `OvcsVehicle` and exposes `vms/0` + `infotainment/0`. `vms_core` and `infotainment_core` contain zero vehicle-specific code.
- Shared per-component CAN frame/signal YAMLs live in `libraries/ovcs_can/priv/can/components/`. Vehicle topology YAMLs live in `vehicles/<name>/priv/can/{vms,infotainment}.yml` and import shared components via `import!:@ovcs_can:can/components/...` (Cantastic cross-app import syntax).
- Vehicle selection is runtime via the `VEHICLE` env var, whose value is the top-level module name of the vehicle package (e.g. `Ovcs1`, `OvcsMini`, `Obd2`). Each **firmware**'s `config/runtime.exs` calls `OvcsVehicle.Firmware.resolve_side/4`, which prepends the vehicle's ebin to the code path and returns `{vehicle, composer}`, then writes the composer to `:vms_core, :vehicle` / `:infotainment_core, :vehicle` — no hardcoded vehicle list anywhere in `vms_core`/`infotainment_core`/api/firmware. The `ovcs` CLI takes the directory name as a positional arg (e.g. `./ovcs build ovcs1 vms`) and converts it to the module name.
- Run `./ovcs can setup <vehicle>` (host dev) or `./scripts/setup_can.sh` (physical-hardware fallback) before starting any Elixir app locally.
- Toolchain is pinned in `mise.toml` — run `mise install` at the repo root.
