---
name: session-wrap-up
description: Use at the end of any session that changed, fixed, or added code in this repo, BEFORE committing. Operationalizes the mandatory CLAUDE.md closeout — commits and pushes, monitors the push-triggered CI run on the runner, then checks tasks/lessons.md, tasks/todo.md, commits, and updates the PR title and description with a session summary ready for merge.
---

# Session Wrap-Up

Run this checklist before the final commit. These steps are **mandatory per CLAUDE.md** —
do not skip them, even for a one-line fix.

**Two-turn flow (keeps the web window open):**
- **Turn 1:** Commit + push any outstanding changes, confirm the push-triggered CI run is going (manual dispatch only as fallback), and end the turn.
- **Turn 2 (CI completes):** Update tasks/lessons.md and tasks/todo.md, update the PR, confirm green, close out CHANGELOG.md's `[Unreleased]` section into a dated header (merging to `main` = deploying to production), offer squash merge.

> **Note:** Documentation updates are not triggered here on a schedule. The `doc-updater` subagent is available for ad-hoc Claude use, and is the required path for the mandatory pre-merge `CHANGELOG.md` close-out this skill's own step 2 performs (see CLAUDE.md's "Mandatory pre-merge CHANGELOG check").
>
> **This skill runs only on an explicit user command** (e.g. "run session wrap-up") — never automatically at the end of a session.

---

## 0. Determine the merge target first

Every PR targets `main` — there is no tiered gate (see `AGENTS.md` and
`docs/decisions/architecture.md`). Every PR, regardless of branch prefix (`claude/*`) or
size, gets the full checklist below: CI green, the `pr-reviewer` pass, a CHANGELOG entry,
and this session wrap-up. There is no cheap gate and no exemption from any of those steps.

**Merging always requires an explicit human "merge" command — no exceptions, for any
branch prefix or PR size.** No PR's merge is ever auto-authorized on green CI alone.
Confirm the PR's base branch before proceeding; run the full checklist below unchanged
for every PR.

## 1. Commit & push outstanding changes first

Before anything else, make sure all session work is committed and pushed to the feature
branch. CI runs against the pushed HEAD commit — uncommitted changes won't be included.
Before pushing, confirm the dispatch skill's Step 5 test-coverage gate passed or was
explicitly exempted (a push-time hook also warns on src/-without-tests/ pushes).

## 2. Locate and monitor the push-triggered CI run

`ci.yml` triggers on push to `claude/**` (as well as manual
`workflow_dispatch`), so the push in step 1 already started CI. Do **not** fire
`gh workflow run` first — that double-runs CI on the same commit.

1. Get the pushed head SHA: `git rev-parse HEAD`.
2. Locate the push-triggered run for that SHA: `mcp__github__actions_list`
   (workflow runs for `ci.yml`, matched on `head_sha`) or `mcp__github__get_check_run`;
   CLI equivalent: `gh run list --workflow=ci.yml --commit <sha>`.
