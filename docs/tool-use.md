# LLM tool-use (agentic function calling)

Status: **goal / not implemented.** This document describes a feature we
want and an analysis of what it would take. It is a design note, not a spec
change yet. The current spec lists the closest version of this ("dynamic
workflow synthesis by agents") as deferred to v1.1+ (spec §13).

A working reference for the design exists at `../llm-workflow`; §3 distills
what to borrow from it and where hwfi must differ.

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
  `builtin/*`). When the model emits a tool call, the engine runs that
  tool/sub-workflow through the normal executor, gets a typed result, and
  feeds it back to the model as a tool message.
- The loop runs until the model stops calling tools (or a round cap is
  hit), and the step returns the model's final output.

The design constraint that makes this interesting: the tools the model can
call are **the project's own declarations**, so a prompt-authored workflow
can expose e.g. `tools/search` and `workflows/extract` to a model and let
the model decide when to use them.

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

`grTools :: [ToolDef]` is the field that advertises callable functions to a
provider. It is always `[]`.

### 2.2 The engine uses the non-agentic generation path

The builtins call `LLM.Generate.generateTextWithFallbacks` /
`genObjectUntyped`. That layer *surfaces* provider tool calls as a stream
chunk (`StreamToolCallChunk`) but does **not** execute them. The
tool-execution loop lives in `LLM.Agent`, which `hwfi` does not import. So
even if `grTools` were populated, nothing would dispatch the resulting
calls or feed results back.

### 2.3 `llm-simple` already has a tool abstraction and a loop

`llm-simple` provides the provider side: `LLM.Agent.Generate.agentLoop`
(round-based tool loop), `LLM.Agent.Types.Tool` (a `ToolDef` paired with an
executor), and a suite of ready-made FS tools in `LLM.Tools.*` with an
`FsConfig` sandbox. hwfi does **not** want to hand the model those FS tools
directly — they bypass hwfi's sandboxed `Workspace`, its `file-io` trace
events, and its `RValue` typing. The `Tool`/`ToolMap` abstraction is the
right shape to plug into; the concrete FS tools are not what we expose.

## 3. Prior art: `../llm-workflow`

`../llm-workflow` is a sibling library that already implements
"tools that call workflows" on top of `llm-simple`. It is **not**
persisted or resumable and leans on `unsafeCoerce`, so it is not a drop-in,
but its *control-flow architecture* is directly applicable and resolves
several of the open questions below. The transferable ideas:

### 3.1 One evaluator for prompts, tools, and workflows

The whole thing is a single defunctionalized CEK-style machine
(`src/LLM/Workflow/Workflow.hs`): a `Stack = Stack Usage (Step o) (Kont o r)`
driven by `loop`/`eval`. "Run an LLM turn", "run a tool", "run a
sub-workflow", "loop", "parallel + merge", "catch" are **all uniform
steps** in the same machine — there is no separate recursive agent loop.

```98:114:../llm-workflow/src/LLM/Workflow/Types.hs
data Workflow i o where
  WPrompt :: AgentWithModels -> Maybe CID -> Workflow PromptArgs Final
  WObject :: (GeneratableObject a) => AgentWithModels -> Workflow PromptArgs a
  WAgentSubmit :: ... -> Text -> AgentWithModels -> Maybe CID -> Workflow PromptArgs a
  WSeq :: Workflow i x -> Workflow y o -> TranscriptPolicy x y -> Workflow i o
  WPar :: Workflow i x -> Workflow i y -> MergePolicy x y o -> Workflow i o
  WLift :: (i -> IO o) -> Workflow i o
  WLiftW :: (i -> IO (Workflow i' o)) -> Workflow (i, i') o
  WMap :: Workflow i o -> TranscriptPolicy o o' -> Workflow i o'
  WLoop :: Int -> Workflow i o -> TranscriptPolicy o i -> [CID] -> Workflow i o
  WLoopWhile :: ... -> Workflow i o
  WCatch :: o -> Workflow i o -> Workflow i o
```

