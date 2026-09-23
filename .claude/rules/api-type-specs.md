---
paths:
  - "packages/shared/types/vendor/**/*"
---

# API Type Specs — Grep Only, Never Read In Full

- Files here are large vendor API specs: Jobber's GraphQL introspection +
  schema (`jobber-introspection.json`, `jobber-schema.graphql`), QuickBooks
  Online / Intuit's REST spec, and Square's OpenAPI spec (`square_api.json`).
  These run to multiple MB each. Never `Read` one of these in full — always
  `grep` for the specific field/endpoint/mutation you're verifying.
- `.claude/hooks/read-guard.sh` mechanically denies unranged reads of these
  files as a backstop. A targeted `offset`/`limit` `Read` is fine once `grep`
  has located the exact section.
- Never guess a field name or endpoint path — confirm it against these specs
  first, and cite the `sourcefile:line` (and pinned API version) you confirmed
  it against. If you can't find it, stop and say so rather than assuming it
  exists.
- Start with `packages/shared/types/vendor/INDEX.md` (hub) → `grep` the
  matching `INDEX-<provider>.md` for the endpoint/field/mutation name, then
  ranged-read the cited `sourcefile:line` to confirm. The index CITES the
  specs, it does not replace them — the citation is the fast path to the
  authoritative source, not a substitute for it.
- **Jobber is the exception that needs live verification.** Jobber's schema
  "is always changing," so a cost/timesheet/expense/invoice field must be
  confirmed against **live GraphiQL** before writing a real query — the
  vendored introspection blob is a starting reference, not the final word.
- For the full workflow and per-integration checklist, see the
  `api-type-guardian` skill. For batch validation without loading these specs
  into the main context, delegate to the `api-type-auditor` subagent.

## Spec provenance

These specs are vendored blobs with no in-file source or date (JSON has no comment
syntax), so provenance is recorded here rather than in the file. Update this table in the
same commit that replaces a spec.

| File | Source | Pinned API version | Last refreshed |
|---|---|---|---|
| `square_api.json` | `raw.githubusercontent.com/square/connect-api-specification/master/api.json` | `Square-Version: <pin>` | _(record on first vendor)_ |
| `jobber-schema.graphql` / `jobber-introspection.json` | Jobber GraphQL API introspection | `X-JOBBER-GRAPHQL-VERSION: <pin>` | _(record on first vendor)_ |
| QuickBooks Online (Intuit) spec | Intuit developer API reference | minorversion `<pin>` | _(record on first vendor)_ |

**How to read Square's version.** In `square_api.json`, `info.version` is `"2.0"` — the
API *generation*, not a dated release. It never changes and says nothing about staleness.
The real dated version is the `Square-Version` pin, which appears in two places that agree:

- `x-fern-global-headers[0].type` → `literal<"YYYY-MM-DD">`
- `components.securitySchemes.oauth2.x-additional-headers[0].schema.default`

Check those before assuming a freshly downloaded spec is newer than the vendored one.

**Refresh procedure.** `curl` the source URL over the file, then regenerate the
`INDEX*.md` hub/spokes and commit them in the same commit — the index cites
`<sourcefile>:<line>` and those line numbers move. For Jobber, prefer live introspection
over a stale blob. `packages/shared/types/vendor/` is excluded from ESLint and Prettier so
the raw download is committed byte-for-byte with no reformatting.

**Square deprecation marker.** Square marks retired schemas and fields with
`"x-release-status": "DEPRECATED"`, *not* OpenAPI's standard `"deprecated": true`, which
is absent throughout the spec. Grepping for `deprecated` alone makes a retired field look
current.
