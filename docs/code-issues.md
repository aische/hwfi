# Haskell Codebase Review — hwfi

Review date: 2026-07-08. Scope: `src/`, `app/`, `hwfi.cabal`. No fourmolu/ormolu/hlint
config is present, so formatting is not flagged.

## 1. Summary

The codebase is in genuinely good shape: the checker is cleanly phased, the
runtime value/error/trace types are well-factored, secret redaction is applied
consistently at observable boundaries, and the lazy Merkle-fingerprint knot in
`Hwfi.Check.Graph` is a highlight. The most important thing to fix first is that
the executable and test-suite are **not built with `-threaded`**, even though the
engine relies on bounded concurrency (`par`), subprocess execution with
timeouts, and networked LLM calls — on the non-threaded RTS a single blocking
`safe` FFI call (e.g. `getaddrinfo` during DNS) stalls *all* green threads, so
`par` silently serialises and can appear to hang. Two further correctness gaps
matter for the security/caching guarantees the docs promise: the workspace
sandbox does **not** actually contain symlink escapes despite claiming to, and
one-shot `builtin/llm-*` step results are **not** invalidated when
`model-catalog.json` changes (only agent model calls fold in the catalog
fingerprint). Everything else is design/perf polish.

## 2. Critical issues

### C1. `[hwfi.cabal:executable/test-suite]` No `-threaded` RTS despite concurrency + subprocess + network
The `common opts` stanza sets only `-Wall -Wunused-imports -Werror=missing-fields`;
neither the `executable hwfi` nor `test-suite` stanza adds `-threaded`
(`rg threaded` finds nothing in build config). The runtime uses
`UnliftIO.Async.pooledForConcurrentlyN` for `par`
(`Hwfi/Runtime/Executor.hs:484`), `System.Process.Typed` with
`System.Timeout.timeout` (`Hwfi/Runtime/Exec.hs:104,118`), and llm-simple network
calls. On the single-threaded RTS:
- there is no real parallelism, so `par(max = N)` gives interleaving at best;
- any blocking **safe** FFI call (DNS `getaddrinfo`, some TLS paths) blocks the
  *entire* process, so concurrent LLM calls in a `par` loop serialise and can
  look like a hang;
- subprocess/timeout behaviour is far more robust under the threaded RTS.

**Fix:** add to both stanzas:
```
ghc-options: -threaded -rtsopts "-with-rtsopts=-N"
```

### C2. `[Hwfi/Runtime/Workspace.hs:69-90, 94-118]` Sandbox does not contain symlink escapes (contradicts its own docs)
The module header (lines 1-9) claims lexical `..` resolution means "a relative
path can never reach outside the workspace even through a symlinked entry created
during the run." That is false for the read/write/mutation builtins.
`resolvePath` only collapses `.`/`..` textually and checks `isAbsolute`; it never
resolves or rejects symlinks. `readTextFile`, `writeTextFile`, `editFile`,
`moveFile`, `copyFile`, `removeFile`, `removeDir` then call `BS.readFile` /
`renamePath` / `removePathForcibly` etc. on the resolved path, all of which
**follow symlinks**. So a symlink inside the workspace (pre-existing in a
user-supplied workspace, or created by an allowlisted `exec` such as `ln -s /etc
link`) lets `read-file link/passwd` escape the sandbox. Only the `find`/`grep`
walk (`walkEntries`, line 334) skips symlinks; the direct file ops do not.

**Fix:** after resolving lexically, `canonicalizePath` the result and verify it is
still under `workspaceRoot` (comparing canonical prefixes), or `getSymbolicLinkStatus`
each component and reject symlinked path elements. At minimum, correct the module
comment so the guarantee is not overstated.

### C3. `[Hwfi/Runtime/Executor.hs:582-596] + [Hwfi/Runtime/StepKey.hs:63-74]` Editing `model-catalog.json` does not invalidate one-shot LLM step caches on resume
`stepKeyFor` builds the callee component from `fingerprintOfQName`, which for a
builtin returns the *fixed* `builtinFingerprint` (engine version + signature only,
`Hwfi/Check/Graph.hs:138-140`). The `model` argument contributes only the model
*name* string via `argMap`. Nothing in the step-key reflects the resolved catalog
entry (provider model id, temperature, timeouts). So if a user edits
`model-catalog.json` — e.g. repoints the name `fast` to a different underlying
model or changes temperature — and then `hwfi resume`s, cached
`builtin/llm-generate` / `llm-chat` / `llm-gen-object` results are still served
stale. This is inconsistent with the agent path, which *correctly* folds
`asModelFingerprint`/`modelCatalogFingerprint` into `modelSubKey`
(`Hwfi/Runtime/Agent.hs:391-400`, `Hwfi/Runtime/Gateways.hs:123-137`).

