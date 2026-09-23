#!/usr/bin/env bash
# PreToolUse hook for Bash — hard-enforces the lesson that naive comma-splitting on a
# CSV file (awk -F',' / cut -d,) silently mis-parses quoted fields that themselves
# contain commas. Recorded at tasks/lessons.md:73-85 (2026-09-01): the mis-parse
# produced a wrong timeline that was reported to the user as a live production outage.
#
# Denies (exit 2 + one-line stderr reason, plus the structured PreToolUse deny on
# stdout for harnesses that read `permissionDecision` instead of the exit code):
#   - A segment whose leading word is `awk` with a field-separator token of
#     `-F,` / `-F','` / `-F","` AND the segment references a `.csv` path.
#   - A segment whose leading word is `cut` with a delimiter token of
#     `-d,` / `-d ','` / `-d','` AND the segment references a `.csv` path.
# The `.csv` conjunct is load-bearing — without it this would misfire constantly on
# log/TSV munging that has nothing to do with CSV quoting. Do not drop it.
#
# Allows everything else, including:
#   - `awk -F',' file.log` (no .csv reference).
#   - `awk '{print $1}' data.csv` (no comma field separator).
#   - `grep -rn "awk -F," docs/` (leading word is grep, not awk).
#
# Fails open: any parse failure, missing command, or unexpected input allows the call.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/segment-split.sh
source "$SCRIPT_DIR/lib/segment-split.sh"
# shellcheck source=lib/json-escape.sh
source "$SCRIPT_DIR/lib/json-escape.sh"

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
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$(json_escape "$1")"
  printf 'CSV PARSE GUARD: %s\n' "$1" >&2
  exit 2
}

REASON='Naive comma-splitting mis-parses quoted CSV fields containing commas. Use python3 -c "import csv" (or a real CSV parser) instead.'

# Require ".csv" at a token boundary: end-of-string, whitespace, a closing quote, or
# a redirection operator (>, <) right after it. A raw substring search matched
# data.csvx, notes.csv.bak, x.csvy — none of which are actually a .csv file — and
# missing >/< let `awk -F, data.csv>out.txt` (no space before the redirect) through.
CSV_EXT_RE='\.csv([[:space:]"'"'"'><]|$)'

# Consume split_segments' NUL-delimited output via process substitution, not a
# `segments="$(...)"` + herestring, since a segment can legitimately contain an
# embedded newline (heredoc body, multi-line -m message) that would otherwise
# fragment into fake extra segments on a newline-delimited read.
while IFS= read -r -d '' seg; do
  seg="$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$seg" ]] && continue

  read -r -a words <<< "$seg"
  cmd0="${words[0]:-}"

  case "$cmd0" in
    awk)
      # Does the raw segment contain -F followed (optionally through quotes) by a
      # bare comma as the field separator?
      printf '%s' "$seg" | grep -qE -- "-F[[:space:]]*[\"']?,[\"']?([[:space:]]|\$)" || continue
      printf '%s' "$seg" | grep -qiE -- "$CSV_EXT_RE" && deny "$REASON"
      ;;
    cut)
      has_comma_d=0
      if printf '%s' "$seg" | grep -qE -- "-d[[:space:]]*[\"']?,[\"']?([[:space:]]|\$)"; then
        has_comma_d=1
      fi
      [[ "$has_comma_d" == "1" ]] || continue
      printf '%s' "$seg" | grep -qiE -- "$CSV_EXT_RE" && deny "$REASON"
      ;;
    *)
      continue
      ;;
  esac
done < <(split_segments "$command")

exit 0
