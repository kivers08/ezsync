#!/usr/bin/env bash
# PreToolUse hook for Edit|Write — DENIES any direct main-context edit of a file that is
# NOT one of the narrow, explicitly-named carve-outs in the `dispatch` skill Step 1 closed
# set (`.claude/skills/dispatch/SKILL.md`, "Do not delegate").
#
# SCOPE — what this hook actually covers, and what it does not:
#   - Repo hooks DO fire for subagent tool calls. An earlier version of this header (and
#     tasks/lessons.md's promotion entry) asserted the opposite; that claim was FALSE and
#     was one of the two "facts" the PreToolUse promotion rested on. On 2026-09-02 a
#     properly-delegated bug-fixer working in its own worktree was denied twice by this
#     gate, i.e. the gate blocked the one write path it is supposed to permit. The
#     subagent carve-out below exists solely to fix that; do not remove it.
#   - Registered on `Edit|Write` only (.claude/settings.json). Bash-driven writes —
#     `sed -i`, `>`/`>>` redirection, `tee`, heredocs, `python - <<EOF` — are therefore
#     UNGATED and can edit any file inline. This is a real, exercised gap, not a
#     theoretical one: commit 43f67b7 was written entirely through it after this gate
#     denied the Edit calls. The owner decided on 2026-09-02 NOT to add a Bash guard
#     hook, so the gap is DELIBERATE and FROZEN — documented here the way
#     .claude/hooks/vitest-suite-guard.sh:35-51 documents its own frozen gaps, so the next
#     reader inherits the decision rather than rediscovering it and "fixing" it. This
#     hook is a mechanical nudge against the accidental inline edit, NOT a security
#     boundary against a caller who is routing around it.
#
# Promoted from a PostToolUse advisory to a PreToolUse deny on 2026-09-02: the advisory
# never surfaced in practice, and the Delegation-First Mandate had to be re-stated in
# prose repeatedly. Per the repo's "mechanism beats prose" promotion rule
# (.claude/skills/session-wrap-up/SKILL.md step 3b.1) it is now hook-enforced.
#
# CLAUDE.md is explicit that markdown/doc/config edits are file writes like any other and
# belong under "always delegate" — an earlier version of this hook exempted a broad
# `tasks/*|.claude/*|docs/*|*.md|*.json` glob, which silently swallowed the exact
# violation recorded at tasks/lessons.md:487-503 (2026-07-24, docs/application_overview.md
# edited inline). That glob is deliberately gone and must not come back.
#
# Fails open: any parse failure, missing field, or unexpected payload shape allows the
# call — a malformed payload must never wedge the session.
set -uo pipefail

# shellcheck source=lib/json-escape.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/json-escape.sh"

# The tool call arrives as JSON on stdin. Read it ONCE into a variable — two fields are
# parsed out of it below and stdin can only be drained once.
payload="$(cat)"

# Pull out the target file path. `tool_input` is the PreToolUse envelope's field; the two
# flatter shapes are kept from the PostToolUse version of this hook so a direct
# `echo '{"file_path":...}'` test still resolves.
file_path="$(node -e '
try {
  const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const path = data.file_path
    || (data.tool_input && data.tool_input.file_path)
    || (data.arguments && data.arguments.file_path);
  if (path) process.stdout.write(path);
} catch (e) {}
' <<< "$payload" 2>/dev/null || true)"

# No path resolved → allow (fail open).
[[ -z "$file_path" ]] && exit 0

# SUBAGENT CARVE-OUT. The PreToolUse envelope carries `agent_id` and `agent_type` at the
# top level when — and only when — the tool call comes from a subagent; both keys are
# absent for a main-context call. Verified on 2026-09-02 by capturing both real envelopes
# live in the same session and diffing their top-level keys.
#
# `transcript_path` is NOT usable for this and must never be used: it is byte-identical in
# both shapes (both point at the session's own .jsonl), so a `/subagents/` path heuristic
# would match nothing and silently fail open for the main context — i.e. disable the whole
# gate. `agent_id` is the only reliable discriminator.
#
# Parsed with the same defensive node-based approach as `file_path` above, so a malformed
# payload still falls through to the fail-open path rather than wedging the session.
agent_id="$(node -e '
try {
  const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const id = data.agent_id || (data.tool_input && data.tool_input.agent_id);
  if (id) process.stdout.write(String(id));
} catch (e) {}
' <<< "$payload" 2>/dev/null || true)"

# Subagent call → allow. Delegated work is exactly what the mandate asks for.
[[ -n "$agent_id" ]] && exit 0

# Allowed-inline paths: the closed set named in the `dispatch` skill Step 1
# (`.claude/skills/dispatch/SKILL.md`, "Do not delegate") — tasks/todo.md,
# tasks/<epic>-ledger.md, .claude/agents/memory/<agent>.md —
# plus two explicit, narrow additions for the session-wrap-up flow (which legitimately
# writes these two files from the main context per .claude/skills/session-wrap-up/
# SKILL.md) — named explicitly rather than left as a wildcard so this can never also
# silently cover CLAUDE.md or skill files.
case "$file_path" in
  tasks/todo.md|*/tasks/todo.md) exit 0 ;;
  tasks/*-ledger.md|*/tasks/*-ledger.md) exit 0 ;;
  .claude/agents/memory/*.md|*/.claude/agents/memory/*.md) exit 0 ;;
  tasks/lessons.md|*/tasks/lessons.md) exit 0 ;; # session-wrap-up Turn 2 writes this directly
  CHANGELOG.md|*/CHANGELOG.md) exit 0 ;; # session-wrap-up Turn 2 closes out [Unreleased] directly
esac

# Everything else — including apps/, packages/, .md, .claude/, docs/, .github/,
# and tasks/*-plan.md — must be edited by a subagent.
REASON="This file must be edited via a subagent, not inline. CLAUDE.md's Delegation-First Mandate puts ALL code, doc and config changes in a subagent with worktree isolation; the only files that may be edited inline are tasks/todo.md, tasks/<epic>-ledger.md, .claude/agents/memory/<agent>.md, tasks/lessons.md and CHANGELOG.md. Everything else -- including apps/, packages/, docs/, .claude/, .github/ and tasks/<topic>-plan.md -- is delegated. To proceed: dispatch a feature-implementer, bug-fixer or general-purpose subagent per the \"dispatch\" skill, stating the target branch, and let it make the edit."
ESCAPED_REASON="$(json_escape "$REASON")"

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$ESCAPED_REASON"
printf 'DELEGATION GATE: %s\n' "$REASON" >&2
exit 2
