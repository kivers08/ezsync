#!/usr/bin/env bash
# Shared JSON string escaping for PreToolUse Bash guards' structured deny output.
#
# Each hook's deny() interpolates a REASON string into
# `"permissionDecisionReason":"%s"` with a bare printf %s — no escaping. Any REASON
# containing a literal `"` (e.g. csv-parse-guard.sh's `python3 -c "import csv"`) or a
# backslash produces invalid JSON on stdout. The exit-2 deny still works for harnesses
# that only read the exit code, but any harness that parses the structured
# `permissionDecision` JSON gets a parse error instead of the reason text.
# Recorded as a real defect in PR #664 (Copilot review, round 3).
#
# json_escape <string> prints the string with `\`, `"`, and newlines escaped so it is
# safe to interpolate into a JSON string value.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}