**Fix:** thread the model-catalog fingerprint into the step-key for LLM builtins
(e.g. resolve `argMap`'s `model` against the store and mix
`modelCatalogFingerprint` into `ctxProj` or a dedicated key field). The doc in
`StepKey.hs` also implies the callee fingerprint captures "anything that could
alter the step's result," which is currently untrue for model config.

## 3. Design / architecture issues

### D1. `[Hwfi/Runtime/Executor.hs:795-798] + [Hwfi/Runtime/Context.hs:54-77] + [Hwfi/Runtime/Trace.hs:453,494-499]` Quadratic `ctx.trace` reconstruction and unbounded in-memory trace
`buildCtx` runs once per step/if/loop and calls `snapshotEvents` (which
`reverse`s the whole accumulated list) and then `contextValue` maps
`VJson . eventToJson` over *every* prior event to materialise `ctx.trace` as
`RValue`s — even for the overwhelmingly common case where the step never reads
`ctx.trace`. That is O(n²) in event count (time and allocation) over a run, and
the `Tracer`'s `IORef (Int, [TraceEvent])` retains every event in memory for the
whole run. For long agentic runs this is a real space/time leak.

**Fix:** build `ctx` lazily so `ctx.trace` is only forced when referenced (it is
already excluded from cacheable step keys), or pass a thunk / on-demand accessor
rather than eagerly converting all events each step. Consider not retaining the
full event list in the tracer when only the append sink is needed.

### D2. `[Hwfi/Runtime/Workspace.hs:331-343]` Accidentally quadratic directory walk
`walkEntries` accumulates with `foldM` where each `visit` returns
`acc <> [(segs, full, dir)] <> sub`. Left-nested `<>` on `[]` makes the walk
O(n²) in the number of entries (each append re-traverses the growing `acc`).
`findFiles`/`grep` inherit this.

**Fix:** build with a difference list or accumulate in reverse and `reverse`
once, or return `sub ++ acc` with a prepend-only pattern; sort at the end (as it
already does).

### D3. `[Hwfi/Runtime/Agent.hs:296-314]` Agent tool results are cached and fed back **redacted**, discarding the real value
On the fresh path, `runAdvertisedCall` computes `redacted = redactedJson result`,
caches `redacted`, and feeds `canonicalJson redacted` back to the model; the
resume path returns `canonicalJson cachedJson` (also the redacted form). The
actual (unredacted) `result` is dropped. Scripted steps instead cache
`valueToJson result` (`Executor.hs:549`). This means a tool that legitimately
returns a `Secret<_>`-bearing record (secret outputs are representable) hands the
model `<secret:?>` with no way to use it, and the two code paths having different
notions of "the step result" is a latent inconsistency. If redaction-to-model is
intentional (defensible under §5.5), it should be documented at the call site;
if not, cache/return the real value and redact only for the trace event.

### D4. `[Hwfi/Runtime/Executor.hs:307-319, 617-630]` Sub-workflow calls reset the step-key scope, contradicting STATUS/spec
`runWorkflow` always starts bodies with scope `""`, and `dispatchResolved`
re-enters `runWorkflow` with no scope threading. But `docs/STATUS.md:59` and
`docs/spec.md` state sub-workflow internal keys are "call-site-prefixed." So two
`par`/`foreach` iterations calling the same sub-workflow with identical args
would (if both were re-executed mid-flight on resume) share the sub-workflow's
internal step cache. This is benign *as long as* identical args imply identical
effects, but the doc/impl divergence is a trap for future changes (e.g. a
sub-workflow reading a volatile source). Either thread `scope` through
`runWorkflow` at the sub-workflow boundary as documented, or fix the docs to say
sub-workflow bodies deliberately reset scope and explain why it's safe.

### D5. `[Hwfi/Runtime/Executor.hs:179-199, 260-265]` No catch-all around a run; an unexpected exception leaves phase `running` with no `run-end`
`performRun`/`performResume` only `bracket` the trace handle and the workspace
lock. Runtime *values* are `Either RuntimeError`, but a genuine synchronous
exception escaping llm-simple, aeson, or disk I/O will bypass `finish`: no
`RunEnd` event, phase stuck at `running` (still resumable, which is at least
safe), and the CLI surfaces a raw exception rather than a typed error. For an
engine whose selling point is resumable, traced runs, the crash path should be
deliberate.

**Fix:** wrap the body in `UnliftIO.Exception.withException`/`onException` (or
`tryAny`) to emit a terminal `RunEnd Aborted`, set `PhaseCrashed`, and record an
`internal` error event before rethrowing.

### D6. `[Hwfi/Check/Graph.hs:90-94] + [Hwfi/Cli.hs:450] + [Hwfi/Runtime/Executor.hs:880-883] + [Hwfi/Check/Decl.hs:687-690]` Partial functions safe-by-construction but avoidable
- `cycleError vs` uses `head vs`; `CyclicSCC` is non-empty by construction, but
  `Data.List.NonEmpty` / a pattern `(v:_)` would make it total.
