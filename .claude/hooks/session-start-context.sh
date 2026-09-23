#!/usr/bin/env bash
# SessionStart hook — operationalizes CLAUDE.md "Session Start Protocol".
# Injects a condensed context slice (lessons index, active sprint, unchecked todos) and
# runs one-time-per-session setup (hooksPath, npm install). Target budget: <=8KB total
# injected output (see the self-check at the bottom) — the old version injected ~32KB
# by cat-ing 15 full lessons entries + a todo.md tail; this version injects an index only.
set -euo pipefail

# Resolve repo root from this script's location (.claude/hooks/ -> repo root).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Activate the versioned Prettier pre-commit hook (.githooks/pre-commit) for this clone.
# `core.hooksPath` is local git config, not versioned, so a fresh clone/worktree won't use
# it until something sets this — do so here, once per session, silently and non-fatally
# (a git-config failure must never break session start).
if [[ -d "$ROOT/.git" || -f "$ROOT/.git" ]]; then
  current_hooks_path="$(git -C "$ROOT" config --get core.hooksPath 2>/dev/null || true)"
  if [[ "$current_hooks_path" != ".githooks" ]]; then
    git -C "$ROOT" config core.hooksPath .githooks >/dev/null 2>&1 || true
  fi
fi

# REMOVED (2026-09-02): the block that copied .claude/hooks/stop-hook-git-check.sh over
# ~/.claude/stop-hook-git-check.sh. That sync existed to persist the advisory-mode patch
# (owner-approved 2026-09-01) into the user-level copy the harness ships, but it is the
# wrong level to fix anything at, for three reasons:
#
#   1. It kept a SECOND live registration of the same advisory alive. The harness's
#      ~/.claude/launcher-settings.json registers a `Stop` hook pointing at
#      ~/.claude/stop-hook-git-check.sh, and .claude/settings.json registers one pointing
#      at $CLAUDE_PROJECT_DIR/.claude/hooks/stop-hook-git-check.sh. Syncing the two files
#      made them byte-identical, so every turn printed the identical advisory TWICE. The
#      repo-level registration is the one to keep; the user-level one is the duplicate.
#   2. ~/.claude content dies with the container. Anything written there is not versioned,
#      not reviewable, and gone on the next session — so it can never be a source of truth,
#      only a copy that silently DIVERGES from the repo copy. That is exactly the
#      2026-09-01 incident recorded in tasks/lessons.md: the advisory was patched live in
#      ~/.claude/stop-hook-git-check.sh, the container restarted, and the patch evaporated.
#   3. Nothing mechanically stops this sync from coming back, so the removal has to be
#      documented rather than merely enforced. .claude/hooks/user-level-write-guard.sh
#      denies an Edit or Write whose target resolves under ~/.claude, but it is registered
#      on the Edit|Write matcher ONLY: a `cp` runs through Bash, which that guard
#      deliberately exempts so the sanctioned install remedy is never blocked by the guard
#      recommending it. A reintroduced `cp` sync would therefore run unimpeded. This
#      comment block is the only thing standing in its way — do not add it back.
#
# The repo copy at .claude/hooks/stop-hook-git-check.sh remains the single source of truth
# and stays registered from .claude/settings.json. Note that removing this sync does NOT by
# itself silence the duplicate: the user-level registration lives in the harness-provisioned
# ~/.claude/launcher-settings.json, which this repo does not track and must never write to,
# so its `Stop` block has to be removed by hand by the owner.

