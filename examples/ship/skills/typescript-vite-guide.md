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

- `npm run dev` for local dev; `npm run build` for production bundle.
- `npm run preview` serves the production build for smoke tests.
- Prefer `tsc --noEmit` or `npm run build` as verification before finishing a task.

## Verification hints

- After scaffold: `npm run build` must exit 0.
- For UI tasks: ensure `dist/index.html` exists after build.
