#!/usr/bin/env bash
#
# verify-agent-work.sh — verifies a subagent actually did what it claimed:
# committed on the expected branch, left a clean tree, and has commits ahead
# of the base branch. Run from *within* the target worktree/repo directory.
#
# Usage: scripts/verify-agent-work.sh <expected-branch> [base-ref]
#
# <base-ref> defaults to origin/main (falling back to local main) when omitted; pass it
# explicitly for a non-main base, e.g. an epic-unit branch based on
# claude/repo-wide-refactor.
#
# Exits non-zero with a clear message on any failure. Prints a PASS summary
# (including the proof-artifact commit log) and exits 0 on success.

set -euo pipefail

expected_branch="${1:-}"
base_ref_arg="${2:-}"

if [ -z "$expected_branch" ]; then
  echo "Usage: $0 <expected-branch> [base-ref]" >&2
  exit 1
fi

# --- Check 1: current branch matches expected ---
actual_branch="$(git branch --show-current)"

if [ "$actual_branch" != "$expected_branch" ]; then
  echo "FAIL: branch mismatch." >&2
  echo "  Expected branch: $expected_branch" >&2
  echo "  Actual branch:   $actual_branch" >&2
  exit 1
fi

# --- Check 2: working tree is clean (no staged or unstaged changes to tracked files) ---
# --untracked-files=no: stray scratch files unrelated to the actual commit shouldn't
# fail this check.
status_output="$(git status --porcelain --untracked-files=no || true)"

if [ -n "$status_output" ]; then
  echo "FAIL: working tree is not clean." >&2
  echo "  git status --short output:" >&2
  git status --short --untracked-files=no >&2
  exit 1
fi

# --- Check 3: branch has commits ahead of the base ---
# Use the provided base-ref if given (e.g. a non-main epic base branch); otherwise
# prefer origin/main, falling back to local main if origin/main isn't available.
base_ref=""

git fetch origin main --quiet 2>/dev/null || true

if [ -n "$base_ref_arg" ]; then
  if git rev-parse --verify --quiet "$base_ref_arg" >/dev/null; then
    base_ref="$base_ref_arg"
  else
    echo "FAIL: could not resolve provided base ref '$base_ref_arg'." >&2
    exit 1
  fi
elif git rev-parse --verify --quiet origin/main >/dev/null; then
  base_ref="origin/main"
elif git rev-parse --verify --quiet main >/dev/null; then
  base_ref="main"
else
  echo "FAIL: could not resolve a base ref (neither origin/main nor local main exists)." >&2
  exit 1
fi

ahead_count="$(git rev-list --count "${base_ref}..HEAD")"

if [ "$ahead_count" -eq 0 ]; then
  echo "FAIL: branch '$actual_branch' has no new commits ahead of $base_ref." >&2
  exit 1
fi

# --- All checks passed ---
proof_log="$(git log --oneline "${base_ref}..HEAD")"

echo "PASS: branch '$actual_branch' verified against $base_ref."
echo "  Commits ahead of $base_ref: $ahead_count"
echo "  Proof (git log --oneline ${base_ref}..HEAD):"
echo "$proof_log"

exit 0