**Lesson for hwfi:** don't bolt an agent loop onto a separate code path.
hwfi's next milestone is control flow (`if`/`foreach`/`par`, spec §13); the
agent tool loop is the *same kind of thing* and should share one evaluator.
This argues against my earlier "recursive loop inside a `builtin/llm-agent`
with a dispatch callback" sketch — see §4.

### 3.2 Tools return a *description* of what to run, not a side effect

The pivotal abstraction is `ToolOutcome`. A tool executor does not run a
workflow itself; it **returns a value telling the engine what to do**:

```18:22:../llm-workflow/src/LLM/Workflow/Types.hs
data ToolOutcome
  = ToolReply Text
  | ToolWorkflow (Workflow PromptArgs Text) PromptArgs
  | ToolYield Value
```

When a tool call yields `ToolWorkflow wf args`, the machine pushes
`RunWorkflow wf args` and, when it finishes, threads the result back as the
tool result via the `KTool` continuation:

```196:205:../llm-workflow/src/LLM/Workflow/Workflow.hs
    RunTool pending _assistantTurn toolCall -> do
      ...
      result <- executeTool rt.rtHooks ctx tools toolCall
      case result of
        ToolWorkflow workflow args -> do
          pure $ Stack uAcc (RunWorkflow workflow args) konts
        ToolReply text -> do
          pure $ Stack uAcc (RunReturn text) konts
```

**Lesson for hwfi:** this is a better answer than a synchronous
"call back into `dispatch`" callback. A model tool call that targets a
hwfi tool/workflow should become a **reified `RunWorkflow`-like step** that
the executor runs under its own tracing/caching, with the sub-workflow's
result fed back to the model. The engine stays in control of every effect;
the tool layer only names what to run.

### 3.3 Typed output via a terminating "submit" tool

This is the mechanism that unifies structured output with tool-calling.
Instead of provider JSON mode, an agent that must return structured data is
given a synthetic `submit_<name>` tool whose parameters *are* the output
schema:

```224:234:../llm-workflow/src/LLM/Workflow/Workflow.hs
      WAgentSubmit @o name agentWithModels mbcid ->
        let ...
            submit = mkSomeSubmit (Proxy @o) name "Submit the final structured result."
            pending = Pending { ..., submitTool = Just submit }
```

The submit tool is special in two ways:

1. **Calling it ends the loop and its arguments become the result.** A
   submit call produces a `ToolYield`; the machine decodes the arguments
   against the output type and `unwindPastTools` discards the remaining
   tool-round continuation, short-circuiting the loop:

```206:213:../llm-workflow/src/LLM/Workflow/Workflow.hs
        ToolYield val ->
          case pending.submitTool of
            Just submit | toolCall.tcName == submit.ssName ->
              case submit.ssDecode val of
                Right decoded ->
                  pure $ Stack uAcc (RunReturn (unsafeCoerce decoded)) (unwindPastTools konts)
                Left err ->
                  pure $ Stack uAcc (RunReturn ("Submit decode error: " <> err)) konts
```

   A decode failure is returned as an ordinary tool reply
   (`"Submit decode error: …"`), so the model can correct itself and call
   submit again — no run abort.

2. **It is mandatory.** `mkSomeSubmit` builds the `ToolDef` from the type's
   `autodocodec` schema and `ssDecode` validates the arguments
   (`src/LLM/Workflow/ToolUtils.hs`); finishing with plain text *without*
   calling submit is a hard error (`submitRequiredError`).

