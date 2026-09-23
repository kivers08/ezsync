---
paths:
  - "apps/web/**"
---

# Static Asset Cache-Busting — Handled by Next.js, Not by Hand

The middleware server-rendered EJS templates and hand-managed `?v=` query strings on
every `public/` asset. **ezsync does not.** `apps/web` is Next.js, which content-hashes
(fingerprints) built assets automatically — bundles, CSS, and imported/`next/image`
assets ship under immutable hashed URLs, so a content change produces a new URL on its
own and there is no manual cache-bust step to remember.

- **Do not add manual `?v=` query strings** in `apps/web`. Import assets so the build
  fingerprints them; let Next's build pipeline own cache invalidation. A hand-rolled
  `?v=` is a smell here, not a convention.
- **The one exception is genuinely hand-served static files** that bypass the build —
  e.g. a raw file dropped in `apps/web/public/` and referenced by a literal path string,
  or a static asset served directly by `apps/api`. Those are NOT fingerprinted; if you
  hand-serve such a file and it can change, either route it through the build so it gets
  hashed, or set explicit cache headers — never rely on a browser re-fetching a stale
  body. Prefer routing through the build.
