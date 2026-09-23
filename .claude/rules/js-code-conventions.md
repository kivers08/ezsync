---
paths:
  - "apps/**/*.ts"
  - "apps/**/*.tsx"
  - "packages/**/*.ts"
  - "scripts/**/*.ts"
---

# TypeScript Code Conventions

- **TypeScript + ESM only**: `import`/`export`, never `require`/`module.exports`. Target
  Node 22, `"type": "module"`.
- **Safe error logging**: in `catch` blocks always log `err.message` (narrow with
  `err instanceof Error ? err.message : String(err)`), never the full error object. Axios
  errors embed the request URL (including API tokens) in `config.url`, which would leak
  credentials to logs.
- **A `catch` must change the outcome**: change what the function returns, release whatever
  the failed work reserved (idempotency slot, lock, claim), or rethrow. A catch that only
  logs and then falls into the success path is a silent failure — treat that shape as a bug
  on sight, including in pre-existing code you are only reading past.
- **Money is never a float**: Postgres `numeric`/`decimal` columns come back from Drizzle as
  **strings**. Do all monetary math with **decimal.js**, and guard nullable inputs with
  `?? 0` — `new Decimal(null)` yields `NaN`, not an error. Never coerce money to a JS
  `number`.
- **Validate at the boundary**: parse all external input (env, webhook bodies, HTTP
  params, third-party API responses you don't control) with **zod**; pass typed data
  inward. Do not trust vendor payload shapes.
- **Multi-tenant scoping**: every query touching tenant data must be `tenant_id`-scoped and
  run under the tenant's RLS context. A query that could read across tenants is a data-leak
  bug — never widen a scope "to make it work."
- **Dates**: prefer `timestamptz` and real `Date` objects; never compare ISO date strings
  with `>`/`<`. Store/compare in UTC.
- **Async**: no floating promises — `await` or explicitly `void` them; unhandled rejections
  in background/sync loops must be caught and logged per-tenant.
