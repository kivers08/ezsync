#!/usr/bin/env bash
# PreToolUse hook for Bash — hard-enforces .claude/rules/testing-verification.md's ban
# on whole-suite Vitest invocations. That rule has been violated twice by different
# sessions relying on instruction-following alone (2026-08-05 and 2026-09-01, both
# recorded in tasks/lessons.md), so this makes the rule mechanical instead.
#
# Denies (exit 2 + one-line stderr reason, plus the structured PreToolUse deny on
# stdout for harnesses that read `permissionDecision` instead of the exit code):
#   - `npm test` / `npm run test` with no file path and no -t/--testNamePattern.
#   - `npx vitest` / `vitest` (any flags) with no positional path arg and no
#     -t/--testNamePattern.
# This applies per-segment across compound commands (&&, ;, |), so a real full-suite
# invocation anywhere in the chain is denied even if other segments are fine.
#
# Allows everything else, including:
#   - `npx vitest run apps/api/src/config/env.test.ts`, `npx vitest -t "name"`,
#     `--testNamePattern=...`.
#   - `npm run lint`, `npm run format:check`, `npm run typecheck`, `npm ci`, `npm install`.
#   - `--version`, `--help` (informational, no tests run).
#   - vitest/npm test appearing incidentally inside a grep, echo, git --grep, heredoc, or
#     a path like apps/api/vitest.config.ts — this only inspects the invoked command word,
#     never a raw substring match anywhere in the string.
#
# NOTE on the `run` subcommand: `vitest run` is the standard non-watch invocation. The
# bare word `run` after `vitest` is NOT treated as a positional test path (it is a
# subcommand), so `npx vitest run` with nothing else is still a full-suite run and is
# denied; `npx vitest run <file>` / `-t "<name>"` is scoped and allowed.
#
# Shell redirection is NOT a test path. The positional-path scan understands redirection
# tokens: a bare operator (`>`, `>>`, `<`, `<<<`, `&>`, `>&`, `2>`, `2>>`, ...) consumes
# the filename token that follows it, and for an unquoted token containing `<`/`>` only
# the portion BEFORE the first redirect character is evaluated as an argv word — an empty
# or pure-fd-number prefix (`2>&1`, `>out.txt`, `2>err.log`) is no word at all, while a
# real prefix (`apps/api/src/a.test.ts>out.txt`) IS a positional path and correctly allows.
#
#   2026-09-02 incident: before this, the scan's plain `-*` test treated the `2>&1` token
#   left in `npx vitest ... 2>&1 | grep foo` as a positional test path, so
#   has_positional_path=1 and the entire suite ran unguarded. That exact
#   command is now denied, and is pinned in both directions by tests/vitestSuiteGuard.test.ts.
#
# DELIBERATE, FROZEN GAPS — known, ACCEPTED false negatives. These constructs were
# surfaced by Copilot on PR #690 and were consciously DECLINED by the owner, who chose to
# keep PR #664's frozen splitter scope rather than grow the hook into a shell parser.
# They are recorded here so the next person inherits the decision instead of
# rediscovering it and "fixing" it:
#   - An unquoted `#` comment (`npx vitest # run the suite`): the comment's words are still
#     tokenized and the first of them counts as a positional path, so the run is allowed.
#   - Process/command substitution (`npx vitest > >(tee out.log)`, `$(...)`, backticks):
#     space-splitting breaks `>(tee out.log)` into several tokens and the trailing
#     `out.log)` counts as a positional path, so the run is allowed.
#   Both are pinned as allow-with-a-comment cases in tests/vitestSuiteGuard.test.ts so any
#   future change to them is a conscious decision, mirroring how
#   tests/gitRefspecGuard.test.js pins the newline gap. Handling either would require
#   real shell-grammar awareness; see .claude/hooks/lib/segment-split.sh's header.
#   As stated there, these hooks are NOT a security boundary against an adversarial
#   caller — they are a mechanical nudge against the accidental cases the lessons they
#   encode were actually about.
#
# Fails open: any parse failure, missing command, or unexpected input allows the call.
# A malformed payload must never wedge the session.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/segment-split.sh
source "$SCRIPT_DIR/lib/segment-split.sh"
# shellcheck source=lib/json-escape.sh
source "$SCRIPT_DIR/lib/json-escape.sh"

# PreToolUse passes the tool call as JSON on stdin. Shapes vary across harness versions
# (`tool_input`, `arguments`, or flat), so check all three — same defensive parse as
# read-guard.sh / delegation-reminder.sh.
command="$(node -e '
try {
  const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const i = d.tool_input || d.arguments || d;
  const c = i.command || d.command || "";
  if (c) process.stdout.write(c);
} catch (e) {}
' 2>/dev/null || true)"

# No command resolved → allow (fail open).
[[ -z "$command" ]] && exit 0

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$(json_escape "$1")"
  printf 'VITEST SUITE GUARD: %s\n' "$1" >&2
  exit 2
}

REASON="Whole-suite Vitest run is blocked by .claude/rules/testing-verification.md. Use a scoped run instead: npx vitest run <specific-file> (or -t \"<name>\"), or push and verify via CI (gh workflow run ci.yml, then get_check_runs)."

