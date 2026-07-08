# Haskell Codebase Review — hwfi

Review date: 2026-07-08. **Reconciled:** 2026-07-09.

Scope: `src/`, `app/`, `hwfi.cabal`. H1 fixes (C1–C3, D4, D5) are implemented and
pinned by regression tests — see [h1-verification.md](h1-verification.md).

## 1. Summary (current)

The codebase is in good shape for v1. Checker phasing, Merkle fingerprints,
secret redaction, and resumable tracing are solid. **H1 runtime hardening is
complete** (threaded RTS, symlink containment, model-catalog step-key
invalidation, sub-workflow scope threading, deliberate crash path).

Remaining work is **perf polish** (quadratic `ctx.trace` rebuild, directory walk),
**agent redaction semantics** (D3), minor nits, and optional property tests —
not correctness blockers for the gap list discussed in chat.

## 2. Critical issues — fixed (H1)

### C1. No `-threaded` RTS — **fixed (H1.1)**

`hwfi.cabal` adds `-threaded -rtsopts "-with-rtsopts=-N"` to executable and
test-suite.

### C2. Symlink sandbox escape — **fixed (H1.2)**

`resolveContainedPath` canonicalises and verifies prefix ⊆ workspace root.
Tests: `WorkspaceSpec` → `symlink containment`.

### C3. Model-catalog change not invalidating one-shot LLM cache — **fixed (H1.3)**

`stepKeyFor` folds `oneShotLlmCtxProjection` / `modelCatalogFingerprint` into
step-keys for one-shot LLM builtins. Tests: `GatewaysSpec`, `ExecutorSpec` →
`Model-catalog invalidation`.

## 3. Design / architecture — status

### D1. Quadratic `ctx.trace` reconstruction — **open (perf)**

`buildCtx` still materialises full trace per step. Deferred in spec §14; address
when long agent runs hurt.

### D2. Quadratic directory walk — **open (perf)**

`walkEntries` left-nested `(<>)`; deferred in spec §14.

### D3. Agent tool results cached redacted — **open (design)**

Model receives redacted JSON from tool cache; may be intentional (§5.5). Document
at call site or cache real value and redact trace only.

### D4. Sub-workflow scope reset — **fixed (H1.4)**

`runWorkflow` threads caller `scope`. Tests: `ControlFlowSpec` →
`sub-workflow scope threading`.

### D5. No crash handler — **fixed (H1.5)**

`guardedFinish` / `finishCrash` emit `internal` + `run-end` `crashed` +
`PhaseCrashed`. Tests: `ExecutorSpec` → `Crash handling`.

### D6. Partial functions — **open (minor)**

`head` on cycle SCC, `hexDigit !!`, `bareIdent ""` fallback, `!!` in accessor —
low priority cleanups.

### D7. `read-file-slice` re-reads whole file — **open (acceptable v1)**

Bounded by read cap; streaming reader deferred.

## 4. Minor issues / nits — **open**

- `Hwfi.Cli` stale Haddock (“stubs not implemented”)
- ULID comment vs timestamp+random run ids
- `fileOpFromText` silent fallback to `OpList`
- `toTurn` lossy tool role mapping (documented)
- `renderDouble` canonicalisation edge cases
- `read-file-slice` newline round-trip
- Agent step-key computed twice in `execStep`

## 5. What's working well

- Lazy Merkle fingerprint knot (`Hwfi.Check.Graph`)
- Uniform secret redaction at observable boundaries
- `MVar`-serialised trace `emit` under `par`
- Four-phase checker with accumulated errors
- Atomic run-store writes

## 6. Testing

H1-critical branches now have regression coverage (see
[h1-verification.md](h1-verification.md)). Still desirable:

- QuickCheck: `canonicalJson`, step-key stability, glob, trace round-trip
- Explicit test for D3 agent redaction semantics (if behaviour is pinned)
