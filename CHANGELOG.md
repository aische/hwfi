# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- v2 resume cleanup: removed stale step-cache docs/comments; runtime emits
  static `cacheable` flags from checker classification; dropped unused
  `aeStepKey` / `atFingerprint` agent fields.

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