# Split the command into segments on &&, ;, and | so each piece of a compound command
# is checked independently — a real full-suite invocation in any segment denies, but
# that same text appearing as a quoted argument to grep/echo/git elsewhere does not
# (it never becomes its own segment's leading word).
# Consumed via process substitution (NUL-delimited), not a herestring — see
# lib/segment-split.sh's header comment for why a newline-delimited read is unsafe.
while IFS= read -r -d '' seg; do
  # Trim leading/trailing whitespace.
  seg="$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$seg" ]] && continue

  # Tokenize the segment. word[0] is the leading command word we care about; skip
  # segments whose leading word is something other than npm/npx/vitest (e.g. grep, echo,
  # git) so incidental mentions of "npm test"/"npx vitest" deep in an argument never trip
  # this check.
  read -r -a words <<< "$seg"
  cmd0="${words[0]:-}"

  case "$cmd0" in
    npm)
      sub="${words[1]:-}"
      [[ "$sub" != "test" && "$sub" != "run" ]] && continue
      # `npm run <script>` only matters for `npm run test`.
      if [[ "$sub" == "run" ]]; then
        [[ "${words[2]:-}" != "test" ]] && continue
      fi
      # Args after a literal `--` are npm-test's own passthrough args (or, for `npm
      # test <file>`, npm doesn't take positional test files without `--`, so a real
      # `npm test foo.test.ts` is nonstandard — treat any arg after test/run test/-- as
      # a potential scoping arg and look for a path or -t/--testNamePattern anywhere in
      # the remaining tokens).
      scoped=0
      for ((idx = 0; idx < ${#words[@]}; idx++)); do
        w="${words[$idx]}"
        case "$w" in
          -t | --testNamePattern | --testNamePattern=* ) scoped=1 ;;
          *.test.ts | *.test.tsx | *.spec.ts | *.spec.tsx ) scoped=1 ;;
        esac
      done
      [[ "$scoped" == "1" ]] && continue
      deny "$REASON"
      ;;
    npx)
      nxt="${words[1]:-}"
      [[ "$nxt" != "vitest" ]] && continue
      _check_vitest_args=1
      _vitest_arg_start=2
      ;;
    vitest)
      _check_vitest_args=1
      _vitest_arg_start=1
      ;;
    *)
      continue
      ;;
  esac

  if [[ "${_check_vitest_args:-0}" == "1" ]]; then
    unset _check_vitest_args
    arg_start="$_vitest_arg_start"
    unset _vitest_arg_start
    scoped=0
    has_positional_path=0
    skip_next=0
    for ((idx = arg_start; idx < ${#words[@]}; idx++)); do
      w="${words[$idx]}"

      # The previous token was a bare redirection operator (`>`, `2>`, `<`, ...), so
      # this token is its filename target, not an argv word. Neither counts as a
      # positional test path.
      if [[ "$skip_next" == "1" ]]; then
        skip_next=0
        continue
      fi

      # A token that begins with a quote character still carries its quotes here —
      # `read -r -a` does no quote removal — so any `<`/`>` inside it was a literal
      # filename character to the shell, never live redirection syntax. Evaluate it
      # as a plain word and skip all redirection handling below.
      if [[ "$w" == '"'* || "$w" == "'"* ]]; then
        case "$w" in
          -*) ;;
          *) has_positional_path=1 ;;
        esac
        continue
      fi

      case "$w" in
        # `run` is Vitest's non-watch subcommand, not a test path — a bare
        # `npx vitest run` is still a full-suite run. Only skip it in the FIRST
        # argument position (right after `vitest`); a later `run` token would be a
        # real path/pattern. `idx == arg_start` is that first-position test.
        run )
          [[ "$idx" -eq "$arg_start" ]] || has_positional_path=1
          ;;
        -t | --testNamePattern | --testNamePattern=* ) scoped=1 ;;
        --version | --help | -v | -h ) scoped=1 ;;
        # Bare redirection operators — the filename target follows as its own token.
        '>' | '>>' | '<' | '<<' | '<<<' | '&>' | '&>>' | '>&' | \
        [0-9]'>' | [0-9]'>>' | [0-9]'<' | [0-9]'<<' | [0-9]'>&' | [0-9]'<&' )
          skip_next=1
          ;;
        # Attached redirection, possibly glued to a real argv word in the same token.
        # Evaluate ONLY the portion before the first redirect character: bash reads
        # `apps/api/src/a.test.ts>out.txt` as the positional path `apps/api/src/a.test.ts` PLUS a
        # redirection, so that IS a scoped run; whereas `2>&1` / `>out.txt` /
        # `2>err.log` have an empty or pure-fd-number prefix, i.e. no argv word at
        # all. See the 2026-09-02 regression note in this file's header.
        # (An attached `run>out` prefix of `run` would fall here and be counted as a
        # path — acceptable: it is not the bare-subcommand no-op case.)
        *'>'* | *'<'* )
          prefix="${w%%[\<\>]*}"
          if [[ -n "$prefix" && ! "$prefix" =~ ^[0-9]+$ ]]; then
            case "$prefix" in
              -*) ;;
              *) has_positional_path=1 ;;
            esac
          fi
          ;;
        -*) ;; # other flag, not a positional path
        *)
          has_positional_path=1
          ;;
      esac
    done
    [[ "$scoped" == "1" || "$has_positional_path" == "1" ]] && continue
    deny "$REASON"
  fi
done < <(split_segments "$command")

exit 0
