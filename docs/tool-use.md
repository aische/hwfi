# LLM tool-use (agentic function calling)

Status: **goal / not implemented.** This document describes a feature we
want and an analysis of what it would take to build. It is a design note,
not a spec change yet. The current spec explicitly lists the closest
version of this ("dynamic workflow synthesis by agents") as deferred to
v1.1+ (spec §13).

## 1. The goal

Today `hwfi` is a **workflow-driven** engine: the workflow orchestrates and
the LLM is called one-shot per step (`builtin/llm-generate`,
`builtin/llm-chat`, `builtin/llm-gen-object`). The LLM produces text or a
JSON object; it never decides to call anything.

We want an **LLM-driven** mode as well: a step where the model is handed a
set of callable tools and, within that step, autonomously issues tool calls
in a loop until it produces a final answer. Concretely:

- A workflow step advertises a set of tools to the model.
- Each advertised tool is backed by a **hwfi tool or sub-workflow** (or a
  `builtin/*`). When the model emits a tool call, the engine dispatches it
  through the existing executor, gets a typed result, and feeds it back to
  the model as a tool message.
- The loop runs until the model stops calling tools (or a round cap is
  hit), and the step returns the model's final output.

This is the standard agent loop. The important design constraint is that
the tools the model can call are **the project's own declarations** — so a
prompt-authored workflow can expose, say, `tools/search` and
`workflows/extract` to a model and let the model decide when to use them.

Two capabilities are in scope and are currently both **absent** (see the
companion analysis that motivated this doc):

1. **hwfi tools/workflows as LLM tools** — expose declared
   tools/sub-workflows (and builtins) to the model as function-call
   targets.
2. **Reuse of `llm-simple`'s agent loop / FS tools** — decide whether to
   drive the loop with `llm-simple`'s `LLM.Agent` machinery or write our
   own on top of `LLM.Generate`.

## 2. Where we are now

### 2.1 The engine never offers tools to the model

Every LLM request the engine builds hardcodes an empty tool list:

```154:163:src/Hwfi/Runtime/Builtins.hs
genReq :: Text -> [Turn] -> GenRequest
genReq system messages =
  GenRequest
    { grSystemPrompt = if T.null system then Nothing else Just system,
      grMessages = messages,
      grTools = [],
      grAbortSignal = Nothing,
      grLLMHooks = llmHooks defaultDebugHooks,
      grHooks = noHooks
    }
```

`grTools :: [ToolDef]` is exactly the field that advertises callable
functions to a provider. It is always `[]`.

### 2.2 The engine uses the non-agentic generation path

The builtins call `LLM.Generate.generateTextWithFallbacks` /
`genObjectUntyped`. That layer *surfaces* provider tool calls as a stream
chunk (`StreamToolCallChunk`) but does **not** execute them. The
tool-execution loop lives in a different module, `LLM.Agent`
(`agentLoop` in `LLM/Agent/Generate.hs`), which `hwfi` does not import.

So even if `grTools` were populated, nothing would dispatch the resulting
calls or feed results back.

### 2.3 `llm-simple` already has the loop and a tool abstraction

`llm-simple` ships everything needed for the provider side:

- `LLM.Agent.Generate.agentLoop` — the round-based tool loop: call the
  model, read `getToolCalls resp`, if none finish, otherwise
  `executeToolsWithAbort`, append an assistant turn + a `ToolTurn`, and
  recurse up to `agMaxToolRounds`.
- `LLM.Agent.Types.Tool` — a `ToolDef` (name, description, JSON-schema
  parameters, readonly flag) paired with an executor
  `toolExecute :: ToolContext -> Value -> IO result`.
- `LLM.Tools.*` — a full suite of ready-made FS tools
  (`readfileToolTyped`, `writefileToolTyped`, `grepToolTyped`,
  `findFilesToolTyped`, `directoryTreeToolTyped`, …) plus an `FsConfig`
  sandbox.

The key insight is that `hwfi` does **not** want to hand the model
`llm-simple`'s FS tools directly — those bypass hwfi's own sandboxed
`Workspace`, its `file-io` trace events, and its `RValue` typing. Instead
we want to synthesize `ToolDef`s from hwfi declarations and route execution
back through `Hwfi.Runtime.Executor`. `llm-simple`'s `Tool`/`ToolMap`
abstraction is the right shape to plug into; its concrete FS tools are not
what we expose.

