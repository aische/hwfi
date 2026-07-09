# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

## Now — v1.0.0 release (R1)

Target: tag **0.1.0.0** with tutorials and two hardened examples (`summarise`,
`coding/fix`). Engine core (M1–M9, H1, 9.2–9.4) is done.

### P0 — trust before tutorials

- [x] R1.1 Pin/fix agent tool-result cache (D3): cache `valueToJson`, redact
      trace/events only; `toolModelJson` on resume; test in `AgentSpec`
- [x] R1.2 Author guide [caching-and-resume.md](caching-and-resume.md)
- [x] R1.3 Doc sync: `spec.md` (§6.1.2 D3, §6.7, §8.4, §9, §11, §13.1),
      `tool-use.md` header, `Hwfi.Cli` Haddock
- [x] R1.4 Root `README.md` (install, `llm-simple` sibling dep, quick start)

### P1 — ergonomics for tutorials

- [x] R1.5 `builtin/json-get` + `builtin/concat` (§13.1.2 subset)
- [x] R1.6 `builtin/log` — `workflow-log` events + `hwfi show`
- [x] R1.7 `examples/summarise/README.md`
- [x] R1.8 `while` example (`workflows/tick-stop` in `control-flow`)

### P2 — release surface

- [x] R1.9 Harden tutorial examples: E2E `summarise` + `coding/fix` on clean
      workspace; DeepSeek via API (`deepseek-v4-flash` in READMEs/catalog)
- [x] R1.10 Minimal cache UX: `hwfi cache clear` subcommand
- [ ] R1.11 Tutorials (user-authored): hello → check → agent → show/resume
- [ ] R1.12 `CHANGELOG.md` + tag 0.1.0.0

## Next — v1.1 (post-release)

Deferred from v1; spec §13.1 and [code-issues.md](code-issues.md).

- [ ] 9.9 Control-flow error handling — `try`/recover; `par` continue-on-failure
- [ ] 9.10 Data plumbing (remainder) — record map/filter/merge
- [ ] 9.11 Simpler loop syntax — inline `while` bodies, `range` loops
- [ ] 9.12 Cache invalidation UX (full) — invalidate-from-step policy
- [ ] 9.14 `WorkflowRef` / `ToolRef` patterns — docs + checker hints
- [ ] 9.4.4 `builtin/extract-skill` stub writer (A40)
- [ ] 9.5 `Bytes`-typed file I/O
- [ ] 9.6 `trace.jsonl` rotation
- [ ] 9.1 OS-level `exec` isolation (namespaces/seccomp/cgroups)
- [ ] D1 `ctx.trace` O(n²) rebuild perf
- [ ] D2 directory-walk perf (`find-files`/`grep`)
- [ ] `Optional<T>` / nullable env (spec §13)

## Done

_Move items here temporarily, then archive to
`docs/log/archive/tasks-YYYY-MM.md`._

- [x] M1–M9, H1, 9.2–9.4 (2026-07-07 – 2026-07-09): see git history / log archive.
