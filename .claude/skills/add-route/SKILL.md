---
name: add-route
description: Use when adding or modifying an Express route or sub-router in the API app. Encodes the sub-router mounting pattern, tenantContext + auth middleware ordering, zod input validation, JSON vs raw-body registration (webhooks), and pino logging. Trigger on any mention of "route", "endpoint", "router", "sub-router", or "API path". Note the Next.js frontend uses its own route handlers — this skill is for apps/api only.
---

# Add a Route

> **Scope: `apps/api` (Express 5) only.** The Next.js frontend (`apps/web`) uses Next.js
> route handlers (`app/**/route.ts`), not Express — do not apply this skill there.

Routes in `apps/api` are **focused sub-routers** assembled in `apps/api/src/server.ts` and
composed under `apps/api/src/routes/`. No business logic lives in route files — a route is
pure composition: run middleware (tenant context, auth), validate input with zod, call a
service, send the response. TypeScript + ESM only.

> Calling an external API from the service this route hits? Invoke **api-type-guardian**
> first. Adding the service function itself? Invoke **add-service-module**.

## Where things live

| Area | Path | Mounted at |
|---|---|---|
| Jobber webhooks | `apps/api/src/routes/webhooks/jobber.ts` | `/webhooks/jobber` |
| Square webhooks | `apps/api/src/routes/webhooks/square.ts` | `/webhooks/square` |
| QBO webhooks | `apps/api/src/routes/webhooks/qbo.ts` | `/webhooks/qbo` |
| OAuth callbacks | `apps/api/src/routes/oauth/` | `/oauth/` |
| Health | `apps/api/src/routes/health.ts` | `/health` |

## Rules

1. **Sub-router pattern.** Every route file exports an `express.Router()` — never registers
   routes on `app` directly. `server.ts` mounts it with `app.use(prefix, router)`.

2. **Raw-body webhook routes FIRST.** Jobber, Square, and QBO webhooks verify an HMAC over
   the **raw** request body, so their routes must register `express.raw({ type: 'application/json' })`
   and be mounted **before** `app.use(express.json())` in `server.ts`. If you add a new
   raw-body webhook, keep that ordering — once `express.json()` has run, the raw bytes are
   gone and signature verification fails. (See AGENTS.md → Square: raw-before-json.)

3. **Tenant context + auth middleware ordering.** Tenant-scoped routes run `tenantContext`
   (resolves the tenant from path/subdomain/OAuth state and sets `app.tenant_id` for RLS)
   and any auth middleware **on the router or at mount time**, before the handlers — never
   as an ad-hoc check inside each handler.

4. **Validate input with zod.** Parse `req.body` / `req.params` / `req.query` with a zod
   schema at the top of the handler; pass typed data inward. Do not trust the shape.

5. **No logic in route files.** Route files call services and send responses; business
   logic lives in `apps/api/src/services/`. Log with pino (`req.log` from pino-http, or the
   shared logger) and log `err.message`, never the full error object.

## Sub-router template

```ts
// apps/api/src/routes/things.ts
import { Router } from 'express';
import { z } from 'zod';
import { logger } from '../config/logger.js';
import { tenantContext } from '../middleware/tenantContext.js';
import * as thingService from '../services/thing/thingService.js';

const router = Router();
router.use(tenantContext); // sets app.tenant_id for RLS on every route below

const createBody = z.object({ name: z.string().min(1), amount: z.string() });

router.get('/', async (req, res) => {
  try {
    const data = await thingService.getThings(req.tenantId);
    res.json({ data });
  } catch (err) {
    logger.error({ err: err instanceof Error ? err.message : String(err) }, 'list things failed');
    res.status(500).json({ error: 'Internal error' });
  }
});

router.post('/', async (req, res) => {
  const parsed = createBody.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.flatten() });
  try {
    const result = await thingService.createThing(req.tenantId, parsed.data);
    res.status(201).json(result);
  } catch (err) {
    logger.error({ err: err instanceof Error ? err.message : String(err) }, 'create thing failed');
    res.status(500).json({ error: 'Internal error' });
  }
});

export default router;
```

Mount in `apps/api/src/server.ts` (after `express.json()`, since this is not a raw-body route):

```ts
import thingsRouter from './routes/things.js';
app.use('/things', thingsRouter);
```

## Raw-body webhook route (mounted BEFORE express.json())

```ts
// apps/api/src/routes/webhooks/square.ts
import { Router, raw } from 'express';
import { verifySquareWebhookSignature } from '../../middleware/verifySquareWebhookSignature.js';

const router = Router();
router.post('/', raw({ type: 'application/json' }), verifySquareWebhookSignature, async (req, res) => {
  // req.body is a Buffer here; the verify middleware used it for HMAC before parsing
  // ...dispatch to the handler, then res.status(200)...
});
export default router;
```

```ts
// in server.ts — BEFORE app.use(express.json())
import squareWebhook from './routes/webhooks/square.js';
app.use('/webhooks/square', squareWebhook);
```

## Before you finish

- Confirm raw-body webhook routes are mounted before `express.json()`.
- Confirm tenant-scoped routes run `tenantContext` before their handlers.
- Add a test for the service the route calls (invoke **write-vitest-test**); run only that
  file with `npx vitest run <file>`.
