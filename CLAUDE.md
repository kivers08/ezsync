# Project Quick Reference

**Project:** ezsync — margin & pricing intelligence for home-service businesses
(multi-tenant SaaS). Integrates **Jobber** · **QuickBooks Online** · **Square** (billing).
**Codename** `ezsync` ("easy sync"); customer-facing brand TBD — keep it out of code except
one `APP_NAME` constant.
**Technical SSoT for all agents:** `AGENTS.md` (integration rules, conventions, structure).

### Stack

TypeScript (ESM, Node 22) · Express 5 API + shared-image **sync-worker** · Next.js +
Tailwind frontend · **Postgres + Drizzle ORM** (drizzle-kit migrations, RLS for tenant
isolation) · **decimal.js** for money · **zod** at boundaries · **pino** logging ·
**Vitest** tests · Redis (ioredis, optional at dev) · Docker/Compose, host-portable
(Vultr → Lightsail → EC2). Full detail: `AGENTS.md` + `docs/decisions/architecture.md`.

### Commands

| Task | Command |
|---|---|
| Run one test file | `npx vitest run apps/api/src/config/env.test.ts` |
| Run tests matching a name | `npx vitest run -t "rejects missing DB_URL"` |
| Generate a migration from schema changes | `npx drizzle-kit generate` (then review the SQL) |
| Apply migrations | `npx drizzle-kit migrate` (idempotent; forward-only) |
| Typecheck | `npm run typecheck` |
| Lint | `npm run lint` |
| Dead-code audit | `npx knip@5 --production` (cross-check hits — `dead-code-audit` skill) |
| One-time hook setup (per clone/worktree) | `git config core.hooksPath .githooks` (auto-set by the SessionStart hook; `.githooks/pre-commit` runs Prettier on staged `.ts`/`.tsx`) |

`npm test` runs **Vitest only** (no ESLint). CI runs lint + typecheck + the full suite.

**Memory:** `docs/decisions/architecture.md` (ADR log), `tasks/todo.md` (in-flight +
backlog), lessons hub + agent spokes + path-scoped `.claude/rules/` —
`.claude/agents/memory/README.md`.
**Agent lane:** Claude interactive on `claude/*` branches (this project is Claude+user only
for now).

@.claude/SESSION_START_PROTOCOL.md

## Workflow Orchestration

### 1. Plan First
Any **non-trivial** task (3+ steps or architectural); obvious fixes and CI findings skip
the gate.

- **New feature** → `brainstorm` skill (via `dispatch` Step 0) → delegated research → plan → approval → delegate.
- **Bug / behavior change** → delegated research (`Explore`/`pattern-finder`, never inline reading) → ≤3 clarifying questions → plan → approval → delegate; a proven cause skips to `bug-fixer`.

Write the plan (`tasks/<topic>-plan.md` / `tasks/todo.md`), get approval, delegate; gone
sideways → STOP and re-plan. This gate binds even when the dispatch skill doesn't fire.

### 2. Subagent Strategy
- Offload research/exploration to subagents; keep the conclusion, not the file dump.
- **Never read a large file in full to search it — `Grep` instead** (enforced by `.claude/hooks/read-guard.sh`). Never `Read` a subagent's `.output` transcript.
- **Any tool call likely to take more than a few seconds uses `run_in_background: true`.**
- Scoping, tiered tool-call caps, `test-writer` chaining: `dispatch` skill; research subagents: `.claude/README.md`.

### 3. Self-Improvement Loop
After ANY correction, file it where its reader will see it: agent-role-specific →
`.claude/agents/memory/<agent-name>.md`; codebase-wide rule with a path signature →
`.claude/rules/*.md` with a `paths:` glob; main-context process rules and judgment no glob
captures → `tasks/lessons.md`. Routing contract: `.claude/agents/memory/README.md`.

### 4. Verification Before Done
CI is the gate, not local runs — full rule (incl. docs-only exemption):
`.claude/rules/testing-verification.md`.

## PR Review & Merge Pipeline

Stage sequencing, review replies: the **`pr-review-pipeline` skill**. The rule below binds
regardless.

**Merging to `main` always requires an explicit human "merge" command — no exceptions,
ever.** (hook-enforced: merge-gate.sh) No inferred consent counts.

**Mandatory pre-merge CHANGELOG check:** `.claude/rules/changelog-conventions.md` — hard
gate on `merge_pull_request` for every PR.

## Delegation-First Mandate

The main context is for user communication, routing, monitoring, review, and pushing.
**All code changes happen in subagents with worktree isolation** — never edit a file
inline when the task can be delegated (incl. markdown/config edits); route via the
**`dispatch` skill**. A short closed set stays inline; **anything not on the inline
closed set is delegated**. The closed set and the agent routing table live in the
**`dispatch` skill — the single canonical copy**.

**Subagent Git Contract**: base branch is `main` by default; exact target branch stated
per dispatch; subagent verifies `git branch --show-current` before its first commit (abort
on mismatch); main context runs `scripts/verify-agent-work.sh <branch> [<base-ref>]` before
"done"/push — full contract in the `dispatch` skill.

## Task Management

Plan first (above); track progress and document results in `tasks/todo.md`. Run the
**`session-wrap-up` skill** only when explicitly commanded — never automatically. Keeping
both task files current is a mandatory pre-merge check —
`.claude/rules/task-files-conventions.md`.

### Pull Request Defaults
- **Always draft** (`--draft`); mark ready once complete/tested/pushed.
- **Always squash merge** (never merge/rebase): concise subject, blank line, short bullets.

## Core Principles

- **Simplicity First / No Laziness / Minimal Impact** — simplest root-cause fix; touch only what's necessary.
- **TypeScript + ESM, safe error logging** — `.claude/rules/js-code-conventions.md`.
- **Money is never a float** — Postgres `numeric` → Drizzle string → decimal.js math.
- **Multi-tenant isolation is non-negotiable** — every tenant-scoped query is `tenant_id`-scoped and RLS-guarded; a missing scope is a data-leak bug on sight.
- **Secrets encrypted at rest** — OAuth tokens are AES-256-GCM encrypted, never plaintext.
- **The approval bar** — *"would a senior/staff engineer approve this?"*; skip for small, obvious fixes.
- **Dead code** — the `dead-code-audit` skill before deleting anything knip flags.
- **API & type guardrails** — never guess; confirm every API call/webhook/field name against the vendor spec — `.claude/rules/api-type-specs.md` / `api-type-guardian` skill. Jobber fields need live GraphiQL verification before real queries.
- **Host-portable by construction** — all backing services via env connection strings; app containers stateless; state only in the Postgres volume. Keeps the Vultr → Lightsail → EC2 path a redeploy, not a rewrite.
- **Deploys are owner-only** — Claude and subagents never trigger, run, or request a deployment: no deploy hooks, no `gh workflow run deploy`, no xCloud MCP write op (sites, servers, cron, SSL, supervisor), no SSH-based deploy. Deployment and server/panel config are the owner's, via the xCloud control panel. Reading xCloud state for diagnostics is fine.