**Lesson for hwfi:** an agent step that must produce a typed record (per its
`rsigOutputs`) should expose a **terminating submit tool** synthesized from
the same `Type -> JSON Schema` translation used for tool parameters (§4.2).
When the model calls it, the engine `coerceFromJson`s the arguments into the
step's typed `RValue` result and stops the loop; a coercion failure is fed
back as a tool message for retry. This gives type-safe agent output while
still letting the agent call tools to gather information first — something
neither `builtin/llm-gen-object` (structured, but no tools) nor a plain
free-text agent can do. In effect `builtin/llm-gen-object` becomes the
degenerate zero-tool case of a submit-terminated agent.

Design choice to settle: whether submit is **mandatory** (agent must call it
to finish, `llm-workflow`'s rule — good when a typed result is required) or
**optional** (agent may finish with free text *or* submit — good when the
step's output is `{ text: String }`). The natural rule for hwfi: derive it
from the step's declared output type — a non-trivial `rsigOutputs` record
implies a mandatory terminating submit tool; a `{ text: String }` output
allows free-text termination.

**Terminating-round semantics.** Because submit ends the loop, a round that
mixes submit with other tool calls is ambiguous: the other calls in that
round would be discarded unrun (`unwindPastTools` throws away the pending
`KTool` frames). We resolve this in two layers:

- *Instruction (soft).* The synthesized submit tool's `toolDescription`
  must state clearly that it ends the task and **must be called on its own,
  never in the same response as other tool calls** — e.g. "Call this only
  when you have everything you need; do not combine it with other tool
  calls in the same turn." Most providers respect this and will emit submit
  as a solitary call.

- *Engine policy (hard), for when a model ignores the instruction.* Decide
  one of: (a) reject the round and feed back a tool message telling the
  model to call submit alone (safest — no side effects run speculatively,
  and it composes with the decode-error retry path); or (b) run the
  non-submit calls in the round first, then submit. Recommended: **(a)**,
  because option (b) executes tool side effects whose results the model
  never sees, which is confusing and can be unsafe for mutating tools.

**Caching/resume.** Submit is just another tool call, so the intra-step
content-addressed caching of §5.2 covers it with no special handling: its
sub-key is `hash(agent-step-key, round, submit-name,
canonical(arguments))`, and on resume a matching submit is served from
cache and the loop terminates identically.

### 3.4 Machine state is inspectable data (the resume lever)

Because the loop is a value (`Stack`/`Kont`), "where am I in the agent
loop" is data, not a Haskell call-stack position. `showKont`, `stackSize`,
`lookupHistory`, `updateHistory`, and `unwindToCatch`
(`src/LLM/Workflow/Utils.hs`) are all ordinary folds over the continuation.

**Lesson for hwfi:** this is exactly what makes a *resumable* agent loop
tractable (§5.2). If the machine state is serialized into the run dir,
resume becomes "reload the stack and keep going" rather than "re-run the
whole loop." Two caveats: (a) `llm-workflow` keeps the stack in memory
only — it does not persist it — so this is architectural inspiration, not
a solved persistence layer; (b) it relies on `unsafeCoerce` because its
continuations are heterogeneously typed GADTs. hwfi is *better* positioned
here: hwfi values are dynamically typed `RValue` with a separate `Type`, so
a continuation stack over `RValue` is homogeneous and can be serialized
without `unsafeCoerce`.

### 3.5 First-class recoverable errors and dynamic workflows

- `WCatch`/`KCatch` + `unwindToCatch` give a first-class error boundary:
  on `RunThrow`, the machine unwinds to the nearest catch frame and
  substitutes a fallback value. This is the recoverable-error boundary that
  §5.4 says an agent loop needs, done as a continuation frame rather than a
  special case.
- `WLiftW :: (i -> IO (Workflow i' o))` computes a workflow at runtime —
  i.e. dynamic workflow synthesis, matching spec §13's `builtin/eval-workflow`.

### 3.6 Tool registry, readonly bit, and the same open questions

Agents declare tools by name (`agTools :: [Text]`), resolved against a
`ToolMap` (`getToolsFromMap`); `ensureAgentTool` injects the submit tool;
`filterReadonlyTools`/`toolReadonly` drop mutating tools in a readonly run.
The design note `../llm-workflow/notes/use-utools.md` works through exactly
the questions we face: hard-fail on unknown tool names, name-collision
policy, a dedicated error type (`GErrUnknownUTool`), and readonly gating.
Its answers (fail hard; registered tool overrides legacy; readonly filters)
are reasonable defaults for hwfi's type-check phase (§5.6).

### 3.7 What `llm-workflow` does *not* solve for us

It has **no persistence, no content-addressed step cache, and no resume** —
those are hwfi's whole point (spec §8). It also builds workflows as
hand-written Haskell GADT values, whereas hwfi workflows are
markdown-defined, type-checked declarations. So we borrow the *evaluator
shape and the `ToolOutcome` indirection*, not the code, and we still owe
the hard work in §5.1–§5.2 ourselves.

## 4. What it would take

The provider mechanics are the easy part. The hard part is making
LLM-chosen, nondeterministic tool calls coexist with hwfi's caching,
resume, tracing, secret-redaction, and type guarantees.

### 4.1 Surface: a new builtin `builtin/llm-agent`

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

The `tools` argument uses hwfi's existing first-class `ToolRef`/`WorkflowRef`
values (`Hwfi.Type.TyToolRef`/`TyWorkflowRef`, resolved to `VRef` at
runtime). The executor's `dispatch` already knows how to call a `VRef`
target:

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

So passing declared tools/workflows to the model as a list of refs is
type-safe and reuses existing dispatch. This is the natural way to say
"the model may call these."

Following §3.1–§3.2, the agent loop should **not** live in `Builtins.hs`
behind a callback. `runBuiltin` only receives a `BuiltinEnv`; a
model-chosen call needs the full `Runtime`. Implement the agent step in the
executor, and model that a chosen tool call produces a reified
"run this ref" step that the executor runs like any nested workflow (so its
`step-start`/`step-end` events nest under the agent step, §8.3.3.6), rather
than an opaque IO callback.

### 4.2 Signature → JSON-schema translation

Each callable ref needs a `ToolDef` whose `toolParameters` is a JSON Schema
for that callee's inputs. We already have the resolved input types:

```31:36:src/Hwfi/TypedProject.hs
data ResolvedSignature = ResolvedSignature
  { rsigInputs :: [(Ident, Type)],
    rsigOutputs :: [(Ident, Type)],
    rsigImports :: [QName]
  }
```

Write a total `Type -> JSON Schema` over hwfi's resolved type vocabulary
(`Hwfi.Type.Type`): `TyString`/`TyInt`/`TyDouble`/`TyBool` → primitives,
`TyList` → array, `TyRecord` → object, `TyFileRef` → string (workspace
path), `TyJson` → unconstrained. Rules:

- `TySecret _` inputs **must not** be exposed to the model (§5.5, A8);
  reject a secret-taking callee as an agent tool at type-check.
- `TyWorkflowRef`/`TyToolRef` inputs can't be model-supplied either.

The same translation drives the mandatory-submit tool of §3.3 when the
agent step must return a typed `rsigOutputs` record.

### 4.3 Model call → typed hwfi call

When the model emits `ToolCall { tcName, tcArguments }`:

1. Resolve `tcName` to one of the advertised refs; unknown names hard-fail
   with a typed error (cf. `../llm-workflow/notes/use-utools.md`).
2. Parse `tcArguments` (a JSON object) into a `Map Ident RValue` using the
   callee's declared input types (`coerceFromJson`, already used to
   reconstruct inputs on resume). A parse/type failure becomes a tool
   result the model can see and retry — **not** a run abort (§5.4).
3. Run the callee through the executor as a nested step (§4.1).
4. Serialize the result `RValue` back to JSON as the tool message content.

### 4.4 Driving the loop

Two options, now informed by §3:

**(a) Reuse `llm-simple`'s `LLM.Agent.agentLoop`.** Fast to stand up, but it
emits its own `GenerateEvent`s (not hwfi `TraceEvent`s), and it is a fixed
recursive loop — it fights the reified-state design that resume needs.

**(b) Build hwfi's own evaluator** in the `../llm-workflow` style: a
step/continuation machine over `RValue`, where an LLM turn, a tool call, and
a sub-workflow are uniform steps, and a model tool call that targets a ref
becomes a `RunWorkflow`-like step. More code, but it (i) keeps trace/cache/
redaction under hwfi's control, (ii) unifies with the M6 control-flow work,
and (iii) makes machine state serializable for resume (§5.2).

Recommendation: **(b)**, explicitly modelled on `../llm-workflow`'s
evaluator but over hwfi's dynamically-typed `RValue` (avoiding the
`unsafeCoerce` that `llm-workflow` needs for its GADT continuations).