## 3. What it would take

The provider mechanics are the easy 20%. The hard 80% is making
LLM-chosen, nondeterministic tool calls coexist with hwfi's caching,
resume, tracing, secret-redaction, and type guarantees. Breakdown below.

### 3.1 A new builtin: `builtin/llm-agent`

Add a builtin alongside the existing LLM tools (spec §6). Rough signature:

```
builtin/llm-agent :
  { system: String,
    prompt: String,               -- or messages: List<{role, content}>
    model: String,
    tools: List<ToolRef<_, _> | WorkflowRef<_, _>>,
    max_rounds: Int }
  -> { text: String, rounds: Int }
```

The important argument is `tools`. The engine already has first-class
`ToolRef`/`WorkflowRef` values (`Hwfi.Type.TyToolRef`/`TyWorkflowRef`,
resolved to `VRef` at runtime), and `dispatch` in the executor already
knows how to call a `VRef` target:

```414:422:src/Hwfi/Runtime/Executor.hs
dispatch rt stepRef bindings target argMap
  | isBareQName target =
      case Map.lookup (bareIdent target) bindings of
        Just (VRef _ realQ) -> dispatchResolved rt stepRef bindings realQ argMap
        Just _ ->
          pure (Left (evalError ("'" <> renderQName target <> "' is not a callable ref value")))
        Nothing ->
          pure (Left (evalError ("call target '" <> renderQName target <> "' is not bound")))
  | otherwise = dispatchResolved rt stepRef bindings target argMap
```

So passing declared tools/workflows to the model as a list of refs fits the
existing type system and dispatch path. This is the natural, type-safe way
to say "the model may call these."

Because `runBuiltin` currently receives only a `BuiltinEnv` (workspace,
models, tracer, step, introspect), the new builtin needs a way to re-enter
the executor to run a chosen tool. That means either:

- threading a `dispatch`-like callback into `BuiltinEnv` (a
  `beCallRef :: QName -> Map Ident RValue -> IO (Either RuntimeError RValue)`),
  or
- implementing `builtin/llm-agent` directly in the executor rather than in
  `Builtins.hs`, since only the executor holds the `Runtime`.

The second is cleaner: the agent builtin is special because it calls back
into workflow execution, so it belongs where `Runtime` lives.

### 3.2 Signature → JSON-schema translation

Each ref the model may call needs a `ToolDef` whose `toolParameters` is a
JSON Schema describing that tool's inputs. We have the resolved input types
already:

```31:36:src/Hwfi/TypedProject.hs
data ResolvedSignature = ResolvedSignature
  { rsigInputs :: [(Ident, Type)],
    rsigOutputs :: [(Ident, Type)],
    rsigImports :: [QName]
  }
```

We need a total function `Type -> JSON Schema` over the resolved type
vocabulary (`Hwfi.Type.Type`): `TyString`, `TyInt`, `TyDouble`, `TyBool`,
`TyJson`, `TyFileRef`, `TyList`, `TyRecord`, etc. Notes:

- `TyFileRef` → `string` (workspace-relative path).
- `TyJson` → unconstrained (`{}`), or better, require the tool author to
  narrow it.
- `TySecret _` inputs **must not** be exposed to the model. A tool that
  takes a secret cannot be an agent tool (the model can't be trusted to
  supply a credential, and it would leak into the prompt). Reject at
  type-check.
- `TyWorkflowRef`/`TyToolRef` inputs likewise can't be model-supplied.

This mirrors what `llm-simple` does with `autodocodec`
(`jsonSchemaVia`), but over hwfi's own `Type`, so we control the mapping
and the redaction rules.

### 3.3 Model call → typed hwfi call

When the model emits a `ToolCall { tcName, tcArguments }`:

1. Resolve `tcName` to one of the advertised refs (reject unknown names —
   `llm-simple`'s loop already returns `"Unknown tool"` for misses, but we
   want a typed error).
2. Parse `tcArguments` (a JSON object) into a `Map Ident RValue` using the
   callee's declared input types (`coerceFromJson`, which we already use to
   reconstruct inputs on resume). A parse/type failure becomes a tool
   result the model can see and retry, **not** a run abort — this is a new
   error-handling posture for the engine (see §4.4).
