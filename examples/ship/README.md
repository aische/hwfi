# `ship` — universal coding agent (experimental)

> **Experimental capstone.** `ship` is a reference orchestration pattern, not a
> hardened tutorial example. CI covers `hwfi check` and static structure only —
> not a full live run. Expect non-deterministic results, API cost, and occasional
> failures.
>
> **Requires [llm-simple](../../README.md#prerequisites)** as a sibling package
> (`../llm-simple` in `cabal.project`). It is not published to Hackage; clone it
> next to `hwfi` before `cabal build`. All LLM steps go through `llm-simple` via
> the hwfi runtime.

A **prompt-only** greenfield coding agent: you supply a natural-language `spec`,
start from an **empty workspace** (there is intentionally no `sample-workspace`),
and the workflow plans, implements per task, reviews, and writes `ship-report.md`.

Compared to [`../webapp`](../webapp) (single-agent single-file HTML builder) and
[`../skills-runtime`](../skills-runtime) (skill discovery demo), `ship` is the
full orchestration capstone: structured planning, per-task builder agents with
`discover-skills` / `load-skill`, review, and audit.

## Recommended path

Work through the tutorials first — do not start here:

1. [`examples/hello`](../hello) — no LLM
2. [`examples/summarise`](../summarise) — linear LLM pipeline
3. [`examples/coding`](../coding) — agent loop + `exec` (`workflows/fix`)
4. [`examples/skills-runtime`](../skills-runtime) — discover/load skills
5. **`examples/ship`** — plan → foreach build → review

See [docs/tutorials/README.md](../../docs/tutorials/README.md),
[docs/workflow-reference.md](../../docs/workflow-reference.md) (orchestration
patterns), and [docs/skills-design.md](../../docs/skills-design.md) (skill
kinds and limits).

## What it does

Given only a `spec` input:

1. **Plans** with `llm-gen-object` (`workflows/plan`) → structured JSON (`goal`,
   `stack`, `tasks` keyed by `"0"`, `"1"`, …).
2. **Builds** each task sequentially with `workflows/build` — an `llm-agent` that
   discovers stack skills, scaffolds code, and verifies via `builtin/exec`.
3. **Reviews** the outcome via multi-turn `llm-chat` (`workflows/review`).
4. **Audits** with `builtin/introspect` + `ctx.trace` (`workflows/audit`).
5. Writes **`ship-report.md`** in the workspace.

Optional post-run: **`workflows/distill`** slices a build agent trace and writes a
draft skill (Mode A, spec §6.6).

## Before you run

| Topic | What to expect |
|-------|----------------|
| **LLM calls** | One plan step, one build agent per task, plus review — many round trips |
| **Cost & time** | DeepSeek is inexpensive but not free; multi-task runs can take many minutes |
| **Non-determinism** | The same `spec` can yield different stacks, task counts, or outcomes |
| **No success guarantee** | Validation is agent-side; there is no scripted repair loop on `exit_code` |
| **Host tools** | The planner may choose stacks that need `npm`, `cabal`, `ghc`, etc. on `PATH` |
| **Model limits** | Default catalog caps `maxTokens` at 1024/2048 — raise for large scaffolds |

## Skills library

Instruction guides under `skills/` (discovered at runtime):

| Skill | Tags | Purpose |
|-------|------|---------|
| `skills/typescript-vite-guide` | typescript, vite | Vite + TS scaffold, npm conventions |
| `skills/haskell-cabal-guide` | haskell, cabal | `cabal init`, build/test |
| `skills/react-patterns-guide` | react, typescript | Components, hooks, testing hints |
| `skills/webapp-html-guide` | html, javascript | Single-file HTML/CSS/JS demos |
| `skills/run-verify` | shell, verify | Callable: run a verify command |

## Prerequisites

### Build hwfi

Clone **`llm-simple`** as a sibling of this repo and build hwfi (see root
[README.md](../../README.md#prerequisites)).

### API key

The catalog uses **DeepSeek** (`deepseek-v4-flash`). Set `DEEPSEEK_API_KEY` via
one of:

1. `examples/ship/.env` — copy from [`.env.example`](.env.example)
2. `--env-file` on the CLI
3. `$XDG_CONFIG_HOME/hwfi/.env`
4. Export in your shell: `export DEEPSEEK_API_KEY=...`

### Host toolchain

`project.json` `exec.allow` includes `sh`, `npm`, `npx`, `node`, `cabal`, and
`ghc` so agents can scaffold real stacks. Install the tools your `spec` implies
(e.g. Node for Vite, GHC/Cabal for Haskell). Tune the allowlist to match your
machine.

## Running it

Use a **clean** scratch workspace — leftover files from a prior run can confuse
agents, and step cache keys do not include workspace file contents (spec §8).

```bash
rm -rf /tmp/ship-ws && mkdir -p /tmp/ship-ws

cabal run hwfi -- check examples/ship

cabal run hwfi -- run examples/ship \
  --workspace /tmp/ship-ws \
  --input spec="Build a single-file HTML todo app with add/toggle/delete and localStorage persistence"
```

Other examples:

```bash
# TypeScript + Vite todo app (needs npm on PATH)
cabal run hwfi -- run examples/ship \
  --workspace /tmp/ship-ws \
  --input spec="Build a TypeScript + Vite todo app with add/toggle/delete and localStorage persistence"

# Tiny Haskell program (needs cabal + ghc on PATH)
cabal run hwfi -- run examples/ship \
  --workspace /tmp/ship-ws \
  --input spec="Build a Haskell program that prints the first 20 primes"
```

On success the workspace contains working code, `ship-report.md`, `audit/`, and
`.hwfi/runs/<run-id>/`.

Inspect the trace (look for `skill-discover` / `skill-load` under build steps):

```bash
cabal run hwfi -- show /tmp/ship-ws <run-id>
```

## Resume

```bash
cabal run hwfi -- resume /tmp/ship-ws <run-id>
```

Agent steps are non-cacheable black boxes, but inner tool calls replay from cache
(§8.2.1). Audit and `builtin/log` steps re-execute on resume (§8.1). Re-running
on a workspace that already has generated files may behave unexpectedly because
cache keys ignore file contents.

## Distill a skill (optional, advanced)

After a successful run, distill a build agent step into a **draft** skill for
human review:

```bash
cabal run hwfi -- run examples/ship \
  --workspace /tmp/ship-ws \
  --entry workflows/distill \
  --input source_run=<run-id> \
  --input source_qname=workflows/build \
  --input source_step_id=build \
  --input target_path=skills/my-stack-guide.md \
  --input skill_name=skills/my-stack-guide \
  --input kind=instruction
```

Then `hwfi check examples/ship` and commit the skill. This is not part of the
default `workflows/main` entry.

## Feature coverage

| Feature | Where |
|---------|-------|
| Skill discovery + loading | `workflows/build` |
| `llm-gen-object` planning | `workflows/plan` |
| `foreach` per-task build | `workflows/main` |
| `llm-chat` review | `workflows/review` |
| `json-get`, `json-values`, `concat`, `log` | `main`, `plan`, tools |
| Full coding builtins + `exec` | `workflows/build` |
| `introspect` / `ctx.trace` | `workflows/audit` |
| Skill extraction entry | `workflows/distill` |

## Design notes

- **Task list bridge** — the planner emits `tasks` as a JSON object keyed by
  `"0"`, `"1"`, …; `tools/plan-tasks` calls `builtin/json-values` to convert
  to `List<Json>` for `foreach` (no fixed slot cap; null slots omitted).
- **Skill discovery** — use short query keywords (`vite`, `typescript`); tag
  matching is bidirectional and matches individual query words.
- **Safe verification** — the planner forbids dev-server `verify_command` values;
  builders prefer `npm run build` / `cabal build`. For HTTP smoke only,
  `tools/vite-dev-smoke` traps and kills the Vite child (never `kill %1`).

## Troubleshooting

- **Run hangs on dev server** — builders should not leave `npm run dev` running;
  use `npm run build` or `tools/vite-dev-smoke` for bounded HTTP checks.
- **Empty or skipped tasks** — null task slots are omitted by `json-values`;
  check the plan step in the trace if `foreach` runs fewer builds than expected.
- **Weak or incomplete scaffolds** — raise `maxTokens` in `model-catalog.json`
  or switch to a stronger catalog entry; the defaults favour demo cost over quality.
- **Flaky builds** — retry with a clean workspace; agent loops are non-deterministic
  and there is no scripted repair phase after build.
