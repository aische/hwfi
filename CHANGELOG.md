# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Planned as **0.2.0.0** — breaking runtime and CLI changes. Upgrading from
0.1.0.0: see **Removed** and **Changed** below; v1 run workspaces (`steps/`
cache) cannot be resumed on v2.

### Added

- v2 machine runtime (`Machine`, `MachineRun`, `StepDriver`, `MachineAgent`,
  `MachineSnapshot`) with cursor + frames execution model — see
  [execution-model.md](docs/execution-model.md).
- `machine.json` snapshot persisted after each transition (and on pause/crash).
- `hwfi step <workspace> <run-id>` — advance one transition then halt (workflow
  statement, agent model call, or agent tool call).
- `hwfi run --step` — create a run and halt after the first transition.
- `--approve` on `hwfi resume` / `hwfi step` for exec confirm gates inside `par`.
- Tagged `RValue` encoding in `machine.json` (fixes typed binding restore on
  resume).
- Checkpoint before agent LLM/tool I/O; snapshot flush on crash/interrupt.

### Changed

- Resume is **machine-snapshot based** (`machine.json` + `trace.jsonl`), not
  content-addressed `steps/<step-key>.json` lookup.
- Agent resume carries `CurAgent` state in the snapshot (no per-round sub-key
  replay under `steps/`).
- `while` predicate `continue` decisions replay from `trace.jsonl` (`while-pred`
  events).
- CLI primary resume command is `hwfi resume` (replaces v1 `hwfi continue`).
- Bare `hwfi` invocation prints help; `hwfi run` prints `run-id` on stderr.
- Runtime emits static `cacheable` flags from checker classification in trace
  events; dropped unused `aeStepKey` / `atFingerprint` agent fields.

### Removed

- `Executor` runtime and `steps/` per-step result cache.
- `hwfi cache clear` and `hwfi cache invalidate` subcommands.
- Intra-step agent sub-key caching under `steps/` (legacy v1 resume path).

### Fixed

- Resume snapshot bindings preserve `VRecord`/`VString` types (not coerced to
  `VJson`).
- Collapsed `CurReady` → step dispatch into one transition (no `CurDispatch`
  gap before agent entry).
- `par` exec confirm: `ConfirmHold` for stepping, `ConfirmAuto` for run-to-end.

## [0.1.0.0] - 2026-07-10

First release of **hwfi**: a markdown-defined, type-checked workflow engine with
durable traces, content-addressed step caching, and resumable LLM agent loops.

### Added

#### Core engine and CLI

- Project loader for markdown workflows, tools, type aliases, and optional
  `skills/` declarations plus `project.json` manifest.
- Static type checker (`hwfi check`) with Merkle callee fingerprints for cache
  invalidation when called declarations change.
- Execution CLI: `hwfi run`, `hwfi resume`, `hwfi show`, `hwfi cache clear`.
- Sandboxed workspace with lexical path resolution and symlink containment.
- Append-only `trace.jsonl`, per-step result cache, and workspace lock.
- Typed `Context` (`ctx.workspace`, `ctx.run`, `ctx.self`, `ctx.inputs`,
  `ctx.trace`, `ctx.env`) available in every step.
- `Secret<T>` type with redaction in traces; API keys via layered key store
  (`--env-file`, project `.env`, process env, `$XDG_CONFIG_HOME/hwfi/.env`).

#### Control flow

- `if` / `else`, `foreach`, bounded `par`, and `while` with resume-safe
  scoped step keys and branch/iteration trace events.

#### LLM and agents

- One-shot builtins: `llm-generate`, `llm-chat`, `llm-gen-object`.
- Agent loops: `llm-agent` (free-text termination) and `llm-agent-object`
  (typed `submit`).
- Tool-use loop with recoverable vs fatal error classes, intra-step model/tool
  sub-caches, and checkpoint resume across agent rounds.
- Usage and cost accounting (`cost_usd` on LLM calls, optional
  `budget.max_cost_usd`).

#### Builtins — files, exec, data

- File I/O: `read-file`, `write-file`, `list-dir`, `read-file-slice`,
  `find-files`, `grep`.
- Mutation: `edit-file` (with `expect` occurrence guard), `move-file`,
  `copy-file`, `remove-file`, `make-dir`, `remove-dir`.
- `exec` with argv-only invocation, program allowlist, timeout, and output caps.
- Data plumbing: `json-get`, `concat`, `json-values`, `log` (`workflow-log`
  trace events).
- Introspection: `introspect`, `eval-workflow`, `list-runs`, `read-run-trace`,
  `trace-slice`.

#### Skills

- Skill extraction from run traces (Mode A) and `skills/` declarations with
  optional provenance frontmatter.
- Runtime skill catalog: `discover-skills`, `load-skill`; callable and
  instruction skill kinds; mid-loop tool expansion in agent steps.

#### Examples and documentation

- Examples: `summarise`, `coding`, `control-flow`, `research`, `ship`,
  `skills`, `skills-runtime`.
- Author docs: [workflow-reference.md](docs/workflow-reference.md),
  [caching-and-resume.md](docs/caching-and-resume.md), normative
  [spec.md](docs/spec.md).

### Fixed

- Agent tool-result cache now stores actual JSON for resume correctness; the
  model sees a redacted view via `toolModelJson` (D3).
- Crash handling emits `run-end` with `crashed` status and persists run state.
- Sub-workflow calls thread caller control-flow scope for correct per-iteration
  cache keys on resume.
- One-shot LLM step keys include model-catalog fingerprint.

### Security

- Workspace path guard rejects traversal and symlink escape outside the root.
- `exec` is fail-closed without an allowlist; no shell, empty child env except
  configured `exec.env` entries.
- Whitelisted `ctx.env` vars only; secrets forbidden from plain-string
  interpolation.

### Known limitations (v1.1 backlog)

- No workflow-level `try`/recover (agent tool errors are recoverable).
- No `Optional<T>` — whitelisted env vars must be present at startup.
- Limited dynamic invocation of `ToolRef` / `WorkflowRef` values.
- Step cache keys do not include live workspace file contents.

See [spec §13](docs/spec.md) and [README](README.md) for the full deferred list.

[Unreleased]: https://github.com/aische/hwfi/compare/v0.1.0.0...HEAD
[0.1.0.0]: https://github.com/aische/hwfi/releases/tag/v0.1.0.0
