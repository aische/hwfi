---
name: skills/react-patterns-guide
skill:
  kind: instruction
  summary: React component structure, hooks, and testing hints
  tags: [react, typescript, frontend, vite]
---

# React patterns guide

Load alongside `skills/typescript-vite-guide` when the spec mentions React.

## Structure

- One component per file under `src/components/` when the app grows.
- Keep `App.tsx` as the composition root; lift state only when multiple siblings need it.
- Co-locate small helpers next to the component that uses them.

## Hooks

- `useState` for local UI state; `useEffect` for subscriptions and persistence side effects.
- `useMemo` / `useCallback` only when profiling shows unnecessary re-renders.
- Custom hooks (`useTodos`, etc.) when logic is reused or `App` grows past ~80 lines.

## localStorage persistence

- Serialize JSON on change; parse in `useState` lazy initializer.
- Guard `typeof window !== "undefined"` if SSR is ever added (not needed for Vite SPA).

## Verification

- `npm run build` after component changes.
- Manual smoke: mount root with `npm run dev` is optional; prefer `build` in CI-style checks.

## Testing hints

- When tests are requested: Vitest + `@testing-library/react` pair well with Vite.
- Test behaviour (clicks, rendered text), not implementation details.
