---
name: add-background-service
description: Use when adding or modifying a background service, sync loop, sweeper, poller, or recurring task in the sync-worker. Encodes the interval/poll-loop pattern that iterates tenants with a per-tenant circuit breaker, graceful shutdown, pino logging, and Redis-optional degradation. Trigger on any mention of "worker", "sync", "sweeper", "poller", "background service", "interval", or "recurring task".
---

# Add a Background Service

Background work runs in the **sync-worker** — the same Docker image as the API, started with
a different entrypoint at `apps/api/src/worker/sync.ts`. Each service is a **self-contained
loop** that, on every tick, **iterates tenants** and does per-tenant work behind a
**per-tenant circuit breaker**, so one tenant's failure (expired token, throttling, bad
data) never blocks the others. TypeScript + ESM only.

## Conventions

- **Named export `start()`** — called once by the worker entrypoint. Export `stop()` so the
  interval is cleared on shutdown.
- **Iterate tenants every tick.** Load active tenants, then loop; each tenant's work is
  wrapped in its own try/catch. Never let one tenant's throw abort the loop over the rest.
- **Per-tenant circuit breaker.** Track consecutive failures per `tenantId`; once a
  threshold is hit, skip that tenant for a cool-down window (or until its next successful
  token refresh) instead of hammering a broken integration. Keep breaker state in
  Redis/DB, not process memory, if the worker may be multi-instance.
- **Errors are non-fatal.** Each tenant iteration and the tick itself catch and log
  (`logger.error({ err: err.message, tenantId }, '...')`); the loop always schedules the
  next tick.
- **pino logger:** `import { logger } from '../config/logger.js';`
- **Redis optional.** If the service uses Redis, follow the app's lazy-connect + in-memory
  fallback pattern — the worker must boot and run without Redis in dev.
- **Graceful shutdown.** The entrypoint listens for `SIGTERM`/`SIGINT`, calls each service's
  `stop()`, waits for the in-flight tick to finish, then exits.
- **Money:** `numeric` arrives as strings — decimal.js, guard nullables with `?? '0'`.
- **Async:** no floating promises inside the loop; `await` each tenant's work (or bound
  concurrency) and catch rejections per tenant.

## Interval guidelines

| Cadence | ms |
|---|---|
| Every minute | `60_000` |
| Every 5 min | `300_000` |
| Token refresh (well before ~60-min expiry) | `3_300_000` (55 min) |
| Daily | check wall-clock hour inside a short (15-min) tick + track `lastRunDate` |

For daily tasks, a `86_400_000` interval only fires if the worker booted at the target
hour; use a short interval and a `lastRunDate` guard instead.

## Template

```ts
// apps/api/src/services/sync/thingSync.ts
import { logger } from '../../config/logger.js';
import { listActiveTenants } from '../tenants/tenantRepository.js';

const INTERVAL_MS = 5 * 60 * 1000;
const FAILURE_THRESHOLD = 3;
let intervalHandle: NodeJS.Timeout | null = null;
let running = false;

// Per-tenant circuit breaker (swap for Redis/DB state if the worker is multi-instance).
const failures = new Map<string, number>();

async function syncTenant(tenantId: string): Promise<void> {
  if ((failures.get(tenantId) ?? 0) >= FAILURE_THRESHOLD) {
    logger.warn({ tenantId }, 'thingSync: circuit open, skipping tenant');
    return;
  }
  try {
    // --- per-tenant work: pull from Jobber/QBO, write tenant-scoped rows ---
    failures.delete(tenantId); // success closes the breaker
  } catch (err) {
    const n = (failures.get(tenantId) ?? 0) + 1;
    failures.set(tenantId, n);
    logger.error(
      { err: err instanceof Error ? err.message : String(err), tenantId, failures: n },
      'thingSync: tenant sync failed',
    );
    // Do NOT rethrow — the loop must continue for other tenants.
  }
}

async function runOnce(): Promise<void> {
  if (running) return; // don't overlap ticks
  running = true;
  try {
    const tenants = await listActiveTenants();
    for (const { id } of tenants) {
      await syncTenant(id);
    }
    logger.info({ tenants: tenants.length }, 'thingSync: tick complete');
  } catch (err) {
    logger.error({ err: err instanceof Error ? err.message : String(err) }, 'thingSync: tick failed');
  } finally {
    running = false;
  }
}

export function start(): void {
  logger.info({ intervalMs: INTERVAL_MS }, 'thingSync: starting');
  void runOnce();
  intervalHandle = setInterval(() => void runOnce(), INTERVAL_MS);
}

export function stop(): void {
  if (intervalHandle) {
    clearInterval(intervalHandle);
    intervalHandle = null;
    logger.info('thingSync: stopped');
  }
}
```

## Registration + graceful shutdown (apps/api/src/worker/sync.ts)

```ts
import * as thingSync from '../services/sync/thingSync.js';

thingSync.start();

for (const sig of ['SIGTERM', 'SIGINT'] as const) {
  process.on(sig, () => {
    thingSync.stop();
    // ...close DB/Redis, then exit once the in-flight tick settles...
    process.exit(0);
  });
}
```

## Before you finish

- Add a test (invoke **write-vitest-test**) asserting: one tenant's thrown error does not
  stop the loop over the others; the breaker opens after the threshold; a happy tick logs
  the expected count. Run only that file with `npx vitest run <file>`.
- Double-check the interval against the business requirement, and confirm the service is
  registered in `apps/api/src/worker/sync.ts` with `stop()` wired to shutdown.
