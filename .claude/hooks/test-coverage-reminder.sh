#!/usr/bin/env bash
# PreToolUse hook for Bash — WARN-ONLY reminder on `git push` when outgoing commits
# touch app/package TypeScript source with no accompanying co-located test change. Backs
# the dispatch skill's Step 5 test-coverage gate (required test-writer chaining) at push
# time.
#
# NEVER denies: always exit 0. Warns via stdout only when:
#   - a command segment is `git push`, AND
#   - the current branch has an upstream (`@{u}` resolves; otherwise skip silently), AND
#   - `@{u}..HEAD` changes any apps/**/*.ts(x) or packages/**/*.ts(x) source file (a
#     non-test .ts) AND no matching *.test.ts(x)/*.spec.ts(x) file (Vitest co-located
#     convention — there is no tests/ dir).
# Silent in every other case.
#
# Fails open: any parse failure, missing command, or git error allows the call silently.
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

# Is any command segment a `git push`?
is_push=0
segments="$(printf '%s' "$command" | tr '&|;' '\n')"
while IFS= read -r seg; do
  seg="$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$seg" ]] && continue
  read -r -a words <<< "$seg"
  [[ "${words[0]:-}" == "git" && "${words[1]:-}" == "push" ]] && is_push=1
done <<< "$segments"

[[ "$is_push" -ne 1 ]] && exit 0

# Outgoing range: upstream..HEAD. No upstream configured -> skip silently.
if ! git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
  exit 0
fi

files="$(git diff --name-only '@{u}..HEAD' 2>/dev/null || true)"
[[ -z "$files" ]] && exit 0

src_changed=0
tests_changed=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    # Co-located test files first — a *.test.ts / *.spec.ts is a test change, never
    # counted as source (the pattern below would otherwise also match it).
    apps/*.test.ts | apps/*.test.tsx | apps/*.spec.ts | apps/*.spec.tsx | \
    packages/*.test.ts | packages/*.test.tsx | packages/*.spec.ts | packages/*.spec.tsx)
      tests_changed=1 ;;
    # Any other TypeScript source under apps/ or packages/.
    apps/*.ts | apps/*.tsx | packages/*.ts | packages/*.tsx)
      src_changed=1 ;;
  esac
done <<< "$files"

if [[ "$src_changed" -eq 1 && "$tests_changed" -eq 0 ]]; then
  echo "Outgoing commits touch apps/ or packages/ TypeScript source with no co-located *.test.ts change — the dispatch pipeline requires a chained test-writer pass or an explicit exemption (dispatch skill Step 5)."
fi

exit 0
