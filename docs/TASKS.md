# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

## Later — server / DB (optional)

Deferred until v2 cutover is complete; may not ship.

- [ ] **M5** `ProjectStore` + `RunStore` typeclasses; DB backend; server API

## Next — semantic review builtins (planned)

Design: [semantic-check-design.md](semantic-check-design.md). Semantic review is
a **workflow**, not engine logic. Builtins are general-purpose primitives.

### Tier 1 — project and markdown structure

- [x] `builtin/check-project` — parse + type-check workspace project; structured
  declarations, call graph, step metadata
- [x] `builtin/parse-markdown` — frontmatter, sections, fenced blocks

### Tier 2 — text corpus analysis

- [x] `builtin/text-metrics` — entropy, compression ratio, token counts
- [x] `builtin/text-similarity` — Jaccard / LCS pairwise similarity
- [x] `builtin/text-search-corpus` — overlap clusters across documents

### Tier 3 — graph and reference utilities

- [ ] `builtin/graph-reachability`
- [ ] `builtin/graph-cycles`
- [ ] `builtin/graph-topo-sort`
- [ ] `builtin/resolve-qnames-in-text` — resolved / unresolved / ambiguous mentions

### Tier 4 — convenience

- [ ] `builtin/diff-text`
- [ ] `builtin/json-validate`
- [ ] `builtin/split-text`

### Example workflow (after Tier 1)

- [x] `examples/semantic-check` — layers 0–1 review; `semantic-report.json` output

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

- **Per-transition stepping (2026-07-14):** `DriveOneBatch` halts after each
  `Stepped` outcome; agent loops step per model/tool call.
- **`hwfi run --step` (2026-07-14):** `performRunMode` + `--step` flag.
- **M6 cleanup (2026-07-14):** Stale step-cache artifacts in docs/examples;
  runtime comment fixes; `cacheable` from checker in traces; removed unused agent
  fields (`aeStepKey`, `atFingerprint`).
- **M6 (2026-07-13):** Dropped step-key cache resume (`Executor`, `steps/`,
  `hwfi cache clear|invalidate`); single v2 path via `MachineRun` +
  `machine.json`; migrated tests; rewrote spec §8 / caching docs; while-pred
  replay from trace; control-flow trace parity.
- **M4 (2026-07-13):** CLI `hwfi step` / `hwfi resume`; v2 default runtime via
  `MachineRun` — `machine.json` snapshot persistence, project-hash staleness
  gate, `performContinueToEnd` / `performStep`.
- **M3 (2026-07-13):** Real `par` + cooperative confirm + per-branch snapshots.
- **M2 (2026-07-13):** Agent `CurAgent` in `stepMachine`; snapshot resume.
- **M1 (2026-07-13):** Sequential `stepMachine`; control flow; `StepEnv`.
- **M0 (2026-07-13):** `Machine`, `MachinePath`, `MachineSnapshot`, stub driver.

Completed v1.1 author-capability items (9.9–9.14) and earlier milestones are
archived in [log/archive/tasks-2026-07.md](log/archive/tasks-2026-07.md).
