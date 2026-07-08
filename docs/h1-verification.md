# H1 verification checklist

Maps runtime-hardening items (H1.1–H1.5, [code-issues.md](code-issues.md))
to regression tests. Run:

```bash
cabal test
```

Or target a group:

```bash
cabal test hwfi --test-options='--match "H1"'
cabal test hwfi --test-options='--match "A13|A15"'
```

## H1.1 Threaded RTS (§7.6)

| Check | Test / evidence |
|-------|-----------------|
| Executable built with `-threaded` | `hwfi.cabal` `executable hwfi` and `test-suite` stanzas |
| `par` uses real concurrency | `ControlFlowSpec` par tests; manual: non-threaded RTS would serialise |

**Status:** done (2026-07-08). Build-config check only; no dedicated runtime test.

## H1.2 Symlink sandbox (§7.1)

| Check | Test |
|-------|------|
| `read-file` rejects escape via symlink | `WorkspaceSpec` → `symlink containment` → rejects read-file |
| `write-file` rejects escape via symlink | same → rejects write-file |
| In-workspace symlink allowed | same → allows read-file through in-workspace symlink |

**Status:** done. `resolveContainedPath` canonicalises and checks root prefix.

## H1.3 Model-catalog fingerprint in step-keys (§8.1)

| Check | Test |
|-------|------|
| Fingerprint changes when catalog entry changes | `GatewaysSpec` → `model-catalog fingerprint` |
| One-shot LLM step re-runs on resume after catalog change | `ExecutorSpec` → `Model-catalog invalidation` |
| Agent path already folded catalog fp | `AgentSpec` intra-step caching |

**Status:** done. `stepKeyFor` adds `modelCatalogProj` for one-shot LLM builtins.

## H1.4 Sub-workflow scope threading (§4.1)

| Check | Test |
|-------|------|
| Sub-workflow side effect runs once per `foreach` iteration | `ControlFlowSpec` → `sub-workflow scope threading` |
| Resume does not re-apply per-iteration sub-workflow effects (`foreach`) | same → foreach resume |
| Same for `par` | same → par iteration + par resume |

**Status:** done. `runWorkflow` / `dispatchResolved` thread caller `scope`.

## H1.5 Crash handling (§8.2)

| Check | Test |
|-------|------|
| Unexpected exception → `internal` error + `run-end` `crashed` + `PhaseCrashed` | `ExecutorSpec` → `Crash handling` |
| Crashed run can resume to completion | same → can resume a crashed run |

**Status:** done. `guardedFinish` / `finishCrash` wrap run body with `tryAny`.

## Related cache / resume guarantees (not H1, often confused)

| Concern | Test | Notes |
|---------|------|-------|
| Callee code edit invalidates step cache | `ExecutorSpec` → `Code-edit invalidation (A13)` | Merkle `callee-fingerprint` in step-key |
| `ctx.trace` stable across cache hits on resume | `ExecutorSpec` → `shows cached upstream events (A15)` | Resume preloads `trace.jsonl`; spec §8.3.5 |
| Durable workspace (mutations not re-applied) | `ExecutorSpec` → `Durable-workspace resume (A25)` | |
| `while` decision pinning on resume | `ControlFlowSpec` → A31 | |

## Still open (from code review; not H1)

Tracked in [spec.md](spec.md) §14 deferred hardening and [TASKS.md](TASKS.md):

- O(n²) `ctx.trace` rebuild per step (perf)
- O(n²) `find-files` / `grep` walk (perf)
- Agent tool results redacted before model (D3; document or fix)
- Property tests for step-keys, glob, trace round-trip (nice-to-have)
