# `ship` — universal coding agent

A **prompt-only** greenfield coding agent: you supply a natural-language `spec`,
start from an **empty workspace**, and the workflow plans, implements per task,
reviews, and writes `ship-report.md`.

Compared to [`../webapp`](../webapp) (single-file HTML builder) and
[`../skills-runtime`](../skills-runtime) (skill discovery demo), `ship` is the
full orchestration capstone: structured planning, per-task builder agents with
`discover-skills` / `load-skill`, review, and audit.

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

The catalog uses **DeepSeek** (`deepseek-v4-flash`). Set `DEEPSEEK_API_KEY` via
[`.env.example`](.env.example) → `.env`, `--env-file`, or your shell.

`project.json` `exec.allow` includes `sh`, `npm`, `npx`, `node`, `cabal`, and
`ghc` so agents can scaffold real stacks. Tune the allowlist to match your
machine.

## Running it

```bash
mkdir -p /tmp/ship-ws

cabal run hwfi -- run examples/ship \
  --workspace /tmp/ship-ws \
  --input spec="Build a single-file HTML todo app with add/toggle/delete and localStorage persistence"
```

Other examples:

```bash
# TypeScript + Vite todo app
cabal run hwfi -- run examples/ship \
  --workspace /tmp/ship-ws \
  --input spec="Build a TypeScript + Vite todo app with add/toggle/delete and localStorage persistence"

# Tiny Haskell program
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

## Distill a skill (optional)

After a successful run, distill a build agent step:

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

Then `hwfi check examples/ship` and commit the skill.

## Resume

```bash
cabal run hwfi -- resume /tmp/ship-ws <run-id>
```

Agent steps are non-cacheable black boxes, but inner tool calls replay from cache
(§8.2.1). Audit and `builtin/log` steps re-execute on resume (§8.1).

## Feature coverage

| Feature | Where |
|---------|-------|
| Skill discovery + loading | `workflows/build` |
| `llm-gen-object` planning | `workflows/plan` |
| `foreach` per-task build | `workflows/main` |
| `llm-chat` review | `workflows/review` |
| `json-get`, `concat`, `log` | `main`, `plan`, tools |
| Full coding builtins + `exec` | `workflows/build` |
| `introspect` / `ctx.trace` | `workflows/audit` |
| Skill extraction entry | `workflows/distill` |

## Notes

- **Validation is agent-side** — there is no scripted `while` loop on `exit_code`;
  builders run `verify_command` hints via `exec` inside the agent loop.
- **Safe verification** — the planner forbids dev-server `verify_command` values;
  builders prefer `npm run build` / `cabal build`. For HTTP smoke only,
  `tools/vite-dev-smoke` traps and kills the Vite child (never `kill %1`).
- **Task list bridge** — the planner emits `tasks` as a JSON object keyed by
  `"0"`, `"1"`, …; `tools/plan-tasks` converts to `List<Json>` for `foreach`.
  Empty slots are JSON `null`; `workflows/main` skips them before calling build.
- **Skill discovery** — use short query keywords (`vite`, `typescript`); tag
  matching is bidirectional and matches individual query words.
- **Step cache** does not include workspace file contents — design idempotent
  agent steps when re-running.
