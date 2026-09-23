---
paths:
  - "CHANGELOG.md"
---

# CHANGELOG Conventions — Grep Only, Pre-Merge Gate

- Never read `CHANGELOG.md` in full — grep `^## \[` for headers, or read only
  the top `[Unreleased]` section.

## Mandatory pre-merge CHANGELOG check

Merging to `main` deploys to production. **Before calling `merge_pull_request` on any
PR** — the gate applies to every PR regardless of its target branch, and regardless of
whether `session-wrap-up` was run — this is a two-part check, do both. Perform it by spawning `doc-updater` in the
background (`isolation: "none"`) with a prompt that names the PR's branch explicitly
(`Branch: <name>`) — `doc-updater`'s Step 0 refuses a dispatch that does not name one —
scoped to *only* this check — no `docs/`, `README.md`, or `AGENTS.md` edits this run —
then review its diff and push once it reports back. `doc-updater` never pushes itself:

1. **No stale content from a different, already-merged PR.** Read `[Unreleased]` and
   confirm it contains only this PR's own entries. If it still contains entries from a
   PR that already merged (a prior close-out was missed), close those out into their own
   dated header(s) first.
2. **Author entries, then close out.** `[Unreleased]` entries are typically already
   present from normal development; `doc-updater` authors any still missing, **then**
   renames `## [Unreleased]` to a dated header (matching the squash commit subject) and
   opens a fresh, empty `## [Unreleased]` above it. Do this even if part 1 found nothing
   stale — it's not conditional on part 1 having a fix to make.

`doc-updater`'s commit should fold in whichever part applies. This is a hard gate on the
merge action itself, not something bundled only into the optional wrap-up skill — relying
on remembering to invoke wrap-up caused part 1 to be missed twice in a row, and
forgetting part 2 specifically (confirming no staleness but never closing out the current
PR's own section) has now required a follow-up PR **twice** — most recently PR #664,
fixed post-hoc in `f97f2aa` (PR #693).

**Part 2 is the half that gets skipped, because part 1 is the only half you can see.**
Stale content from someone else's PR is visible the moment you open `[Unreleased]`;
failing to close out *your own* entries is invisible until the next PR trips over them.
So a clean-looking `[Unreleased]` on the way IN does not satisfy this gate — the gate is
not met until `[Unreleased]` has been renamed to a dated header on the way OUT and a
fresh empty `[Unreleased]` opened above it. If you are about to call
`merge_pull_request` and the diff you are merging still contains a live `## [Unreleased]`
section with entries under it, part 2 has not been done.

Closing out `[Unreleased]` is itself a documentation-only change and does **not** require
re-triggering CI (see CLAUDE.md's "Verification Before Done"). Because this spawn
runs in the background per the repo's background-agent rule, the push/merge happens in a
follow-up turn after `doc-updater`'s completion notification, not the same turn.

**Rotation:** `CHANGELOG.md` holds the last **15 days** of dated entries. Move anything
older verbatim into `CHANGELOG-archive.md`, oldest first. Whole sections only — never
split one. `## [Unreleased]` never moves, and stays topmost. Docs-only, no CI, fold into
the current PR.

The 15 days are measured **from the newest dated entry in the file**, not from today's
date. Measuring from today would empty the live changelog entirely after a month of no
commits, leaving nothing to grep; measuring from the newest entry always keeps a working
window of recent history no matter how long the repo sits idle. In an actively developed
repo the two bases coincide, because the newest entry is normally today's.

**History of this rule — read before changing it again.** The rule originally paired *two*
parameters: rotate when the file exceeds ~1,000 lines, moving entries older than 30 days.
Those can contradict each other, and on 2026-09-02 they did: `CHANGELOG.md` held 1,433
lines — 43% over the cap — spanning only 29 days, so *zero* sections qualified as "older
than 30 days" and rotation could never fire no matter how large the file grew. PR #693
fixed that by dropping the age window and keying rotation to the line count alone, the
same quantity the cap measured, which made it always satisfiable. Later the same day the
owner replaced that with the present rule: a single 15-day window, no line cap. This is
**not** a regression to the broken original. The original failed because two independent
parameters could contradict; one parameter cannot contradict itself, so the "never fires"
failure mode is structurally impossible here. At this repo's velocity 15 days is also a far
tighter bound than ~1,000 lines ever was, so it fires readily. If you change this rule
again, keep it to a single criterion.