## 5. The hard problems

### 5.1 Determinism vs. the step cache

hwfi's caching and resume assume a **statically known call graph**. A
step's identity is its step-key:

```315:322:src/Hwfi/Runtime/Executor.hs
-- | Execute a single step, honouring the step cache (§8.1, §8.2):
--
--   1. evaluate arguments (with the ambient @ctx@ injected);
--   2. if cacheable, compute the step-key and — when resuming — try the cache;
--      a hit binds the reconstructed result and emits /no/ events (§8.3.4);
--   3. otherwise emit @step-start@, dispatch, emit @step-end@, and (if
--      cacheable) persist the result under its step-key.
```

An agent step's behaviour — which tools it calls, in what order, with what
args — is chosen by the model and is **not** a function of the resolved
arguments. So an agent step cannot be a cacheable black box. Either mark
`builtin/llm-agent` non-cacheable (like `builtin/introspect`, spec §6/§8.2),
or design **intra-step caching**: give each model-chosen tool call its own
sub-key and cache tool results individually while the loop as a whole is not
cacheable. `classifyCacheable` needs a rule for the agent builtin either
way.

### 5.2 Resume semantics

Resume replays the trace, skips cacheable steps with a persisted result, and
re-runs non-cacheable steps:

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

If an agent step is merely non-cacheable, resuming after a crash re-runs the
**entire** loop — re-issuing every model call (cost) and re-executing every
tool call (side effects like `builtin/write-file`). Two complementary fixes,
both enabled by §3:

