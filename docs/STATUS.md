# Status

Last updated: 2026-07-07

## Current focus

**M7 (mutation + `exec` tools) is complete.** Workflows and agents can now
modify the sandboxed workspace and run allowlisted commands, so coding
workflows are possible. Navigation (`read-file-slice`/`find-files`/`grep`),
mutation (`edit-file`/`move-file`/`copy-file`/`remove-file`/`make-dir`/
`remove-dir`), and `builtin/exec` are native builtins over
`Hwfi.Runtime.Workspace` — one sandbox, one trace stream, one cache scheme.
Next is **M8** (control flow: `if`/`foreach`/`par`).

## Done recently

- `Hwfi.Runtime.Glob`: pure, unit-tested glob matcher (`**`/`*`/`?`) for
  `find-files` (§6.2), ported from `llm-simple`'s pure matcher.
- `Hwfi.Runtime.Workspace`: `readFileSlice`, `findFiles`, `grepFiles`
  (regex via `regex-tdfa`), and the mutation ops — all through the existing
  sandbox guard (A22), with an `expect` guard on `edit-file` (A23).
- `Hwfi.Runtime.Exec`: `typed-process` child in the workspace root; argv-only
  (no shell), allowlist + `env` allowlist + timeout + output cap from
  `project.json.exec`; non-zero/timed-out exit returned as a *value* (A24).
- `Hwfi.Project.Manifest`: `ExecPolicy` parsing (fail-closed default).
- `Hwfi.Runtime.Trace`: `FileOp` enum extended (read-slice/find/grep/edit/
  move/copy/remove/mkdir/rmdir) + new `Exec` event, JSON round-trip and
  `hwfi show` rendering (§8.3.2).
- `Hwfi.Check`: `execErrors` pass rejects un-allowlisted / policy-less
  `builtin/exec` at check time (A24); mutation/exec builtins are advertisable
  agent tools (§7.5).
- `examples/coding`: scripted `workflows/render` (edit → exec) and agentic
  `workflows/fix` (llm-agent repairs a broken `sh -n` build).
- 188 tests (was 152): Glob/Exec unit specs, Workspace navigation+mutation
  specs (A22/A23), Check exec-policy fixtures (A24), an executor durable-
  workspace resume test (A25), and an end-to-end agent coding loop over a
  fake gateway + real builtins (A26).

## Blockers

- None.

## Notes / decisions

- `grep` uses `regex-tdfa` (pure Haskell, POSIX ERE) to avoid a new C
  dependency; not literal RE2, but adequate for common patterns (§6.2).
- Exec allowlist violations are surfaced as recoverable *sandbox* errors in
  the agent loop (the model can retry with an allowed program), while a
  direct scripted step aborts. Only internal errors are fatal in the loop.
- Durable-workspace invariant (§8.2): mutation and `exec` steps are cacheable;
  on resume a completed one is served from cache and its side effect is **not**
  re-applied. Verified end-to-end (A25) and per tool call in the agent loop.
- The general control-flow unification (CEK-style) is still deferred; the M6
  agent loop remains the single reified state machine, reused by M8.

## Next up

See [TASKS.md](TASKS.md) → **M8: control flow (`if`/`foreach`/`par`)**,
plus the carried-over optional items (agent state serialisation §8.2.1,
OS-level `exec` isolation §7.5, `Bytes`-typed file I/O).
