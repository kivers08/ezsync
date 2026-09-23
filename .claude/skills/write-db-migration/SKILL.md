---
name: write-db-migration
description: Use when adding or changing the database schema — new table, column, index, or alter. Encodes the Drizzle workflow (edit schema in packages/db/schema, drizzle-kit generate, review SQL, drizzle-kit migrate), forward-only migrations, tenant_id + RLS on tenant-scoped tables, and numeric money columns (Postgres + Drizzle).
---

# Write a DB Migration

**Schema is defined in TypeScript** under `packages/db/schema/` — that is the source of
truth. Migrations are **generated** from the schema by drizzle-kit, not hand-numbered. All
migrations are **forward-only** (no down-migrations); drizzle-kit owns ordering and the
journal (`packages/db/migrations/meta/`). Mirror `.claude/rules/db-migrations.md` — this
skill is the full-detail version of that rule.

## Workflow (never skip a step)

1. **Edit the Drizzle schema** in `packages/db/schema/` — add/alter the table, column, or
   index in TypeScript. This is the change you actually author.
2. **Generate:** `npx drizzle-kit generate`. This emits a new SQL file (+ journal entry)
   under `packages/db/migrations/`.
3. **Review the emitted SQL.** Open the generated file and confirm it does exactly what you
   intended — no accidental table drop, correct types, correct nullability. drizzle-kit
   infers from the schema diff; a rename can surface as drop+add, which loses data.
4. **Apply:** `npx drizzle-kit migrate` (idempotent, forward-only). Confirm it applies
   cleanly and that a second run is a no-op.

Never hand-edit generated SQL **except** to add a guarded data backfill or an RLS policy
drizzle-kit didn't emit (see below) — and say so in the PR. Never renumber files by hand.

## Tenant-scoped tables (multi-tenant is non-negotiable)

Every table holding tenant data must have all three:

- a **`tenant_id`** column, FK → `tenants.id` (`notNull`);
- an **index leading with `tenant_id`** for the common access paths;
- **Row-Level Security enabled** with a policy keyed on the request's tenant context.

RLS is enforced at the Postgres level so a query that forgets its scope still can't read
across tenants. If drizzle-kit does not emit the `ENABLE ROW LEVEL SECURITY` + policy
statements, add them by hand to the generated migration and keep a matching `.sql` snippet
noted in `packages/db/schema/` so it isn't lost on the next `generate`.

```sql
-- appended to the generated migration for a tenant-scoped table:
ALTER TABLE things ENABLE ROW LEVEL SECURITY;
CREATE POLICY things_tenant_isolation ON things
  USING (tenant_id = current_setting('app.tenant_id')::uuid);
```

The `tenantContext` middleware sets `app.tenant_id` per request (`SET LOCAL app.tenant_id`);
the policy reads it. See `.claude/rules/js-code-conventions.md` and the `add-repository`
skill for the query side.

## Column conventions

- **Money:** `numeric(precision, scale)` — never `float`/`double`. Drizzle round-trips
  `numeric` as **strings**; pair with decimal.js in app code (never JS floats).
- **Timestamps:** `timestamptz`, `defaultNow()` where appropriate. Use a Postgres trigger
  or an app-set value for `updated_at`.
- **Idempotent upserts:** rely on `ON CONFLICT ... DO NOTHING/UPDATE` (Drizzle
  `.onConflictDoNothing()` / `.onConflictDoUpdate()`) — not application check-then-insert.
- Index every FK and common lookup column.

## Destructive changes

Dropping a table or column requires a `-- BACKUP RECOMMENDED:` comment in the migration
stating what data is at risk, and a `pg_dump` before deploy. A rename that drizzle-kit
emitted as drop+add is a destructive change — treat it as such.

## Template — Drizzle schema (packages/db/schema/things.ts)

```ts
import { pgTable, uuid, text, numeric, timestamp, index, unique } from 'drizzle-orm/pg-core';
import { tenants } from './tenants.js';

export const things = pgTable(
  'things',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    tenantId: uuid('tenant_id')
      .notNull()
      .references(() => tenants.id),
    externalId: text('external_id').notNull(),
    amount: numeric('amount', { precision: 12, scale: 2 }).notNull().default('0'),
    status: text('status').notNull().default('draft'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => ({
    tenantExternal: unique('uq_things_tenant_external').on(t.tenantId, t.externalId),
    tenantIdx: index('idx_things_tenant').on(t.tenantId),
  }),
);
```

Then: `npx drizzle-kit generate` → review the SQL → append the RLS policy if not emitted →
`npx drizzle-kit migrate`.

## Before you finish

- Confirm `npx drizzle-kit migrate` applies cleanly **and** is a no-op on a second run.
- Confirm the tenant-scoped table has `tenant_id`, a `tenant_id`-leading index, and an RLS
  policy in the migration.
- If services or repositories read the new columns, update them and their tests — see the
  `add-repository` and `write-vitest-test` skills.
