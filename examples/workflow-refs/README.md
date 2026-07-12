# workflow-refs example

Demonstrates [WorkflowRef / ToolRef patterns](../../docs/workflow-refs.md)
without an LLM:

- **Conditional static dispatch** — `workflows/conditional-route` branches on
  `use_search` and calls `tools/search` or `tools/lookup`.
- **Ref as workflow input** — `workflows/pass-handler` accepts
  `handler: WorkflowRef<...>`; the caller passes `handler = tools/search` (bare
  qname value).

## Run

```bash
cabal run hwfi -- check examples/workflow-refs
cabal run hwfi -- run examples/workflow-refs \
  --workspace /tmp/workflow-refs-ws \
  --input q=hello \
  --input use_search=true
```

For agent tool-list patterns (static and `${inputs.toolbox}`), see
[`examples/skills-runtime`](../skills-runtime) and
`test/fixtures/check/agent-runtime-tools`.

## Related docs

- [docs/workflow-refs.md](../../docs/workflow-refs.md)
- [workflow-reference.md](../../docs/workflow-reference.md) — agent steps,
  control flow
