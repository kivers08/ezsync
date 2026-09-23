# Architectural Decision Log

This file is **append-only and immutable** — never rewrite a past entry. If a decision
is superseded, add a NEW dated entry that references the old one; the old entry stays as
written. It holds **architectural** decisions only (system structure, tooling, process
that shapes how code is built/verified/deployed).

When this file approaches ~250 lines, rotate the oldest entries out to
`docs/decisions/architecture-archive.md` (grep-only), mirroring the `CHANGELOG.md` /
`tasks/*-archive.md` rotation convention.

Newest entries at the top.

## Records

### [2026-09-23] — Language & runtime: TypeScript, ESM, Node 22
- **Context:** The Bluegrass middleware this project draws its patterns from was
  CommonJS JavaScript. ezsync is a greenfield SaaS with a shared codebase across an API,
  a worker, a Next.js frontend, and shared packages, where type safety across the vendor
  boundaries (Jobber/QBO/Square) and the DB is high-value.
- **Decision:** TypeScript throughout, ESM modules (`import`/`export`), targeting Node 22.
- **Consequences:** Types flow from the Drizzle schema and zod boundary schemas into
  services and routes. No CommonJS `require`. Ported middleware patterns are rewritten in
  TS/ESM, not copied verbatim.

### [2026-09-23] — Postgres + Drizzle ORM
- **Context:** The product turns raw job/financial data into analytical rollups
  (job-type and client-level profitability, forward pricing). That favours a real
  relational engine with strong aggregate/window support. We also want type-safe queries
  and want the DB layer to stay consistent with the TS/ESM stack rather than introducing
  a second paradigm.
- **Decision:** Postgres as the database; Drizzle ORM (with drizzle-kit migrations) over
  `node-postgres` (`pg`). The Drizzle schema in `packages/db/schema/` is the source of
  truth; migrations are generated (`drizzle-kit generate`) and applied forward-only.
  Money columns are Postgres `numeric`, returned by Drizzle as **strings**, with all math
  done in decimal.js.
- **Consequences:** Analytical rollups get Postgres's aggregate power; queries are
  type-checked; the DB layer matches the rest of the stack. Tradeoff accepted: Drizzle is
  younger and less battle-tested than some ORMs, and the string-money contract must be
  respected everywhere (a raw `numeric` used as a JS number is a bug). No numbered
  raw-SQL migration workflow — schema-first via drizzle-kit.

### [2026-09-23] — Multi-tenancy via Postgres Row-Level Security
- **Context:** ezsync is multi-tenant (many home-service businesses per instance),
  unlike the single-tenant middleware. A cross-tenant data leak is the highest-severity
  failure this product can have.
- **Decision:** Every tenant-scoped table carries a `tenant_id`, and isolation is
  enforced at the database with Postgres **Row-Level Security**. A `tenantContext`
  middleware resolves the tenant per request and sets it on the DB session
  (`SET LOCAL app.tenant_id`); webhooks carry tenant context in the route and are
  verified against that tenant's secret; background/sync work iterates tenants with a
  per-tenant circuit breaker; idempotency and logs are tenant-scoped.
- **Consequences:** Isolation is defence-in-depth — even a query that forgets its
  `tenant_id` filter is caught by RLS. A missing tenant scope is treated as a data-leak
  bug on sight. All DB access must run inside a session that has set the tenant.

### [2026-09-23] — OAuth tokens encrypted at rest with AES-256-GCM
- **Context:** Per-tenant OAuth tokens for Jobber and QBO are long-lived credentials to
  third parties' financial data. The middleware stored such tokens in plaintext; that is
  not acceptable here.
- **Decision:** Encrypt OAuth tokens at rest with **AES-256-GCM** (per-row IV + auth
  tag), using a master key supplied from env/KMS. Tokens live in the `connections` table,
  never in `.env`. Fetch/refresh always take a `tenantId`.
- **Consequences:** A database dump alone does not expose usable tokens. The master key
  becomes a critical secret with its own handling requirements. Error logging must never
  emit the full error object — axios errors embed the token-bearing request URL.

