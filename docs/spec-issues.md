### High Severity (Architectural / Logic Gaps)

**1. Cache Invalidation on Code Changes (Spec §8.1)**
The step-key hash is defined as `hash(qname, step-id, resolved-args, ctx-projection)`. Notice that this hash **does not include the AST or content hash of the tool/sub-workflow being called**. 
* **The issue:** If the user executes a run, aborts it, edits the markdown logic of a sub-workflow or tool, and then runs `hwfi resume`, the runtime will see matching `(qname, step-id, resolved-args)` and treat the step as a cache hit. It will skip the execution, completely ignoring the new code changes.
* **Fix suggestion:** The step-key hash needs to include a content hash of the target declaration (the sub-workflow/tool being invoked).

**2. Missing Env Vars & Type System Nullability (Spec §5.1, §7.2)**
`project.json` defines an `env` whitelist which determines the shape of `ctx.env`. 
* **The issue:** What happens if a whitelisted environment variable is *missing* from the host environment at runtime? The type system lacks an `Option<T>` or union type (like `String | Null`), though `null` is a valid literal. 
* **Fix suggestion:** You need to explicitly define whether a missing whitelisted variable crashes the run at startup (strict mode), or if it resolves to `null`. If it resolves to `null`, `hwfi check` cannot statically guarantee that string operations won't fail at runtime unless you introduce an `Optional<String>` type.

**3. Grammar Bug in `TypeExpr` (Spec §3.4)**
* **The issue:** The EBNF for `TypeExpr` lacks a production rule for referencing your custom type aliases. It lists `String`, `Int`, `Record`, etc., but nowhere does it allow `QName` or `Ident` to reference aliases like `types/message` (which is explicitly allowed in §2.1).
* **Fix suggestion:** Add `| QName` to the `TypeExpr` production in the EBNF.

**4. Multi-turn Chat History in LLM Tools (Spec §6)**
* **The issue:** `builtin/llm-generate` takes `{ system: String, prompt: String, model: String }`. There is no way to pass an array of prior messages (chat history), which is essential for multi-turn agentic loops. While a user could format the whole trace into a single string `prompt`, this is clunky and bypasses `llm-simple`'s native multi-message capabilities.
* **Fix suggestion:** Consider adding a `messages: List<Record<{role: String, content: String}>>` argument, or a specific `builtin/llm-chat` tool.

### Medium Severity (Edge Cases)

**5. String Interpolation of Complex Types (Spec §3.2)**
* **The issue:** What happens if a user writes `"Result is ${ctx.inputs}"` where `ctx.inputs` is a `Json` object or a `List`? The type-checker rules (§5.6.3) say "its type must match the target position", implying it might expect exactly a `String` inside `${}`. Since v1 has no casting functions, this would lead to a strict type error making it very difficult to log or format JSON values into strings.
* **Fix suggestion:** Explicitly define that interpolation implicitly stringifies/JSON-encodes non-string types, OR provide a built-in tool/function to cast `Json` to `String`.

**6. `ctx.trace` Shape on Resume (Spec §8.3.3.4)**
* **The issue:** When a run is resumed, skipped steps emit `StepStart` and `StepEnd (cached=true)` to the append-only `trace.jsonl`. However, they *do not* emit the `LlmCall` or `FileIo` events that were emitted during their original run. If a downstream step reads `ctx.trace` to learn what happened, the history it sees will look drastically different depending on whether the upstream steps were freshly executed or skipped via cache.
* **Fix suggestion:** Clarify how `ctx.trace` is constructed on resume. Ideally, `ctx.trace` should be rebuilt by loading the original events from `trace.jsonl` rather than just the synthetic "cache skipped" events, so that the workflow logic doesn't break depending on caching.

**7. Array Out of Bounds / Missing Field Errors**
* **The issue:** Because v1 lacks `if` statements or length checks (§3.2, §4), doing `ctx.trace[0]` when the trace is empty, or accessing `inputs.optional_field` when it doesn't exist, will cause a runtime evaluation error.
* **Fix suggestion:** Spec §8.3.2 lists `Error` kinds (`"type"`, `"io"`, `"sandbox"`, `"llm"`, `"user"`, `"internal"`). You should explicitly define an `"eval"` or `"runtime"` error kind for expression evaluation failures (like out-of-bounds or missing record fields).

### Minor Nitpicks

* **YAML vs DSL Syntax:** Spec §3.4 uses colons for types in records (`Record<{ Ident : TypeExpr }>`) but the step DSL uses equals for values (`{ Field = Expr }`). This is a standard programming language convention (types use `:`, values use `=`), just making sure it's intentional so the megaparsec parsers don't get mixed up.
* **Implicit Returns:** Spec §5.6.5 says the last step's bind is the return value if there's no explicit `return`. Because tools like `builtin/llm-generate` return a `Record<{ text: String }>`, a workflow that declares an output of `summary: String` will *always* require an explicit `return { summary = ${res.text} }`. The implicit return is mostly useless unless the last tool's output shape perfectly mirrors the workflow's output shape.

Are you happy to proceed with M1, or would you like to tweak the specs for any of these issues first? (Since you have Ask Mode active, let me know how you'd like to proceed or if you'd like me to draft specific fixes for the markdown!)