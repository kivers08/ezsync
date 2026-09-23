---
name: dispatch
description: Meta-skill for delegating any code-change task to an implementation subagent with worktree isolation. Use when the user gives any task that requires writing, editing, or deleting code — routes, services, handlers, tests, migrations, bug fixes, or PR reviews. Keeps the main context clean by routing work to the right subagent. Use when task phrases like "implement", "add", "fix", "build", "write a test", "review this PR", or any imperative implying code changes appear. For a non-trivial new feature or an unclear-cause bug, this skill first routes through CLAUDE.md's "Plan First" intake gate (brainstorm or research → plan → approval) before spawning an implementation subagent.
---

# Dispatch

When a user gives a task that requires code changes, **do not implement it in the main context**. Route it to the appropriate subagent with worktree isolation so the main context stays clean for monitoring, updates, and communication.

## Step 0: Triage — classify the lane, then does this need the intake gate first?

**First, classify the request into a lane** — not every task is a code change:
- **Business/advisory** (pricing, strategy, competitors, market questions) → dispatch
  `market-analyst`. Read-only — no worktree needed.
- **Copy** (ads, email, SMS, web copy, social) → dispatch `copywriter`.
- **Deliverable** (deck, doc, spreadsheet, PDF, flyer, designed page) → dispatch
  `deliverable-builder`.
- **Docs about the codebase itself** (CHANGELOG, README, AGENTS.md sync) → existing
  `doc-updater`, unchanged.
- **Code** → continue to the existing triage/classification below, unchanged.

Non-code lanes (`market-analyst`/`copywriter`/`deliverable-builder`) follow the **same**
delegation-and-background rules as code lanes: dispatch with `run_in_background: true`
and keep the main context reserved for conversation, not the work itself.
`market-analyst` is read-only (no worktree/branch needed, spawn with no isolation, like
`pr-reviewer`); `copywriter` and `deliverable-builder` write files and follow the normal
worktree/branch Subagent Git Contract just like `feature-implementer`/`bug-fixer`.

**For a code task, the gate below is unchanged:**

- **Small, obvious fix, proven-cause bug, or a CI review-finding fix?** → skip
  straight to Step 1, no gate.
- **New, not-yet-existing feature?** → invoke the **`brainstorm` skill**
  (`.claude/skills/brainstorm/SKILL.md`) first. Do not classify or spawn an
  implementation subagent until that skill produces an approved plan.
- **Bug or change to existing behavior with an unclear cause?** → delegate research to
  an `Explore`/`pattern-finder` subagent first, then ask at most 1-3 clarifying
  questions the code couldn't answer, then write the plan to `tasks/todo.md`, then get
  approval. Only then proceed to Step 1.

## Step 1: Classify the task

This table is the **single canonical routing + model table** (moved here from
`.claude/README.md`, which now just points here). Every agent defined in
`.claude/agents/*.md` pins its model in frontmatter (`model:`), so cost/capability track
the job, not the calling session.

