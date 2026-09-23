#!/usr/bin/env bash
# PreToolUse hook for Bash — hard-enforces the recurring lesson that
# `git push ... main:<branch>` (or `test:<branch>`) uses the LOCAL branch as the
# refspec source, which is routinely stale and silently pushes wrong commits.
# Recorded four separate times: tasks/lessons.md:35, tasks/lessons.md:288-312,
# tasks/lessons-archive.md:322-332, tasks/lessons-archive.md:345.
#
# Denies (exit 2 + one-line stderr reason, plus the structured PreToolUse deny on
# stdout for harnesses that read `permissionDecision` instead of the exit code):
#   - Any `git push ...` command segment containing a token matching `^main:` or
#     `^test:` — a <src>:<dst> refspec whose source is a bare local branch name.
#
# Allows everything else, including:
#   - `git push origin <branch>` / `git push -u origin <branch>` (no colon).
#   - `git push origin origin/main:test` (source is already origin/...).
#   - `git push origin <sha>:test` (source is a SHA, not a bare local branch).
#   - `--force-with-lease=refs/heads/main:<expected-sha>` (contains a colon but is
#     not a refspec token — it's a single `--flag=value` argument).
#   - `git diff main...HEAD`, `git merge`, `git rebase` — deliberately out of scope;
#     a hook cannot know whether origin/main was fetched in a prior tool call, so
#     that half of the original candidate was reviewed and rejected.
#
# Fails open: any parse failure, missing command, or unexpected input allows the call.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/segment-split.sh
source "$SCRIPT_DIR/lib/segment-split.sh"
# shellcheck source=lib/json-escape.sh
source "$SCRIPT_DIR/lib/json-escape.sh"

# PreToolUse passes the tool call as JSON on stdin. Shapes vary across harness versions
# (`tool_input`, `arguments`, or flat), so check all three — same defensive parse as
# vitest-suite-guard.sh / read-guard.sh / delegation-reminder.sh.
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
  printf 'GIT REFSPEC GUARD: %s\n' "$1" >&2
  exit 2
}

# Note: "fetch first" is NOT a valid remedy here — `git fetch` updates the
# remote-tracking ref `origin/main`, not the local `main` that a bare `main:test`
# refspec resolves its source from, so the refspec stays exactly as stale after a
# fetch. This exact confusion produced the bug tracked in tasks/lessons.md:35 and
# issue #662 — do not reintroduce that advice here.
REASON='git push using a bare local branch as a refspec source (e.g. main:test) is stale-prone — use a remote-tracking ref (origin/main:test) or an explicit commit SHA instead.'

# Split the command into segments on unquoted &&, ;, and | so each piece of a compound
# command is checked independently. Quote-aware: a raw tr-based split treated a
# separator character inside a quoted string (e.g. `echo "foo | git push origin
# main:test"`) as a real segment break, fabricating a `git push ...` segment out of a
# quoted string and denying an echoed/grepped command that never actually runs git.
# Consumed via process substitution (NUL-delimited), not a herestring — see
# lib/segment-split.sh's header comment for why a newline-delimited read is unsafe.
while IFS= read -r -d '' seg; do
  seg="$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$seg" ]] && continue

  read -r -a words <<< "$seg"
  cmd0="${words[0]:-}"
  [[ "$cmd0" != "git" ]] && continue
  sub="${words[1]:-}"
  [[ "$sub" != "push" ]] && continue

  for ((idx = 2; idx < ${#words[@]}; idx++)); do
    w="${words[$idx]}"
    # Skip single-argument flags like --force-with-lease=refs/heads/x:<sha> — those
    # contain a colon but are one `--flag=value` token, not a bare <src>:<dst> refspec.
    case "$w" in
      -*) continue ;;
    esac
    # Normalize the token before matching: `read -a` does no shell quote-removal on
    # already-literal text, so a quoted refspec like 'main:test' (or "main:test")
    # still carries its literal quote characters, and Git's force-refspec form
    # (+main:test) still carries its leading `+`. Strip both so the match below sees
    # the same bare `main:test` regardless of how the caller spelled it.
    # Order matters: quotes must be stripped BEFORE the leading `+`, because a
    # quoted force-refspec like '+main:test' has the `+` *inside* the quotes — a
    # `+`-strip run first sees a token starting with `'`, not `+`, and never fires,
    # leaving the quote (and the `+`) in place for the match below. Fixed in PR #664
    # round 4 (Copilot review) after that exact ordering bug let '+main:test' through.
    norm="$w"
    if [[ "$norm" == \'*\' || "$norm" == \"*\" ]]; then
      norm="${norm:1:-1}"
    fi
    [[ "$norm" == +* ]] && norm="${norm#+}"
    # A refspec token: <src>:<dst>. Only care when <src> is exactly the bare local
    # branch name `main` or `test` (not `origin/main`, not a SHA, not empty for a
    # delete-refspec `:branch`).
    case "$norm" in
      main:* | test:*)
        deny "$REASON"
        ;;
    esac
  done
done < <(split_segments "$command")

exit 0