3. `dispatch` through the executor. The callee runs as a normal nested
   workflow/tool, producing its own `step-start`/`step-end` trace events
   that nest under the agent step (§8.3.3.6).
4. Serialize the result `RValue` back to JSON as the tool message content.

### 3.4 Driving the loop

Two options:

**(a) Reuse `llm-simple`'s `LLM.Agent.agentLoop`.** Build a `ToolMap` whose
`toolExecute` closes over the hwfi dispatch callback, and hand it an
`Agent`. Pros: the round loop, abort handling, round cap, and turn
bookkeeping are already written and tested. Cons: it emits its own
`GenerateEvent`s (not hwfi `TraceEvent`s), its `ToolContext` model differs
from ours, and we'd adapt `RuntimeArgs`/`Hooks`. We'd also import a much
larger surface of `llm-simple` than the curated `Hwfi.Compat` currently
allows (spec §10 keeps the dependency surface deliberately small).

**(b) Write hwfi's own loop over `LLM.Generate`.** Reuse the streaming
tool-call chunks and write a small loop that emits hwfi trace events and
dispatches through the executor. More code, but the loop is short (~40
lines, cf. `agentLoop`) and it keeps trace/caching/redaction fully under
hwfi's control.

Recommendation: **(b)**. The loop is trivial; the value is in hwfi owning
tracing, caching keys, and redaction. Reusing `agentLoop` would fight the
persistence model (§4) more than it saves.

## 4. The hard problems

These are the reasons this is a milestone, not a patch.

### 4.1 Determinism vs. the step cache

hwfi's caching and resume assume a **statically known call graph**. A
step's identity is its step-key:

```315:362:src/Hwfi/Runtime/Executor.hs
-- | Execute a single step, honouring the step cache (§8.1, §8.2):
--
--   1. evaluate arguments (with the ambient @ctx@ injected);
--   2. if cacheable, compute the step-key and — when resuming — try the cache;
--      a hit binds the reconstructed result and emits /no/ events (§8.3.4);
--   3. otherwise emit @step-start@, dispatch, emit @step-end@, and (if
--      cacheable) persist the result under its step-key.
```

The step-key is `hash(qname, step-id, resolved args, stable ctx projection,
callee fingerprint)` (§8.1). An agent step's *behaviour* — which tools it
calls, in what order, with what args — is chosen by the model and is **not**
a function of the resolved arguments. Two runs of the same agent step with
identical inputs can legitimately produce different tool-call sequences.

Consequences:

- **An agent step cannot be cacheable as a black box.** Either mark
  `builtin/llm-agent` non-cacheable (like `builtin/introspect`, which
  "marks the calling step non-cacheable", spec §6 / §8.2), or design a
  sub-step caching scheme where each model-triggered tool call gets its own
  step-key and is individually cacheable while the loop itself is not.
- The classifier `classifyCacheable` (consulted in `execStep`) needs a rule
  for the agent builtin.

### 4.2 Resume semantics

Resume replays the trace and skips cacheable steps with a persisted result;
non-cacheable steps always re-run:

```364:374:src/Hwfi/Runtime/Executor.hs
cacheHit :: Runtime -> Type -> Maybe Text -> IO (Maybe RValue)
cacheHit rt resultTy mKey
  | not (rtResume rt) = pure Nothing
  | otherwise = case mKey of
      Nothing -> pure Nothing
      Just key -> do
        mJson <- lookupCachedResult (rtStore rt) key
        pure (mJson >>= either (const Nothing) Just . coerceFromJson resultTy)
```

If an agent step is non-cacheable, resuming after a crash **re-runs the
entire agent loop from scratch**, re-issuing every model call (cost) and
re-executing every tool call (side effects — e.g. `builtin/write-file`).
For a long agent loop this is expensive and potentially unsafe.

The principled fix is **intra-step caching**: give each model-chosen tool
call a deterministic sub-key (e.g.
`hash(agent-step-key, round-index, tcName, canonical(tcArguments))`) and
cache tool results individually. On resume, the loop replays: model calls
whose *inputs* match are served from cache, tool calls whose sub-key hits
are skipped. This is the same content-addressing idea as `RunStore`'s step
cache, applied one level down. It is real design work and touches
`StepKey`, `RunStore`, and the trace schema.

