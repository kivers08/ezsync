---
name: add-service-module
description: Use when adding or modifying a service module under apps/api/src/services/ (jobber, qbo, square, webhook, etc.). Encodes this repo's pure-function service conventions — named exports, TS/ESM, pino logging, zod validation of external responses, axios/fetch choice, per-tenant token access, and descriptive thrown errors.
---

# Add a Service Module

Services in `apps/api/src/services/` are **thin modules of pure named functions** — no
classes, no shared mutable state. Each function does one domain task and throws on failure
with a descriptive message; the caller (route handler) decides the HTTP response.
TypeScript + ESM only — `import` / `export`, never `require`.

> Touching an external API in this module? Invoke **api-type-guardian** first — never guess
> a field name.

## Conventions

- **Exports:** named `export async function ...`. One module per domain area under
  `services/<area>/` (`jobber/`, `qbo/`, `square/`, `webhook/`).
- **Logging:** `import { logger } from '../../config/logger.js';` then
  `logger.info({ ctx }, 'message')` / `logger.error({ err: err.message }, 'message')`. Log
  `err.message`, never the full error object — axios errors embed the request URL (with
  tokens) in `config.url`.
- **Validation:** parse any external response you don't control with **zod** before using
  it. Vendor payload shapes are not to be trusted; pass typed data inward.
- **HTTP client:** `axios` for Jobber GraphQL and QBO REST; the official **Square Node SDK**
  for Square (don't hand-roll Square REST). Native `fetch` is fine for simple calls.
- **Per-tenant tokens:** every function that hits a vendor takes a `tenantId` and fetches
  that tenant's OAuth token from the encrypted `connections` store (AES-256-GCM, never
  `.env`, never plaintext). One tenant's expired/throttled token must never affect another.
- **Money:** `numeric` fields arrive as strings — use decimal.js, guard nullables with
  `?? '0'`. Never JS floats.

## The real integrations

- **Jobber** — GraphQL. Calls go through a shared `jobber/jobberClient.ts`
  (`executeGraphQL({ query, variables, accessToken })`). Mutations use `*Edit` (e.g.
  `clientEdit`), never `*Update`; always destructure and check `userErrors`. IDs are Base64
  Global IDs. Respect the credit-based rate limit (see the `add-jobber-webhook` skill).
- **QuickBooks Online (QBO)** — REST via `intuit-oauth` + `node-quickbooks`/direct REST.
  Every call needs the tenant's `realmId` (stored per connection). Primary reads: P&L, AR
  aging.
- **Square** — official Node SDK, **Subscriptions API** for recurring billing. Per-tenant.

## Error pattern

```ts
// Generic API error
if (response.data.errors) {
  throw new Error(`Jobber GraphQL errors: ${JSON.stringify(response.data.errors)}`);
}

// Jobber mutations: always check userErrors
const { client, userErrors } = data.clientEdit;
if (userErrors?.length) {
  throw new Error(`Jobber clientEdit userErrors: ${userErrors.map((e) => e.message).join(', ')}`);
}
return client;
```

Secondary / non-fatal work (notifications, notes) belongs in the **caller's** try/catch so
it can't break the primary flow — see the `add-webhook-handler` skill.

## Template

```ts
// apps/api/src/services/jobber/clientService.ts
import { z } from 'zod';
import { logger } from '../../config/logger.js';
import { executeGraphQL } from './jobberClient.js';
import { getTenantToken } from '../auth/tokenStore.js';

const ClientResult = z.object({ id: z.string() });

/**
 * Edit a Jobber client for a tenant. Throws on GraphQL/userErrors.
 */
export async function editClient(
  tenantId: string,
  clientId: string,
  input: { name?: string },
) {
  const accessToken = await getTenantToken(tenantId, 'jobber');
  const query = /* GraphQL */ `mutation ($id: EncodedId!, $input: ClientEditInput!) {
    clientEdit(id: $id, input: $input) { client { id } userErrors { message } }
  }`;
  const data = await executeGraphQL({ query, variables: { id: clientId, input }, accessToken });

  const { client, userErrors } = data.clientEdit;
  if (userErrors?.length) {
    throw new Error(`Jobber clientEdit userErrors: ${userErrors.map((e: { message: string }) => e.message).join(', ')}`);
  }
  const entity = ClientResult.parse(client);
  logger.info({ tenantId, id: entity.id }, 'client edited');
  return entity;
}
```

## Before you finish

- Add a unit test (invoke **write-vitest-test**): happy path, `userErrors`/error path, and
  an edge case; assert `tenantId` is threaded into the call. Run only that file with
  `npx vitest run <file>`.
