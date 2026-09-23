---
paths:
  - "tasks/lessons.md"
  - "tasks/todo.md"
  - "tasks/*-archive.md"
  - ".claude/agents/*.md"
---

# Task Files Conventions — Ranged Reads Only

- `tasks/lessons.md` and `tasks/todo.md`: read only through the end of their
  index section — both files use `## Index` — a ranged read, then grep the
  specific heading/topic text needed; never read either file in full.
- `tasks/todo.md` is **open-only by standing rule**: it holds ONLY
  not-yet-completed work. Completed items/sections rotate to
  `tasks/todo-archive.md` at wrap-up (verbatim, under a dated rotation divider,
  with matching lines added to the archive's Index) — they never accumulate in
  `tasks/todo.md`. A mostly-completed section gets split: its open `- [ ]`
  boxes stay under their topic heading with a `context:` pointer to the
  archived narrative. The `## Index` at the top mirrors the open sections —
  keep it in sync when adding or rotating a section.
- `tasks/*-archive.md` files (e.g. `tasks/lessons-archive.md`,
  `tasks/todo-archive.md`) are **not** auto-loaded and grow without bound —
  treat them as grep-only historical records; never read either in full.
- `tasks/active_sprint.md` is **exempt** from the ranged-reads rule above — it is
  hard-capped at ~100 lines and injected whole by the SessionStart hook. The cap is
  what preserves the exemption: if it ever grows past that cap, treat it like
  `tasks/todo.md` above until it's trimmed back down. It holds only in-flight work;
  completed units move to `tasks/todo.md`.
- `docs/decisions/architecture.md` is an append-only ADR log (never rewrite a past
  entry — supersede with a new dated entry), capped at ~250 lines with rotation to
  `docs/decisions/architecture-archive.md` (grep-only) as it grows.
- Keeping `tasks/todo.md` and `tasks/lessons.md` current is an ongoing
  practice **and** a mandatory pre-merge check at the `pr-review-pipeline`
  skill's stage 4, alongside the CHANGELOG gate — it is not gated behind
  `session-wrap-up`.

## Plan-file lifecycle

- `tasks/<topic>-plan.md` (and any companion `<topic>-ledger.md`) lives in `tasks/`
  while its work is active — planned, awaiting approval, or in flight.
- When the work merges or the plan is superseded, the `session-wrap-up` flow
  `git mv`s the file(s) to `tasks/archive/` — a grep-only historical record,
  same handling as the other `*-archive.md` files: never read in full.
- Instruction/task files stay under **250 lines** (the read-guard threshold for
  unranged reads) — split or rotate a file before it crosses that ceiling.
- Agent definitions in `.claude/agents/*.md` are exempt from the 250-line ceiling: they
  are runtime-injected into the subagent and sit outside the read-guard's
  docs/tasks/root-md scope, so the ceiling is a style guideline there, not a
  hook-enforced limit (owner decision 2026-09-09).

## Archiving a lessons entry — check the citation binds the same role

Before archiving a `tasks/lessons.md` entry as "now enforced by X", name which
role the citation actually binds (coordinator / worker / subagent) and confirm it
is the same role whose mistake produced the lesson. **"A check exists somewhere in
the pipeline" is not sufficient if it runs on the wrong side of the mistake.** On
PR #551 the 2026-06-19 "verify current branch before committing" lesson was
archived citing worker-side `feature-implementer.md`/`bug-fixer.md` git-status
checks — but its failure mode was coordinator-side (the main context committing
onto the wrong branch after a worker switched the shared worktree), which no
worker-side check can catch. Copilot caught the mis-archival and `4a98eae`
restored the lesson.

The same test applies when a hub entry is retired in favour of an
`.claude/agents/memory/*.md` spoke: a spoke binds only the agent that reads it, so
any half of the lesson that binds the **main context** must be kept in the hub or
promoted to a rules file / the `dispatch` skill, not dropped with the body.
