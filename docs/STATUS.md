# Status

Last updated: 2026-07-13

## Current focus

**v2 runtime (cursor + frames)** — M4 CLI cutover done. Default `hwfi run` /
`continue` / `resume` use machine snapshots. Next: M5 `ProjectStore` DB backend.
Design: [execution-model.md](execution-model.md).

Legacy v1.1 cache-as-resume `Executor.performRun` remains for direct test/API
use until M6.

## Done recently

- **M4 done** — `Hwfi.Runtime.MachineRun` orchestrates v2 runs with
  `machine.json` snapshots, trace append, workspace lock; CLI `continue` /
  `step` (+ `resume` alias); staleness check on continue; `ConfirmHold` for
  exec gates; `RunResult.rrHalted` for step-batch pauses.
- **M3** — real `par`, cooperative confirm, per-branch snapshots.
- **M2** — agent `CurAgent` stepping; snapshot resume.
- **M1** — sequential `stepMachine`, control flow, `StepEnv`, `runMachine`.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) → **M5** `ProjectStore` + `RunStore` typeclasses; DB backend.
