#!/usr/bin/env bash
# PreToolUse hook for Edit|Write — denies a write whose target resolves inside
# "$HOME/.claude/" but NOT inside "$CLAUDE_PROJECT_DIR".
#
# WHY: a user-level "~/.claude" file is not part of the repo and does not survive a
# container restart. On 2026-09-01 a subagent patched "~/.claude/stop-hook-git-check.sh"
# live; the container restarted on session resume and the patch silently vanished, so a
# later `cp` into the repo captured the stock (unpatched) version instead. The failure
# mode is the dangerous part: the edit *appears* to succeed at the time and only vanishes
# later, with no error to notice. The fix is always the same: commit the canonical copy
# under the repo's own ".claude/" — that copy is version-controlled and survives restarts —
# and, only if a user-level copy is genuinely needed, install it from there with a Bash
# `cp`, which this hook deliberately does not block. Nothing in this repo currently
# installs into "~/.claude": the repo copy is the ONLY copy, registered directly from
# ".claude/settings.json", and no sync step exists or should be reintroduced (the one that
# used to live in session-start-context.sh was removed on 2026-09-02 — it kept a second,
# divergent registration of the same hook alive).
#
# DENIES: an Edit or Write whose resolved absolute path falls under "$HOME/.claude/" and
# is not also under "$CLAUDE_PROJECT_DIR" (falls back to a BASH_SOURCE-relative root if
# unset, as merge-gate.sh does). A relative path or one containing ".." is resolved
# before the comparison so it cannot slip past.
#
# DOES NOT COVER (deliberately):
#   - Bash. The sanctioned install path is `cp <repo file> "$HOME/.claude/..."` run via
#     Bash — this hook is registered only on the Edit|Write matcher so that remedy is
#     never blocked by the very guard that recommends it.
#   - Read. Diagnostics against a live "~/.claude" file stay open.
#   - A worktree path under "$CLAUDE_PROJECT_DIR" (e.g.
#     ".claude/worktrees/<slug>/.claude/settings.json") — that is legitimate project work,
#     not a user-level write, because it lives under the project root. The safe default
#     chosen here is narrow: only deny when the resolved path is under "$HOME/.claude/";
#     a worktree living anywhere else (e.g. a /tmp checkout) is never affected by this
#     hook at all, since it isn't under "$HOME/.claude/" either.
#
# Fails open: any parse failure, missing field, unresolved HOME, or unexpected payload
# shape allows the call — a malformed payload must never wedge the session.
set -uo pipefail

# shellcheck source=lib/json-escape.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/json-escape.sh"

# $CLAUDE_PROJECT_DIR is set by the harness for every hook invocation (it's how
# settings.json locates this very script); fall back to the BASH_SOURCE-relative root
# used by merge-gate.sh if unset.
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# No usable HOME → cannot determine the user-level root, fail open.
[[ -z "${HOME:-}" ]] && exit 0

parsed="$(node -e '
try {
  const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const i = d.tool_input || d.arguments || d;
  const p = i.file_path || d.file_path || "";
  if (p) process.stdout.write(p);
} catch (e) {}
' 2>/dev/null || true)"

# No path resolved → allow (fail open).
[[ -z "$parsed" ]] && exit 0

# Resolve to an absolute, normalized path (no "..", no symlink games). `realpath -m`
# normalizes even a path that does not exist yet (a Write target), which is the common
# case here; a relative path is resolved against the project root, matching how the
# other tools in this harness always pass absolute paths but staying defensive against
# one that somehow isn't.
resolve() {
  local p="$1"
  if [[ "$p" != /* ]]; then
    p="$ROOT/$p"
  fi
  realpath -m -- "$p" 2>/dev/null
}

target="$(resolve "$parsed")"
[[ -z "$target" ]] && exit 0

home_claude="$(realpath -m -- "$HOME/.claude" 2>/dev/null)"
[[ -z "$home_claude" ]] && exit 0

project_root="$(realpath -m -- "$ROOT" 2>/dev/null)"
[[ -z "$project_root" ]] && exit 0

under_home_claude=0
case "$target" in
  "$home_claude" | "$home_claude"/*) under_home_claude=1 ;;
esac

[[ "$under_home_claude" == "0" ]] && exit 0

under_project=0
case "$target" in
  "$project_root" | "$project_root"/*) under_project=1 ;;
esac

[[ "$under_project" == "1" ]] && exit 0

REASON="A ~/.claude file dies with the container and a live edit there vanishes silently on session resume (2026-09-01 incident). Commit the canonical copy under the repo's .claude/ instead -- that is the only copy this repo keeps -- and, only if a user-level copy is genuinely needed, install it from there with a Bash \"cp\", which this hook does not block."
ESCAPED_REASON="$(json_escape "$REASON")"

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$ESCAPED_REASON"
printf 'USER-LEVEL WRITE GUARD: %s\n' "$REASON" >&2
exit 2