| Task type | Subagent to spawn | Pinned model |
|---|---|---|
| New feature, enhancement, new route/service/handler/migration | `feature-implementer` | `claude-sonnet-5` |
| Bug report, failing test, error log, regression | `bug-fixer` | `claude-sonnet-5` |
| "Write tests for X", coverage gap | `test-writer` | `claude-sonnet-5` |
| "Review this PR", "check before merge", code-quality/security pass | `pr-reviewer` (read-only, no worktree) | `claude-opus-5` — carries the review gate |
| Pre-merge CHANGELOG close-out; post-change doc sync (CHANGELOG/docs/README/AGENTS.md, ad-hoc) | `doc-updater` (no worktree — commits on the current branch; never edits source code; **never `tasks/**` or `.claude/**` — its constraints make it refuse those, route them to general-purpose**; dispatch must state `Branch:` explicitly — its Step 0 refuses a dispatch that names none, and the correct value is the main context's own current branch) | `claude-sonnet-5` |
| Pre-build research: find existing reusable code + conventions to match (`file:line` + placement advice) | `pattern-finder` (read-only) | `claude-haiku-4-5-20251001` |
| Validate proposed endpoints/mutations/fields against `packages/shared/types/vendor/` | `api-type-auditor` (read-only) | `claude-haiku-4-5-20251001` |
| Business/advisory question (pricing, strategy, competitors, market) | `market-analyst` (read-only; see Step 0 lane triage) | `claude-sonnet-5` |
| Customer-facing copy (ads, email, SMS, web, social) | `copywriter` (see Step 0 lane triage) | `claude-sonnet-5` |
| Finished artifact (deck, doc, spreadsheet, PDF, designed page) | `deliverable-builder` (see Step 0 lane triage) | `claude-sonnet-5` |

The built-in `Explore` agent and the catch-all `claude` agent are **deliberately
unpinned** — they inherit the session model by design (full rationale:
`.claude/README.md`).

**Do not delegate:** only the items on the list below — **this is the closed set's single
canonical home** (CLAUDE.md keeps the mandate and points here):
- Answering questions or explaining code
- Collaborative brainstorming and clarifying-question intake during plan-mode task
  triage (the research that grounds the resulting plan is itself delegated to an
  `Explore`/`pattern-finder` subagent — asking is inline, tracing code is not)
- Reading files / grepping for symbols to answer a question
- Read-only git inspection (`git status`, `git diff`, `git log`, `git branch`, `git show`) — orienting or reviewing state, not a code change
- `git push` after reviewing a subagent's committed work
- `gh pr create` / MCP PR operations
- Spawning and monitoring subagents
- `/session-wrap-up` (only when explicitly commanded)
- Session bookkeeping/status logging in `tasks/todo.md`, and for a multi-unit epic, its `tasks/<epic>-ledger.md` (a narrow, pre-established exception — do not generalize it beyond these two file patterns)
- Appending a curated entry to `.claude/agents/memory/<agent-name>.md` (the same narrow bookkeeping-style carve-out as `tasks/todo.md` above — not a general license to edit other `.claude/` files inline)
- `tasks/lessons.md` and `CHANGELOG.md`, only from the session-wrap-up flow: session-wrap-up Turn 2 writes `tasks/lessons.md` and closes out `CHANGELOG.md` `[Unreleased]` directly — the same narrow bookkeeping carve-out; not a general license (the hook allows these two paths unconditionally; the session-wrap-up restriction is prose-only)

Anything not on that list gets delegated, including markdown doc/config edits.

## Step 2: Build the subagent prompt

Include ALL of the following — the subagent has no memory of prior conversation.
(The `Key rules` line below is a verbatim paste kept because whether SUBAGENTS receive
`.claude/rules/` path-scoped injection is UNVERIFIED — the official Claude Code docs do
not address subagents; this repo's own `.claude/README.md` §Rules and
`.claude/agents/memory/README.md` assert it, but it has never been observed end-to-end;
forge Phase 0 check 9 (`tasks/forge-plan.md`) decides. Canonical home:
`.claude/rules/js-code-conventions.md` — edit that file first, then mirror here.)

**First, check the target agent's `tools:` list** (frontmatter in
`.claude/agents/<name>.md`; summarised in `.claude/README.md`) and never ask for an
action the agent has no tool for. A dispatch that asks for something outside the tool
list either fails loudly — best case — or gets papered over in the summary, and the main
context then pushes believing work is committed when it is not. Specifically:

- **A write-only agent has no shell and cannot stage, commit, or push.** `copywriter`'s
  tools are `Read, Write, Edit, Grep, Glob` — no `Bash`. End any such prompt with *"leave
  the files in the working tree; the main context will commit them"* and budget a
  main-context turn to verify and commit. On the 2026-08-28 catalogue rewrite the prompt
  ended with "commit only, do not push"; the agent wrote all 11 files correctly, then
  reported plainly that it could not stage or commit them and left them untracked. It
  handled the impossible instruction well — the instruction should never have been given.
