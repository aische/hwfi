---
name: workflows/investigate
inputs:
  question: String
outputs:
  answer: String
  rounds: Int
imports:
  - builtin/llm-agent
  - tools/corpus
  - tools/lookup
---

## agent

You are a research agent with access to a small document corpus. Use the
`tools_corpus` tool to see which documents exist, and `tools_lookup` to read one
by name. Investigate the user's question by reading the relevant documents, then
answer it directly in prose. Do not fabricate sources.

## flow

An LLM-driven step (spec §6.1): instead of a fixed script, `builtin/llm-agent`
advertises the two read-only tools above to the model and lets it decide which to
call, and in what order, until it produces a final answer. Every model round and
tool call is content-addressed under this step, so a resumed run replays the same
choices without re-paying the LLM or re-running the tools (spec §8.2.1). The step
is a non-cacheable black box to the enclosing workflow (spec §8.1).

```step
result <- builtin/llm-agent(
  system = @self#agent,
  prompt = ${inputs.question},
  model = "smart",
  tools = [ tools/corpus, tools/lookup ],
  max_rounds = 6
) @investigate
return { answer = ${result.text}, rounds = ${result.rounds} }
```
