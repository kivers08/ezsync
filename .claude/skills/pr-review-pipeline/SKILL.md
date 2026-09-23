---
name: pr-review-pipeline
description: Use when driving a PR through review after subscribing to it via subscribe_pr_activity — sequences the pr-reviewer pass, CI, and merge readiness in a fixed order. Trigger on "PR review", "ready for review" webhook, or a PR reaching draft->ready transition.
---

# PR Review & Merge Pipeline

## Current status

> **Review gate: the `pr-reviewer` agent.** This project is Claude + user only — there are
> no third-party automated reviewers (no Copilot, Gemini, or Jules). The `pr-reviewer`
> agent is the acting primary review gate for every PR, dispatched in the background after
> a PR is marked ready. It returns findings only to the main session and posts nothing to
> GitHub itself: no findings → trigger CI; findings → delegate the fix → push → trigger CI.
>
> If a third-party automated reviewer is set up later, add it here and record **who**
> verifies its availability and **when** — never infer availability from the calendar.

## The gate — every PR, whatever its base branch

Per `tasks/test-environment-plan.md`'s "Branching & PR gate model" section, routine agent
work now bases off and PRs directly into `main` — there is no cheaper `test`-tier gate.
`main` is the routine, default target, but the pipeline is **not** scoped to `main`: an
epic-unit PR into its epic branch (the one non-`main` base `CLAUDE.md`'s "Subagent Git
Contract" permits) follows this exact same pipeline. Nothing below is conditional on the
base branch.

**Every PR gets the full pipeline below**: the mandatory CHANGELOG close-out, the
`pr-reviewer` pass, CI — subject only to the narrow docs-only exemption in
`.claude/rules/testing-verification.md`, restated at stage 3 — and stage 6's explicit
human "merge" command. `CLAUDE.md`'s "no exceptions, ever" human-merge rule has no
carve-out for any PR, `claude/*` included; the CHANGELOG gate and the human-merge command
have no exemption at all.

When subscribed to a PR (via `subscribe_pr_activity`), follow these stages **in order —
review always before CI, never the reverse:**

0. **Draft.** The PR stays a draft while code changes are in progress.

1. **Ready = the trigger — but only once pushing for this round is fully done.** Once code
   changes are complete and tested, but **before** pushing: close out `CHANGELOG.md`'s
   `[Unreleased]` section into a dated header (the mandatory pre-merge check in CLAUDE.md —
   do it now, not in stage 4, so it lands in the same push as the code). Spawn `doc-updater`
   in the background (`isolation: "none"`) with a prompt that names the PR's branch
   explicitly (`Branch: <name>`) — `doc-updater`'s Step 0 refuses a dispatch that does not
   name one — scoped to *only* the two-part check in CLAUDE.md's "Mandatory pre-merge
   CHANGELOG check" — no `docs/`, `README.md`, or `AGENTS.md` edits this run. Review its diff, then push the code and the
   CHANGELOG close-out together in one push for the round; `doc-updater` never pushes
   itself. Once that's landed: mark the PR ready
   (`mcp__github__update_pull_request` with `draft: false` — a standard step, do it
   proactively, don't wait to be asked). Then dispatch `pr-reviewer` in the background as
   the primary reviewer (same pattern as the `review` skill's Step 2 —
   `run_in_background: true`, then end the turn) — once, after every outstanding push for
   this round has landed, never before or between pushes. Do **not** trigger `ci.yml` yet
   — the review runs first.

2. **Branch on the `pr-reviewer` result.** `pr-reviewer` returns findings only to the main
   session and posts nothing to GitHub, so there are no review threads to reply to.
   - **No findings:** go straight to stage 3.
   - **Findings:** for each, either fix it or decide it needs no action. Any actual
     code/test/doc fix goes through the Delegation-First Mandate — dispatch `bug-fixer`
     (or `feature-implementer` for larger changes) with worktree isolation, review its
     diff, then push. These fixes are exempt from the plan-mode intake gate — a
     review/CI finding is already a fully-specified defect with a proposed
     remedy, so dispatch it directly with no brainstorming or research step first.
     Ambiguous/architectural findings go to the user via `AskUserQuestion` rather than
     being fixed unilaterally. Skip duplicates/no-ops silently.
   - Fold the review-driven fixes into the eventual squash-merge commit's bulleted list
     (per CLAUDE.md's "Squash commit message").
   - Once every finding is resolved, push all the fix commits together, then proceed to
     stage 3. Do **not** request a second review pass by default — only if a fix was large
     or risky enough to warrant independent verification, and even then dispatch it once,
     after every fix commit for this round has been pushed — never mid-round.

3. **CI.** Trigger `ci.yml` on the self-hosted runner (`gh workflow run ci.yml --ref
   <branch>`). Poll to completion with `gh run watch <run-id> --exit-status` or
   `mcp__github__pull_request_read` (`method: get_check_runs`); on failure read logs
   (`gh run view <run-id> --log-failed`), fix, re-trigger. **This is the cycle's only
   automatic CI trigger** — don't fire it earlier than this stage, and don't fire it
   again in stage 4 or 5. The CHANGELOG close-out already happened in stage 1, before this
   stage even runs. A later documentation-only push (e.g. a stage-4 CHANGELOG amendment)
   does **not** reopen this trigger; only a subsequent push touching non-documentation
   files would.
   - **Docs-only exemption (the only skip, and it is narrow)** —
     `.claude/rules/testing-verification.md` is authoritative; do not widen it here. Skip
     the trigger only when **both** hold: (a) everything changed since the last green run
     on this branch is prose (`*.md`, `docs/**`, `tasks/**`, `CHANGELOG.md`, `README.md`,
     `AGENTS.md`), and (b) the branch's merge-base is current with its base branch — a
     stale merge-base still requires CI even for a docs-only diff. Any touch of `src/`,
     `tests/`, `scripts/`, `package.json`/`package-lock.json`, `.github/workflows/*.yml`,
     `packages/db/migrations/*.sql`, `packages/db/schema/**`, `.env.example`, or anything
     else affecting runtime, dependency resolution, or the lint/test result **always**
     requires a CI run.

4. **Documentation updates.** Once CI is green and every stage-2 finding is resolved,
   submit remaining docs as their own pre-merge step, before squash-merging. The mandatory
   CHANGELOG close-out already happened in stage 1, before the review dispatch — see the
   amendment note below if it needs a follow-up. Three parts here:
   - **(a) Mandatory:** confirm `tasks/todo.md` reflects this PR's final state — plan
     items checked off, and a review/results section documenting what was done.
   - **(b) Mandatory:** confirm `tasks/lessons.md` captures any corrections or lessons
     from this PR's cycle.
   - **(c) Judgment call:** does this PR's change affect `README.md`, `docs/**`, or
     `AGENTS.md`? If yes, update them now, in this same step — not as a later follow-up PR.
   - On a docs-only PR, (c) may be a no-op — but **(a) and (b) are never skipped.** A
     docs-only or process PR can still have todo items to check off and a lesson to
     capture.
   - **CHANGELOG amendment (rare):** if stage 2's review-fix commits made the stage-1
     CHANGELOG entry incomplete or wrong, amend it now as part of this same docs push.
     This is documentation-only and does not start a new review round, so it does not
     require another `pr-reviewer` dispatch.
   - Pushing this documentation commit does NOT require re-triggering `ci.yml` (CLAUDE.md,
     "Verification Before Done").

5. **Session wrap-up — only if the user explicitly asks.** Per CLAUDE.md's Task
   Management section, `session-wrap-up` runs ONLY on an explicit user command, never
   automatically as part of this pipeline. If not asked for, skip to 6. If asked for:
   `session-wrap-up` has no conditional/skip mode — its step 2 fires `ci.yml`
   unconditionally — so when stage 3 already went green, do NOT invoke the skill as one
   monolithic unit. Instead work through its remaining steps by hand, skipping step 2
   entirely: step 1 (commit/push anything outstanding), then steps 3–8 (`tasks/lessons.md`,
   `tasks/todo.md`, PR title/description, CI-green verification against stage 3's existing
   run, CHANGELOG close-out, squash-merge offer). Only run the skill end-to-end if stage 3
   has not produced a green run yet.

6. **Stop and wait.** Report CI-green plus a ready-to-merge summary. Do NOT merge — wait
   for the user's explicit "merge", then squash-merge to `main`. This is universal: no
   category of change (docs-only, dependency-only, hotfix, however trivial) skips the
   explicit-approval requirement. Do not merge on inferred consent, on prior approval of
   a similar change, or because the user said "go ahead" about something else — the merge
   action needs its own explicit go-ahead.

## Replying to PR review comments

The `pr-reviewer` gate posts nothing to GitHub — it returns findings to the main session
only, so its findings create no review threads. This section applies only when a **human**
leaves review comments on the PR.

Whenever a code change is made in direct response to a PR review comment, reply to that
comment on GitHub, briefly stating what was done and why. Use
`mcp__github__add_reply_to_pull_request_comment` for **inline code review thread** replies
only; use `mcp__github__add_issue_comment` for general PR thread comments (the inline-reply
tool returns 422 on non-review comments).
