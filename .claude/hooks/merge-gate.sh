#!/usr/bin/env bash
# PreToolUse hook — registered directly in .claude/settings.json only for the
# mcp__github__merge_pull_request matcher; Bash merges reach it via
# bash-guard-dispatch.sh's `*merge*` route (#713) — denies any merge unless an explicit human
# "merge" command was just given this session (mechanized as a marker file with a 10min
# TTL) AND the merge method is squash. CLAUDE.md: "Merging to main always requires an
# explicit human 'merge' command — no exceptions."
#
# Fails open: any parse failure or unrecognized shape allows the call (this hook only
# acts when it can positively identify a merge attempt).
set -uo pipefail

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$1"
  printf 'MERGE GATE: %s\n' "$1" >&2
  exit 2
}

# Anchor the marker to the project root (not cwd) so it resolves the same way no matter
# what directory the hook is invoked from, and so a stray marker under some unrelated
# directory can never satisfy the gate. $CLAUDE_PROJECT_DIR is set by the harness for
# every hook invocation (it's how settings.json locates this very script); fall back to
# the BASH_SOURCE-relative root used by the other hooks (e.g. read-guard.sh) if unset.
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# In a LINKED WORKTREE "$ROOT/.git" is a file, not a directory, so a marker can never be
# created there and an explicitly authorized merge would be denied forever. Resolve git's
# common dir instead — it is shared by the main checkout and every linked worktree, so one
# marker satisfies the gate from anywhere. `git rev-parse --git-common-dir` returns a
# RELATIVE path (".git") when run at the repo root, so absolutize it against $ROOT; from
# the main checkout this still yields exactly "$ROOT/.git/claude-human-merge-ok". Fail
# open to the old "$ROOT/.git" path if git is unavailable or the dir isn't a repo.
COMMON_DIR="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -z "$COMMON_DIR" ]]; then
  COMMON_DIR="$ROOT/.git"
elif [[ "$COMMON_DIR" != /* ]]; then
  COMMON_DIR="$ROOT/$COMMON_DIR"
fi
MARKER="$COMMON_DIR/claude-human-merge-ok"

REASON="Merging requires an explicit human 'merge' command this session. If the user just gave one, run \`touch $MARKER\` and retry — marker expires in 10 min. Squash only."
marker_ok() {
  [[ -f "$MARKER" ]] || return 1
  local mtime now age
  mtime="$(stat -c%Y "$MARKER" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  age=$((now - mtime))
  [[ "$age" -lt 600 ]]
}

parsed="$(node -e '
try {
  const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const i = d.tool_input || d.arguments || d;
  const toolName = d.tool_name || d.name || "";
  const command = i.command || "";
  const mergeMethod = i.merge_method || "";
  process.stdout.write([toolName, command, mergeMethod].join(""));
} catch (e) {}
' 2>/dev/null || true)"

[[ -z "$parsed" ]] && exit 0

IFS=$'\x01' read -r tool_name command merge_method <<< "$parsed"

# Bash path: `gh pr merge ...`
if [[ -n "$command" ]]; then
  is_merge=0
  bad_method=0
  segments="$(printf '%s' "$command" | tr '&|;' '\n')"
  while IFS= read -r seg; do
    seg="$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$seg" ]] && continue
    read -r -a words <<< "$seg"
    cmd0="${words[0]:-}"
    sub="${words[1]:-}"
    sub2="${words[2]:-}"
    if [[ "$cmd0" == "gh" && "$sub" == "pr" && "$sub2" == "merge" ]]; then
      is_merge=1
      for w in "${words[@]:3}"; do
        case "$w" in
          --merge | --rebase) bad_method=1 ;;
        esac
      done
    fi
  done <<< "$segments"

  if [[ "$is_merge" == "1" ]]; then
    [[ "$bad_method" == "1" ]] && deny "$REASON"
    marker_ok || deny "$REASON"
  fi
  exit 0
fi

# MCP path: mcp__github__merge_pull_request
if [[ "$tool_name" == *"merge_pull_request"* ]]; then
  [[ "$merge_method" != "squash" ]] && deny "$REASON"
  marker_ok || deny "$REASON"
fi

exit 0
