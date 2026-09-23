# `.claude/` — Repository Skills & Subagents

Repo-specific Claude Code tooling for **ezsync** (Jobber · QuickBooks Online · Square).
Skills hold the procedural conventions and auto-surface in context; subagents do
delegated, separate-context research and defer to the skills for "what the conventions
are."

## Skills (`skills/<name>/SKILL.md`)
Auto-invoked when their `description` matches what you're doing.

| Skill | Fires when… |
|---|---|
| **api-type-guardian** | Before writing/modifying any Jobber/QBO/Square API call, webhook parse, or field name. Enforces checking `packages/shared/types/vendor/`; Jobber fields also need live GraphiQL. |
| **add-service-module** | Adding/changing a service in `apps/api/src/services/**` — pure-function exports, pino logging, error pattern. |
| **add-background-service** | Adding/changing a background sweeper, poller, refresher, or the sync-worker loop — interval pattern, graceful shutdown, pino logging, per-tenant iteration. |
| **add-route** | Adding/changing an Express route or sub-router in `apps/api` — sub-router pattern, auth ordering, raw-body-before-`express.json()` rule for webhook routes. |
| **add-jobber-webhook** | Jobber webhook handlers and GraphQL pagination — dispatch table modes, per-tenant atomic `claimWebhookSlot`, cost-aware GraphQL + adaptive delay. |
| **add-repository** | New DB access module — parameterized queries, tenant-scoped/RLS-guarded reads, decimal.js guards, pagination, idempotent inserts, transactions. |
| **write-db-migration** | Any schema change — edit the Drizzle schema in `packages/db/schema/`, then `drizzle-kit generate`, review the SQL, `drizzle-kit migrate`. |
| **add-webhook-handler** | Adding/changing a webhook handler — response contract, tenant-scoped idempotency, non-fatal secondary ops. |
| **write-vitest-test** | Adding tests — Vitest, happy + error paths, mocking at module boundaries. |
| **session-wrap-up** | Ending any session that changed code (invoke only when explicitly commanded) — triggers CI, updates lessons/todo, updates the PR, offers squash merge. |
| **dispatch** | Meta-skill for routing any code-change task to the right implementation subagent with worktree isolation. Use when a task requires writing, editing, or deleting code. |
| **pr-review-pipeline** | Driving a PR through review — sequences review, CI, and merge readiness in a fixed order; covers replying to review comments. |
| **dead-code-audit** | Before deleting anything `npx knip@5 --production` flags as unused — encodes knip's known false-positive patterns in this repo. |
| **review** | Canonical review skill — code review (`full`, the default) or security-focused review (`security`) of the current branch diff vs its base. Dispatches a background `pr-reviewer` agent so the main window stays open. |
| **audit** | Research-only audit of a subsystem, ending in a report under `docs/audits/` and a draft PR. Never merges. |
| **brainstorm** | Collaborative intake for a new feature — clarifying questions before any research or planning. Invoked by `dispatch`'s Step 0 triage, not self-triggered. |
| **xcloud** | Reading xCloud server/site state for diagnostics via the xCloud MCP tools. Deploys and any xCloud write op are **owner-only** — never triggered by Claude. |

_Future skills (not yet present): `add-qbo-integration` and `add-square-billing` will land
when those integrations move past stubs._

## Rules (`rules/<name>.md`)
Path-scoped, auto-loading context. Unlike skills (matched on the task description), a
rules file's `paths:` frontmatter (glob patterns) auto-loads it into context only when
Claude reads a matching file — no invocation needed.

