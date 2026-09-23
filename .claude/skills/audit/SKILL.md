---
name: audit
description: Use for a research-only audit of a subsystem, mapping its full footprint (including coupled tags/labels/config keys) into a written report and a draft PR. Trigger on any mention of "audit", "map the footprint of", or "research-only audit".
---

# Audit a Subsystem

Given $ARGUMENTS as the audit target:
1. Spawn an `Explore` agent (or `pattern-finder` if the target is a specific code area rather than a broad subsystem) to map the full footprint, including coupled systems (tags, labels, config keys), not just direct references.
2. Dispatch `doc-updater` to write the findings to `docs/audits/<target>.md`, scoped to only that one file — this path is inside `doc-updater`'s allowed `docs/` scope, so it is not an exception. (The `docs/audits/` directory is created on first use if it doesn't exist yet.)
3. Open a PR with `gh pr create --draft`. Report the PR number and STOP. Never merge.
