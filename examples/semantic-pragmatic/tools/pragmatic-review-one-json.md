---
name: tools/pragmatic-review-one-json
inputs:
  item: Json
  schema: Json
outputs:
  findings: List<types/finding>
imports:
  - builtin/concat
  - builtin/json-get-string
  - builtin/llm-gen-object
  - builtin/text-grep
  - tools/empty-findings
  - tools/json-get-location
  - tools/pragmatic-filter-findings
  - tools/pragmatic-llm-to-findings
---

## reviewer

You review workflow prose for pragmatic coherence. You receive a slice body and,
for pair reviews, a peer slice body. Selection metadata explains why the slice
was flagged; it is not part of the prose under review.

Rules:
- Judge only text in **Slice under review** and **Peer slice** sections.
- Do not comment on entropy, compression, outliers, or review tooling unless
  those words appear in the slice bodies.
- Felicity violations must cite phrases from the slice bodies.
- Be conservative: only flag issues with evidence in the bodies.
- Return JSON matching the supplied schema exactly.

## flow

Run `llm-gen-object` on one gated slice loaded from a prior check report.

```step
location <- tools/json-get-location(json = ${inputs.item}, path = "location") @loc

body <- builtin/json-get-string(json = ${inputs.item}, path = "body") @body
peer_body <- builtin/json-get-string(json = ${inputs.item}, path = "peer_body") @peer_body
review_task <- builtin/json-get-string(json = ${inputs.item}, path = "review_task") @task
context <- builtin/json-get-string(json = ${inputs.item}, path = "context") @context

peer_block <- try {
  _ <- builtin/text-grep(
    text = ${peer_body.text},
    pattern = ".+"
  ) @peer_hit

  peer_loc <- tools/json-get-location(json = ${inputs.item}, path = "peer_location") @peer_loc

  block <- builtin/concat(
    parts = [
      "\n\n## Peer slice\nLocation: ",
      ${peer_loc.location.file},
      "#",
      ${peer_loc.location.section},
      "\n\n",
      ${peer_body.text}
    ]
  ) @block

  return { text = ${block.text} }
} catch {
  return { text = "" }
} @peer

prompt <- builtin/concat(
  parts = [
    "## Slice under review\nLocation: ",
    ${location.location.file},
    "#",
    ${location.location.section},
    "\n\n",
    ${body.text},
    ${peer_block.text},
    "\n\n## Review task\n",
    ${review_task.text},
    "\n\n## Context\n",
    ${context.text}
  ]
) @prompt

pack <- try {
  obj <- builtin/llm-gen-object(
    system = @self#reviewer,
    prompt = ${prompt.text},
    schema = ${inputs.schema},
    model = "fast"
  ) @llm

  converted <- tools/pragmatic-llm-to-findings(
    value = ${obj.value},
    location = ${location.location}
  ) @findings

  filtered <- tools/pragmatic-filter-findings(
    findings = ${converted.findings}
  ) @filtered

  return { findings = ${filtered.findings} }
} catch {
  empty <- tools/empty-findings() @skip
  return { findings = ${empty.findings} }
} @probe

return { findings = ${pack.findings} }
```
