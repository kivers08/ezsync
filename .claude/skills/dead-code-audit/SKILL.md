---
name: dead-code-audit
description: Use before deleting anything flagged by npx knip@5 --production as unused. Encodes knip's known false-positive patterns for this TypeScript monorepo so real exports aren't deleted by mistake. Trigger on "dead code", "knip", "unused export", or "dead-code sweep".
---

# Dead Code Auditing

Standard command: `npx knip@5 --production`

This is an **npm-workspaces monorepo** (`apps/*`, `packages/*`). Run knip from the repo
root so it resolves every workspace and its cross-workspace imports; a per-package run
reports exports consumed by a sibling workspace as dead. If knip needs per-workspace
config, add a `workspaces` block to `knip.json` rather than running it package-by-package.

knip has known false-positive patterns in a TS/ESM codebase — **always cross-reference
every finding with a repo-wide grep before deleting anything**:

| Limitation | What it misses | Example |
|---|---|---|
| Cross-workspace consumers | An export in `packages/shared` or `packages/db` used only by `apps/api`/`apps/web` looks dead from the defining package | shared zod schemas, `APP_NAME`, Drizzle schema tables imported by the API |
| `--production` excludes tests | Exports consumed only by `*.test.ts` files appear dead | test-only helpers, fixtures |
| Dynamic / string-keyed access | `obj[key]` or `import()` of a computed path — the member looks unused | handler/service lookup maps keyed by webhook topic |
| Framework-convention entry points | Files a framework loads by convention, not by an import knip can see | Next.js `app/`/`pages/` route files, drizzle-kit config, worker/CLI entrypoints |
| Re-export barrels | A symbol re-exported through an `index.ts` barrel and consumed elsewhere | `packages/shared/src/index.ts` re-exports |

Grep command to verify before any deletion (repo-wide, covers all workspaces):
`grep -rn "SYMBOL_NAME" apps/ packages/ scripts/`
