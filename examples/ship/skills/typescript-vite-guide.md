---
name: skills/typescript-vite-guide
skill:
  kind: instruction
  summary: Scaffold and build a TypeScript + Vite project
  tags: [typescript, vite, npm, frontend]
---

# TypeScript + Vite guide

Use this stack when the spec calls for Vite, TypeScript, or a modern SPA scaffold.

## Scaffold

1. From the empty workspace root, run:
   `npm create vite@latest . -- --template vanilla-ts` (or `react-ts` when React is requested).
2. Run `npm install`.
3. Keep source under `src/`; entry `index.html` at the project root.

## Conventions

- `npm run dev` is for **local human use only** — do not run it inside `builtin/exec`.
- `npm run build` produces `dist/`; use it for automated verification.
- `npm run preview` is also long-running — avoid in agent `exec` unless using a trap/kill wrapper.

## Verification inside `builtin/exec`

**Always prefer foreground checks:**

```text
cd <app-dir> && npm run build
test -f <app-dir>/dist/index.html
grep -qi todo <app-dir>/dist/index.html   # when appropriate
```

**Never** put these in `verify_command` or agent `exec`:

- `npm run dev & ...`
- `kill %1` (unreliable in non-interactive `sh`)
- unbounded `vite` / `vite preview` without cleanup

If HTTP smoke is explicitly required, call **`tools/vite-dev-smoke`** once (trap + `$!` cleanup).

## Discover hint

Use `discover-skills(query = "vite", kinds = [], limit = 5)` to find this guide.
