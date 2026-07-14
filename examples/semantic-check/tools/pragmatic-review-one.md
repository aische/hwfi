---
name: tools/pragmatic-review-one
inputs:
  item: types/review-gate-item
  schema: Json
outputs:
  findings: List<types/finding>
imports:
  - builtin/concat
  - builtin/llm-gen-object
  - builtin/text-grep
  - tools/empty-findings
  - tools/pragmatic-filter-findings
  - tools/pragmatic-llm-to-findings
  - tools/string-nonempty
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

Run `llm-gen-object` on one gated slice.

```step
peer_block <- try {
  _ <- builtin/text-grep(
    text = ${inputs.item.peer_body},
    pattern = ".+"
  ) @peer_hit

  block <- builtin/concat(
    parts = [
      "\n\n## Peer slice\nLocation: ",
      ${inputs.item.peer_location.file},
      "#",
      ${inputs.item.peer_location.section},
      "\n\n",
      ${inputs.item.peer_body}
    ]
  ) @block

  return { text = ${block.text} }
} catch {
  return { text = "" }
} @peer

prompt <- builtin/concat(
  parts = [
    "## Slice under review\nLocation: ",
    ${inputs.item.location.file},
    "#",
    ${inputs.item.location.section},
    "\n\n",
    ${inputs.item.body},
    ${peer_block.text},
    "\n\n## Review task\n",
    ${inputs.item.review_task},
    "\n\n## Context\n",
    ${inputs.item.context}
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
    location = ${inputs.item.location}
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
