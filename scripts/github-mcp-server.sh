#!/usr/bin/env bash
# Wrapper for the `github` MCP server declared in .mcp.json.
#
# Why this exists: Claude Code fixes its own process environment at launch time, so a
# SessionStart hook that runs *after* Claude Code has already started (e.g. one that
# provisions a fresh token via `gh auth login`, or refreshes `gh auth token` on a
# container that reset $HOME) cannot inject GITHUB_PERSONAL_ACCESS_TOKEN into Claude
# Code's own environment for .mcp.json to inherit. Resolving the token here, at the
# moment the MCP server process is actually spawned, is what lets a fresh/ephemeral
# container work without requiring a full Claude Code restart.
set -u

# Respect an already-set token as-is (e.g. exported by the user's shell or CI) — only
# fall back to `gh auth token` when nothing is already present.
if [[ -z "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]]; then
  gh_token="$(gh auth token 2>/dev/null || true)"
  if [[ -n "$gh_token" ]]; then
    GITHUB_PERSONAL_ACCESS_TOKEN="$gh_token"
  fi
fi

if [[ -z "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]]; then
  # stdout is the MCP JSON-RPC channel — never write here. Diagnostics go to stderr and
  # we still exec the server so the failure surfaces as the server's own auth error
  # rather than a silent hang.
  echo "github-mcp-server.sh: no GITHUB_PERSONAL_ACCESS_TOKEN and 'gh auth token' returned nothing — starting server anyway, expect an auth error" >&2
fi

export GITHUB_PERSONAL_ACCESS_TOKEN

exec "${GITHUB_MCP_SERVER_PATH:-github-mcp-server}" stdio "$@"
