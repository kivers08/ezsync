---
paths:
  - "apps/**/*.ts"
  - "packages/**/*.ts"
  - "**/*.test.ts"
---

# Testing & Verification — CI Is the Gate, Not Local Runs

- Never invoke `npm test`, or `npx vitest run` without an explicit test-file
  path or `-t` name filter, locally — no stated purpose makes a whole-suite
  invocation acceptable. That's CI's job: push, trigger CI, verify via
  `mcp__github__pull_request_read` (`method: get_check_runs`).
- Binds subagent dispatch prompts too — a dispatch prompt's "Acceptance
  criteria" must never instruct a subagent to run the full suite as its own
  gate.
- Scoped runs stay fine: `npx vitest run <specific-file>` while actively
  writing/debugging that file is normal iteration, not a violation. Local
  lint/format verification means **scoped to changed files only** —
  `npx eslint <changed files>` / `npx prettier --check <changed files>` —
  never repo-wide `npm run lint` / `npm run format:check`; those are CI's
  job (CI already runs both as its own gates). The line is re-running the
  *entire* Vitest suite (or a repo-wide lint/format sweep) as a local
  pass/fail gate.
- No exception for "this change feels high-stakes" — perceived risk is never
  a reason to add a local full-suite run on top of or instead of CI.
- **Never trigger CI for a documentation-only diff.** If everything changed
  since the last green CI run on the branch/PR is prose CI never executes or
  type-checks — `CHANGELOG.md`, `README.md`, `AGENTS.md`, anything under `docs/`
  or `tasks/`, or any other prose-only `*.md` — skip CI entirely; lint/Vitest
  results can't change. Examples: a CHANGELOG close-out commit, a
  `tasks/todo.md` or `tasks/lessons.md` edit.
- **The docs-only exemption is narrow.** Any change touching `apps/**`,
  `packages/**`, `package.json`/`package-lock.json`, `.github/workflows/*.yml`,
  `packages/db/migrations/*.sql`, `.env.example`, or anything else affecting
  runtime behavior, dependency resolution, or the lint/test result **always**
  requires a CI run, however small.
- **The docs-only exemption also requires a current merge-base.** It only applies when
  the branch's merge-base is current with its base branch — a stale merge-base can fail
  CI on code the PR never touched, so a docs-only diff on an out-of-date branch still
  requires CI (or a merge of the base branch first). Merging `origin/main` in resolves
  it.
- **A merge commit combining two independently-green branches needs its own CI
  run.** Each branch passing alone is not evidence the merge passes: one branch's
  test can assert against behaviour the other branch's change invalidates. Push
  the merge commit and let CI gate it; the docs-only exemption above never covers
  a merge commit that combines code branches.
- **`[skip ci]` only when the commit's diff is entirely docs.** CI's `paths-ignore`
  (`**.md`, `docs/**`, `tasks/**`) already suppresses prose-only pushes by itself, so
  `[skip ci]` adds nothing on a genuinely docs-only commit and is purely a hazard on any
  other: GitHub honours it unconditionally, bypassing `paths-ignore`'s
  every-file-must-match safety. Before writing `[skip ci]`, run `git diff --name-only`
  against the commit and confirm **every** path matches `**.md`, `docs/**` or `tasks/**`.
  Note `.claude/**` non-`.md` files (hooks, `settings.json`) are *not* ignored paths.
- **Verifying CI means matching the run's `head_sha` to the PR's current head, not
  reading the last conclusion.** A green check on a PR can belong to an earlier SHA; a
  later push that skipped CI leaves that stale green in place and the PR still shows
  green. Compare `mcp__github__pull_request_read` (`method: get_check_runs`) `head_sha`
  — or `gh run list --branch <b> --json headSha,conclusion` — against
  `git rev-parse HEAD` / the PR's head SHA, and treat a mismatch as "not verified",
  not as green.
- **`scripts/verify-agent-work.sh` PASSing is not test evidence.** It checks
  branch, cleanliness and commits-ahead only — never test outcomes. Never report
  a merged branch as verified on its strength alone.
- **Scope a targeted Vitest run away from worktrees.** `vitest` invoked from the repo
  root can also match checkouts under `.claude/worktrees/`, reporting the same
  failure several times — pass an explicit file path or a `--dir`/`--root` scope
  that excludes `.claude/worktrees`.
- After pushing, trigger CI, then verify with `gh run watch <run-id> --exit-status`
  or `mcp__github__pull_request_read` (`method: get_check_runs`) — this offloads
  execution to the runner and keeps the context window clean. For logic errors CI
  can't catch (wrong business rule, broken runtime behaviour), use logs or
  demonstrate correctness another way — but never dump full `npm test` output into
  the context.
