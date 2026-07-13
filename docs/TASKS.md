# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

## Now — v2 runtime (cursor + frames)

Design: [execution-model.md](execution-model.md).

- [ ] **M1** Sequential `stepMachine` (statements, builtins, sub-workflows)
- [ ] **M2** Agent `Current` states; remove agent sub-key replay dependency
- [ ] **M3** Real `par` + cooperative confirm + per-branch snapshots
- [ ] **M4** CLI `step` / `continue`; replace `performResume`; cut over default runtime
- [ ] **M5** `ProjectStore` + `RunStore` typeclasses; DB backend
- [ ] **M6** Drop step-key cache path; rewrite spec §8 and caching docs

## Next — v1.1 (paused during v2)

Deferred from v1; spec §13 and [code-issues.md](code-issues.md).

- [ ] 9.4.4 `builtin/extract-skill` stub writer (A40)
- [ ] 9.5 `Bytes`-typed file I/O
- [ ] 9.6 `trace.jsonl` rotation
- [ ] 9.1 OS-level `exec` isolation (namespaces/seccomp/cgroups)
- [ ] D1 `ctx.trace` O(n²) rebuild perf
- [ ] D2 directory-walk perf (`find-files`/`grep`)
- [ ] `Optional<T>` / nullable env (spec §13)

## Done

- **M0 (2026-07-13):** `Machine`, `MachinePath`, `MachineSnapshot`, `StepDriver` stub;
  `MachineSpec` (snapshot round-trip, path navigation, first-step transition).

Completed v1.1 author-capability items (9.9–9.14) and earlier milestones are
archived in [log/archive/tasks-2026-07.md](log/archive/tasks-2026-07.md).
