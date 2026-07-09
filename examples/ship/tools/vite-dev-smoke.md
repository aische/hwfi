---
name: tools/vite-dev-smoke
inputs:
  dir: String
outputs:
  exit_code: Int
  stdout: String
imports:
  - builtin/exec
---

## flow

Bounded HTTP smoke test for a Vite app: start `npm run dev` in the background,
curl `127.0.0.1:5173`, then kill the child via `trap EXIT` and `$!` (safe in
non-interactive `sh -c`; do not use `kill %1`).

```step
r <- builtin/exec(
  program = "sh",
  args = [
    "-c",
    "cd ${inputs.dir} && sh -c 'pid=; cleanup() { [ -n \"$pid\" ] && kill \"$pid\" 2>/dev/null; wait \"$pid\" 2>/dev/null; }; trap cleanup EXIT INT TERM; npm run dev >/dev/null 2>&1 & pid=$!; for i in 1 2 3 4 5; do curl -sf http://127.0.0.1:5173/ >/dev/null && break; sleep 1; done; curl -sf http://127.0.0.1:5173/ | grep -qi root'"
  ],
  stdin = "",
  timeout_ms = 30000
)
return { exit_code = ${r.exit_code}, stdout = ${r.stdout} }
```
