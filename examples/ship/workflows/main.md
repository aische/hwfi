---
name: workflows/main
inputs:
  spec: String
  tasks: List<types/task>
  targets: List<String>
  plan_schema: Json
outputs:
  summary: String
  report_path: String
  first_status: Int
imports:
  - builtin/exec
  - builtin/log
  - builtin/json-get
  - builtin/concat
  - builtin/write-file
  - tools/authorize
  - tools/task-line
  - workflows/plan
  - workflows/implement
  - workflows/repair
  - workflows/continue-pred
  - workflows/review
  - workflows/audit
---

## flow

Capstone orchestrator: authorize → plan → per-task implement + `while` repair →
parallel final syntax checks → review → audit.

```step
-- 0. Secret gate + phase log (non-cacheable).
_ <- tools/authorize(token = ${ctx.env.SHIP_API_TOKEN}) @auth
_ <- builtin/log(
  message = "ship run started: ${ctx.env.ENGINEER_NAME} (run ${ctx.run.id})",
  fields = null
) @startlog

-- 1. Structured planning via llm-gen-object.
plan <- workflows/plan(
  spec = ${inputs.spec},
  tasks = ${inputs.tasks},
  schema = ${inputs.plan_schema}
) @plan

goal <- builtin/json-get(json = ${plan.plan}, path = "goal") @goal
_ <- builtin/log(
  message = "plan ready: ${goal.value}",
  fields = null
) @planlog

-- 2. Per-task implement, then capped repair rounds (while + max_iterations).
rows <- foreach task in ${inputs.tasks} {
  _ <- builtin/log(message = "task start: ${task.id}", fields = null) @tlog
  head <- tools/task-line(task = ${task})
  impl <- workflows/implement(task = ${task}) @impl
  _ <- while(
    predicate = workflows/continue-pred,
    predicate_args = {},
    body = workflows/repair,
    body_args = { task = ${task} },
    max_iterations = 2
  ) @repair
  row <- builtin/concat(
    parts = [${head.line}, " — ", ${impl.answer}]
  ) @row
} @tasks

-- 3. Parallel final syntax checks (par preserves input order).
checks <- par(max = 2) target in ${inputs.targets} {
  c <- builtin/exec(
    program = "sh",
    args = ["-n", ${target}],
    stdin = "",
    timeout_ms = 0
  ) @check
} @validate

notes <- builtin/concat(
  parts = [
    "Task results:\n",
    "${rows}",
    "\n\nSyntax checks:\n",
    "${checks}"
  ]
) @notes

-- 4. Multi-turn review and persist the ship report.
review <- workflows/review(
  spec = ${inputs.spec},
  plan = ${plan.plan},
  notes = ${notes.text}
) @review

_ <- builtin/write-file(
  path = "ship-report.md",
  text = """# Ship report

Engineer: ${ctx.env.ENGINEER_NAME}

## Spec

${inputs.spec}

## Plan (JSON)

${plan.plan}

## Notes

${notes.text}

## Review

${review.summary}
"""
) @report

-- 5. Audit trail (non-cacheable).
_ <- workflows/audit(label = "ship") @audit

return {
  summary = ${review.summary},
  report_path = "ship-report.md",
  first_status = ${checks[0].exit_code}
}
```