3. Monitor **that** run — it is this session's CI gate.
4. **Fallback — manual dispatch, only if no push-triggered run appears within ~a
   minute** (branch outside `claude/**`, or Actions didn't fire):
   `gh workflow run ci.yml --ref <current branch>` (workflow_dispatch), then locate
   and monitor that run instead.

After confirming (or, fallback-only, firing) the run, output one line:
> "CI running on the self-hosted runner — I'll finish the PR steps when it completes."

**End the turn.** Do NOT block waiting.

## 3. tasks/lessons.md — if you were corrected (Turn 2)

After any user correction this session, append a rule that prevents the same mistake.
This file is **not** auto-loaded — it's read at session start via the hook.

Work through the file's `## Index` section, never the whole file: grep the Index
(`grep -n -A 40 '^## Index' tasks/lessons.md`, head-limited) to find related/existing
entries, then ranged-read (offset/limit) only the specific entries you need. Append the
new entry body and add its one-line Index entry.

### 3b. Memory promotion & consistency (Turn 2)

Run these three checks over `tasks/lessons.md` (hub), `.claude/rules/*.md` and
`.claude/agents/memory/*.md` (spokes) before closing out. Route every entry by **who reads
it and how** — role-specific correction → the agent's spoke (read in full at Step 0);
codebase-wide rule with a path signature → a `.claude/rules/` file with a `paths:` glob
(auto-loads on a matching file); main-context process rules and judgment no glob captures
→ the hub. The full contract is `.claude/agents/memory/README.md`, "Where a correction
goes":

1. **Promote twice-corrected lessons.** Any lesson that has now been corrected/violated
   twice → promote it to a `.claude/rules/` file or a hook (mechanism beats prose), then
   replace the entry body with a tombstone line in the hub's `## Index` pointing at the
   new home.
2. **Archive settled entries.** Entries settled for >30 days → move the body to
   `tasks/lessons-archive.md`, leaving only the Index line. Before citing any mechanism
   as having superseded an entry, apply
   `.claude/rules/task-files-conventions.md`'s "Archiving a lessons entry" test: name
   which role the citation binds and confirm it is the role whose mistake produced the
   lesson. When the new home is an `.claude/agents/memory/*.md` spoke or a
   `.claude/rules/` file, **that file becomes authoritative** and the hub keeps only the
   tombstone — do not mirror the body in both places.
3. **Never compete with a rules file (issue #662).** Before writing ANY new lessons entry
   about tooling/process, `grep -ril '<topic>' .claude/rules/` for the governing file —
   the new entry must cross-reference that file and stay consistent with it, never state
   a competing version. A contradicting entry injected at session start causes
   violations, not just drift.

## 4. tasks/todo.md — track + review (Turn 2)

- Mark completed items done.
- Add a short review section summarising what was accomplished this session.

## 5. Update PR title and description (Turn 2)

### 5a. Find the PR
Use `mcp__github__list_pull_requests` to find the open PR for the current branch.

### 5b. Build the summary
When a `tasks/*-ledger.md` exists for the session's epic, derive the summary from the
ledger's unit lines (unit numbers, status, commit SHAs, PR numbers) instead of
reconstructing it from git log. Otherwise, compile a bullet list of everything completed
this session — drawn from commits on this
branch, tasks/todo.md review section, and any review comments addressed. Group by
category (e.g. **Added**, **Fixed**, **Changed**, **Removed**, **Tests**, **Docs**).
Keep each bullet concise (one line).

### 5c. Update the PR via mcp__github__update_pull_request
Call `mcp__github__update_pull_request` with:
- `title` — keep the existing title OR refine it to a clear one-line summary
- `body` — the formatted summary using this template:

```
## What changed

**Completed this session:**
- <bullet>
- <bullet>
...

Branch: `<branch-name>`
```

### 5d. Build the squash commit message
Compose the squash commit message (do NOT post it as a comment yet — step 7 uses it):

```
<PR title or one-line summary> (#<PR number>)

<Grouped bullets — concise, past tense, conventional-commit style>
- Add <thing> to <location>
- Fix <what> (<why in a few words>)
- Update <doc> to reflect <change>
<etc.>

Co-authored-by: Claude <noreply@anthropic.com>
```

Rules:
- Subject line: 72 chars max, imperative mood
- One bullet per logical change, under 80 chars
- No session commentary, test counts, timestamps, or Claude Code session URL

## 6. Verify CI completed green (Turn 2)

Poll with `gh run watch <run-id> --exit-status` or `mcp__github__pull_request_read`
(`method: get_check_runs`) until `status: completed`. Check `conclusion: success`.

If CI failed: read logs via `gh run view <run-id> --log-failed` (`mcp__github__get_job_logs`
is not an available tool in this repo's MCP config), fix the issue, push the fix — on
`claude/**` the push itself triggers a fresh CI run (locate it per step 2; fall
back to `gh workflow run ci.yml --ref <branch>` only if none appears) — and wait again.

## 7. Close out CHANGELOG.md's Unreleased section (Turn 2, before merging)

`main` is the release line — merging this PR is what ships it (deploys are owner-only, via
the xCloud panel; Claude never triggers one), so the merge itself is the release from this
session's standpoint.

Run **CLAUDE.md's "Mandatory pre-merge CHANGELOG check"** — that section is authoritative
and applies to every merge whether or not this skill was invoked. Mechanically, here:

- Rename `## [Unreleased]` to `## [<today's date>] — <one-line summary>`, using the same
  summary as the squash commit subject from step 5d.
- Insert a fresh, empty `## [Unreleased]` above it for the next PR.
- Commit on the branch as a normal new commit — it gets flattened into the squash commit
  on merge, so there's no need to amend. **Only if this commit's diff is entirely within
  `ci.yml`'s `paths-ignore` (`**.md`, `docs/**`, `tasks/**`)** — check with
  `git diff --name-only` — include `[skip ci]` so the push doesn't start a redundant CI
  run. If the commit also touches anything else (a hook under `.claude/`, `settings.json`,
  `apps/**`, `packages/**`), **omit `[skip ci]` entirely**: it bypasses `paths-ignore`
  unconditionally and a code change would ship unverified while the PR still displays an
  earlier SHA's green check. See `.claude/rules/testing-verification.md`.

## 8. Squash merge the PR (Turn 2)

Present the squash commit message composed in step 5d to the user, then ask:

> "Ready to squash-merge PR #N into main with the commit message above. Merge now?"

If confirmed:
- Call `mcp__github__merge_pull_request` with `merge_method: "squash"`, `commit_title`
  set to the subject line, and `commit_message` set to the body.
- Report the merge result (commit SHA, merged-at timestamp).
- If CI hasn't passed or there are unresolved review threads, say so and let the user decide.

If the user declines, post the squash commit message as a PR comment for manual use.

## Quick checklist
- [ ] Outstanding changes committed and pushed — dispatch Step 5 test-coverage gate passed or explicitly exempted before push (a push-time hook also warns on src/-without-tests/ pushes)
- [ ] tasks/lessons.md updated (if corrected this session)
- [ ] Memory promotion & consistency pass run (step 3b: promote twice-corrected, archive >30d settled, no rules-file contradiction)
- [ ] tasks/todo.md items marked + review section added
- [ ] PR title and description updated with session summary
- [ ] Push-triggered CI run located (manual dispatch fallback only) and green (lint + typecheck + Vitest passing)
- [ ] CHANGELOG.md's `[Unreleased]` closed into a dated header before merge
- [ ] Squash merged (or commit message posted for manual merge)
