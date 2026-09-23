---
name: api-type-guardian
description: Use BEFORE writing or modifying ANY Jobber, QuickBooks Online, or Square API call, webhook payload parse, request/response shape, or field name. Enforces confirming every name against the authoritative vendor source (live Jobber GraphiQL, Intuit docs, the official Square SDK) so field names and endpoint paths are never guessed or hallucinated.
---

# API Type Guardian

**Hard rule: never guess a field name, endpoint path, enum value, or payload shape.**
Confirm every one against the vendor's authoritative source before writing code. If you
can't find it, **stop and say so** rather than assuming it exists.

## Step 1 — Identify the integration

ezsync integrates exactly three vendors: **Jobber**, **QuickBooks Online (QBO)**, and
**Square**. Nothing else.

## Step 2 — Confirm against the authoritative source

| Integration | Authoritative source | How to confirm |
|---|---|---|
| **Jobber** (GraphQL queries, mutations, webhook topics, enums) | **Live GraphiQL** is authoritative — Jobber's schema "is always changing," and field names are **not yet verified** in this repo. | Run the exact query/mutation in Jobber's GraphiQL explorer and read the schema pane. Confirm the field, its type, and the `userErrors` shape there before writing it. Any local schema dump is a stale convenience, never the source of truth. |
| **QuickBooks Online** | **Intuit developer docs** (the Accounting API entity/reports reference). | Verify the entity, endpoint path, the fields you read (P&L, AR aging), and that the call takes the tenant's `realmId`. Treat the Intuit docs as authoritative. |
| **Square** | The **official Square Node SDK** types + Square API reference (Subscriptions API for billing). | Prefer the SDK's typed methods/models over hand-rolled REST; the SDK types are the field-name contract. Cross-check the API reference for webhook event shapes and enum values. |

## Step 3 — Verify the specifics

- Exact field name + casing (Jobber GraphQL is camelCase; QBO JSON is PascalCase for many
  entity fields — confirm, don't assume).
- Required vs optional; the type/enum of each field.
- For **Jobber**: the mutation/query name (mutations use `*Edit`, never `*Update`), the
  `EncodedId!` Base64 Global-ID format, and the `userErrors` shape.
- For **QBO**: the endpoint path + HTTP method, and that `realmId` is included.
- For **Square**: the SDK method + model type, and the webhook event `type` string.

## Step 4 — Only then write or modify code

Match the confirmed names exactly. For Jobber mutations, always destructure and check
`userErrors` (see the `add-service-module` skill for the error pattern). Parse untrusted
vendor responses with zod at the boundary (`.claude/rules/js-code-conventions.md`).

## Red flags that mean STOP and re-check

- You're about to type a field name from memory.
- The field "feels right" but you haven't seen it in GraphiQL / the Intuit docs / the Square
  SDK **this session**.
- You're copying a shape from a different vendor's response.
- You're relying on a Jobber field a stale local dump shows but you haven't confirmed in
  live GraphiQL — Jobber's schema drifts, so live verification is mandatory before real
  queries.
