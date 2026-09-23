# todo

Open work only. Completed items rotate to `tasks/todo-archive.md` at wrap-up (never
accumulate here). Read this file through the Index, then grep the heading you need — see
`.claude/rules/task-files-conventions.md`.

## Index

- In flight
- Backlog

## In flight

_(nothing in flight yet)_

## Backlog

- [ ] **Data-model design pass** — final Drizzle schema for `tenants`, `connections`
  (per-tenant encrypted OAuth tokens), raw entities (Jobber/QBO ingested records),
  rollups (job-type / client-level profitability aggregates), and `subscriptions`
  (Square billing state). Settle table shapes, `tenant_id` + RLS on every tenant-scoped
  table, and money columns as `numeric`. `brainstorm` before schema is written.
- [ ] **Live Jobber GraphiQL field verification** — confirm every cost / timesheet /
  expense / invoice field name against live GraphiQL before any real query is written;
  the vendored introspection blob is a starting reference only. Record confirmed
  `field → type` pairs so queries cite a verified source.
