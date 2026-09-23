---
name: brainstorm
description: Use when the dispatch skill's Step 0 triage judges a request to be a new, not-yet-existing feature (per CLAUDE.md's "Plan First" gate) — the sole invocation path; this skill never self-triggers independently.
---

# Brainstorming Skill Workflow

Dispatch's triage already decided this needs a design. "This seems simple" is not an exit
mid-process once you're here — a simple feature earns a *short* design, not a skipped one.
The only legitimate exit is step 1 revealing the feature already exists, in which case
route back to `CLAUDE.md` §1's research-first path instead of continuing here.

1. **Context check — locate only, don't trace.** Use `Glob`/`Grep` to see whether
   something similar already exists. Do NOT ask the owner a question the code can
   already answer. If a real trace is needed (not just locating), delegate it to an
   `Explore`/`pattern-finder` subagent — never read files inline (see `tasks/lessons.md`).
   This is a narrow existence-check only, not the full grounding research — that happens
   after the design is agreed (step 4 below, and `CLAUDE.md` §1's "delegated research to
   ground it").
2. **Scope, then one question at a time.** If the request bundles multiple independent
   features or subsystems, say so and split first — brainstorm and plan one at a time,
   each getting its own `tasks/<topic>-plan.md`. For an appropriately-scoped request, use
   `AskUserQuestion` to work through intent, constraints, edge cases, and success criteria
   as a genuine back-and-forth — continue until the shape is actually agreed, not until a
   fixed number of questions is hit.
3. **Propose options.** Present 2-3 technical approaches with trade-offs, leading with
   your recommendation and why. YAGNI — cut anything the agreed shape doesn't need.
4. **Ground the design.** Once the shape is agreed, delegate a thorough verification
   pass to an `Explore`/`pattern-finder` subagent — confirm every assumption, file
   reference, and touchpoint against the actual codebase before writing anything up.
   This is the full grounding research step 1 above deferred — not the same as that
   step's narrow existence-check.
5. **Write the design.** Write the complete design to `tasks/<topic>-plan.md` (matching
   this repo's existing naming/location convention), covering approach/architecture,
   files & touchpoints, error handling, and verification/testing, plus a summary +
   checklist entry to `tasks/todo.md`. Before presenting it, re-read once for
   placeholders, internal contradictions, and any requirement readable two ways, and fix
   them inline.
6. **Single final review.** Present the complete written plan for one explicit approval —
   not a section-by-section sign-off. Do not write code until it's approved.