# Provision the toolchain itself (node/npm, gh, github-mcp-server) when it is missing.
# Same ephemeral-container reason as the block above: remote containers reset $HOME every
# session, and node/npm/gh/github-mcp-server live under ~/.local — so they vanish with the
# container and a fresh session otherwise starts with a dead toolchain (no npm for the
# install below, no gh for PR work, no github-mcp-server for the project-scoped `github`
# MCP server declared in .mcp.json). This runs BEFORE the dependency install so a freshly
# provisioned npm is on PATH in time for it. Strictly best-effort: every network call is
# time-boxed and every failure degrades to one short notice, because nothing here may
# break session start.
# Opt out with CLAUDE_SKIP_TOOLCHAIN_PROVISION=<anything> (e.g. a deliberately pinned host).
if [[ -z "${CLAUDE_SKIP_TOOLCHAIN_PROVISION:-}" ]]; then
  # True only when EVERY named command resolves. node, npm and npx ship as one Node
  # distribution, so a host with `node` but no `npm` is still a broken toolchain — and
  # checking `node` alone let exactly that case skip provisioning and fall through to the
  # dependency install with no npm, the state this block exists to prevent.
  tc_have() {
    local tc_c
    for tc_c in "$@"; do command -v "$tc_c" >/dev/null 2>&1 || return 1; done
    return 0
  }

  # nvm-managed node can exist but be off a non-interactive PATH — try the same fallback
  # the dependency block uses before concluding the Node toolchain is genuinely absent.
  if ! tc_have node npm && [[ -s "${NVM_DIR:-${HOME:-}/.nvm}/nvm.sh" ]]; then
    set +eu
    # shellcheck disable=SC1091
    source "${NVM_DIR:-${HOME:-}/.nvm}/nvm.sh" >/dev/null 2>&1 || true
    set -eu
  fi

  # Happy path (all five present) costs five `command -v` checks, prints nothing and
  # makes no network call.
  if ! tc_have node npm npx gh github-mcp-server; then
    # Both upstreams below ship prebuilt linux-x64/amd64 tarballs only; on any other
    # architecture a download would install a binary that cannot run, so skip instead.
    if [[ "$(uname -m 2>/dev/null || echo unknown)" != "x86_64" ]]; then
      echo "===== toolchain provisioning skipped (non-x86_64 host) ====="
    elif [[ -z "${HOME:-}" ]]; then
      echo "===== toolchain provisioning skipped (no HOME) ====="
    else
      TC_BIN="$HOME/.local/bin"
      # Scratch dir for tarballs only — cleaned up inline at the end of this block rather
      # than via a second EXIT trap, which would clobber the $OUT trap set further down.
      TC_TMP="$(mktemp -d 2>/dev/null || true)"
      if [[ -z "$TC_TMP" ]]; then
        echo "===== toolchain provisioning skipped (no scratch dir) ====="
      else
        mkdir -p "$TC_BIN" 2>/dev/null || true

        # SHA-256 of $1 on stdout; empty when no hashing tool exists, which callers must
        # treat as a fail-closed skip (never as "nothing to check").
        tc_sha256() {
          if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$1" 2>/dev/null | cut -d' ' -f1
          elif command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
          fi
        }

        if ! tc_have node npm npx; then
          # Track the repo's own Node requirement (.nvmrc major) and resolve the newest
          # matching release, rather than hardcoding a patch version that goes stale.
          # .nvmrc may hold `22`, `22.11.0`, `v22.11.0` or an alias like `lts/jod` — take
          # the major only, and fall back to 22 for anything that isn't purely digits.
          tc_major="$(tr -d '[:space:]' < "$ROOT/.nvmrc" 2>/dev/null | cut -d. -f1 || true)"
          tc_major="${tc_major#v}"
          [[ "$tc_major" =~ ^[0-9]+$ ]] || tc_major=22
          echo "===== node/npm/npx incomplete — provisioning Node ${tc_major}.x into $TC_BIN ====="
          tc_ver="$(curl -fsSL --max-time 10 https://nodejs.org/dist/index.json 2>/dev/null |
            grep -o "\"version\":\"v${tc_major}\.[0-9.]*\"" | head -1 | cut -d'"' -f4 || true)"
          if [[ -z "$tc_ver" ]]; then
            echo "===== node provisioning failed (could not resolve a v${tc_major} release) — continuing ====="
          else
            tc_tar="node-${tc_ver}-linux-x64.tar.xz"
            # Fail closed on integrity: this runs unattended and extracts executables
            # straight onto PATH, and HTTPS attests the host, not the artifact. Resolve
            # the published hash FIRST — no hash, no tool, or no match means no install.
            # `$2 == f` anchors on the exact filename (SHASUMS256.txt lists many names
            # that share this one as a prefix, e.g. the .tar.gz and the -headers tarball).
            tc_want="$(curl -fsSL --max-time 10 "https://nodejs.org/dist/${tc_ver}/SHASUMS256.txt" 2>/dev/null |
              awk -v f="$tc_tar" '$2 == f { print $1; exit }' || true)"
            if [[ -z "$tc_want" ]]; then
              echo "===== node provisioning aborted (no published SHA-256 for ${tc_tar}) — continuing ====="
            elif ! curl -fsSL --max-time 60 -o "$TC_TMP/$tc_tar" \
                   "https://nodejs.org/dist/${tc_ver}/${tc_tar}" 2>/dev/null; then
              echo "===== node provisioning failed (download) — continuing ====="
            else
              tc_got="$(tc_sha256 "$TC_TMP/$tc_tar" || true)"
              if [[ -z "$tc_got" ]]; then
                rm -f "$TC_TMP/$tc_tar" 2>/dev/null || true
                echo "===== node provisioning aborted (no sha256sum/shasum to verify with) — continuing ====="
              elif [[ "${tc_got,,}" != "${tc_want,,}" ]]; then
                rm -f "$TC_TMP/$tc_tar" 2>/dev/null || true
                echo "===== node provisioning aborted (SHA-256 mismatch on ${tc_tar}) — continuing ====="
              elif mkdir -p "$HOME/.local/node${tc_major}" 2>/dev/null &&
                   tar -xJf "$TC_TMP/$tc_tar" -C "$HOME/.local/node${tc_major}" --strip-components=1 2>/dev/null; then
                # Linking IS the install: an unwritable ~/.local/bin leaves an extracted
                # tarball that nothing on PATH can reach, so a swallowed `ln` failure must
                # never be reported as success. Track it, then confirm the tools actually
                # resolve before claiming anything was installed.
                tc_linked=1
                for tc_b in node npm npx; do
                  ln -sf "$HOME/.local/node${tc_major}/bin/$tc_b" "$TC_BIN/$tc_b" 2>/dev/null || tc_linked=0
                done
                # ~/.local/bin is on PATH via .bashrc/.profile, but this hook runs
                # non-interactively — export it now so the npm install below sees npm.
                export PATH="$TC_BIN:$PATH"
                if [[ "$tc_linked" -eq 1 ]] && tc_have node npm npx; then
                  echo "===== node ${tc_ver} installed (SHA-256 verified) ====="
                else
                  echo "===== node provisioning failed (node/npm/npx not linked into $TC_BIN) — continuing ====="
                fi
              else
                echo "===== node provisioning failed (extract) — continuing ====="
              fi
            fi
          fi
        fi

        if ! tc_have gh; then
          # Binary only — `gh auth login` stays the user's action and is never automated.
          echo "===== gh missing — provisioning GitHub CLI into $TC_BIN ====="
          tc_ghver="$(curl -fsSL --max-time 10 https://api.github.com/repos/cli/cli/releases/latest 2>/dev/null |
            grep -o '"tag_name": *"v[0-9][0-9.]*"' | head -1 | cut -d'"' -f4 || true)"
          tc_ghver="${tc_ghver#v}"
          if [[ -z "$tc_ghver" ]]; then
            echo "===== gh provisioning failed (could not resolve latest release) — continuing ====="
          else
            tc_ghtar="gh_${tc_ghver}_linux_amd64.tar.gz"
            # Same fail-closed contract as node above; the release's checksums.txt lists
            # every asset, so anchor on the exact filename rather than substring-matching.
            tc_ghwant="$(curl -fsSL --max-time 10 \
              "https://github.com/cli/cli/releases/download/v${tc_ghver}/gh_${tc_ghver}_checksums.txt" 2>/dev/null |
              awk -v f="$tc_ghtar" '$2 == f { print $1; exit }' || true)"
            if [[ -z "$tc_ghwant" ]]; then
              echo "===== gh provisioning aborted (no published SHA-256 for ${tc_ghtar}) — continuing ====="
            elif ! curl -fsSL --max-time 60 -o "$TC_TMP/$tc_ghtar" \
                   "https://github.com/cli/cli/releases/download/v${tc_ghver}/${tc_ghtar}" 2>/dev/null; then
              echo "===== gh provisioning failed (download) — continuing ====="
            else
              tc_ghgot="$(tc_sha256 "$TC_TMP/$tc_ghtar" || true)"
              if [[ -z "$tc_ghgot" ]]; then
                rm -f "$TC_TMP/$tc_ghtar" 2>/dev/null || true
                echo "===== gh provisioning aborted (no sha256sum/shasum to verify with) — continuing ====="
              elif [[ "${tc_ghgot,,}" != "${tc_ghwant,,}" ]]; then
                rm -f "$TC_TMP/$tc_ghtar" 2>/dev/null || true
                echo "===== gh provisioning aborted (SHA-256 mismatch on ${tc_ghtar}) — continuing ====="
              elif tar -xzf "$TC_TMP/$tc_ghtar" -C "$TC_TMP" 2>/dev/null &&
                   cp "$TC_TMP/gh_${tc_ghver}_linux_amd64/bin/gh" "$TC_BIN/gh" 2>/dev/null &&
                   chmod 0755 "$TC_BIN/gh" 2>/dev/null; then
                export PATH="$TC_BIN:$PATH"
                # Same standard as node: only claim success if the binary is really in
                # place, executable, and resolvable on PATH.
                if [[ -x "$TC_BIN/gh" ]] && tc_have gh; then
                  echo "===== gh ${tc_ghver} installed (SHA-256 verified) — run 'gh auth login' to authenticate ====="
                else
                  echo "===== gh provisioning failed (no executable gh at $TC_BIN/gh) — continuing ====="
                fi
              else
                echo "===== gh provisioning failed (extract) — continuing ====="
              fi
            fi
          fi
        fi

        if ! tc_have github-mcp-server; then
          # Binary only — the token itself is resolved at server-launch time by
          # scripts/github-mcp-server.sh, never provisioned or stored by this hook.
          echo "===== github-mcp-server missing — provisioning it into $TC_BIN ====="
          tc_mcpver="$(curl -fsSL --max-time 10 https://api.github.com/repos/github/github-mcp-server/releases/latest 2>/dev/null |
            grep -o '"tag_name": *"v[0-9][0-9.]*"' | head -1 | cut -d'"' -f4 || true)"
          tc_mcpver="${tc_mcpver#v}"
          if [[ -z "$tc_mcpver" ]]; then
            echo "===== github-mcp-server provisioning failed (could not resolve latest release) — continuing ====="
          else
            tc_mcptar="github-mcp-server_Linux_x86_64.tar.gz"
            # Same fail-closed contract as node/gh above; the release's checksums.txt
            # lists every asset, so anchor on the exact filename rather than
            # substring-matching.
            tc_mcpwant="$(curl -fsSL --max-time 10 \
              "https://github.com/github/github-mcp-server/releases/download/v${tc_mcpver}/github-mcp-server_${tc_mcpver}_checksums.txt" 2>/dev/null |
              awk -v f="$tc_mcptar" '$2 == f { print $1; exit }' || true)"
            if [[ -z "$tc_mcpwant" ]]; then
              echo "===== github-mcp-server provisioning aborted (no published SHA-256 for ${tc_mcptar}) — continuing ====="
            elif ! curl -fsSL --max-time 60 -o "$TC_TMP/$tc_mcptar" \
                   "https://github.com/github/github-mcp-server/releases/download/v${tc_mcpver}/${tc_mcptar}" 2>/dev/null; then
              echo "===== github-mcp-server provisioning failed (download) — continuing ====="
            else
              tc_mcpgot="$(tc_sha256 "$TC_TMP/$tc_mcptar" || true)"
              if [[ -z "$tc_mcpgot" ]]; then
                rm -f "$TC_TMP/$tc_mcptar" 2>/dev/null || true
                echo "===== github-mcp-server provisioning aborted (no sha256sum/shasum to verify with) — continuing ====="
              elif [[ "${tc_mcpgot,,}" != "${tc_mcpwant,,}" ]]; then
                rm -f "$TC_TMP/$tc_mcptar" 2>/dev/null || true
                echo "===== github-mcp-server provisioning aborted (SHA-256 mismatch on ${tc_mcptar}) — continuing ====="
              elif tar -xzf "$TC_TMP/$tc_mcptar" -C "$TC_TMP" 2>/dev/null &&
                   cp "$TC_TMP/github-mcp-server" "$TC_BIN/github-mcp-server" 2>/dev/null &&
                   chmod 0755 "$TC_BIN/github-mcp-server" 2>/dev/null; then
                export PATH="$TC_BIN:$PATH"
                # Same standard as node/gh: only claim success if the binary is really
                # in place, executable, and resolvable on PATH.
                if [[ -x "$TC_BIN/github-mcp-server" ]] && tc_have github-mcp-server; then
                  echo "===== github-mcp-server ${tc_mcpver} installed (SHA-256 verified) ====="
                else
                  echo "===== github-mcp-server provisioning failed (no executable github-mcp-server at $TC_BIN/github-mcp-server) — continuing ====="
                fi
              else
                echo "===== github-mcp-server provisioning failed (extract) — continuing ====="
              fi
            fi
          fi
        fi

        rm -rf "$TC_TMP" 2>/dev/null || true
      fi
    fi
  fi