- **Intra-step content-addressed caching.** Give each model call and each
  tool call a deterministic sub-key
  (`hash(agent-step-key, round, tcName, canonical(tcArguments))`) and cache
  results individually — the same idea as `RunStore`'s step cache, one level
  down. On resume, matching model/tool calls are served from cache.
- **Serialized machine state.** Because the loop is reified as a
  step/continuation value (§3.4), the run dir can persist the current
  `Stack`, and resume reloads it. hwfi's `RValue`/`Type` split makes this
  serializable without `unsafeCoerce`. This is the larger change and should
  be its own sub-milestone.

### 5.3 Tracing

New `EventBody` constructors are needed (in `Hwfi.Runtime.Trace`) so
`hwfi show` and `ctx.trace` can represent an agent loop: e.g.
`agent-round-start`, `agent-tool-call` (name + redacted args),
`agent-tool-result`, `agent-round-end`, final answer — plus
`eventToJson`/`eventFromJson`/`renderEvent`. Redaction (§8.3.4, A8) must
apply to tool arguments and results exactly as `redactedJson` applies to
step args today.

### 5.4 Error-handling posture

v1 aborts on the first error (spec §13). An agent loop needs to turn a
failed tool call into a tool message the model can react to and retry —
otherwise one malformed call kills the run. So the agent step introduces a
**localized, recoverable error boundary**. `../llm-workflow` models this
cleanly as a `WCatch`/`KCatch` continuation frame (§3.5); hwfi should adopt
the same first-class approach rather than a special case. We must still
classify which failures are recoverable (bad tool args, tool error result)
vs. fatal (lock lost, provider auth failure).