- `hexDigit d = "0123456789abcdef" !! d` — safe (d ∈ [0,15]) but a `case` or
  `Data.Char.intToDigit` is total and clearer.
- `bareIdent` returns `""` on an empty qname in both `Executor` and `Check.Decl`.
  An empty `QName` shouldn't be constructible; the `""` fallback silently masks
  an invariant violation instead of failing loudly. Prefer a non-empty qname
  representation or an `internalError`.
- `xs !! i` in `Eval.applyAccessor:110` is guarded by an explicit bounds check —
  fine, but `Data.List.genericIndex`/`atMay` would remove the foot-gun entirely.

### D7. `[Hwfi/Runtime/Workspace.hs:157-171]` `read-file-slice` re-reads and re-splits the whole file per page
Each call reads the entire file, `T.lines`, then `drop off . take lim`. Paging a
large file is O(file_size × pages). Acceptable given the 1 MiB read guard, but
worth noting for the intended "navigate large files" use case; a streaming line
reader would scale better.

## 4. Minor issues / nits

- `[Hwfi/Cli.hs:1-18]` Stale module Haddock: "The remaining commands are stubs
  that report 'not implemented'." `run`/`resume`/`show` are fully implemented.
- `[Hwfi/Cli.hs:437-438]` Comment says "A ULID is planned for M5" but M5 is done
  and this is still the timestamp+24-bit-random scheme; either implement or drop
  the aspiration. Collision risk is low (workspace-locked, per-second + 24 bits)
  but non-zero for rapid same-second runs.
- `[Hwfi/Runtime/Trace.hs:82-95]` `fileOpFromText` maps any unrecognised op to
  `OpList`; a corrupt/newer trace line silently renders as `list`. A `Maybe`
  return (skipping the line, as the reader already does for bad JSON) would be
  more honest.
- `[Hwfi/Runtime/Builtins.hs:336-338]` `toTurn` collapses the `tool` role into a
  `UserTurn` — lossy but documented; fine for v1.
- `[Hwfi/Runtime/Value.hs:145-150]` `renderDouble` relies on `round`
  (banker's rounding) to detect integrality then `show`s the `Integer`; large or
  scientific-notation doubles fall through to `show d` (e.g. `1.0e7`), which may
  not be the desired canonical decimal. Minor.
- `[Hwfi/Runtime/Workspace.hs:167-171]` A trailing newline is lost by
  `T.lines`/`T.intercalate "\n"` round-trips in slices; `eof` computation is
  correct but the returned text can't be byte-reassembled. Document if it matters.
- `[Hwfi/Runtime/Executor.hs:513-541]` For agent steps the agent step-key is
  computed twice (once as `mKey` is `Nothing` so skipped, once in
  `runAgentStep`). Not a bug, but the double call to `stepKeyFor` reads oddly;
  factor the agent-key computation out of the `mKey` branch.

## 5. What's working well (specific)

- `[Hwfi/Check/Graph.hs:106-131]` The self-referential lazy `MapL.mapWithKey`
  fingerprint knot, gated on prior acyclicity, is elegant and correct, with an
  accurate comment explaining why strictness would loop.
- `[Hwfi/Runtime/Value.hs:89-101] + [Hwfi/Runtime/Secret.hs:36-37]` Redaction is
  applied uniformly at every observable boundary (trace, introspect, CLI output)
  and the `Secret` `Show` instance closes the accidental-`show` leak.
- `[Hwfi/Runtime/Trace.hs:449-490]` The `MVar`-serialised `emit` correctly keeps
  `seq` assignment and the file append atomic so `par` iterations produce an
  in-order, resume-consistent trace.
- `[Hwfi/Check.hs:49-113]` Clear four-phase checker with each phase able to
  assume the previous invariants; error accumulation (not fail-fast) gives good
  diagnostics.
- `[Hwfi/Runtime/RunStore.hs:281-286]` Atomic `.tmp`+`renameFile` writes for
  `run.json` and step-cache entries are the right call for crash-safety.

## 6. Testing & documentation gaps

- **Property tests are absent** (the suite is example-based hspec). High-value
  QuickCheck targets: `canonicalJson` key-order invariance / idempotence;
  step-key stability under argument reordering (`encodeArgs`/`argsToJson` sort);
  `matchGlob`/`matchSegment`; `resolveSegments` never escaping the root;
  `eventToJson`/`eventFromJson` round-trip across *all* `EventBody` constructors.
- **Untested critical branches:** the C2 symlink escape and C3 catalog-edit
  resume-invalidation both lack coverage and are exactly the kind of guarantee a
  regression test should pin. Also worth a test: an unexpected exception mid-run
  (D5) and the resulting `run.json` phase.
- `docs/STATUS.md:59` vs `Executor.runWorkflow` scope handling (D4) — doc and
  code disagree; reconcile.
- `Hwfi/Runtime/Workspace.hs` header symlink claim (C2) is actively misleading.