fi

# Install dependencies if node_modules is missing (fresh clone / web session)
if [[ ! -d "$ROOT/node_modules" ]]; then
  # npm may not be on PATH in a non-interactive shell (e.g. nvm-managed node on
  # WSL2) — source nvm if available, then fall back gracefully instead of
  # letting `set -e` kill the whole hook on a bare exit-127 `npm` call.
  if ! command -v npm >/dev/null 2>&1 && [[ -s "${NVM_DIR:-${HOME:-}/.nvm}/nvm.sh" ]]; then
    set +eu
    # shellcheck disable=SC1091
    source "${NVM_DIR:-${HOME:-}/.nvm}/nvm.sh" >/dev/null 2>&1 || true
    set -eu
  fi
  if command -v npm >/dev/null 2>&1; then
    echo "===== Installing npm dependencies ====="
    npm --prefix "$ROOT" install --prefer-offline 2>&1 | tail -5 || true
  else
    echo "===== npm not on PATH — skipping dependency install ====="
  fi
fi

# Everything below this line is the actual context injection — captured into a temp file
# so the self-check at the end can measure its total size before printing it.
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

{
  # ---- a. Condensed banners (full text lives in CLAUDE.md / the dispatch skill) ----
  cat <<'RULE'
===== BACKGROUND AGENT RULE (full text: CLAUDE.md "Subagent Strategy") =====
Every subagent spawn and slow command uses run_in_background:true, then end the turn —
size is not an exception. See tasks/lessons.md, 2026-07-15 for the incident.
RULE

  cat <<'SCOPING'
===== DISPATCH SCOPING (full text: dispatch skill) =====
Don't fold test-authorship into a large dispatch — chain test-writer instead. Split
independent file sets into parallel dispatches rather than one combined prompt.
SCOPING

  # ---- b. Lessons index ----
  # tasks/lessons.md carries a `## Index` section (lines of the form
  # `- [YYYY-MM-DD] rule -> grep "anchor"`) — inject its newest entries verbatim.
  LESSONS="$ROOT/tasks/lessons.md"
  if [[ -s "$LESSONS" ]]; then
    if grep -q '^## Index' "$LESSONS"; then
      printf "===== Lessons index (tasks/lessons.md — ## Index, newest 14 entries) =====\n"
      # Index lines are newest-first; inject only the newest ~14 to stay inside the 8KB
      # total budget (measured: ~240 bytes/index line).
      awk '/^## Index/{f=1;next} f && /^## /{exit} f' "$LESSONS" | grep '^- ' | head -14 || true
      printf "older entries: grep tasks/lessons.md's Index\n\n"
    else
      # A `## Index` is required by .claude/rules/task-files-conventions.md. Only stdout is
      # injected into the session (stderr is never shown), so warn on both and inject
      # nothing from lessons.
      printf '\xE2\x9A\xA0 tasks/lessons.md has no ## Index \xE2\x80\x94 required by .claude/rules/task-files-conventions.md; lessons not injected\n'
      printf 'WARN: tasks/lessons.md has no ## Index \xE2\x80\x94 required by .claude/rules/task-files-conventions.md; lessons not injected\n' >&2
    fi
  fi

  # ---- c. Active sprint (capped injection — first 60 lines, warn if the file is >100) ----
  ACTIVE_SPRINT="$ROOT/tasks/active_sprint.md"
  if [[ -s "$ACTIVE_SPRINT" ]]; then
    as_lines="$(wc -l < "$ACTIVE_SPRINT" | tr -d ' ')"
    printf "===== Active sprint (tasks/active_sprint.md) =====\n"
    if [[ "$as_lines" -gt 100 ]]; then
      printf '\xE2\x9A\xA0 active_sprint.md is %s lines (cap ~100) — trim or rotate per task-files-conventions\n' "$as_lines"
    fi
    if [[ "$as_lines" -gt 60 ]]; then
      head -60 "$ACTIVE_SPRINT"
      printf '[...injection capped at 60 of %s lines — read the file for the rest]\n' "$as_lines"
    else
      cat "$ACTIVE_SPRINT"
    fi
    printf '\n'
  fi

  # ---- d. Unchecked todos only — last 12 `- [ ]` lines, no tail slice ----
  TODO="$ROOT/tasks/todo.md"
  if [[ -s "$TODO" ]]; then
    printf "===== Unchecked todos (tasks/todo.md — last 12 open items; see the file's own ## Index for more) =====\n"
    grep -n '\- \[ \]' "$TODO" | tail -12 || true
    printf '\n'
  fi

  # ---- e. Size-cap warnings (silent when under) ----
  for f in "$ROOT"/.claude/agents/memory/*.md; do
    [[ -f "$f" ]] || continue
    n="$(wc -l < "$f" | tr -d ' ')"
    if [[ "$n" -gt 100 ]]; then
      printf '\xE2\x9A\xA0 %s is %s lines (cap ~100 per spoke)\n' "${f#"$ROOT"/}" "$n"
    fi
  done
  if [[ -f "$TODO" ]]; then
    n="$(wc -l < "$TODO" | tr -d ' ')"
    [[ "$n" -gt 1000 ]] && printf '\xE2\x9A\xA0 tasks/todo.md is %s lines (cap ~1000) — archive completed sections\n' "$n"
  fi
  if [[ -f "$LESSONS" ]]; then
    n="$(wc -l < "$LESSONS" | tr -d ' ')"
    [[ "$n" -gt 400 ]] && printf '\xE2\x9A\xA0 tasks/lessons.md is %s lines (cap ~400) — promote/archive settled entries\n' "$n"
  fi
} > "$OUT"

cat "$OUT"

# ---- f. Final self-check on injected size ----
size="$(stat -c%s "$OUT" 2>/dev/null || wc -c < "$OUT")"
if [[ "$size" -gt 8192 ]]; then
  printf '\xE2\x9A\xA0 SessionStart injection is %s bytes (budget 8KB) — trim the hub index or sprint file.\n' "$size"
fi