| Rule | Loads for | Reminds about |
|---|---|---|
| **api-type-specs** | `packages/shared/types/vendor/**` | Multi-MB vendor specs (Jobber/QBO/Square) — grep the field, never read in full; cite source+version; Jobber needs live GraphiQL. Points to `api-type-guardian`/`api-type-auditor`. |
| **db-migrations** | `packages/db/**` | Drizzle schema is the source of truth → `drizzle-kit generate`/`migrate`; forward-only; Postgres/RLS/`tenant_id`, `numeric`→string→decimal.js. Points to `write-db-migration`/`add-repository`. |
| **testing-verification** | `apps/**/*.ts`, `packages/**/*.ts`, `**/*.test.ts` | CI is the gate, not local runs — never invoke `npm test`/unfiltered `npx vitest run` locally as a completion gate; scoped `npx vitest run <file>` and local lint/format checks stay fine. |
| **js-code-conventions** | `apps/**/*.ts`, `packages/**/*.ts` | TypeScript/ESM, safe error logging (`err.message`, never the URL-bearing error object), decimal.js money-math guards. |
| **changelog-conventions** | `CHANGELOG.md` | Grep-only convention, and the mandatory pre-merge CHANGELOG close-out gate. |
| **static-asset-cache-busting** | `apps/web/**` | Next.js fingerprints built assets automatically — no manual `?v=` busting; only hand-served static files need explicit cache handling. |
| **client-side-views** | `apps/web/**` | Browser-only React logic (effects, handlers, SDK callbacks) is unreachable by Vitest — green CI is not sign-off, flag it review-critical; extract pure logic out for testing; every exit path of an async fix must settle what the waiter awaits. |
| **task-files-conventions** | `tasks/lessons.md`, `tasks/todo.md`, `tasks/*-archive.md`, `.claude/agents/*.md` | Ranged-read-only convention for these files; open-only `todo.md`; ADR-log rotation; see also the read-guard hook. |

## Subagents (`agents/<name>.md`)

**Routing + model tables: the `dispatch` skill (Step 1) — the single canonical copy.**
Implementation agents run in isolated git worktrees; `test-writer`-chained runs,
`doc-updater`, and the read-only research/review agents are the exceptions (see the
`dispatch` skill, Step 3).

| Agent | Role |
|---|---|
| **feature-implementer** | Implements a scoped, already-designed unit of work on a branch. |
| **bug-fixer** | Reproduces and fixes one reported bug; adds a regression test. |
| **test-writer** | Writes/extends Vitest tests for already-implemented code. |
| **doc-updater** | Keeps docs/CHANGELOG in sync with a change; never pushes itself. |
| **pr-reviewer** | Reviews a branch diff (correctness, security, conventions); returns findings, never edits. |
| **pattern-finder** | Read-only search across the codebase for patterns/usages. |
| **api-type-auditor** | Batch-validates API calls/fields against the vendor specs without loading them into the main context. |

Design rationale worth keeping here:

- Every agent defined in `agents/*.md` pins its model in frontmatter (`model:`) so cost
  and capability track the job, not the calling session.
- **The built-in `Explore` agent and the catch-all `claude` agent are deliberately NOT
  pinned** — neither has a definition file here, so both inherit the session model by
  design. Creating `agents/explore.md` to pin one may **shadow the built-in outright**
  (system prompt and tool access, not just model); `Explore` is read-only by construction
  and the `tools:` allowlist has no deny syntax, so a hand-written shadow could easily
  grant write access or withhold a needed tool. Leave both unpinned unless the harness
  gains a model-only override for built-in agent names.

### Per-agent memory

Curated, role-specific behavior notes live in `agents/memory/<agent-name>.md` — distinct
from `tasks/lessons.md`'s codebase-wide rules. Own-only read (each agent reads only its
own file, skipping silently if absent); write is curated only, by the main context, never
self-written. Full convention: `agents/memory/README.md`.

## Hooks (`hooks/*.sh`)
Git hooks live in `../.githooks/` (versioned) rather than `.git/hooks/` (not versioned).
The SessionStart hook sets `core.hooksPath .githooks` automatically each session (silent,
non-fatal) so `.githooks/pre-commit` — which runs `prettier --write` on just the staged
`.ts`/`.tsx` files before every commit — is active without manual setup. One-time manual
equivalent for a shell outside a Claude session: `git config core.hooksPath .githooks`
(see CLAUDE.md's Commands table).

## Design
- **Single source of truth:** procedures live in skills; subagents reference them by name.
- **Skills-first:** most repo knowledge is procedural ("how to write a migration"), best
  delivered as a skill that surfaces in the main context exactly when needed.
- **Delegation-first:** implementation work goes to subagents with worktree isolation so
  the main context stays clean for monitoring, communication, and review.
- **dispatch skill** routes any code-change task to the right implementation subagent —
  triaging first through CLAUDE.md's task-intake gate for non-trivial work.
