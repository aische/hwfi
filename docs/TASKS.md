# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

## Later — server / DB (optional)

Deferred until v2 cutover is complete; may not ship.

- [ ] **M5** `ProjectStore` + `RunStore` typeclasses; DB backend; server API

## Now — semantic review (experimental track)

Design: [semantic-check-design.md](semantic-check-design.md) (§Experimental track).
Policy stays in `examples/semantic-check`; engine exposes general-purpose
primitives only. Entropy and speech-act heuristics are **signals, not verdicts**.

**Done foundation:** layers 0–2 wired; Tier 1–2 builtins + `resolve-qnames-in-text`.

### E2 — Speech-act heuristics *(deterministic, no LLM)*

Pattern-based illocutionary tagging; compare prose profiles to step metadata.

- [ ] `types/speech-act-tag` — `{ force, sentence, patterns }` per tagged sentence
- [ ] `types/speech-act-hint` — finding shape for act mismatches / bare directives
- [ ] `tools/speech-act-scan` — tag section bodies (directive / assertive / commissive / declarative)
- [ ] `tools/speech-act-align` — step `target`/`agent_tools` vs agent-section act profile
- [ ] Wire into report — `speech_act_hints` array in `semantic-report/v1`

### E3 — Layer 3 pragmatic LLM pass *(gated)*

LLM only on slices flagged by E1/E2; bounded cost.

- [ ] `builtin/split-text` — sentence/paragraph chunks for act tagging + LLM context
- [ ] `tools/review-gate` — union entropy outliers, similarity pairs, speech-act mismatches
- [ ] `tools/pragmatic-review` — `llm-gen-object` with fixed contradiction/clarity schema
- [ ] Workflow input `mode` — `strict` (skip LLM) vs `exploratory` (run layer 3)
- [ ] Report field `pragmatic_findings`

### E4 — Graph layer *(parallel with E2/E3)*

Structural graph analysis on `check-project` output.

- [ ] `builtin/graph-reachability`
- [ ] `builtin/graph-cycles`
- [ ] `builtin/graph-topo-sort`
- [ ] `tools/graph-findings` — orphans, import cycles, unreachable from entry
- [ ] Report field `graph_findings`

### Engine backlog (deferred until E3/E4 need them)

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