### 4.3 Tracing

New trace event bodies are needed so `hwfi show` and `ctx.trace` can
represent an agent loop: something like `agent-round-start`,
`agent-tool-call` (name + redacted args), `agent-tool-result`,
`agent-round-end`, and the final answer. `EventBody` (in
`Hwfi.Runtime.Trace`) plus `eventToJson`/`eventFromJson`/`renderEvent` all
need the new constructors. Redaction (§8.3.4, A8) must apply to tool
arguments and results the same way it applies to step args today
(`redactedJson` in `execStep`).

### 4.4 Error handling posture

v1 aborts on the first error ("Control-flow-driven error handling
(`try`/recover) … deferred; v1 aborts on the first error", spec §13). But
an agent loop *needs* to turn a failed tool call into a tool message the
model can react to and retry — otherwise a single malformed tool call kills
the run. So the agent builtin introduces a **localized, recoverable error
boundary** inside an otherwise abort-on-error engine. We must decide which
failures are recoverable (bad tool arguments, tool returning an error
result) vs. fatal (workspace lock lost, provider auth failure). This is a
deliberate, scoped exception to the global policy and should be documented
as such.

### 4.5 Sandbox and secrets

- Tools the model calls still run through hwfi's sandboxed `Workspace`, so
  path-traversal protection (§7.1) is preserved for free — provided we
  route through the executor and do **not** expose `llm-simple`'s FS tools
  directly.
- `Secret<_>` inputs must never be model-supplied or interpolated into the
  prompt (§5.5, A8). Enforced at type-check (§3.2 above): a tool with a
  secret parameter is not eligible as an agent tool.
- The introspection escape hatch (`builtin/introspect`) exposes the whole
  run (redacted). If it were reachable as an agent tool the model could
  pull the entire trace/bindings into its context; probably it should be
  disallowed as an agent tool.

### 4.6 Type-checking the new builtin

`Hwfi.Check.Builtins` and `Hwfi.Check.Graph` (`builtinFingerprint`) must
learn `builtin/llm-agent`, including validating that every element of
`tools` is a `ToolRef`/`WorkflowRef` and that none of the referenced
callees take secrets. The import graph checker already rejects circular
tool imports (spec §12); an agent tool set can reintroduce cycles at
runtime (model calls A which the agent-loop lets call B which calls A), so
a recursion/round cap is the safety net, not the type checker.

## 5. Proposed milestone shape

Ordered so each step is independently testable:

1. **Schema translation** `Type -> JSON Schema`, with secret/ref rejection.
   Pure, unit-testable.
2. **Executor callback** so a builtin can re-enter dispatch
   (`beCallRef`), or move the agent builtin into the executor.
3. **`builtin/llm-agent`** with hwfi's own loop over `LLM.Generate`,
   marked non-cacheable initially. Type-check + graph fingerprint support.
4. **Trace events** for rounds/tool-calls/results, with redaction, plus
   `hwfi show` rendering and `eventFromJson` round-trip.
5. **Intra-step caching** (§4.2): per-tool-call and per-model-call
   sub-keys, so resume doesn't replay a whole loop. This is the largest and
   should be its own sub-milestone.
6. **Docs**: promote the relevant part of spec §13 into a real §6 entry and
   an assertion (A-series) for the loop behaviour.

## 6. Recommendation

The feature is worth building and fits the type system cleanly (refs +
dispatch already exist). The provider loop is small. **Do not** try to
bolt on `llm-simple`'s `LLM.Agent` and FS tools wholesale — that fights the
persistence and redaction model and widens the dependency surface `spec
§10` deliberately keeps narrow. Instead, synthesize `ToolDef`s from hwfi
signatures, drive a thin loop over `LLM.Generate`, and route every
model-chosen call back through `Hwfi.Runtime.Executor`.

The genuine cost is **not** the loop — it is reconciling nondeterministic,
model-driven calls with hwfi's deterministic caching/resume contract
(§4.1–4.2) and introducing a scoped recoverable-error boundary (§4.4).
Those two decisions should be settled before any code is written.
