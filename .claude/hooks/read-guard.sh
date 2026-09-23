#!/usr/bin/env bash
# PreToolUse hook for Read — hard-enforces CLAUDE.md's "never read a large file in full
# to search it" rule. Cost is quadratic in tool-call count and the single biggest
# per-call inflator is an oversized tool result, so a full read of a vendored spec, the
# CHANGELOG, or a subagent transcript can cost more than the entire task it serves.
#
# Denies (exit 2 + one-line stderr reason, plus the structured PreToolUse deny on stdout
# for harnesses that read `permissionDecision` instead of the exit code):
#   1. Subagent transcripts (`<agentId>.output` under a session `tasks/` dir) — always.
#   2. Named giants (vendored API specs, CHANGELOG, the grep-only archives) read whole.
#   2b. Any docs/tasks/root-md file over MAX_DOC_LINES lines read whole (src/ excluded).
#   3. Any file over 256KB read whole.
#
# Ranged reads (`offset`/`limit` present) are the sanctioned escape hatch for 2, 2b, and
# 3 — targeted reads stay allowed, only unbounded slurps are blocked. Fails open: any
# parse or stat failure allows the read, so a malformed payload can never wedge the
# session.
set -uo pipefail

MAX_BYTES=262144 # 256KB
MAX_DOC_LINES=250

# Resolve repo root from this script's location (.claude/hooks/ -> repo root).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# PreToolUse passes the tool call as JSON on stdin. Shapes vary across harness versions
# (`tool_input`, `arguments`, or flat), so check all three — same defensive parse as
# delegation-reminder.sh. Emits "<path>\n<0|1 ranged>".
parsed="$(node -e '
try {
  const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const i = d.tool_input || d.arguments || d;
  const p = i.file_path || d.file_path || "";
  const ranged = (i.offset != null || i.limit != null) ? "1" : "0";
  if (p) process.stdout.write(p + "\n" + ranged);
} catch (e) {}
' 2>/dev/null || true)"

# No path resolved → allow (fail open).
[[ -z "$parsed" ]] && exit 0

file_path="${parsed%%$'\n'*}"
ranged="${parsed##*$'\n'}"
[[ -z "$file_path" ]] && exit 0

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$1"
  printf 'READ BLOCKED: %s\n' "$1" >&2
  exit 2
}

# 1. Subagent transcript — no ranged exception; these are never worth paging through.
case "$file_path" in
  */tasks/*.output | tasks/*.output)
    case "$file_path" in
      "$ROOT"/tasks/*) ;; # this repo's own tasks/ dir — not a transcript
      *) deny "Subagent transcript. Use the agent completion summary, or aggregate with a script/grep." ;;
    esac
    ;;
esac

# Ranged reads of anything below are allowed — that is the escape hatch.
[[ "$ranged" == "1" ]] && exit 0

# 2. Named giants: the shared vendored-type subtree, CHANGELOG, and the grep-only archives.
# `packages/shared/types/` matches as a subtree rather than by filename: the vendor spec /
# type-declaration files there (Jobber GraphQL, QBO, Square) are all authoritative and
# would otherwise slip past both the named list and the 256KB fallback.
# `tasks/lessons.md` and `tasks/todo.md` get the same treatment as CHANGELOG.md, for the
# same reason: both now carry a `## Index` section, so a ranged read through
# it plus a grep can substitute for a full read.
case "$file_path" in
  */packages/shared/types/* | packages/shared/types/* | \
  */CHANGELOG.md | CHANGELOG.md | \
  */CHANGELOG-archive.md | CHANGELOG-archive.md | \
  */tasks/todo-archive.md | tasks/todo-archive.md | \
  */tasks/lessons-archive.md | tasks/lessons-archive.md | \
  */tasks/todo.md | tasks/todo.md | \
  */tasks/lessons.md | tasks/lessons.md)
    deny "Grep-only file. Grep for the symbol, or Read with offset/limit."
    ;;
esac

# 2b. Docs/tasks/root-md line-count sweep: any file under docs/, tasks/, or a root-level
# *.md file (not nested elsewhere) that grows past MAX_DOC_LINES auto-requires a ranged
# read, without needing to be added to the named-giants list by hand. Deliberately scoped
# away from src/ (and everything else) so a long code file or comment block can never
# accidentally trip this rule — computed off the path relative to $ROOT so it behaves the
# same whether $file_path arrives absolute or relative.
rel_path="${file_path#"$ROOT"/}"
doc_scoped=0
case "$rel_path" in
  docs/* | tasks/*)
    doc_scoped=1
    ;;
  *.md)
    case "$rel_path" in
      */*) ;; # nested under some other dir - not root-level, leave unscoped
      *) doc_scoped=1 ;;
    esac
    ;;
esac

if [[ "$doc_scoped" == "1" && -f "$file_path" ]]; then
  lines="$(wc -l < "$file_path" 2>/dev/null || echo 0)"
  if [[ "$lines" -gt "$MAX_DOC_LINES" ]]; then
    deny "File is ${lines} lines (>${MAX_DOC_LINES} in docs/tasks/root-md) — add a Table of Contents and read only through it, or Read with offset/limit."
  fi
fi

# 3. Generic catch-all for future giants not on the named list.
if [[ -f "$file_path" ]]; then
  size="$(stat -c%s "$file_path" 2>/dev/null || echo 0)"
  if [[ "$size" -gt "$MAX_BYTES" ]]; then
    deny "File is ${size}B (>256KB). Grep for the symbol, or Read with offset/limit."
  fi
fi

exit 0
