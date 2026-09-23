---
name: add-webhook-handler
description: Use when adding or changing a Square, QBO, or Jobber webhook handler, event route, or event-processing flow. Encodes the structured handler return contract, per-tenant idempotency, non-fatal secondary ops, tenant context from the route, and the raw-body-before-json ordering rule. For Jobber's topic-dispatch specifics use add-jobber-webhook.
---

# Add a Webhook Handler

Handlers process one inbound event and **return a structured result — they never throw to
the Express layer.** The route wrapper turns the result into the HTTP response. All handlers
are multi-tenant: the tenant is resolved from the route (path/subdomain/OAuth `state`) and
verified against that tenant's signing secret before the handler runs.

> Parsing an external payload? Invoke **api-type-guardian** to confirm field names first.
> Adding a Jobber topic? Use **add-jobber-webhook** (topic dispatch table, rate limits).

## The return contract

Every handler returns:

```ts
type WebhookResult = {
  status: 'success' | 'skipped' | 'failed';
  responseCode: number; // HTTP status to send — almost always 200 so the provider stops retrying
  responseBody: Record<string, unknown>; // JSON echoed back to the provider
};
```

## Rules

1. **Tenant context first.** The route has already resolved and RLS-scoped the tenant; the
   handler receives `tenantId` and threads it into every DB call and vendor request. Never
   process a webhook without a tenant.

2. **Idempotency, keyed by tenant.** Claim the event before doing work so retries don't
   double-process. Use `claimWebhookSlot(tenantId, eventId, topic)` (Drizzle
   `insert(...).onConflictDoNothing(...)` — see the `add-repository` skill). If the slot is
   already taken, return `{ status: 'skipped', responseCode: 200, ... }`.

3. **Primary op in a top-level try/catch.** On failure: `logger.error({ err: err.message }, '...')`
   and return `{ status: 'failed', responseCode: 500, responseBody: { error } }`. A catch
   must change the outcome — if the write can be retried, release the slot before returning.

4. **Secondary ops are non-fatal.** Notifications, notes, cross-system links each get their
   **own** inner try/catch that logs and continues — they must not break work that already
   succeeded.

5. **Route ordering (raw body).** Webhook signature verification needs the raw body, so the
   route registers `express.raw({ type: 'application/json' })` and is mounted **before**
   `app.use(express.json())` in `server.ts`. If you add a new raw-body webhook, keep that
   ordering. (AGENTS.md → Square/Jobber/QBO webhook rules.)

## Template

```ts
// apps/api/src/services/webhook/handlers/someEventHandler.ts
import { logger } from '../../../config/logger.js';
import { claimWebhookSlot, releaseWebhookSlot } from '../webhookRepository.js';

type WebhookResult = {
  status: 'success' | 'skipped' | 'failed';
  responseCode: number;
  responseBody: Record<string, unknown>;
};

export async function processSomeEvent(args: {
  tenantId: string;
  eventId: string;
  payload: unknown;
}): Promise<WebhookResult> {
  const { tenantId, eventId } = args;
  const topic = 'some.topic';
  try {
    // 1. Idempotency, keyed by tenant
    const claimed = await claimWebhookSlot(tenantId, eventId, topic);
    if (!claimed) {
      return { status: 'skipped', responseCode: 200, responseBody: { duplicate: true } };
    }

    // 2. Primary op (throws on failure)
    await doPrimaryWork(args);

    // 3. Secondary, non-fatal ops
    try {
      await notify(tenantId, '…');
    } catch (notifyErr) {
      logger.error(
        { err: notifyErr instanceof Error ? notifyErr.message : String(notifyErr), tenantId },
        'notification failed (non-fatal)',
      );
    }

    return { status: 'success', responseCode: 200, responseBody: { received: true } };
  } catch (err) {
    logger.error(
      { err: err instanceof Error ? err.message : String(err), tenantId, eventId },
      'failed to process some.topic',
    );
    // Transient failure before a durable write → release so a retry can re-attempt.
    await releaseWebhookSlot(tenantId, eventId, topic);
    return { status: 'failed', responseCode: 500, responseBody: { error: 'processing failed' } };
  }
}
```

## Release vs. keep the idempotency slot

| Situation | Action |
|---|---|
| Transient API error (timeout, 5xx) before any durable write | `releaseWebhookSlot` — allow retry |
| Business-logic rejection (already processed, not applicable) | Keep claim — return `{ status: 'skipped', responseCode: 200 }` |
| Successful completion | Keep claim — prevents re-triggering |

## Provider-specific patterns

- **Square (billing):** payment/subscription events. Do not treat a payment as final until
  its status is terminal (`COMPLETED`); `AUTHORIZED`/pending is not captured. Store
  subscription state per tenant.
- **QBO:** the event notification is thin — it carries entity ids, not the data. Fetch the
  entity from QBO (with the tenant's `realmId`) inside the handler; verify field names
  against Intuit docs first.
- **Jobber:** item id lives at `req.body.data.webHookEvent.itemId`; topics are present-tense
  (`INVOICE_CREATE`). Topic dispatch + adaptive rate-limit retry are in **add-jobber-webhook**.

## Before you finish

- Add a test covering success, duplicate-skip, and primary-failure (slot released) paths,
  and assert the tenant is scoped through — invoke **write-vitest-test**; run only that file
  with `npx vitest run <file>`.
