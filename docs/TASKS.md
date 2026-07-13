# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

## Now — v2 runtime (cursor + frames)

Design: [execution-model.md](execution-model.md).

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

- **M3 (2026-07-13):** Real `par` + cooperative confirm + per-branch snapshots —
  `MachinePar`, `CurParPool`, `FrPar` scheduler/drain/confirm; `StepEnv` confirm
  policy; `MachinePath` nested block paths; `MachineSpec` par e2e/resume/confirm.
- **M2 (2026-07-13):** Agent `CurAgent` in `stepMachine` — `MachineAgent` drives one
  transition per call (model or tool); agent reducible state in snapshot; v2 path
  does not consult intra-step sub-key cache; `seRunWorkflow` seam; `MachineSpec`
  agent e2e + mid-agent snapshot resume.
- **M1 (2026-07-13):** Sequential `stepMachine` — dispatch, builtins, sub-workflows,
  control flow (`if`, `foreach`, `while`, `try`); `StepEnv`, `runMachine`; `FrForeach`,
  `FrSeq.fsBindings`; `MachineSpec` file-only e2e.
- **M0 (2026-07-13):** `Machine`, `MachinePath`, `MachineSnapshot`, `StepDriver` stub;
  `MachineSpec` (snapshot round-trip, path navigation, first-step transition).

Completed v1.1 author-capability items (9.9–9.14) and earlier milestones are
archived in [log/archive/tasks-2026-07.md](log/archive/tasks-2026-07.md).
