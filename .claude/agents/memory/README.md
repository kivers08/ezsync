# Per-Agent Memory — Routing Contract

This directory holds the **spokes** of the repo's memory system. Together with
`.claude/rules/` and `tasks/lessons.md` it is the repo's **sole memory system** — the
harness's own auto-memory is disabled (`autoMemoryEnabled: false` in
`.claude/settings.json`).

## Where a correction goes

Three destinations, each defined by **who actually reads it and how**. Route by asking
"who has to know this, and what will put it in front of them?" — never by topic alone.

| Destination | Takes | How it reaches its reader |
|---|---|---|
| **Spoke** — `.claude/agents/memory/<agent-name>.md` | A correction specific to one agent's own role/behavior (e.g. "bug-fixer tends to over-scope fixes into refactors") | That agent reads its own spoke **in full at Step 0** of every dispatch — the `dispatch` Step 2 prompt template mandates it. Automatic and complete. |
| **Rules file** — `.claude/rules/<name>.md` with a `paths:` glob | A codebase-wide technical rule that has a **path signature** — some glob predicts when it matters (e.g. TS/decimal.js conventions on `apps/**/*.ts`, Drizzle schema rules on `packages/db/schema/**/*.ts`) | Auto-loads into context for **anyone** — main context or subagent — the moment they read a matching file. No invocation needed (`.claude/README.md` §Rules). Automatic and targeted. |
| **Hub** — `tasks/lessons.md` | Main-context process rules, and cross-cutting judgment **no path glob captures** (e.g. "reproduce an agent's claim against primary evidence"). Plus the `## Index` tombstone for every entry promoted to a spoke or rules file | The SessionStart hook injects the newest `## Index` lines into the **main context** every session. Subagents reach it only by **targeted grep** — the dispatch template tells them to grep it for topics the dispatch touches. |

**The hub is read, but only two ways: the main context's Index injection, and a subagent's
targeted grep.** A grep only finds a rule you already suspect exists. That asymmetry — not
any claim that the hub goes unread — is why the spoke and the rules file are the
authoritative homes whenever a lesson fits one of them.

## Authority

- A **spoke is authoritative** for entries binding its own agent; a **rules file is
  authoritative** for rules its `paths:` glob covers. When a lesson moves to either, the
  hub keeps only its `## Index` tombstone pointing there — bodies are never mirrored in
  two places.
- **A spoke binds only its own reader; a rules file binds only what its glob matches.** So
  any half of a lesson that binds the main context, or that no glob covers, stays in the
  hub. See `.claude/rules/task-files-conventions.md`, "Archiving a lessons entry."
- A rule that has become **mechanically enforced** (a hook) beats all three — the entry
  becomes a tombstone naming the hook.

**Spokes:** one file per agent, named `<agent-name>.md`. All 10 are **pre-created** — one
for every agent defined in `.claude/agents/*.md` — so an agent never handles a missing
file. No agent reads another agent's spoke.

**Write:** curated only — the **main context** files entries to all three destinations
after reviewing a subagent's finished work (including via `pr-reviewer`'s findings).
Never self-written by a subagent, never cross-agent.

**Format (binding for spokes):** every spoke entry is a dated `##` heading followed by
labelled blocks —

```markdown
## <Full rule sentence> (YYYY-MM-DD)

**Mistake:** what went wrong, one or two sentences.
**Rule:** the corrected behavior, stated imperatively.
**Trigger:** the situation in which this rule applies.
```

`**Rule:**` and `**Trigger:**` are required; `**Mistake:**` is optional where an entry
records a near-miss or a convention rather than an error. No other labels — fold any extra
qualification into the block it belongs to. The date is a **parenthetical suffix in the
heading**; the `[YYYY-MM-DD]` *prefix* form is reserved for the `## Index` lines of the hub
and the archives. For `tasks/lessons.md`, `tasks/todo.md` and the `tasks/*-archive.md`
files, `.claude/rules/task-files-conventions.md` is authoritative — this note governs
spokes only and does not restate those conventions.

**Size cap:** ~100 lines per spoke — the SessionStart hook warns when a spoke exceeds it;
condense or archive (promotion/rotation happens in the `session-wrap-up` skill's memory
step).