### 5.5 Sandbox and secrets

- Tools the model calls run through hwfi's sandboxed `Workspace`, so
  path-traversal protection (§7.1) is preserved for free — provided we route
  through the executor and do **not** expose `llm-simple`'s FS tools
  directly.
- `Secret<_>` inputs must never be model-supplied or interpolated (§5.5,
  A8) — enforced at type-check (§4.2).
- A readonly bit on tools/workflows (as `llm-workflow` uses,
  `filterReadonlyTools`) lets a readonly agent run drop mutating tools.
- `builtin/introspect` probably should not be reachable as an agent tool
  (it exposes the whole run to the model's context).

### 5.6 Type-checking the new builtin

`Hwfi.Check.Builtins` and `Hwfi.Check.Graph` (`builtinFingerprint`) must
learn `builtin/llm-agent`, validating that every element of `tools` is a
`ToolRef`/`WorkflowRef` and that no referenced callee takes secrets. Runtime
recursion (model calls A → agent lets A call B → B calls A) is bounded by
the round cap, not the type checker; the existing circular-import check
(spec §12) does not cover model-driven cycles.

## 6. Proposed milestone shape

Ordered so each step is independently testable:

1. **Schema translation** `Type -> JSON Schema`, with secret/ref rejection.
   Pure, unit-testable. Reused for both tool params and submit output.
2. **Evaluator refactor**: express step execution as a reified
   step/continuation machine over `RValue` (modelled on
   `../llm-workflow`), so tools, sub-workflows, and — later — control flow
   share one loop. This is the foundational change.
3. **`builtin/llm-agent`** driving that machine over `LLM.Generate`, with
   model tool calls reified as `RunWorkflow`-style steps; marked
   non-cacheable initially. Type-check + graph fingerprint support.
4. **Terminating submit tool** for typed agent output (§3.3): calling it
   ends the loop and its coerced arguments become the step result; mandatory
   or optional per the step's declared output type. Subsumes
   `builtin/llm-gen-object` as the zero-tool case.
5. **Trace events** for rounds/tool-calls/results, with redaction, plus
   `hwfi show` rendering and `eventFromJson` round-trip.
6. **Intra-step + serialized-state resume** (§5.2). Largest; own
   sub-milestone.
7. **Docs**: promote the relevant part of spec §13 into a real §6 entry and
   an A-series assertion for the loop behaviour.

## 7. Recommendation

Build it, and use `../llm-workflow` as the architectural reference. The
feature fits hwfi's type system cleanly (refs + `dispatch` already exist),
and `llm-workflow` proves the control-flow shape works on top of
`llm-simple`.

Two firm positions, both reinforced by the prior art:

1. **Do not adopt `llm-simple`'s `LLM.Agent` loop or FS tools wholesale.**
   Synthesize `ToolDef`s from hwfi signatures, and route every model-chosen
   call back through `Hwfi.Runtime.Executor`. The FS tools bypass hwfi's
   sandbox/trace/typing; the fixed recursive loop bypasses the reified
   state that resume needs.
2. **Build one evaluator, not a bolted-on loop.** Model step execution as a
   defunctionalized step/continuation machine over `RValue`, exactly as
   `../llm-workflow` does over its `Final`/`PromptArgs` types — but without
   `unsafeCoerce`, since hwfi values are already dynamically typed. Then the
   agent tool loop, sub-workflow calls, and the M6 control-flow constructs
   (`if`/`foreach`/`par`) are one mechanism.

The genuine cost is **not** the loop — `llm-workflow` shows it is small. It
is (a) reconciling nondeterministic model-driven calls with hwfi's
deterministic caching/resume contract (§5.1–§5.2), which `llm-workflow`
does *not* solve because it has no persistence, and (b) making the reified
machine state serializable for resume. Settle those two before writing code.
