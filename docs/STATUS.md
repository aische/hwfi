# Status

Last updated: 2026-07-07

## Current focus

**M4 (runtime and built-in tools) is complete.** `hwfi run` executes a
type-checked project end-to-end: it evaluates step arguments, injects the
ambient `ctx` per step, dispatches to built-in tools and sub-workflows,
and produces workflow outputs. Ready to start **M5: persistence, tracing,
and resume** (the trace ADT and an in-memory tracer already exist as the
seam M5 will persist through).

## Done recently

- `Hwfi.Runtime.Value`: `RValue` runtime values, JSON conversion,
  canonical (sorted-key) JSON, the §3.2.1 render table, secret redaction,
  and CLI/JSON input coercion by declared type.
- `Hwfi.Runtime.Error`: `RuntimeError` + `ErrorKind` (§8.3.2 kinds).
- `Hwfi.Runtime.Trace`: stable `TraceEvent` ADT + JSON encoders (§8.3) and
  an in-memory `Tracer` (monotonic gap-free `seq`, ISO-8601 `at`).
- `Hwfi.Runtime.Workspace`: canonicalised root + lexical traversal guard
  (A5), UTF-8 file read/write/list.
- `Hwfi.Runtime.Gateways`: gateways from `LLM.Providers.*` + `KeyStore`;
  `ModelConfig` assembly from the catalog; unknown-model error lists names
  (A11).
- `Hwfi.Runtime.{Context,Eval,Builtins,Executor}`: per-step `ctx`, the
  expression evaluator (with `eval` errors, §8.3.2), all `builtin/*`
  tools, and the linear step interpreter with sub-workflow recursion (A6).
- `hwfi run` wired (inputs, entrypoint override, key/env validation);
  `examples/summarise/`; 102 tests (was 71) incl. an end-to-end file
  workflow covering A3/A6/A9.

## Blockers

- None.

## Notes / decisions

- Persistence is intentionally out of M4: the executor accumulates the
  trace in memory via `Tracer`; M5 adds the `trace.jsonl` writer, step-key
  caching, and resume on the same seam.
- `run-start`'s `project_hash` is currently the entrypoint's Merkle
  fingerprint (a stand-in); M5 replaces it with a project-dir content hash.
- `ctx.trace` is a `List` of per-event JSON values; indexing yields a
  `TraceEvent` (opaque `Json` at runtime), matching the checker's typing.
- Errors nest: each failing step in a call chain emits its own `error`
  event, so every `StepStart` has a terminal (§8.3.3 invariant 3).

## Next up

See [TASKS.md](TASKS.md) → **M5**. Start with 5.1 (run directory +
`run.json`) and 5.4 (persist the existing `Tracer` events to `trace.jsonl`).
