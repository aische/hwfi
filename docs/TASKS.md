# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

## Now

_(empty — pick from Next)_

## Next — v1.1 (post-release)

Deferred from v1; spec §13.1 and [code-issues.md](code-issues.md).

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

- [x] 9.14 `WorkflowRef` / `ToolRef` patterns — docs + checker hints (2026-07-12)
- [x] 9.12 Cache invalidation UX (full) — `hwfi cache invalidate`,
      trace step keys, docs (2026-07-12)
- [x] 9.9 Control-flow error handling — `try`/`catch` + `par(on_error =
      "collect")` per §4.4 / §4.1.1 (2026-07-12)
- [x] 9.9 spec — `try`/recover + `par` collect-errors design (§4.4, §4.1.1)
      (2026-07-12)
- [x] 9.11 Simpler loop syntax — inline `while` bodies + `range(n)` (2026-07-12)
- [x] 9.10 Data plumbing (remainder) — `record-merge`/`record-filter`/`record-map`
      (2026-07-12)
- [x] R1 v1.0.0 release (P0–P2, tag `v0.1.0.0`) — archived in
      [log/archive/tasks-2026-07.md](log/archive/tasks-2026-07.md) (2026-07-12)
- [x] 9.15.1–9.15.4 Agent skill runtime (§6.7): catalog, `discover-skills`,
      `load-skill`, checkpoint/resume, runtime `tools` list; A45–A50;
      `examples/skills-runtime` (2026-07-09)
- [x] M1–M9, H1, 9.2–9.4 (2026-07-07 – 2026-07-09): see git history / log archive.
