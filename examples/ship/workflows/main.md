---
name: workflows/main
inputs:
  spec: String
outputs:
  summary: String
  report_path: String
  goal: String
imports:
  - builtin/log
  - builtin/json-get
  - builtin/concat
  - builtin/write-file
  - tools/plan-tasks
  - tools/task-line
  - workflows/plan
  - workflows/build
  - workflows/review
  - workflows/audit
---

## flow

Universal coding-agent orchestrator: plan → per-task build → review → audit →
`ship-report.md`.

```step
_ <- builtin/log(
  message = "ship run started (run ${ctx.run.id})",
  fields = null
) @startlog

plan <- workflows/plan(spec = ${inputs.spec}) @plan

goal <- builtin/json-get(json = ${plan.plan}, path = "goal") @goal
stack <- builtin/json-get(json = ${plan.plan}, path = "stack") @stack
stack_text <- builtin/concat(parts = ["${stack.value}"]) @stacktext
_ <- builtin/log(
  message = "plan ready: ${goal.value} (stack: ${stack_text.text})",
  fields = null
) @planlog

task_list <- tools/plan-tasks(plan = ${plan.plan}) @tasks

rows <- foreach task in ${task_list.tasks} {
  _ <- builtin/log(message = "task start: ${task}", fields = null) @tlog
  head <- tools/task-line(task = ${task})
  built <- workflows/build(
    spec = ${inputs.spec},
    stack = ${stack_text.text},
    task = ${task}
  ) @build
  line <- builtin/concat(
    parts = [${head.line}, " — ", ${built.answer}]
  ) @row
} @buildloop

notes <- builtin/concat(
  parts = ["Task results:\n", "${rows}"]
) @notes

review <- workflows/review(
  spec = ${inputs.spec},
  plan = ${plan.plan},
  notes = ${notes.text}
) @review

_ <- builtin/write-file(
  path = "ship-report.md",
  text = """# Ship report

## Spec

${inputs.spec}

## Plan (JSON)

${plan.plan}

## Task notes

${notes.text}

## Review

${review.summary}
"""
) @report

_ <- workflows/audit(label = "ship") @audit

return {
  summary = ${review.summary},
  report_path = "ship-report.md",
  goal = "${goal.value}"
}
```
