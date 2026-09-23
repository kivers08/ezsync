#!/usr/bin/env bash
# PreToolUse hook for Bash — denies `git commit`/`git add` when the current branch is
# also checked out in ANOTHER worktree (the PR #551 shape: two sessions silently racing
# on the same branch). No "expected branch" heuristic — there's no reliable intent signal.
#
# Fails open: any parse failure, missing command, or git-command failure allows the call.
set -uo pipefail

command="$(node -e '
try {
  const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const i = d.tool_input || d.arguments || d;
  const c = i.command || d.command || "";
  if (c) process.stdout.write(c);
} catch (e) {}
' 2>/dev/null || true)"

[[ -z "$command" ]] && exit 0

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$1"
  printf 'WORKTREE COMMIT GUARD: %s\n' "$1" >&2
  exit 2
}

flagged=0
segments="$(printf '%s' "$command" | tr '&|;' '\n')"

while IFS= read -r seg; do
  seg="$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$seg" ]] && continue

  read -r -a words <<< "$seg"
  cmd0="${words[0]:-}"
  [[ "$cmd0" != "git" ]] && continue
  sub="${words[1]:-}"
  if [[ "$sub" == "commit" || "$sub" == "add" ]]; then
    flagged=1
  fi
done <<< "$segments"

[[ "$flagged" == "0" ]] && exit 0

cur_branch="$(git branch --show-current 2>/dev/null || true)"
[[ -z "$cur_branch" ]] && exit 0
cur_path="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$cur_path" ]] && exit 0

wt_list="$(git worktree list --porcelain 2>/dev/null || true)"
[[ -z "$wt_list" ]] && exit 0

other_path=""
current_wt_path=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*)
      current_wt_path="${line#worktree }"
      ;;
    "branch refs/heads/"*)
      b="${line#branch refs/heads/}"
      if [[ "$b" == "$cur_branch" && "$current_wt_path" != "$cur_path" ]]; then
        other_path="$current_wt_path"
      fi
      ;;
  esac
done <<< "$wt_list"

[[ -z "$other_path" ]] && exit 0

deny "Branch $cur_branch is checked out in worktree $other_path — a dispatched agent may own it. cd there, or verify with \`git worktree list\` before committing here."
