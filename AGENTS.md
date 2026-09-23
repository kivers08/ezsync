# ezsync — Technical Reference & Conventions

This file is the **Single Source of Truth (SSoT)** for integration-specific technical
rules that live only here — not a general instruction file. Read by Claude and human
developers.

## Table of Contents

- [Agent Lanes & Division of Labor](#agent-lanes--division-of-labor)
- [1. Critical Integration Rules](#1-critical-integration-rules)
  - [Jobber](#jobber)
  - [QuickBooks Online (QBO)](#quickbooks-online-qbo)
  - [Square (billing)](#square-billing)
- [2. Multi-Tenancy Rules](#2-multi-tenancy-rules)
- [3. Key Lessons Learned](#3-key-lessons-learned)
- [4. Directory Structure Overview](#4-directory-structure-overview)
- [5. Elsewhere](#5-elsewhere)

---

## Agent Lanes & Division of Labor

Single active lane for now:

| Agent | Lane | Branch | Output |
|---|---|---|---|
| **Claude + user** | All work — features, architecture, bug diagnosis, PR review | `claude/*` | Draft PR, squash merge |

Additional automated lanes (e.g. scheduled batch cleanup, third-party PR review) are **not
set up** for this project yet. Add a row here when one is introduced so lanes never
overlap.

---

## 1. Critical Integration Rules

> ezsync integrates **all three** of Jobber, QBO, and Square — Jobber and QBO for data,
> Square for billing. None is optional.

### Jobber
- **API:** GraphQL. Patterns adapted from Bluegrass Middleware's Jobber client, but
  **multi-tenant** here (middleware was single-tenant).
- **Tokens:** per-tenant OAuth, stored **encrypted (AES-256-GCM)** in `connections`, never
  `.env`. Fetch/refresh always take a `tenantId`.
- **IDs:** Base64 Global IDs (`EncodedId!`). Encode: `Buffer.from('gid://Jobber/Client/' + numericId).toString('base64')`.
- **Mutations:** use `*Edit` (e.g. `clientEdit`), never `*Update`.
- **Rate limits:** credit-based leaky bucket — respect `throttleStatus`, use adaptive
  delay + small page sizes (`first: 25`). Per-tenant, so one tenant's throttling must not
  block others.
- **Webhooks:** topics present-tense (`INVOICE_CREATE`); item ID at
  `req.body.data.webHookEvent.itemId`. Idempotency via `claimWebhookSlot(tenantId, id, topic)`.
- **Field names are NOT yet verified.** Confirm every cost/timesheet/expense field against
  live GraphiQL before writing real queries — Jobber's schema "is always changing."

### QuickBooks Online (QBO)
- **Auth:** `intuit-oauth` (official Intuit OAuth2 client). Per-tenant tokens, encrypted,
  same store/refresh contract as Jobber.
- **API:** `node-quickbooks` or direct REST. Primary reads: **P&L**, **AR aging**.
- **Realm ID** (company id) is stored per connection alongside the token — required on
  every call.
- NEW integration (no middleware equivalent) — verify endpoints/fields against Intuit docs
  before use; treat the vendor spec as authoritative (`api-type-guardian` skill).

### Square (billing)
- **Subscriptions API** (official Node SDK) for recurring billing — this is the billing
  engine. Distribution is via Jobber Marketplace (OAuth/discovery only); Jobber takes no
  cut — we bill directly through Square.
- **Webhook HMAC:** verify `x-square-hmacsha256-signature` computed over
  `notificationUrl + rawBody`. `express.raw({ type: 'application/json' })` MUST be
  registered **before** `express.json()` for webhook routes.
- Store Square subscription state per tenant (`subscriptions`).

---

## 2. Multi-Tenancy Rules

- **Every tenant-scoped table has `tenant_id`** and is protected by Postgres **Row-Level
  Security**. A query without a tenant scope is a **data-leak bug on sight**.
- **Request context:** a `tenantContext` middleware resolves the tenant (path/subdomain/
  session) and sets it for the DB session (RLS `SET LOCAL app.tenant_id`).
- **Webhooks carry tenant context** in the route (path/subdomain/OAuth `state`), verified
  against that tenant's signing secret; idempotency + logs are tenant-scoped.
- **Background/sync work iterates tenants** with a **per-tenant circuit breaker** — a
  failed token refresh or sync for one tenant must not block the others.
- **Secrets at rest:** OAuth tokens encrypted with AES-256-GCM (per-row IV + auth tag),
  master key from env/KMS. Never store plaintext tokens.

---

## 3. Key Lessons Learned

Stack coding rules (TS/ESM, safe `err.message` logging, decimal.js for money, Drizzle/
Postgres query conventions) live in `.claude/rules/js-code-conventions.md` and
`.claude/rules/db-migrations.md` — canonical home, not restated here (the `dispatch`
skill's prompt template pastes the key rules verbatim for subagents, which don't auto-load
rules files). Cross-cutting lessons with no other home:

- **Money:** Postgres `numeric` → Drizzle returns **strings** → wrap in `decimal.js`;
  guard nullable inputs with `?? 0` (`new Decimal(null)` is `NaN`). Never JS floats.
- **Version sweeps:** when updating a version string (Node, API version, etc.), `grep` the
  whole repo for every occurrence.
- **ISO 8601 comparison:** never compare date strings with `>`/`<`; convert to `Date` (or
  compare true `timestamptz`) first.
- **SSRF guard:** block ALL IANA-reserved IP ranges (CGNAT, benchmark, etc.) in any
  outbound-fetch filter.
- **Zero-as-null:** in financial rates/multipliers, treat `0` as "not set" if zero is
  semantically invalid.
- **Safe error logging:** log `err.message`, never the full error object — axios errors
  embed the request URL (with tokens) in `config.url`.

---

## 4. Directory Structure Overview

Monorepo (npm workspaces):

- `apps/api/` — Express 5 API (TS). `src/config/` (env/db/redis), `src/middleware/`
  (tenant context, webhook verifiers), `src/routes/`, `src/services/` (`jobber/`, `qbo/`,
  `square/`, `webhook/`), `src/worker/sync.ts` (sync-worker entrypoint — same image).
- `apps/web/` — Next.js + Tailwind frontend.
- `packages/db/` — Drizzle: `schema/` (source of truth for tables), `migrations/`
  (drizzle-kit generated), `client.ts`, `drizzle.config.ts`.
- `packages/shared/` — zod schemas, shared TS types, constants (`APP_NAME`).
- `infra/` — `Dockerfile`, `docker-compose.yml`, `nginx-app.conf`.
- `tasks/` — session memory. `todo.md` (in-flight + backlog) and `lessons.md` (active
  rules) are live; `*-archive.md` hold history — grep, never read in full.
- `docs/` — `decisions/architecture.md` (ADR log), plus product/spec docs.

---

## 5. Elsewhere

- **Session start / grep-only files** — `.claude/SESSION_START_PROTOCOL.md` + `.claude/rules/task-files-conventions.md`
- **API/type guardrails** — `.claude/rules/api-type-specs.md` + `api-type-guardian` skill
- **Core dev principles** — `.claude/rules/js-code-conventions.md` + CLAUDE.md "Core Principles"
- **DB / migrations** — `.claude/rules/db-migrations.md` + `write-db-migration` skill (Drizzle)
- **Operational workflows** — CLAUDE.md "Workflow Orchestration" + the `pr-review-pipeline` skill
- **Verifying completion** — `.claude/rules/testing-verification.md` (CI is the gate)
- **CHANGELOG requirement** (hard pre-merge gate on every PR) — `.claude/rules/changelog-conventions.md`
- **Deploy / hosting portability** — CLAUDE.md "Core Principles" (host-portable) + `docs/decisions/architecture.md`
