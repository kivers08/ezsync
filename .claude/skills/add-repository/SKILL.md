---
name: add-repository
description: Use when adding or modifying a database repository module — a file that wraps Drizzle queries for a specific domain (clients, jobs, invoices, webhooks, subscriptions, etc.). Encodes tenant-scoped queries under RLS, Drizzle-typed selects/inserts, transactions, .onConflictDoUpdate/Nothing idempotency, and decimal.js for money columns. Trigger on any mention of "repository", "DB layer", "database queries", "Drizzle query", or adding CRUD for a new table.
---

# Add a Repository Module

Repositories are **plain async functions** that wrap **Drizzle** queries for one domain.
They live under `apps/api/src/services/<domain>/` (or a shared `packages/db` helper when
truly cross-app), take a `tenantId`, run under the tenant's RLS context, and use named
exports. TypeScript + ESM only — `import` / `export`.

> Adding a new table? Invoke **write-db-migration** first (edit the Drizzle schema, then
> `drizzle-kit generate`). The schema in `packages/db/schema/` is the source of truth.

## Rules

### 1. Every query is tenant-scoped

Tenant data is protected by Postgres Row-Level Security **and** an explicit `tenant_id`
filter — belt and suspenders. A query that could read across tenants is a data-leak bug on
sight; never widen a scope "to make it work."

```ts
import { eq, and } from 'drizzle-orm';
import { db } from '@ezsync/db/client';
import { things } from '@ezsync/db/schema';

export async function getThings(tenantId: string) {
  return db.select().from(things).where(eq(things.tenantId, tenantId));
}

export async function getThingById(tenantId: string, id: string) {
  const rows = await db
    .select()
    .from(things)
    .where(and(eq(things.tenantId, tenantId), eq(things.id, id)))
    .limit(1);
  return rows[0] ?? null; // null for a missing row, never undefined
}
```

RLS is set by the request's `tenantContext` (`SET LOCAL app.tenant_id`); the explicit
`eq(things.tenantId, tenantId)` documents intent and guards code paths outside a request
scope (worker/sync). Never drop it.

### 2. Typed inserts/updates via Drizzle — no raw field spreading

Build the write from an explicit shape, not from `req.body` directly, so callers can't
overwrite `id`/`tenantId`/immutable columns. Drizzle's types catch unknown columns.

```ts
export async function updateThing(
  tenantId: string,
  id: string,
  fields: Partial<Pick<typeof things.$inferInsert, 'name' | 'status' | 'notes'>>,
) {
  if (Object.keys(fields).length === 0) return; // nothing to update
  await db
    .update(things)
    .set({ ...fields, updatedAt: new Date() })
    .where(and(eq(things.tenantId, tenantId), eq(things.id, id)));
}
```

### 3. decimal.js for money columns

`numeric` columns come back from Drizzle as **strings**. Wrap them in `decimal.js` for any
math, and **guard nullable columns with `?? '0'`** — `new Decimal(null)` yields `NaN`, not
an error, which silently corrupts a total.

```ts
import Decimal from 'decimal.js';

const gross = new Decimal(row.amount ?? '0'); // amount is `numeric`, arrives as string
```

Never coerce money to a JS `number`.

### 4. Idempotent upserts — `.onConflictDoNothing` / `.onConflictDoUpdate`

Rely on a `UNIQUE` constraint plus Drizzle's conflict clause instead of check-then-insert.
For a webhook idempotency slot, `onConflictDoNothing` + inspecting the returned rows tells
you whether this caller won the race:

```ts
export async function claimWebhookSlot(tenantId: string, eventId: string, topic: string) {
  const inserted = await db
    .insert(webhookSlots)
    .values({ tenantId, eventId, topic })
    .onConflictDoNothing({
      target: [webhookSlots.tenantId, webhookSlots.eventId, webhookSlots.topic],
    })
    .returning({ id: webhookSlots.id });
  return inserted.length > 0; // true = this caller acquired the slot
}
```

Upsert-on-update variant:

```ts
await db
  .insert(clients)
  .values(row)
  .onConflictDoUpdate({
    target: [clients.tenantId, clients.externalId],
    set: { name: row.name, updatedAt: new Date() },
  });
```

### 5. Transactions via Drizzle

Use `db.transaction` for multi-statement work where partial completion is worse than
failure (financial writes, state transitions). The callback commits on return, rolls back
on throw — thread `tenantId` through every statement.

```ts
export async function reconcile(tenantId: string, id: string) {
  return db.transaction(async (tx) => {
    await tx.insert(ledger).values({ tenantId, /* ... */ });
    await tx
      .update(things)
      .set({ status: 'reconciled' })
      .where(and(eq(things.tenantId, tenantId), eq(things.id, id)));
  });
}
```

### 6. Pagination — cursor, not OFFSET

For unbounded tables, page by an ordered key (still tenant-scoped):

```ts
import { gt, asc } from 'drizzle-orm';

export async function getThingPage(tenantId: string, afterId: string | null, limit = 50) {
  const where = afterId
    ? and(eq(things.tenantId, tenantId), gt(things.id, afterId))
    : eq(things.tenantId, tenantId);
  return db.select().from(things).where(where).orderBy(asc(things.id)).limit(limit);
}
```

## Template

```ts
// apps/api/src/services/thing/thingRepository.ts
import { eq, and, asc } from 'drizzle-orm';
import { db } from '@ezsync/db/client';
import { things } from '@ezsync/db/schema';

export async function getAllThings(tenantId: string) {
  return db
    .select()
    .from(things)
    .where(eq(things.tenantId, tenantId))
    .orderBy(asc(things.createdAt));
}

export async function getThingById(tenantId: string, id: string) {
  const rows = await db
    .select()
    .from(things)
    .where(and(eq(things.tenantId, tenantId), eq(things.id, id)))
    .limit(1);
  return rows[0] ?? null;
}

export async function createThing(tenantId: string, value: typeof things.$inferInsert) {
  const [row] = await db
    .insert(things)
    .values({ ...value, tenantId })
    .returning();
  return row;
}

export async function deleteThing(tenantId: string, id: string) {
  await db.delete(things).where(and(eq(things.tenantId, tenantId), eq(things.id, id)));
}
```

## Before you finish

- If you added a table, confirm **write-db-migration** was run (schema + generated SQL +
  RLS policy).
- Every money column you read is wrapped in `decimal.js` with `?? '0'` on nullable ones.
- Every query filters by `tenantId`; none can read across tenants.
- Add tests: mock the Drizzle client, assert the tenant filter and parameters, test the
  `null` return for a missing row — invoke **write-vitest-test**. Run only that file with
  `npx vitest run <file>`.