- **Keep the verification in the dispatcher, not in the agent's self-report.** For copy
  work, keep dispatching with explicit banned-term lists and keep running the
  extract-then-grep check over the proposed copy alone (extract the "Proposed
  description" blocks, then grep those). In the same run `copywriter` caught itself
  writing a `BRAND_VOICE` §3 banned term mid-draft, fixed it, and disclosed both — it
  defaults conservative. That still doesn't substitute for the independent check: a
  self-report covers what the agent noticed, not what it missed. Do not downgrade the
  check because the report looks thorough.

```
Task: <one-paragraph description of what to build/fix, fully self-contained>

Branch: <the branch pre-created for this dispatch in Step 3 — NOT the main context's own
  current branch>
  (Carve-out for `doc-updater`: this field is inverted for that agent. It runs
  `isolation: "none"` in the main checkout, so `Branch:` must be the main context's own
  current branch, not a pre-created one — and its Step 0 refuses a dispatch that names none.)
Base branch: main

Context:
- Memory spoke: read .claude/agents/memory/<agent-name>.md in full at Step 0 (small file;
  your role-specific corrections live there)
- Stack: TypeScript (ESM, Node 22) / Express 5 API + shared-image sync-worker / Postgres +
  Drizzle ORM / Redis (ioredis, optional at dev) / Vitest
- Entry point: apps/api/src/index.ts (bootstrap); apps/api/src/worker/sync.ts (sync-worker)
- Layering: routes (thin) → services (pure functions) → repositories (Drizzle client only) —
  tenant-scoped queries run under RLS context
- Key rules (verbatim from .claude/rules/js-code-conventions.md): TypeScript + ESM only
  (import/export, never require/module.exports); log err.message in catch, never the full
  error object (axios embeds tokens in config.url); a catch must change the outcome (return,
  release the claim, or rethrow) — a log-and-fall-through is a bug; money is never a float —
  Postgres numeric comes back from Drizzle as strings, do all math with decimal.js and guard
  nullable inputs with ?? 0 (new Decimal(null) is NaN); validate all external input (env,
  webhook bodies, HTTP params, vendor responses) with zod at the boundary; every
  tenant-scoped query is tenant_id-scoped under the tenant's RLS context — a cross-tenant
  read is a data-leak bug; prefer timestamptz/Date, never compare ISO date strings with </<;
  no floating promises (await or void); OAuth tokens (Jobber/QBO) are read per-tenant from
  the encrypted store, never from env
- Grep tasks/lessons.md for topics the dispatch touches (`grep -n -i '<topic>' tasks/lessons.md`,
  then a ranged read of the matching entry with offset/limit) before starting — never read it in
  full; the read-guard denies unranged reads by design
  (tasks/lessons-archive.md holds superseded ones; grep it, never read it in full)
- GREP-ONLY, NEVER READ IN FULL: packages/shared/types/vendor/square_api.json (~3.2MB),
  packages/shared/types/vendor/jobber-introspection.json (~2.3MB),
  packages/shared/types/vendor/jobber-schema.graphql (~432KB), CHANGELOG.md, and tasks/*-archive.md.
  Use small -A/-B/-C context windows; a full read blows the context budget. For
  CHANGELOG.md: read only the top [Unreleased] section when appending, or grep
  `^## \[` for headers. Same for any other generated/vendored/spec-like large file —
  grep first; read targeted line ranges via offset/limit only if truly necessary.
  tasks/lessons.md and tasks/todo.md get the same treatment: read only through the
  end of the `## Index` section (a ranged read), then grep the specific
  heading/topic text needed — never read either file in full.
  .claude/hooks/read-guard.sh denies unranged reads of these — that's the guardrail
  working, not a bug; re-issue with offset/limit or grep instead

Budget and result hygiene:
- Hard limit: <N> tool calls (dispatcher sets N per dispatch: 25 small fix / 35 standard /
  50 restructure-scale). Count every tool call you make starting from 1. The moment you
  reach N — whether or not the task is finished — you MUST stop making tool calls and
  immediately output a structured progress report instead: what's done, what's verified,
  what remains, and the exact next step for a follow-up run to pick up from. Do not
  exceed N under any circumstances, including "just one more to verify." This is a hard
  stop, not a suggestion — cost is quadratic in tool-call count, so a follow-up run
  picking up cleanly is always cheaper than one long-running agent that overruns.
  RESERVE YOUR LAST 3 CALLS for verification and the final report — never spend call N
  on an edit.
- Check scope with `git diff --stat` / `--name-only`, not full diff bodies. Use `grep -c`
  or head-limited greps for presence/absence checks instead of dumping whole files.

Subagent Git Contract (mandatory):
(a) Your exact target branch is: <branch>
(b) Before your first commit, run `git branch --show-current` and confirm it matches
    the branch above. If not, STOP and report the mismatch — do not commit.
(c) Never create or commit to an auto-generated worktree branch. You were given a
    pre-created worktree path — work only inside it, on the branch specified.
(d) End your final report with: branch name, commit SHA(s), and
    `git log --oneline origin/main..HEAD` (use `<base>..HEAD` instead when this dispatch
    was given an explicitly non-`main` base, e.g. an epic-unit branch).

Files to focus on: <list specific files if known>
Skills to apply — Read .claude/skills/<name>/SKILL.md for each before writing code: <applicable skills: add-service-module / add-route / add-jobber-webhook / etc.>

Before your commit: run `npx prettier --write <files you touched>` — CI's `format:check`
fails the build on unformatted `.ts`/`.tsx`, and this is the step that catches it before
push, not after. Run this AFTER `npx eslint <files you touched>` and before `git add`. Scope
both to the files you touched — never the repo-wide `npm run lint` / `npm run format:check`,
which are CI's own gates.

Acceptance criteria:
- `npx eslint <files you touched>` passes (no new errors)
- `npx prettier --check <files you touched>` passes (no unformatted files) — CI enforces
  this repo-wide as its own gate, separate from lint
- `npm run typecheck` passes (no new type errors)
- <specific functional requirement>
- <specific functional requirement>
(Run only the specific test file for the task with `npx vitest run <file>` — never the full
suite. CI runs lint + typecheck + the full suite after the main context pushes, and verifies
it via get_check_runs.)

Do NOT push. Report back with: files changed, decisions made, anything requiring manual verification — plus, for `feature-implementer`/`bug-fixer`, the worktree path/branch and the list of functions needing test coverage. That list is MANDATORY (empty only if truly nothing is testable) — it is the direct input to the required test-writer chain the dispatcher runs next (Step 5's test-coverage gate). (Test count only applies to `test-writer`'s own report.)
```

### Size the dispatch — chain and split rather than raise the ceiling

- When a dispatch's code changes touch more than one or two files, or need real
  test-authorship (new test cases, not just fixing an assertion an approved change
  broke), **chain `test-writer` afterward** (Step 3's chained mode, same worktree)
  rather than folding it into the `feature-implementer`/`bug-fixer` prompt.
- When a task has genuinely independent, non-overlapping file sets (one part touches
  only webhook handlers, another only a payment form), dispatch them as **parallel
  sibling agents**. Each agent's budget stays realistic because its scope is actually
  narrower, and wall-clock time drops.
- **Raising the tool-call ceiling is a last resort**, for a task that is genuinely one
  cohesive unsplittable unit — never the default response to a blown budget. A single
  dispatch carrying three substantial code changes *plus* all five affected test files
  *plus* the verification loop blew a stated 35-call limit at 74 calls and landed **zero
  commits**; a second, narrower dispatch was needed just to finish. The root cause was
  the skipped `test-writer` chain, not the number 35.

## Subagent Git Contract (full rationale)

Prevents a recurring failure mode: a worktree-isolated subagent silently commits to its
own auto-generated branch (`worktree-agent-<id>`) instead of the shared branch the main
context expected, forcing a manual recovery.

- **Every dispatch prompt states the exact target branch** — never leave a subagent to
  infer one.
- **Every subagent verifies before its first commit**: run `git branch --show-current`
  and confirm it matches the branch it was told. If it doesn't, STOP and report the
  mismatch — do not commit.
- **Never commit to an auto-generated worktree branch when an explicit target branch was
  given.** (worktree pre-creation mechanics: Step 3 below)
- **Every subagent's final report ends with proof**: the branch name, the commit SHA(s)
  it created, and `git log --oneline origin/main..HEAD` (a routine dispatch's base is
  `main` — use `<base>..HEAD` instead only for an explicitly non-`main` base, e.g. an
  epic-unit branch).
- **The main context verifies this proof before relaying "done" or pushing** — via
  `bash scripts/verify-agent-work.sh <expected-branch> [<base-ref>]`, run from inside the
  worktree (see Step 5 above). The script's own default base-ref is `origin/main`, which
  IS the routine dispatch base — so `<base-ref>` can be omitted for ordinary work. Pass it
  explicitly only for a deliberately non-`main` base (e.g. an epic-unit branch based on
  `claude/repo-wide-refactor`).

## Step 3: Spawn with the right isolation and ALWAYS run in background

- **`feature-implementer`, `bug-fixer`**: pre-create the worktree on an explicit branch
  **before** spawning — `git worktree add -b <branch> <path> <base>` (e.g. `git worktree
  add -b claude/<task-slug> .claude/worktrees/<task-slug> main` — ordinary feature/bug
  work branches off `main`; use a different `<base>` only for an epic-unit branch or
  another explicitly-stated base) — then spawn the agent
  pointed at `<path>` **without** `isolation: "worktree"`. Plain `isolation: "worktree"`
  auto-generates a `worktree-agent-<id>` branch that will never match the `Branch:` value
  in the Step 2 prompt template, which the Subagent Git Contract (see CLAUDE.md) requires
  the agent to abort on. Do not use the alternative of telling the subagent to check out
  the intended branch inside an auto-created worktree instead — `git checkout <branch>`
  fails with "already checked out at ..." whenever that branch is checked out elsewhere
  (e.g. the main checkout itself is sitting on it). Use this same pre-created branch name
  as the Step 2 template's `Branch:` value — not `git branch --show-current` (that's the
  main context's own current branch, not necessarily the one being dispatched). Still set
  `run_in_background: true`.
- **`test-writer`, standalone** (an explicit "write tests for X" / coverage-gap request, not chained after another agent): pre-create the worktree the same way as above, then spawn without `isolation: "worktree"`, with `run_in_background: true`.
- **`test-writer`, chained after `feature-implementer`/`bug-fixer`**: spawn *without* `isolation: "worktree"` — a fresh worktree would branch off `main` and never see the code the prior agent just committed. Include the exact worktree path and branch name from the prior agent's report in the prompt, instruct it to `cd` into that path first, and tell it to use absolute paths rooted at that worktree for every Read/Write/Edit call afterward (those tools don't follow shell `cd`). Still `run_in_background: true`. Only review and push once both the code commit and the test commit have landed — test-writer's own commit step (see its Step 4) is what produces the test commit.
- **`pr-reviewer`, `doc-updater`**: no worktree needed — spawn with `run_in_background: true`. (`doc-updater` still edits and commits directly on the current branch, unlike read-only `pr-reviewer`. Its dispatch must state `Branch:` explicitly as the main context's own current branch — the opposite of the worktree-agent case above — because its Step 0 refuses a dispatch that names none.)
- **Before spawning any agent that works in the MAIN checkout** (`doc-updater`, general-purpose units — anything not worktree-isolated and not read-only), run `touch .claude/.dispatch-active` first, so the stop hook knows a background agent may own in-flight changes (Step 5 clears it after verification).

- **The worktree's base is not automatically what you assume.** Two failures, one
  cause. (a) *Continuing an existing branch:* when the target branch already exists,
  the prompt's first instruction must be
  `git fetch origin <branch> && git reset --hard origin/<branch>` — a worktree created
  off `main` will simply be missing the files the session has been working on. (b)
  *Chained sequences:* after spawning the first agent of a chain, run
  `git merge-base --is-ancestor <expected-commit> <branch>` before trusting any
  `main..HEAD` diff — a worktree branched from a commit that predates a doc/plan commit
  you made moments earlier will report those files as *deleted*. If it fails,
  `git rebase main` on the worktree branch first (safe while the branch is unpushed).
  Verify the reported commit's parent before cherry-picking, in case the reset was
  skipped or targeted the wrong ref.

**Always set `run_in_background: true`.** This keeps the main window free for the user to type while the agent works. You will be notified automatically when it finishes.

### Same unit → continue the agent; new scope → fresh dispatch

State the dispatch's **complete** scope in the Step 2 prompt, including the full "Files to
focus on" list, before spawning. A subagent's stated file-scope constraint is a security
boundary, not a convenience — it will (correctly) refuse work outside it.

- **Follow-up work on the same unit** — review-finding fixes, an added test, a second pass
  over the same files — **defaults to `SendMessage` to the same agent.** It keeps its full
  context (what it read, why it chose what it chose); a fresh dispatch briefed from a
  summary loses all of that. Clarification, correction, or new facts are the everyday
  examples of this same-unit case. Resuming replays the prior transcript, so expect a
  higher token cost for the round (an earlier measurement put it at roughly double);
  accepted as the cheaper trade against rebuilding context from a summary.
- **A genuinely new scope** — different files, or a different task — gets a fresh dispatch
  with a complete brief. Don't grow scope mid-flight via `SendMessage` by adding files or
  tasks the agent was told not to touch; let it finish (or stop it) and re-dispatch.
- A subagent refusing out-of-scope work sent via `SendMessage` is behaving correctly —
  treat the refusal as a signal the original dispatch was under-specified, and re-dispatch
  properly. Don't re-send the same request harder.

## Step 4: Tell the user what's running — then END YOUR TURN

Immediately after spawning, output exactly one line:
> "Delegated to `<subagent-name>` (background). Working on: <one-line task summary>. I'll report back when it finishes — you can keep typing."

Then **stop** — do not add more text, do not call more tools. End the turn so the user's input box is available.

## Step 5: When the subagent finishes (follow-up turn)

The agent runs in the background, so review-and-push happens in a **separate follow-up
turn**, triggered by the completion notification — NOT in the spawn turn. This is by
design: it keeps the main window open while the agent works.

When the notification arrives, first verify the agent's claim before summarising it: run
`(cd <worktree-path> && bash scripts/verify-agent-work.sh <expected-branch> [<base-ref>])`
— it checks the worktree is on the expected branch, has a clean tree, and has commits
ahead of the base, and prints the commit log as proof — against what the agent
reported — don't relay the subagent's prose as-is. The script's `origin/main` default IS
the routine dispatch base, so `<base-ref>` can be omitted for ordinary work; pass it
explicitly only when verifying a deliberately non-`main` base like an epic-unit branch —
otherwise the script reports every commit already on that base as "the agent's own work,"
not just this dispatch's. (A worktree-isolated subagent
can end up committing to its own auto-generated branch instead of the shared branch you
expected; this script catches that before it reaches push.) The script's own PASS output
already includes the full `<base>..HEAD` commit log, so no separate log command is needed
even for a chained hand-off (e.g. `test-writer` run after `feature-implementer` in the
same worktree).

After verifying the work of a main-checkout agent (`doc-updater`, general-purpose
units), run `rm -f .claude/.dispatch-active` to clear the marker Step 3 set.

**Never relay a subagent's SQL to the owner unchecked.** Any SQL leaving this session
for a human to run on the live database is API-surface: grep the Drizzle schema under
`packages/db/schema/` for every table and column in it before it goes out, and say where
each was verified. This binds the **main context** — the `bug-fixer` spoke's matching rule
binds only the agent, and the coordinator is the last checkpoint. An agent that produces
operator-facing SQL naming a column that does not exist would have it error on production
mid-incident; a prompt that hands you SQL is not verification either — check it against the
schema yourself.

### Test-coverage gate (required, after verifying a `feature-implementer`/`bug-fixer` report)

1. In the worktree, run `git diff --name-only <base>..HEAD` (same `<base>` as the
   verify script above).
2. If any non-test source file changed (`apps/**/src/`, `packages/**/src/`, `scripts/`)
   and **no** `*.test.ts` file changed in that range, chaining `test-writer` (per Step
   3's chained mode) is **REQUIRED** before push — the report's "functions needing test
   coverage" list is the chained test-writer's direct input.
3. The **only** exemptions, each of which must be stated aloud to the user when
   claimed: the change is genuinely untestable in Vitest (config/markdown/generated
   files), or the user explicitly waived tests for this dispatch. **"It's small" is
   not an exemption.**
4. **Learning gate:** if this subagent's work needed ANY correction (wrong branch,
   missed convention, re-done step, reviewer finding), append a curated entry to
   `.claude/agents/memory/<agent-name>.md` NOW — before that agent type's next
   dispatch. An unrecorded mistake repeated by the next dispatch is a process
   failure, not the agent's.

Then summarise its report to the user:
- What was built/fixed (file paths)
- Test count and pass/fail (once `test-writer` has been chained in, if applicable)
- Whether it's ready to push or what needs fixing first

### Long-running Bash also goes in the background
When you do run commands inline (review, verification), background anything slow so the
window stays open: `npm test`, `npm install`, `npm ci`, `npx drizzle-kit migrate`,
`npm run typecheck`, `npx knip`. Spawn them with `run_in_background: true` and check the
result via Monitor / the completion notification instead of blocking the turn. Quick
commands (`git diff`, `git log`, `grep`) stay foreground.

## Step 6: Push and PR (after user approves)

1. Run `git push -u origin <branch>` from the main context — first confirm the Step 5
   test-coverage gate passed or was explicitly exempted (a push-time hook also warns on
   src/-without-tests/ pushes).
2. Create a draft PR if one doesn't exist.
3. Offer to spawn `pr-reviewer` to review the diff on the open PR before it's marked ready for review.

From here the PR is driven by the **`pr-review-pipeline`** skill (pr-reviewer → CI → docs →
merge on explicit human approval).

## Multi-unit epics: ledger file (optional)

For an epic split across several sequential units/PRs (e.g. a repo-wide refactor),
maintain `tasks/<epic>-ledger.md` yourself in the main context — one line per unit:
`Unit <N>: complete (commit <sha>, PR #<n>)` or `Unit <N>: pending`. This is the same
session-bookkeeping carve-out as `tasks/todo.md` above, not a delegated task. Check it
before dispatching a new unit so a session resumed after context compaction doesn't
re-dispatch already-finished work. Skip this for single-unit tasks — it's overhead a
normal dispatch doesn't need.
