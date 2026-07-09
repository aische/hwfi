# Spec review notes — reconciliation status

Original review predates M1–M9 and H1. Updated 2026-07-09.

## Resolved

| # | Topic | Resolution |
|---|-------|------------|
| 1 | Cache invalidation on code edit | Step-key includes Merkle `callee-fingerprint` (§8.1). Test A13. |
| 2 | Missing env vars | Strict presence at startup (§5.7); missing whitelisted var aborts before run. |
| 3 | `TypeExpr` alias grammar | EBNF includes `\| QName` (spec §3.4); parser supports `TAlias`. |
| 4 | Multi-turn chat | `builtin/llm-chat` specified and implemented (§6). |
| 5 | Interpolation of complex types | §3.2.1 rendering table; interpolation JSON-encodes structured types. |
| 6 | `ctx.trace` on resume | §8.3.5: preload persisted `trace.jsonl`; test A15. |
| 7 | Eval errors | `KEval` / `"eval"` kind in runtime (§8.3.2). |
| 8 | Agent skill runtime (§6.7) | `discover-skills`, `load-skill`, catalog, checkpoint/resume; tests A45–A50; `examples/skills-runtime`. |

## Still accurate (by design or deferred)

- **Implicit returns** — uncommon; tools return `{ text }` while workflows declare `{ summary }`; explicit `return` is the norm.
- **YAML `:` vs DSL `=`** — intentional (spec §3.4 note).
- **No `Optional<T>`** — deferred v1.1 (spec §13).
- **No workflow-level `try`/recover** — deferred §13.1.1; agent loop has
  localized recoverable errors only (§6.1.4); `eval-workflow` parse/check
  failures use `{ ok, errors }` (§6.4).
- **Author capability backlog** — record ops, loop sugar, finer cache
  invalidation, `WorkflowRef` patterns: spec §13.1, tasks 9.9–9.14.
  **Partially addressed in R1:** `json-get`, `concat`, `builtin/log`,
  `hwfi cache clear`, usage/cost (§8.4), D3 agent cache semantics (§6.1.2).

## Implementation gaps (not spec gaps)

See [spec.md](spec.md) §14 deferred hardening and [code-issues.md](code-issues.md) D1–D2.
