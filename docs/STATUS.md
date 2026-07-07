# Status

Last updated: 2026-07-07

## Current focus

**M6 (LLM tool-use) is complete.** `builtin/llm-agent` and
`builtin/llm-agent-object` drive an agentic tool-use loop: within one
step the model is advertised the project's own eligible tools/workflows
and autonomously issues tool calls until it yields a final answer
(free-text) or calls the terminating `submit` tool (typed output). The
agent step is a non-cacheable black box, but every model round and tool
call inside it is content-addressed and reused on resume (§8.2.1). Ready
to start **M7** (control flow), which reuses the same loop shape.

## Done recently

- `Hwfi.Runtime.Schema`: pure `Type -> JSON Schema` with secret/ref/
  `Bytes` rejection; `ineligibilityReasons` for agent-eligibility (§6.1.1).
- `Hwfi.Runtime.Agent`: the reified round/tool-call state machine over
  `RValue` (modelled on `../llm-workflow`, no `unsafeCoerce`). Model calls
  and tool calls sub-keyed under the agent step-key and cached in
  `RunStore`; `submit` validation, mixed-submit rejection, recoverable vs
  fatal tool errors (§6.1.3–6.1.4).
- `Hwfi.Check.{Builtins,Decl,Check}`: agent builtins registered; bespoke
  `checkAgentCall`/`checkToolElem` (eligible inputs, no `introspect`
  reachability via cycle-safe `reachesIntrospect`); non-cacheable (§8.1).
- `Hwfi.Runtime.Trace`: `agent-round-start/-tool-call/-tool-result/
  -round-end` events + JSON round-trip + `hwfi show` rendering (§8.3).
- `Hwfi.Runtime.Executor`: agent step wired via `runAgentStep` with the
  agent step-key namespacing nested tool steps; `Gateways` gained
  `modelCatalogFingerprint` for the model sub-key.
- `examples/research`: `workflows/investigate` (llm-agent) + `answer`
  (llm-agent-object) advertising read-only `tools/corpus`, `tools/lookup`.
- 152 tests (was 128): schema unit, trace round-trip, A18 check fixtures,
  and an end-to-end agent loop over a fake gateway incl. resume (A17–A21).

## Blockers

- None.

## Notes / decisions

- Scope decision: M6 uses a **dedicated agent-loop** state machine rather
  than refactoring the whole executor into a CEK machine. The general
  control-flow unification is deferred to M7, which provides the second
  consumer that justifies it.
- Tool results are cached as **redacted** JSON: no secrets reach the
  intra-step cache, and a resumed call feeds back the same redacted
  content the model originally saw. (Agent tools returning secrets is an
  accepted rare-case limitation.)
- `AgentRoundStart`/`RoundEnd` are emitted lazily so a resumed round whose
  model + tool calls are all cache hits emits no new events (§8.3.3.7).

## Next up

See [TASKS.md](TASKS.md) → **M7: control flow** (`if`/`foreach`/`par`),
which shares the M6 loop. 6.g (serialise machine state to skip the replay
re-walk) remains an optional performance follow-up.
