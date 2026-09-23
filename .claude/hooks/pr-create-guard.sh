#!/usr/bin/env bash
# PreToolUse hook for Bash — denies `gh pr create` without `--draft`. PRs default to
# draft per CLAUDE.md's Pull Request Defaults; this is auto-fixable and has zero
# realistic false positives, so it's a hard block rather than a warning.
#
# Fails open: any parse failure or missing command allows the call.
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
  printf 'PR CREATE GUARD: %s\n' "$1" >&2
  exit 2
}

REASON="PRs default to draft (CLAUDE.md) — add --draft; mark ready after review."

segments="$(printf '%s' "$command" | tr '&|;' '\n')"

while IFS= read -r seg; do
  seg="$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$seg" ]] && continue

  read -r -a words <<< "$seg"
  cmd0="${words[0]:-}"
  [[ "$cmd0" != "gh" ]] && continue
  sub="${words[1]:-}"
  [[ "$sub" != "pr" ]] && continue
  sub2="${words[2]:-}"
  [[ "$sub2" != "create" ]] && continue

  has_draft=0
  for ((idx = 3; idx < ${#words[@]}; idx++)); do
    [[ "${words[$idx]}" == "--draft" ]] && has_draft=1
  done
  [[ "$has_draft" == "0" ]] && deny "$REASON"
done <<< "$segments"

exit 0
