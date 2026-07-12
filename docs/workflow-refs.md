# WorkflowRef and ToolRef patterns

First-class `WorkflowRef<In, Out>` and `ToolRef<In, Out>` values (spec §5.1)
let workflows pass **callable references** without hard-coding every callee at
author time. They show up in three main places:

1. **Agent `tools` lists** (§6.1, §6.1.6) — advertise callees to the model.
2. **Workflow inputs** — pass a chosen callee into an orchestrator; step-keys
   incorporate the referenced declaration's fingerprint (§8.1).
3. **Bound ref step targets** — invoke a ref stored under a bind name (§3.1).

Related runtime paths:

- [Agent tools and `submit`](workflow-reference.md#agent-steps) (§6.1)
- [`builtin/eval-workflow`](workflow-reference.md#eval-workflow) for *synthesized*
  source (§6.4) — distinct from first-class refs to existing declarations
- [Skill discover / load](workflow-reference.md#skills) (§6.7) — mid-loop
  callable expansion

Example project: [`examples/workflow-refs`](../examples/workflow-refs).

---

## Static agent tool lists

The most common pattern: list bare qnames where a `ToolRef` / `WorkflowRef` is
expected. Each name resolves to a declaration that passed `hwfi check` and is
**agent-eligible** (no `Secret<_>`, refs, `Bytes`, or transitive
`builtin/introspect` — §6.1.1).

```step
result <- builtin/llm-agent(
  system = @self#agent,
  prompt = ${inputs.question},
  model = "fast",
  tools = [ tools/search, tools/lookup, workflows/summarise ],
  max_rounds = 8
) @answer
```

Sub-workflows in the list run like tools: nested executor step, nested trace,
JSON result back to the model.

See also [`examples/skills-runtime`](../examples/skills-runtime) for
`discover-skills` / `load-skill` in the baseline list.

---

## Runtime-built tool lists

When the toolbox depends on caller input or prior steps, pass any expression
of type `List<ToolRef<_, _> | WorkflowRef<_, _>>` (§6.1.6 phase 2):

```step
result <- builtin/llm-agent(
  system = @self#sys,
  prompt = ${inputs.q},
  model = "fast",
  tools = ${inputs.toolbox},
  max_rounds = 4
)
```

Static eligibility is enforced at `hwfi check` only when the list is a
literal of bare qnames. Fully dynamic lists produce a **check warning** and
enforce eligibility at runtime instead.

Fixture: `test/fixtures/check/agent-runtime-tools`.

---

## Passing refs as workflow inputs

Declare a ref-typed input when an orchestrator should receive a callee without
calling it immediately:

```yaml
inputs:
  handler: WorkflowRef<Record<{ path: FileRef }>, Record<{ text: String }>>
```

A caller passes a bare qname value:

```step
report <- workflows/run-with(
  handler = workflows/extract,
  path = ${inputs.path}
)
```

The ref travels as a value; step-keys hash the **referenced declaration's
fingerprint**, so editing `workflows/extract` busts caches that passed it as an
argument (§8.1).

Use this for routers, test harnesses, and pipelines that delegate to different
implementations without duplicating orchestration logic.

---

## Conditional dispatch

v1 has no expression-level equality on refs. Choose callees with:

### Branch on a flag (`if`)

Pick between **static** step calls or **static** tool lists per branch:

```step
answer <- if ${inputs.useSearch} {
  r <- tools/search(q = ${inputs.q}) @search
  _ <- r
} else {
  r <- tools/lookup(q = ${inputs.q}) @lookup
  _ <- r
} @pick
```

Each branch may also build a different agent toolbox before calling
`builtin/llm-agent` (see `examples/workflow-refs/workflows/conditional-agent`).

### Runtime list assembly

Build `List<ToolRef | WorkflowRef>` from prior steps (discover/load skills,
record literals, etc.) and pass it to `builtin/llm-agent` once — the model
sees the assembled set on the first round.

### `while` with static callees

For iterative refinement, `while` accepts static qnames or `${bind}` when
`bind` is a **top-level** `ToolRef`/`WorkflowRef` bind name (§4.3.1):

```step
results <- while(
  predicate = workflows/check-done,
  predicate_args = { target = ${inputs.target} },
  body = workflows/refine,
  body_args = { target = ${inputs.target} },
  max_iterations = 20
) @loop
```

---

## Invoking a bound ref

A step target may be a **bare bind name** in scope whose type is
`ToolRef`/`WorkflowRef` (§3.1, §5.6.1):

```step
-- `handler` must be bound earlier with a ref type (not a plain record).
out <- handler(path = ${inputs.path}) @run
```

Important scoping rules:

| Position | Works? | Notes |
|----------|--------|-------|
| `tools/search(...)` | Yes | Static qname call |
| `handler(...)` when `handler` is a ref bind | Yes | Dynamic dispatch |
| `${inputs.handler}(...)` | **No** | Step targets are qnames, not expressions |
| `${inputs.handler}` as ref argument | Yes | Passes the ref value |
| `handler = tools/search` in args | Yes | Bare qname → ref value |

To call a ref that arrives via `inputs`, either thread it through ref-typed
workflow parameters and bind it at the call site of a specialized wrapper, or
use static qnames / runtime tool lists instead of higher-order step calls.

---

## `eval-workflow` vs existing refs

| Mechanism | What it references | When to use |
|-----------|-------------------|-------------|
| `ToolRef` / `WorkflowRef` | Declarations that passed `hwfi check` | Known project callees; agent tools; pluggable handlers |
| `builtin/eval-workflow` | Markdown source text at runtime | Model-synthesized workflows (§6.4) |

`eval-workflow` is agent-eligible and returns `{ ok, outputs, errors }` without
aborting the run on check failures — the model can recover. First-class refs
always point at checked declarations.

---

## Checker hints

`hwfi check` emits non-fatal **hints** (stderr) for common ref mistakes
(§13.1.6):

| Mistake | Hint |
|---------|------|
| `search(...)` instead of `tools/search(...)` | Suggests the full qname when the bare name is not a ref bind |
| `text = tools/search` where a `String` was intended | Bare qname is a ref value, not a call — use `result <- tools/search(...)` |
| `tools = [ ${tools/search} ]` in a static list | Static lists want bare qnames; use `[ tools/search ]` or a dynamic `${...}` list |
| Dynamic `tools = ${inputs.toolbox}` | Warning: runtime-only eligibility checking (§6.1.6) |

Fixtures: `test/fixtures/check/ref-hints-*`.

---

## Further reading

- [workflow-reference.md](workflow-reference.md) — step DSL, agent steps, control flow
- [tool-use.md](tool-use.md) — agent loop design
- [caching-and-resume.md](caching-and-resume.md) — fingerprint and ref arguments in step-keys
- [skills-design.md](skills-design.md) — callable skills and `ToolRef` dispatch
