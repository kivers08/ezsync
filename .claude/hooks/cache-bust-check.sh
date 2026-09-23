#!/usr/bin/env bash
# PostToolUse hook for Edit|Write — WARN ONLY.
#
# HISTORY / SCOPE: in the middleware this guarded EJS templates under src/views/ that
# hand-wrote `?v=<hash>` cache-busting query params on their asset <link>/<script> tags,
# warning when a version string was bumped in the template but left stale in tests/.
# ezsync's frontend is Next.js, which fingerprints its own asset filenames at build time,
# so there is no hand-maintained `?v=` cache-buster there and that check is obsolete.
#
# The only place a hand-served static asset with a manual `?v=` param could reappear is a
# static file that apps/api serves directly (a `public/` dir under the Express app). This
# hook therefore does nothing at all unless the edited file lives under such a dir AND it
# actually contains a `?v=` param — in every normal .ts/.tsx/.md/config edit it exits 0
# immediately and silently, so it can never fire spuriously.
#
# NEVER denies: always exit 0 (a multi-file sweep must not be blocked mid-way).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

file_path="$(node -e '
try {
  const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const path = d.file_path || (d.arguments && d.arguments.file_path) || (d.tool_input && d.tool_input.file_path) || "";
  if (path) process.stdout.write(path);
} catch (e) {}
' 2>/dev/null || true)"

[[ -z "$file_path" ]] && exit 0

# Only hand-served static assets under apps/api are in scope. Anything else (all Next.js
# frontend files, all TS source, docs, config) is a silent no-op.
case "$file_path" in
  */apps/api/*/public/* | apps/api/*/public/* | \
  */apps/api/public/*   | apps/api/public/*) ;;
  *) exit 0 ;;
esac

[[ -f "$file_path" ]] || exit 0
grep -q '?v=' "$file_path" 2>/dev/null || exit 0

echo "CACHE-BUST CHECK: $file_path carries a hand-written \`?v=\` cache-buster. Next.js fingerprints its own assets; a hand-served static asset with a manual version param must have every reference bumped together — verify no stale copies remain."

exit 0
