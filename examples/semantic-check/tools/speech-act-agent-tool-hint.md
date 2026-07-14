---
name: tools/speech-act-agent-tool-hint
inputs:
  decl: types/declaration-summary
  step: types/step-summary
  tags: List<types/speech-act-tag>
outputs:
  hints: List<types/speech-act-hint>
imports:
  - tools/empty-speech-act-hints
  - tools/speech-act-decl-has-directive
  - tools/speech-act-is-agent-target
  - tools/string-nonempty
---

## flow

When an agent step advertises tools, agent sections should contain directives.

```step
target <- tools/speech-act-is-agent-target(target = ${inputs.step.target}) @target

pack <- if ${target.ok} {
  inner <- try {
    _ <- tools/string-nonempty(items = ${inputs.step.agent_tools}) @tools

    probe <- tools/speech-act-decl-has-directive(
      decl = ${inputs.decl},
      tags = ${inputs.tags}
    ) @probe

    branch <- if ${probe.ok} {
      empty <- tools/empty-speech-act-hints() @skip
      return { hints = ${empty.hints} }
    } else {
      return {
        hints = [{
          severity = "warning",
          category = "coverage_gap",
          location = { file = ${inputs.decl.path}, section = ${inputs.step.step_id} },
          claim = "Agent step advertises tools but agent sections lack directive language",
          evidence = "tools=${inputs.step.agent_tools}",
          suggestion = "Add imperative guidance in the agent section that names when/how to use the advertised tools",
          force = "directive",
          step_id = ${inputs.step.step_id}
        }]
      }
    } @directives

    return { hints = ${branch.hints} }
  } catch {
    empty <- tools/empty-speech-act-hints() @skip
    return { hints = ${empty.hints} }
  } @probe

  return { hints = ${inner.hints} }
} else {
  empty <- tools/empty-speech-act-hints() @skip
  return { hints = ${empty.hints} }
} @kind

return { hints = ${pack.hints} }
```
