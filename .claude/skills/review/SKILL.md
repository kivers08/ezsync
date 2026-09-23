---
name: review
description: Canonical review skill — run a code review or security review of the current branch diff vs its base branch (main by default, determined per-invocation). Takes a mode argument, `full` (code review) or `security` (security-focused). Use for "code review", "security review", "review this branch", "review this PR". Dispatches to a background pr-reviewer agent so the main window stays open.
---

# Review (background dispatch)

**Mode argument:** `full` (general code review) or `security` (security-focused). Default
to `full` when no mode is given.

**Do not run the review in the main context.** Spawn a single `pr-reviewer` agent with `run_in_background: true` and end the turn immediately.

## Step 1 — Get the current branch and its base

Run: `git branch --show-current`. Determine the base to diff against: `main` by default
for a routine `claude/*` PR, or an explicitly-stated non-`main` base for an
epic-unit branch. Confirm the base stated in the dispatch — don't assume `main`.

## Step 2 — Spawn a background pr-reviewer agent

Use the Agent tool with:
- `subagent_type: "pr-reviewer"`
- `run_in_background: true`
- The prompt below (fill in `BRANCH` from step 1, `BASE` from the base you determined, and the mode-specific blocks)

Shared prompt skeleton (both modes):

```
Perform a full {code|security} review of branch BRANCH vs BASE.

Stack: TypeScript (ESM, Node 22) / Express 5 + sync-worker / Postgres + Drizzle ORM / Redis / Vitest
Key rules: see .claude/rules/js-code-conventions.md (TypeScript + ESM only — no require/module.exports; err.message in catch blocks, never the full error object; a catch must change the outcome — no log-and-fall-through; decimal.js with ?? 0 guards on all nullable numeric columns, money is never a JS float; zod at every external boundary; every tenant-scoped query is tenant_id-scoped under RLS; timestamptz/Date, never ISO-string comparison; no floating promises); plus:
- Drizzle client access only in repository modules — never in routes or services
- OAuth tokens (Jobber/QBO) read per-tenant from the encrypted store, never from env

Run: git diff BASE...HEAD

{MODE BLOCK — angles + output shape, below}
```

### Mode block — `full` (code review)

```
Review angles — for each, surface up to 6 candidates:
A. Line-by-line: wrong conditions, null deref, missing/floating await, swallowed errors, raw SQL built by string interpolation instead of parameterized/Drizzle query builder, money coerced to a JS float
B. Removed behavior: deleted guards or error paths not re-established in new code
C. Cross-file: changed function signatures that break call sites — grep callers for every changed public function
D. Reuse: new code re-implementing something already in packages/shared/ or adjacent services
E. Simplification: redundant state, deep nesting, copy-paste blocks
F. Efficiency: N+1 queries, sequential awaits that could be Promise.all, blocking startup work
G. Altitude: validation/auth at the wrong layer, bandaids on shared infrastructure
H. Multi-tenancy: any tenant-scoped query missing a `tenant_id` scope / RLS context — a data-leak bug on sight
I. Conventions (AGENTS.md + .claude/rules/js-code-conventions.md): quote the exact rule and the exact line number that breaks it

Verify each candidate (CONFIRMED / PLAUSIBLE / REFUTED). Keep only CONFIRMED and PLAUSIBLE.

Return findings as a JSON array, ranked most-severe first, max 8:
[
  {
    "file": "path/to/file.ext",
    "line": 123,
    "summary": "one-sentence bug statement",
    "failure_scenario": "concrete inputs/state → wrong output or crash"
  }
]
```

### Mode block — `security`

```
Security angles to check:
1. SQL injection: any raw SQL built by string interpolation — use parameterized queries / Drizzle's query builder, never string-concatenated SQL
2. Command injection: exec/spawn with user-controlled input
3. XSS: unescaped user data rendered in the frontend (React/Next.js — never `dangerouslySetInnerHTML` with untrusted data)
4. Auth/authz: missing auth middleware on new routes, session/OAuth-state validation bypasses
5. Credential leakage: tokens/keys logged, full error objects (not err.message) in catch blocks — Axios embeds API tokens in config.url; OAuth tokens must stay AES-256-GCM encrypted at rest, never plaintext or logged
6. HMAC/signature bypass: Jobber / Square / QBO webhook signature verification shortcuts or missing checks (Square: raw-body HMAC verified before express.json())
7. Path traversal: file system operations with user-controlled paths
8. IDOR / tenant isolation: missing ownership checks when fetching/updating by ID; any tenant-scoped query missing its `tenant_id`/RLS scope (cross-tenant read/write is the highest-severity class here)
9. Rate limiting: new endpoints that accept user input with no rate limiting
10. Input validation: missing or bypassable zod validation at an external boundary (env, webhook body, API input)
11. Secrets in code: hardcoded credentials, API keys, or tokens
12. SSRF: outbound fetch to a user-controlled URL without blocking all IANA-reserved IP ranges

For each finding:
- Quote the exact vulnerable line
- Describe the attack vector
- State the fix

Return findings as a JSON array, ranked most-severe first (CRITICAL > HIGH > MEDIUM > LOW), max 10:
[
  {
    "file": "path/to/file.ext",
    "line": 123,
    "severity": "HIGH",
    "summary": "one-sentence vulnerability statement",
    "attack_vector": "how an attacker exploits this",
    "fix": "what to change"
  }
]
```

## Step 3 — End the turn immediately

After spawning, output exactly (matching the mode):
> "{Code|Security} review running in background (pr-reviewer agent). I'll post findings here when it finishes — you can keep typing."

Then **stop**. Do not add more text or call more tools.
