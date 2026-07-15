# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

## Later — server / DB (optional)

Deferred until v2 cutover is complete; may not ship.

- [ ] **M5** `ProjectStore` + `RunStore` typeclasses; DB backend; server API

## Now — architecture cleanup

Design: [semantic-check-design.md](semantic-check-design.md) §Architecture cleanup.

Decouple deterministic review from optional LLM. Policy stays in example workflows;
no new review-specific engine builtins.

- [ ] **`semantic-check` always strict** — layers 0–2b only; remove `mode` input
  and in-workflow layer 3 (`pragmatic-review`)
- [ ] **Always emit `review_gate`** — compute high-signal gate items on every check
  run (not only when LLM is enabled)
- [ ] **Optional pragmatic workflow** — new project (e.g. `semantic-pragmatic`):
  `--input source_run=<run-id>` loads report + `review_gate`, runs bounded
  `llm-gen-object`, writes `pragmatic_findings` back into the run directory
- [ ] **Pipeline docs** — document order: check → optional pragmatic → summary;
  update example READMEs and report `mode` field semantics
- [ ] **Retire `mode=exploratory` on check** — avoid strict/exploratory coupling;
  exploratory becomes an explicit second step

## Next — semantic review E4 (graph layer)

Deferred until architecture cleanup ships. Design:
[semantic-check-design.md](semantic-check-design.md) §Experimental track.

- [ ] `builtin/graph-reachability`
- [ ] `builtin/graph-cycles`
- [ ] `builtin/graph-topo-sort`
- [ ] `tools/graph-findings` — orphans, import cycles, unreachable from entry
- [ ] Report field `graph_findings`

### Engine backlog (deferred until E4 need them)

- [ ] `builtin/diff-text`
- [ ] `builtin/json-validate`

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

Recent milestones; earlier items in [log/archive/tasks-2026-07.md](log/archive/tasks-2026-07.md).

- **semantic-summary CLI (2026-07-15):** `source_run` input; `builtin/read-json`.
- **semantic-summary workflow (2026-07-15):** mechanical rollup + optional narrative.
- **Layer 3 gate noise mitigation (2026-07-15):** high-signal gates; post-filter.
- **E1–E3 experimental track (2026-07-14–15):** corpus, speech acts, gated LLM.
- **Semantic review primitives + layers 0–1 (2026-07-14):** check-project stack.
- **M6 runtime (2026-07-13–14):** v2 cursor/frames, `--step`, cache removal.
