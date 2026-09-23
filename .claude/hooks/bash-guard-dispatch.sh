#!/usr/bin/env bash
# PreToolUse dispatcher for the Bash matcher — collapses seven separate guard-script
# spawns into a single process per Bash tool call:
#   vitest-suite-guard.sh, git-refspec-guard.sh, csv-parse-guard.sh,
#   worktree-commit-guard.sh, pr-create-guard.sh, merge-gate.sh,
#   test-coverage-reminder.sh
#
# Every one of those guards is a no-op for the overwhelming majority of Bash calls
# (`ls`, `cat file`, `git status`, ...), yet settings.json spawned all seven on every
# single call. This script reads the PreToolUse payload from stdin ONCE, extracts the
# command string, and uses it to decide which guards are even worth invoking.
#
# ROUTING IS DELIBERATELY OVER-INCLUSIVE. Each `case` pattern below is a verified
# SUPERSET of that guard's actual trigger condition (checked against the guard's own
# source, not guessed) — so a guard may run and silently no-op more often than its
# true trigger requires, but it is never skipped in a case where it would actually
# have denied or warned. An extra harmless spawn is an acceptable cost; silently
# disabling a guardrail is not.
#
# Every selected guard receives the EXACT original stdin payload, byte-for-byte, and
# is invoked exactly as it is under its own standalone PreToolUse registration
# (`bash "$GUARD_PATH"` with the payload on stdin) — this script never reimplements
# or reinterprets any guard's logic, it only decides whether to spawn it. Guards run
# in the pre-#713 registration order; no guard has a standalone Bash-matcher
# registration any more (merge-gate.sh keeps its separate
# mcp__github__merge_pull_request registration). Output is streamed straight through
# (no capture-and-replay), so stdout/stderr are preserved byte-for-byte exactly as a
# direct invocation would produce. The first guard to
# exit non-zero stops the chain immediately and its exit code becomes this script's
# exit code.
#
# FAILS OPEN: any error in THIS script (unparseable payload, missing guard file,
# unexpected shape, node unavailable) must never block the underlying Bash call.
# Deliberately no `set -e` — every risky step degrades to "route to nothing, exit
# 0" rather than aborting the script uninspected.
set -uo pipefail

# Lazy: only pay for the dirname/cd subshell when CLAUDE_PROJECT_DIR isn't already
# set (the production case is set, so this normally never runs), and swallow its
# stderr — a degraded PATH missing `dirname` would otherwise print
# "dirname: command not found" to stderr on every single Bash tool call.
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  PROJECT_DIR="$CLAUDE_PROJECT_DIR"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" 2>/dev/null && pwd 2>/dev/null)"
  PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd 2>/dev/null)"
fi

# Read stdin ONCE — it can only be drained once, and every guard invoked below
# needs the same payload replayed to it.
PAYLOAD="$(cat)"

# Best-effort extraction of the command string — the exact same defensive shape
# parse (tool_input.command / arguments.command / flat .command) that every guard
# already performs independently. Any failure here (bad JSON, node missing) just
# yields an empty COMMAND, which matches none of the case patterns below, so
# nothing runs and the script falls through to `exit 0` — fail open.
COMMAND="$(printf '%s' "$PAYLOAD" | node -e '
try {
  const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const i = d.tool_input || d.arguments || d;
  const c = i.command || d.command || "";
  if (c) process.stdout.write(c);
} catch (e) {}
' 2>/dev/null || true)"

# Lowercased copy used ONLY to decide routing below — the ORIGINAL $PAYLOAD (not
# this) is what gets piped to each guard. Lowercasing only ever makes a pattern
# match MORE often, never less, so it cannot turn a real trigger into a miss.
CMD_LC="$(printf '%s' "$COMMAND" | tr '[:upper:]' '[:lower:]')"

RUN_VITEST=0
RUN_REFSPEC=0
RUN_CSV=0
RUN_WORKTREE=0
RUN_PRCREATE=0
RUN_MERGE=0
RUN_COVERAGE=0

# vitest-suite-guard.sh: real trigger requires a segment's leading word to be
# literally "npm", "npx" (with next word "vitest"), or "vitest". Any such command
# necessarily contains the substring "npm" or "vitest".
case "$CMD_LC" in
  *vitest* | *npm*) RUN_VITEST=1 ;;
esac

