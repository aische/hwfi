# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

## Later — server / DB (optional)

Deferred until v2 cutover is complete; may not ship.

- [ ] **M5** `ProjectStore` + `RunStore` typeclasses; DB backend; server API

## Now — semantic review E4 (graph layer)

Design: [semantic-check-design.md](semantic-check-design.md) §Experimental track.

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

- **Architecture cleanup (2026-07-15):** check always strict; always `review_gate`;
  `semantic-pragmatic` workflow; pipeline docs.
- **Doc sync (2026-07-15):** `workflow-reference` semantic builtins; `llm-simple`
  0.1.0.2; model catalog defaults; `scripts/semantic-review.sh` documented.
- **semantic-summary CLI (2026-07-15):** `source_run` input; `builtin/read-json`.
- **semantic-summary workflow (2026-07-15):** mechanical rollup + optional narrative.
- **Layer 3 gate noise mitigation (2026-07-15):** high-signal gates; post-filter.
- **E1–E3 experimental track (2026-07-14–15):** corpus, speech acts, gated LLM.
- **Semantic review primitives + layers 0–1 (2026-07-14):** check-project stack.
- **M6 runtime (2026-07-13–14):** v2 cursor/frames, `--step`, cache removal.
