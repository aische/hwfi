# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

## Later — server / DB (optional)

Deferred until v2 cutover is complete; may not ship.

- [ ] **M5** `ProjectStore` + `RunStore` typeclasses; DB backend; server API

## Now — semantic review (experimental track)

Design: [semantic-check-design.md](semantic-check-design.md) (§Experimental track).
Policy stays in `examples/semantic-check`; engine exposes general-purpose
primitives only. Entropy and speech-act heuristics are **signals, not verdicts**.

**Done foundation:** layers 0–2b + gated layer 3; Tier 1–2 builtins +
`resolve-qnames-in-text`, `split-text`, `text-grep`.

### E4 — Graph layer *(parallel with E2/E3)*

Structural graph analysis on `check-project` output.

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

- **E3 layer 3 gated LLM (2026-07-14):** `tools/review-gate`, `tools/pragmatic-review`,
  `types/review-gate-item`, `pragmatic-schema.json`; workflow inputs `mode` +
  `schema`; report `mode`, `review_gate`, `pragmatic_findings`.
- **E2 speech-act heuristics (2026-07-14):** `types/speech-act-tag`,
  `types/speech-act-hint`; `tools/speech-act-scan`, `tools/speech-act-align`
  (+ pattern/align helpers); report `speech_act_hints`; engine
  `builtin/split-text`, `builtin/text-grep`.
- **E1 layer 2 corpus wiring (2026-07-14):** `types/corpus-profile`, `types/corpus-slice`,
  `tools/corpus-profile`, `tools/corpus-clusters`, `tools/corpus-hints`; report
  `semantic-report/v1` with `corpus_profile` + `corpus_hints`.
- **Semantic review engine primitives (2026-07-14):** Tier 1 (`check-project`,
  `parse-markdown`), Tier 2 (`text-metrics`, `text-similarity`,
  `text-search-corpus`), `resolve-qnames-in-text`, `list-concat`.
- **`resolve-qnames-in-text` prose layer (2026-07-14):** `prose_hints` 142 → 2
  on ship; section scan via `parse-markdown`.
- **`examples/semantic-check` layers 0–1 (2026-07-14):** structural + referential
  review; `semantic-report/v0`.
- **Eval errors in `try`/`catch` (2026-07-14):** catchable eval failures in StepDriver.
- **`return` in control-flow blocks (2026-07-14):** nested loop/branch tail return.
- **M6 runtime (2026-07-13–14):** v2 cursor/frames, `--step`, cache removal.

Earlier milestones archived in [log/archive/tasks-2026-07.md](log/archive/tasks-2026-07.md).