# git-refspec-guard.sh: real trigger requires a `git push` segment. Necessarily
# contains "push".
case "$CMD_LC" in
  *push*) RUN_REFSPEC=1 ;;
esac

# csv-parse-guard.sh: real trigger requires an awk/cut segment referencing a
# literal ".csv" path (grep -qi, case-insensitive) — necessarily contains "csv".
case "$CMD_LC" in
  *csv*) RUN_CSV=1 ;;
esac

# worktree-commit-guard.sh: real trigger requires a segment whose leading word is
# "git" and whose second word is "add" or "commit" — necessarily contains "git"
# followed later by "add" or "commit".
case "$CMD_LC" in
  *git*add* | *git*commit*) RUN_WORKTREE=1 ;;
esac

# pr-create-guard.sh: real trigger requires a segment "gh pr create" (in that word
# order) without --draft — necessarily contains "gh" then "pr" then "create" in
# order.
case "$CMD_LC" in
  *gh*pr*create*) RUN_PRCREATE=1 ;;
esac

# merge-gate.sh (Bash-matcher path): real trigger requires a segment "gh pr merge".
# Deliberately routed on the broader "merge" alone (rather than the tighter
# "gh...pr...merge") — this guard is the hard block on merging to main, the single
# highest-cost guard to under-route, so it is biased even further toward
# over-inclusion than the others.
case "$CMD_LC" in
  *merge*) RUN_MERGE=1 ;;
esac

# test-coverage-reminder.sh: real trigger requires a `git push` segment —
# necessarily contains "push". Same superset as git-refspec-guard.sh.
case "$CMD_LC" in
  *push*) RUN_COVERAGE=1 ;;
esac

# Streams $PAYLOAD to the guard at $1 and lets its stdout/stderr pass straight
# through to this script's own stdout/stderr (no capture/replay), so output is
# byte-for-byte identical to a direct standalone invocation. Returns the guard's
# exit code. Missing guard file -> fail open (return 0, do nothing).
run_guard() {
  local guard_path="$1"
  [[ -f "$guard_path" ]] || return 0
  # Return the GUARD's own exit status, not the pipeline's. Under `set -o
  # pipefail`, if the guard exits 0 without draining stdin and $PAYLOAD exceeds
  # the pipe buffer (64KB), `printf` is killed by SIGPIPE and the pipeline as a
  # whole reports 141 — which would make this fail-open dispatcher wrongly BLOCK
  # a benign call. PIPESTATUS[1] is the guard's real exit code regardless of what
  # happened to `printf`. Read it immediately after the pipeline — nothing may
  # come between them or bash overwrites PIPESTATUS.
  printf '%s' "$PAYLOAD" | bash "$guard_path"
  return "${PIPESTATUS[1]}"
}

HOOKS_DIR="$PROJECT_DIR/.claude/hooks"

if [[ "$RUN_VITEST" == "1" ]]; then
  run_guard "$HOOKS_DIR/vitest-suite-guard.sh"
  rc=$?
  [[ $rc -ne 0 ]] && exit $rc
fi

if [[ "$RUN_REFSPEC" == "1" ]]; then
  run_guard "$HOOKS_DIR/git-refspec-guard.sh"
  rc=$?
  [[ $rc -ne 0 ]] && exit $rc
fi

if [[ "$RUN_CSV" == "1" ]]; then
  run_guard "$HOOKS_DIR/csv-parse-guard.sh"
  rc=$?
  [[ $rc -ne 0 ]] && exit $rc
fi

if [[ "$RUN_WORKTREE" == "1" ]]; then
  run_guard "$HOOKS_DIR/worktree-commit-guard.sh"
  rc=$?
  [[ $rc -ne 0 ]] && exit $rc
fi

if [[ "$RUN_PRCREATE" == "1" ]]; then
  run_guard "$HOOKS_DIR/pr-create-guard.sh"
  rc=$?
  [[ $rc -ne 0 ]] && exit $rc
fi

if [[ "$RUN_MERGE" == "1" ]]; then
  run_guard "$HOOKS_DIR/merge-gate.sh"
  rc=$?
  [[ $rc -ne 0 ]] && exit $rc
fi

if [[ "$RUN_COVERAGE" == "1" ]]; then
  run_guard "$HOOKS_DIR/test-coverage-reminder.sh"
  rc=$?
  [[ $rc -ne 0 ]] && exit $rc
fi

exit 0
