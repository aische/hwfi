# Status

Last updated: 2026-07-07

## Current focus

**M5 (persistence, tracing, resume) is complete.** Every `hwfi run`
now writes a durable run directory under `<workspace>/.hwfi/runs/<id>/`
(`run.json`, `steps/<step-key>.json`, append-only `trace.jsonl`), and
`hwfi resume` re-executes an interrupted run: cacheable steps with a
persisted result are skipped (no new trace events), non-cacheable steps
always re-run, and `ctx.trace` is reconstructed from the file so
downstream behaviour is caching-independent. `hwfi show` pretty-prints a
run. Ready to start **M6+** (deferred features, spec §13).

## Done recently

- `Hwfi.Runtime.Trace`: append-only file sink on `emit` (flushed per
  line), resume preload + `seq` continuation, `eventFromJson` decoder
  (inverse of `eventToJson`), `renderEvent` for `hwfi show`.
- `Hwfi.Runtime.StepKey`: §8.1 step-key = hash(qname, step-id, canonical
  resolved-args with `Ref` args contributing target fingerprints, stable
  `ctx` projection, callee fingerprint). Secrets hashed by actual value.
- `Hwfi.Runtime.RunStore`: run-dir layout, `run.json` schema + atomic
  read/write, content-addressed step cache, strict `trace.jsonl` reader,
  and the exclusive `<workspace>/.hwfi/lock` (§12).
- `Hwfi.Runtime.Executor`: cache-aware `execStep`; `performRun` /
  `performResume` orchestrating lock + `run.json` phase + persistent
  tracer; real `projectContentHash`; runtime fingerprint-by-qname.
- `TypedStep` gained `tsResultType` (threaded through `Check.Decl` /
  `Check`) so a cached result reconstructs to a typed `RValue`.
- `hwfi run/resume/show` wired; 128 tests (was 102) incl. A4/A7/A13/A15
  and a truncated-trace crash-resume test.

## Blockers

- None.

## Notes / decisions

- Caching is consulted **only on resume** (spec §8.2); every attempt
  still *writes* cache entries so a later resume can use them.
- Step classification is per-call-site and static: a cacheable step that
  calls a sub-workflow is skipped wholesale on a cache hit, even if the
  sub-workflow contains non-cacheable steps (its result was persisted).
- `run.json.inputs` and `steps/*.json` store **actual** (non-redacted)
  values — resume must re-evaluate with the real inputs/results — while
  `trace.jsonl` redacts secrets (§8.3.4, A8). Both live under `.hwfi/`.
- `run.json` records `project_dir` so `hwfi resume <ws> <id>` can
  re-parse and re-check the project (a code edit re-invalidates step
  keys, A13) without the user re-supplying the path.
- The workspace lock is an advisory OS `flock`; a second in-process open
  of the lock file (GHC single-writer) is caught and reported as busy.

## Next up

See [TASKS.md](TASKS.md) → **M6+**. Nothing is required before starting;
control flow (`if`/`foreach`/`par`) is the natural next milestone.
