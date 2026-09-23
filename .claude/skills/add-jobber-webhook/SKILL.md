---
name: add-jobber-webhook
description: Use when adding or modifying a Jobber webhook handler, topic dispatch entry, or any code that calls the Jobber GraphQL API in a loop (pagination, sync, backfill). Encodes the multi-tenant TOPIC_HANDLERS dispatch table, per-tenant HMAC verification, atomic per-tenant idempotency via claimWebhookSlot, and GraphQL cost-aware adaptive rate-limit retry. Trigger on any mention of "Jobber webhook", "TOPIC_HANDLERS", "claimWebhookSlot", "adaptive delay", or "Jobber GraphQL".
---

# Add a Jobber Webhook Handler

Jobber is a core integration (data source). Webhooks land at
`apps/api/src/routes/webhooks/jobber.ts`, which resolves the tenant from the route, verifies
the signature against **that tenant's** HMAC secret, then dispatches via a `TOPIC_HANDLERS`
table. New topics are added by inserting an entry into the table — no new routes needed.
TypeScript + ESM only. See AGENTS.md → **Jobber** for the canonical integration rules.

> Parsing a Jobber payload? Invoke **api-type-guardian** first. Jobber field names are **not
> yet verified** — confirm every field against live GraphiQL before writing real queries.

## Multi-tenant essentials (vs. the single-tenant middleware)

- **Per-tenant HMAC secret.** Verify `x-jobber-hmac-sha256` over the raw body using the
  signing secret for the tenant resolved from the route — not one global secret.
- **Per-tenant idempotency.** The slot key is `(tenantId, eventId, topic)`. One tenant's
  duplicate can't shadow another tenant's event.
- **Per-tenant rate limits.** Jobber's credit bucket is per tenant, so one tenant's
  throttling must not block others — never share a global backoff.
- **Item id** lives at `req.body.data.webHookEvent.itemId`; topics are present-tense
  (`INVOICE_CREATE`).

## Dispatch table — three modes

```
'await'      Handler runs inline; router awaits it and logs the (tenant-scoped) result.
             onResult(result) may return 'skipped' to override the status.
'delegate'   Handler owns req and res; router does `return await handler(req, res)`.
             DB logging does NOT happen — the handler is fully responsible.
             Only for handlers that need a non-200 response or custom headers.
'background' Fire-and-forget. Router returns 200 immediately; handler runs detached.
             Rejections are caught by onError (default: logger.error).
```

```ts
// TOPIC_HANDLERS entry
const TOPIC_HANDLERS: Record<string, TopicHandler> = {
  INVOICE_CREATE: {
    mode: 'await',
    run: (ctx) => handleInvoiceCreate(ctx),
    onResult: (result) => (result?.processed ? undefined : 'skipped'),
  },
};
```

**Unhandled topics return 200 silently** (no 404 retry loop) — safe to deploy a handler
before the topic starts arriving.

## Idempotency — always use `claimWebhookSlot(tenantId, id, topic)`

Jobber commonly fires several deliveries of the same event within milliseconds. A
check-then-mark pattern loses the race; use the atomic per-tenant claim (Drizzle
`insert(...).onConflictDoNothing(...)` — see the `add-repository` skill).

```ts
import { claimWebhookSlot, releaseWebhookSlot } from '../webhook/webhookRepository.js';

async function handleInvoiceCreate(ctx: { tenantId: string; body: JobberWebhookBody }) {
  const { tenantId, body } = ctx;
  const eventId = body.data?.webHookEvent?.itemId;
  const topic = 'INVOICE_CREATE';
  if (!eventId) {
    logger.warn({ tenantId, topic }, 'missing itemId in payload');
    return { processed: false };
  }

  const claimed = await claimWebhookSlot(tenantId, eventId, topic); // (tenantId, id, topic)
  if (!claimed) {
    logger.info({ tenantId, eventId }, 'duplicate delivery, skipping');
    return { processed: false };
  }

  try {
    await doTheWork(ctx);
    return { processed: true };
  } catch (err) {
    // Transient error before a durable write → release so a retry can re-attempt.
    await releaseWebhookSlot(tenantId, eventId, topic);
    throw err;
  }
}
```

| Situation | Action |
|---|---|
| Transient API error (timeout, 5xx) before any write | `releaseWebhookSlot` — allow retry |
| Business-logic rejection (already paid, etc.) | Keep claim — `return { processed: false }` |
| Successful completion | Keep claim — prevents re-triggering |

`claimWebhookSlot` returns `false` (does not throw) on DB errors — treat `false` as "don't
proceed."

## GraphQL in loops — cost-aware adaptive delay

For any paginated/batch Jobber call, use the cost-aware client so you don't exhaust the
per-tenant credit bucket. Respect `throttleStatus`, keep page sizes small (`first: 25`).

```ts
import { executeGraphQLWithCost, calculateAdaptiveDelay } from '../jobber/jobberClient.js';

async function fetchAllPages(tenantId: string, accessToken: string) {
  let cursor: string | null = null;
  const results: Node[] = [];
  do {
    const { data, rateLimitInfo } = await executeGraphQLWithCost({
      query: MY_PAGINATED_QUERY,
      variables: { after: cursor, first: 25 },
      accessToken,
    });
    results.push(...(data.myConnection?.nodes ?? []));
    cursor = data.myConnection?.pageInfo?.endCursor ?? null;
    if (cursor) {
      const { delayMs } = calculateAdaptiveDelay(rateLimitInfo);
      await new Promise((r) => setTimeout(r, delayMs));
    }
  } while (cursor);
  return results;
}
```

The delay backs off as the bucket depletes; the backoff is scoped to this tenant's call.

**Throttle detection** — handle both levels:

```ts
function isThrottleError(err: unknown): boolean {
  const e = err as { response?: { status?: number }; message?: string };
  return e?.response?.status === 429 || Boolean(e?.message?.includes('THROTTLED'));
}
```

- **GraphQL-level:** `response.data.errors` contains an entry with type `THROTTLED`.
- **HTTP-level:** Jobber returns HTTP 429 (`err.response.status === 429`).

On a throttle error in a pagination loop, back off with an extended delay before retrying
the same page — **for that tenant only**.

**Required env var:** `JOBBER_API_VERSION` — throws at the first GraphQL call if missing.

## Single (non-paginated) calls

```ts
import { executeGraphQL } from '../jobber/jobberClient.js';
const data = await executeGraphQL({ query: MY_QUERY, variables: { id }, accessToken });
```

## Webhook logging

The router writes a **tenant-scoped** `webhook_logs` row after `'await'` and `'background'`
handlers (not `'delegate'`): `tenant_id`, `event_type` (raw topic), `status`
(`success`/`skipped`/`failed`), `response_code`, `source: 'jobber'`. Your handler does not
write this — only `'delegate'` handlers log themselves.

## Before you finish

- Add tests: claimed path (work runs), duplicate path (`processed: false`), error path
  (slot released, error rethrown), and assert `tenantId` is threaded through — invoke
  **write-vitest-test**; run only that file with `npx vitest run <file>`.
- Confirm the idempotency table's unique constraint is on `(tenant_id, event_id, topic)`
  (see `packages/db/schema/`).
- Confirm `JOBBER_API_VERSION` is set if you use GraphQL pagination.
