---
name: workflows/main
inputs:
  doc: FileRef
  docs_dir: FileRef
  schema: Json
outputs:
  digest: String
  report_path: String
imports:
  - builtin/list-dir
  - builtin/read-file
  - builtin/write-file
  - builtin/llm-generate
  - tools/authorize
  - tools/headline
  - workflows/extract
  - workflows/critique
  - workflows/audit
---

## summariser

You are a precise research summariser. Given a document and some structured
metadata about it, produce a single, well-organised paragraph that a busy
engineer could read in thirty seconds. No preamble, no bullet points, no
headings — just the paragraph.

## flow

The orchestrator. It threads together nearly every engine feature:

1. `tools/authorize` gates the run on a `Secret<String>` token read from
   `ctx.env` (spec §5.5, redacted in the trace, A8).
2. `builtin/list-dir` enumerates the corpus directory (spec §6).
3. `builtin/read-file` loads the target document.
4. `workflows/extract` calls `builtin/llm-gen-object` to derive structured JSON
   metadata under the caller-supplied `schema` (A6, sub-workflow nesting).
5. `tools/headline` renders a headline from a `types/doc-brief` record built
   inline with record and list literals.
6. `builtin/llm-generate` writes the summary paragraph, using the `@self#summariser`
   prompt (spec §3.2, §5.6.4) and interpolating structured values.
7. `workflows/critique` refines the draft over a multi-turn `builtin/llm-chat`
   exchange (A16).
8. `builtin/write-file` persists the digest.
9. `workflows/audit` records an introspection + trace snapshot in
   non-cacheable steps (A7).

```step
-- 1. Secret-gated authorization. The token is Secret<String>; it is passed to a
--    Secret<_> parameter and never interpolated, so it cannot leak.
_ <- tools/authorize(token = ${ctx.env.RESEARCH_API_TOKEN}) @auth

-- 2. Enumerate the corpus directory (FileRef -> { entries: List<String> }).
listing <- builtin/list-dir(path = ${inputs.docs_dir})

-- 3. Read the target document.
contents <- builtin/read-file(path = ${inputs.doc})

-- 4. Extract structured metadata as Json via a sub-workflow (gen-object).
meta <- workflows/extract(text = ${contents.text}, schema = ${inputs.schema}) @extract

-- 5. Build a typed doc-brief record inline and render a headline.
head <- tools/headline(
  brief = {
    title      = "${inputs.doc}",
    audience   = ${ctx.env.RESEARCHER_NAME},
    key_points = ["overview", "key claims", "open questions"]
  }
)

-- 6. Summarise. @self#summariser is the system prompt; the prompt interpolates a
--    String, a Json value (meta.brief), and another String.
summary <- builtin/llm-generate(
  system = @self#summariser,
  prompt = """Researcher: ${ctx.env.RESEARCHER_NAME}
Headline: ${head.line}
Extracted metadata (JSON): ${meta.brief}

Summarise the following document in one paragraph:

${contents.text}""",
  model = "fast"
) @summary

-- 7. Refine the draft through a multi-turn chat sub-workflow.
crit <- workflows/critique(draft = ${summary.text}, topic = "${inputs.doc}") @critique

-- 8. Persist the digest as markdown, interpolating the directory listing too.
_ <- builtin/write-file(
  path = "digest.md",
  text = """# Research digest

${head.line}

Corpus files: ${listing.entries}

## Draft summary

${summary.text}

## Refined summary

${crit.refined}
"""
) @writedigest

-- 9. Write an audit trail (non-cacheable observation steps).
_ <- workflows/audit(label = "research-digest") @audit

return { digest = ${crit.refined}, report_path = "digest.md" }
```
