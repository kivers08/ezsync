---
paths:
  - "packages/db/schema/**/*.ts"
  - "packages/db/migrations/**/*.sql"
  - "packages/db/drizzle.config.ts"
---

# DB & Migration Conventions (Drizzle + Postgres)

**Schema is defined in TypeScript** under `packages/db/schema/` — that is the source of
truth. Migrations are **generated** from it, not hand-numbered.

- **Workflow:** edit the Drizzle schema → `npx drizzle-kit generate` → **review the emitted
  SQL** in `packages/db/migrations/` → `npx drizzle-kit migrate` to apply. Never hand-edit
  generated SQL except to add a guarded data backfill or an RLS policy drizzle-kit didn't
  emit (see below), and say so in the PR.
- **Forward-only:** no down-migrations. Migrations only move forward. drizzle-kit owns the
  ordering + journal (`packages/db/migrations/meta/`) — do not renumber files by hand.
- **Every tenant-scoped table:**
  - has a `tenant_id` column (FK → `tenants.id`),
  - has an index leading with `tenant_id` for the common access paths,
  - has a **Row-Level Security policy** enabled (`ENABLE ROW LEVEL SECURITY` + a policy
    keyed on `current_setting('app.tenant_id')`). If drizzle-kit doesn't emit the policy,
    add it in the generated migration and keep a matching `.sql` snippet in
    `packages/db/schema/` notes so it isn't lost on the next generate.
- **Money columns:** `numeric(precision, scale)` (never `float`/`double`). They round-trip
  as strings — pair with decimal.js in app code (`js-code-conventions`).
- **Timestamps:** `timestamptz`, default `now()` where appropriate. Use Postgres triggers
  or app-set values for `updated_at`.
- **Idempotent upserts:** use `ON CONFLICT ... DO NOTHING/UPDATE` (Drizzle
  `.onConflictDoNothing()/.onConflictDoUpdate()`), not application-level check-then-insert.
- **Destructive changes** (dropping tables/columns) require a `-- BACKUP RECOMMENDED:`
  comment in the migration stating what data is at risk, and a `pg_dump` before deploy.
- Full convention detail: the `write-db-migration` skill. For the repository-layer half of
  a schema change (tenant-scoped queries, transactions): the `add-repository` skill.
