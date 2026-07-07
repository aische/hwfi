# Status

Last updated: 2026-07-07

## Current focus

Spec written from `idea.md`; tasks broken into milestones M1–M5 (v1) + M6
backlog. Next actionable work is **M1: project skeleton** — cabal init,
`llm-simple` path dependency, test framework, CLI stub.

## Done recently

- Concretised `docs/spec.md`: project layout, markdown workflow syntax,
  v1 type system, built-in tools, workspace sandboxing, content-addressed
  step-key persistence and resume semantics, CLI surface, acceptance
  criteria
- Second pass on spec: replaced JSON step blocks with a small DSL
  (`bind <- qname(args)`); added `@self#heading` markdown-section refs;
  added ambient typed `Context` (`workspace`, `run`, `self`, `inputs`,
  `trace`, `env`); added `Secret<T>` with trace redaction; added
  `builtin/introspect` escape hatch; refined step-key hashing to split
  stable vs. volatile ctx access and mark trace-reading steps
  non-cacheable; factored type checker as a pure function so v1.1 dynamic
  workflow evaluation can reuse it. Acceptance criteria now A1–A9.
- Rewrote `docs/TASKS.md` into milestones M1–M6 with cross-cutting items

## Blockers

- None. Several `[open]` design questions in the spec must be resolved
  before their owning milestone starts (tracked as task X.2).

## Next up

See [TASKS.md](TASKS.md) → **Now (M1)**.