### [2026-09-23] — Vitest over Jest for testing
- **Context:** The middleware used Jest. ezsync is TS/ESM; Jest's ESM/TS story adds
  configuration friction, and the toolchain is Vite-adjacent.
- **Decision:** Use **Vitest**. Scoped runs are `npx vitest run <file>` / `-t <name>`;
  the full suite is CI's job, never a local completion gate.
- **Consequences:** First-class TS/ESM support with less config. All ported test patterns
  and the test-writing skill/agent target Vitest, not Jest.

### [2026-09-23] — npm-workspaces monorepo
- **Context:** The system spans an Express API, a sync-worker (same image, different
  entrypoint), a Next.js frontend, a DB layer, and shared zod/type/constant code. These
  need to share types and versions without publishing packages.
- **Decision:** A single **npm-workspaces monorepo**: `apps/api` (Express 5 + worker),
  `apps/web` (Next.js + Tailwind), `packages/db` (Drizzle schema/migrations/client), and
  `packages/shared` (zod schemas, shared TS types, constants incl. `APP_NAME`). Vendor
  API specs live under `packages/shared/types/vendor/`.
- **Consequences:** One install, shared types across boundaries, atomic cross-cutting
  changes in one PR. Workspace-aware tooling (build, lint, test, CI path filters) must
  understand the `apps/**` + `packages/**` layout.

### [2026-09-23] — Square Subscriptions for billing
- **Context:** Distribution is via the Jobber App Marketplace, but Jobber takes no cut —
  we bill customers directly. We need recurring subscription billing.
- **Decision:** Bill via the **Square Subscriptions API** (official Node SDK), per
  tenant, with Square subscription state stored in a `subscriptions` table. Square
  webhooks are HMAC-verified over `notificationUrl + rawBody`, with
  `express.raw({ type: 'application/json' })` registered before `express.json()` on
  webhook routes. Jobber Marketplace is OAuth/discovery only.
- **Consequences:** Billing is decoupled from the data integrations; Jobber remains a
  data + distribution channel, not a payment channel. Webhook body-parser ordering is a
  hard requirement for signature verification.

### [2026-09-23] — Host portability by construction (12-factor)
- **Context:** The deploy target will move over time: Vultr (xCloud panel) for dev →
  AWS Lightsail → EC2, later with managed backing services (RDS, ElastiCache). The move
  must not be a rewrite.
- **Decision:** Follow 12-factor: every backing service (Postgres, Redis, external APIs)
  is reached via an env connection string; app containers are stateless; state lives only
  in the Postgres volume or a managed service. Redis (ioredis) is optional at dev time —
  the app must boot without it (in-memory fallback). The host move is `docker compose up`
  on a new host; SSL/DNS is the only per-host piece (Certbot now; ALB + ACM on AWS
  later). Deploys and server/panel config are **owner-only** — Claude never triggers a
  deploy or an xCloud write op (reading xCloud state for diagnostics is fine).
- **Consequences:** Moving hosts is a redeploy, not a code change. No component may
  assume a specific host, a local disk for state, or a mandatory Redis.

### [2026-09-23] — Jobber + QBO + Square all in scope
- **Context:** The middleware integrated Jobber (plus GHL/Melissa, which are dropped).
  ezsync's value proposition depends on joining operational data (Jobber) with financial
  data (QBO) and billing on top (Square). This is not a QBO-only or Jobber-only app.
- **Decision:** All three integrations are first-class and none is optional. **Jobber**
  (GraphQL) and **QuickBooks Online** (Intuit `intuit-oauth` + REST) supply data;
  **Square** supplies billing. Jobber client/OAuth/webhook patterns are adapted from the
  middleware, single-tenant → multi-tenant. QBO is a new integration. Jobber field names
  must be verified against live GraphiQL before real queries are written.
- **Consequences:** Three OAuth/token lifecycles (two encrypted data connections + Square
  billing), three webhook verification schemes, and a per-vendor spec discipline
  (`api-type-guardian`). GHL, Melissa/RentCast enrichment, payroll, and the Bluegrass
  brand are explicitly out of scope.
