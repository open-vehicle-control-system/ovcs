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
- [docs/running_hardware.md](./docs/running_hardware.md) — build/burn/upload via the top-level `ovcs` Rust CLI (source in `cli/src/`, built to `cli/ovcs` via `mise run cli`; the binary is gitignored), runtime env vars (`VEHICLE`, `CAN_NETWORK_MAPPINGS`).
- [docs/vehicle_parameterisation.md](./docs/vehicle_parameterisation.md) — end-to-end: how `VEHICLE` selects a composer, what each firmware boots, the behaviours in play, and the bus helpers.
- [docs/testing_can_messages.md](./docs/testing_can_messages.md), [docs/testing_generic_controllers.md](./docs/testing_generic_controllers.md) — CAN + controller testing.
- [vehicles/ovcs1/WIRING.md](./vehicles/ovcs1/WIRING.md) — OVCS1 wiring.

Prefer updating these docs over duplicating their content here.

## Workflow rules

- **Don't commit until the user validates.** Make the edits, run whatever sanity checks are possible locally, and stop. Wait for the user to confirm the change works on their end before running `git commit`. Small follow-up tweaks can be squashed into the eventual commit.

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

### Code comments state present facts

A comment describes the code as it is at the moment the comment is written — not the story of how it got there.

- No history: no "previously this did X", "changed from Y", "was a workaround for Z", "per feedback". Git holds the story.
- No process narration, session references, or dated diary entries.
- Explain non-obvious *why* and invariants; skip what the code already states plainly.
- A stale comment is deleted, not amended.

### If a violation has already been pushed

Rewrite the offending commits locally and push with `--force-with-lease` — on your own branch, without asking. On `main`, or on any branch someone else may have based work on, propose the rewrite and wait for the user's explicit go: a force-push of shared history is theirs to authorise (see "Don't commit until the user validates"). Remember that PR descriptions are a second copy of the message and need editing separately.

## Repo-specific notes for Claude

- Polyglot **monorepo** (Elixir/Nerves, Phoenix, Vue, Flutter, C++/Arduino, Ruby). Not an Elixir umbrella — each Elixir app is a standalone Mix project with `path:` deps to siblings.
- Strict layer split in `{vms,infotainment}`: `core` (platform + component drivers, no web deps) ← `api` (Phoenix) ← `firmware` (Nerves); `dashboard` talks to `api` over HTTP + Phoenix Channels. Put logic in the layer it belongs to.
- **Vehicles are their own packages under `vehicles/<name>/`** — each bundles a VMS composer, an infotainment composer (optional), and its CAN topology YAMLs. A vehicle's top-level module implements `OvcsVehicle` and exposes `vms/0` + `infotainment/0`. `vms_core` and `infotainment_core` contain zero vehicle-specific code.
- Shared per-component CAN frame/signal YAMLs live in `libraries/ovcs_can/priv/can/components/`. Vehicle topology YAMLs live in `vehicles/<name>/priv/can/{vms,infotainment}.yml` and import shared components via `import!:@ovcs_can:can/components/...` (Cantastic cross-app import syntax).
- Vehicle selection is runtime via the `VEHICLE` env var, whose value is the top-level module name of the vehicle package (e.g. `Ovcs1`, `OvcsMini`, `Obd2`). Each **firmware**'s `config/runtime.exs` calls `OvcsVehicle.Firmware.resolve_vehicle/3`, which prepends the vehicle's ebin to the code path, then writes the matching composer to `:vms_core, :vehicle` / `:infotainment_core, :vehicle` — no hardcoded vehicle list anywhere in `vms_core`/`infotainment_core`/api/firmware. The `ovcs` CLI takes the directory name as a positional arg (e.g. `./ovcs build ovcs1 vms`) and converts it to the module name.
- Run `./ovcs can setup <vehicle>` (host dev) or `./scripts/setup_can.sh` (physical-hardware fallback) before starting any Elixir app locally.
- Toolchain is pinned in `mise.toml` — run `mise install` at the repo root.
