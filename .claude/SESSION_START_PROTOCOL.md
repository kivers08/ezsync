<!-- Imported by CLAUDE.md via @.claude/SESSION_START_PROTOCOL.md — do not delete or
     rename without updating that import. -->

## Session Start Protocol

A **SessionStart hook** (`.claude/hooks/session-start-context.sh`) injects a slice of
`tasks/lessons.md` (the most recent entries — active rules from past corrections) and a
slice of `tasks/todo.md` (unchecked items plus the tail of the file) into context every
session — neither file is loaded in full — and prints the Delegation-First reminder live.
Scan that injected content for patterns relevant to the current task before planning or
coding. If the hook output is missing, read the `## Index` section (ranged read) in each
file and grep for the specific entries needed — do not read either file in full.

Completed/superseded history lives in `tasks/todo-archive.md` and
`tasks/lessons-archive.md`. These are **not** auto-loaded and grow without bound — treat
them as grep-only historical records; never read either in full.
