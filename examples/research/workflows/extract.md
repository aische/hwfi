---
name: workflows/extract
inputs:
  text: String
  schema: Json
outputs:
  brief: Json
imports:
  - builtin/llm-gen-object
---

## extractor

You extract structured metadata from a document. Return only data that is
supported by the text. Be terse. Follow the requested JSON schema exactly.

## flow

Call `builtin/llm-gen-object` (spec §6) to turn free-form document text into a
structured JSON object that conforms to the caller-supplied `schema`. The schema
is a `Json` value threaded in as a workflow input (typically via
`--input schema=@schema.json`), demonstrating structured CLI inputs (spec §9)
and the `Json` type. The `${obj.value}` result is passed back out as a bare
`Json` reference.

```step
obj <- builtin/llm-gen-object(
  system = @self#extractor,
  prompt = "Extract structured metadata from the following document:\n\n${inputs.text}",
  schema = ${inputs.schema},
  model  = "smart"
)
return { brief = ${obj.value} }
```
