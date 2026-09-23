#!/usr/bin/env bash
# Equivalence harness for .claude/hooks/bash-guard-dispatch.sh.
#
# For each representative PreToolUse-shaped payload, runs the command through:
#   (a) "reference" — the seven guards invoked directly, in the exact order they
#       are registered on the Bash matcher in settings.json today, stopping at the
#       first non-zero exit (mirroring the dispatcher's own stop-on-first-denial
#       contract, and harmless here since every guard is silent — no stdout/stderr
#       — on its own non-trigger path, so running fewer vs. all seven produces the
#       same combined output regardless).
#   (b) "dispatcher" — .claude/hooks/bash-guard-dispatch.sh.
# and asserts exit code, stdout, and stderr are identical between the two. Any
# difference is a FAIL. Exits non-zero if any case fails.
#
# Run directly: bash .claude/hooks/tests/bash-guard-dispatch-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCHER="$HOOKS_DIR/bash-guard-dispatch.sh"

# Same as the pre-#713 Bash-matcher registration order; only merge-gate.sh still has a
# standalone .claude/settings.json registration, on the mcp__github__merge_pull_request
# matcher.
GUARDS=(
  "vitest-suite-guard.sh"
  "git-refspec-guard.sh"
  "csv-parse-guard.sh"
  "worktree-commit-guard.sh"
  "pr-create-guard.sh"
  "merge-gate.sh"
  "test-coverage-reminder.sh"
)

TMP_ERR="$(mktemp)"
trap 'rm -f "$TMP_ERR"' EXIT

# run_sequential <payload> -> sets SEQ_OUT, SEQ_ERR, SEQ_RC
run_sequential() {
  local payload="$1"
  SEQ_OUT=""
  SEQ_ERR=""
  SEQ_RC=0
  local g out err rc
  for g in "${GUARDS[@]}"; do
    : >"$TMP_ERR"
    out="$(printf '%s' "$payload" | bash "$HOOKS_DIR/$g" 2>"$TMP_ERR")"
    rc=$?
    err="$(cat "$TMP_ERR")"
    SEQ_OUT+="$out"
    SEQ_ERR+="$err"
    if [[ $rc -ne 0 ]]; then
      SEQ_RC=$rc
      return
    fi
  done
}

# run_dispatcher <payload> -> sets DISP_OUT, DISP_ERR, DISP_RC
run_dispatcher() {
  local payload="$1"
  : >"$TMP_ERR"
  DISP_OUT="$(printf '%s' "$payload" | bash "$DISPATCHER" 2>"$TMP_ERR")"
  DISP_RC=$?
  DISP_ERR="$(cat "$TMP_ERR")"
}

json_payload() {
  # Minimal JSON string escaping for embedding an arbitrary shell command as a
  # JSON string value: backslash and double-quote only (test commands below never
  # contain control characters).
  local cmd="$1" esc
  esc="${cmd//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  printf '{"tool_input":{"command":"%s"}}' "$esc"
}

PASS=0
FAIL=0

check() {
  local label="$1" command="$2"
  local payload
  payload="$(json_payload "$command")"

  run_sequential "$payload"
  local seq_out="$SEQ_OUT" seq_err="$SEQ_ERR" seq_rc="$SEQ_RC"

  run_dispatcher "$payload"
  local disp_out="$DISP_OUT" disp_err="$DISP_ERR" disp_rc="$DISP_RC"

  if [[ "$seq_rc" == "$disp_rc" && "$seq_out" == "$disp_out" && "$seq_err" == "$disp_err" ]]; then
    printf 'PASS  %-40s command=%q rc=%s\n' "$label" "$command" "$seq_rc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %-40s command=%q\n' "$label" "$command"
    printf '      sequential: rc=%s out=%q err=%q\n' "$seq_rc" "$seq_out" "$seq_err"
    printf '      dispatcher: rc=%s out=%q err=%q\n' "$disp_rc" "$disp_out" "$disp_err"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Trigger cases (one per guard) ==="
check "vitest-suite-guard (deny)" "npx vitest"
check "git-refspec-guard (deny)" "git push origin main:test"
check "csv-parse-guard (deny)" "awk -F',' '{print \$1}' data.csv"
check "worktree-commit-guard (routed)" "git add foo.ts"
check "pr-create-guard (deny)" "gh pr create --title x --body y"
check "merge-gate (deny)" "gh pr merge 123 --merge"
check "test-coverage-reminder (routed)" "git push origin claude/bash-guard-dispatcher"

echo "=== Routing-regression cases (non-canonical spelling) ==="
check "git-refspec-guard (double space git/push)" "git  push origin main:test"
check "git-refspec-guard (chained, git not leading word)" "cd foo && git push origin main:test"
check "pr-create-guard (double spaces, no --draft)" "gh  pr  create --title x --body y"

echo "=== Benign cases ==="
check "ls" "ls"
check "cat file" "cat file.txt"
check "git status" "git status"
check "git diff" "git diff"
check "grep foo" "grep foo bar.txt"

echo "=== Additional benign / mixed cases ==="
check "npm run lint (scoped, not test)" "npm run lint"
check "npx vitest run scoped file (allow)" "npx vitest run apps/api/src/foo.test.ts"
check "git push origin feature-branch (no refspec)" "git push origin feature-branch"
check "gh pr create --draft (has --draft, allow)" "gh pr create --title x --body y --draft"
check "gh pr merge 123 --squash (good method, no marker)" "gh pr merge 123 --squash"
check "awk without csv" "awk -F',' '{print \$1}' data.log"
check "cut with csv but no comma delim" "cut -d: -f1 data.csv"

echo
echo "=== Summary ==="
echo "PASS: $PASS  FAIL: $FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
