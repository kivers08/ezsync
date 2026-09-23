#!/usr/bin/env bash
# Shared quote-aware compound-command splitter for PreToolUse Bash guards.
#
# Splitting a shell command on bare `&`, `|`, `;` characters (e.g. `tr '&|;' '\n'`)
# is not quote-aware: a separator character that appears *inside* single or double
# quotes (e.g. the `;` in `awk -F, '{print $1; print $2}' data.csv`) still gets
# split on, breaking one logical command into two segments. A guard that requires
# two conjuncts (e.g. "leading word is awk" AND "references a .csv path") to both
# appear in the *same* segment then silently fails open, because each half ends up
# in a different segment. Recorded as a real bypass in PR #664 (Copilot review).
#
# The same naive split also produces false positives in the other direction: a
# separator character inside a quoted string (e.g. the `|` in
# `echo "foo | git push origin main:test"`) still gets split on, fabricating a
# `git push ...` segment out of a string that never actually invokes git. Quote
# awareness fixes both directions at once.
#
# split_segments <command-string> prints one segment per NUL-terminated record,
# splitting only on unquoted &, |, ; characters. Callers MUST consume the output
# with a NUL-delimited read, e.g.:
#   while IFS= read -r -d '' seg; do ... done < <(split_segments "$command")
# NOT `segments="$(split_segments ...)"` followed by `while read <<< "$segments"` —
# a segment can legitimately contain an embedded newline (e.g. a heredoc body, or a
# `-m "line one\nline two"` commit message), and newline-delimited output collides
# with that, silently fragmenting one atomic segment into multiple fake ones on
# `read`'s side. That fragmentation was a real bypass: a heredoc body line
# containing `git push origin main:test` was denied even though the actual command
# was just `cat <<'EOF' ... EOF`, which never invokes git. Recorded in PR #664
# (Copilot review, round 3).
#
# Additional refinements, all PR #664 Copilot review follow-ups:
#   - A backslash inside a double-quoted string is consumed together with the
#     character it escapes, so `echo "a\";b"` doesn't treat the escaped `"` as
#     closing the string and then split on the `;` that's still logically inside it.
#     (Single-quoted strings don't support backslash escaping, so this only applies
#     while `quote` is `"`.)
#   - A backslash *outside* any quotes is likewise consumed together with the next
#     character, so an escaped separator (`foo\; git push origin main:test`) is
#     never split on — the `\;` is one literal argument character to the shell, not
#     a command separator.
#   - An unquoted `&` immediately preceded by `>` or `<` (i.e. part of a `>&`/`<&`
#     redirection operator, as in `2>&1`) is treated as a literal part of that
#     operator rather than a command separator — otherwise `npm test 2>&1` splits
#     into `npm test 2>` (which reads as an unscoped, deniable `npm test`) and `1`.
#     A bare background `&` (preceded by a command/argument, not a redirection
#     target) is unaffected and still splits, since it's never preceded by `>`/`<`.
#
# DELIBERATE, FROZEN GAP — a literal newline is NEVER treated as a command separator,
# even though bash itself does treat an unquoted newline as one. This is intentional,
# not an oversight, and the scope has been explicitly frozen here rather than chasing
# it (PR #664 round 4, Copilot review):
#   - The round-3 fix moved split_segments to NUL-delimited output specifically so a
#     segment could contain an embedded newline (a heredoc body, or a multi-line `-m`
#     commit message) without that newline being misread as a record separator by
#     the caller's `read` loop — see the NUL-delimited-record note above. Making an
#     unquoted, syntactic newline split again would require telling that syntactic
#     case apart from a newline sitting inside a quoted string or heredoc body, which
#     is real shell parsing (tracking heredoc-body state across the whole command),
#     not a local per-character rule.
#   - The practical consequence: a command string containing a real, literal newline
#     byte between two logical lines (e.g. `echo ready` then, on the next line,
#     `git push origin main:test`) is NOT split at that newline, so the second
#     line's `git push` is never inspected as its own segment. This is a known,
#     accepted false negative — see
#     tests/gitRefspecGuard.test.js's "documented gap" case, which pins today's
#     allow behavior deliberately so a future change to it is a conscious decision.
#   - The false negative was judged the lesser cost versus the false positive it
#     replaces: a guard denying real heredoc/multi-line-message content (blocking
#     legitimate work) is worse than a guard that fails to catch a determined bypass
#     via a raw newline — these hooks were never a security boundary against an
#     adversarial caller, only a mechanical nudge against the accidental cases the
#     lessons they encode were actually about.
#   - Other constructs this splitter does NOT understand, for the same reason (they
#     all require real shell-grammar awareness, not just quote/escape tracking):
#     `$(...)`/backtick command substitution, process substitution (`>(...)`/`<(...)`),
#     `$'...'` ANSI-C quoting, nested or multiple heredocs, `<<<` herestrings,
#     fd-numbered redirections (`3<&0`), `#` comments, and `&&`/`||` precedence mixed
#     with pipes. None of these are believed to be exploitable beyond the same
#     "misses a guardrail" false-negative class already accepted above; if a false
#     *positive* turns up in one of them, that's a new bug to reproduce and fix, same
#     as every prior round.
#   - Two of those — an unquoted `#` comment (`npx vitest # run the suite`) and process
#     substitution (`npx vitest > >(tee out.log)`) — were surfaced concretely by Copilot
#     on PR #690 and were consciously DECLINED by the owner, who chose to keep this
#     splitter's frozen scope rather than grow it into a shell parser. They are KNOWN,
#     ACCEPTED false negatives, pinned as allow-with-a-comment cases in
#     tests/vitestSuiteGuard.test.ts (the same treatment the newline gap gets in
#     tests/gitRefspecGuard.test.js) so a future change to either is a conscious
#     decision rather than a rediscovery.
#
# NOT a frozen gap — redirection IS handled downstream. This splitter keeps `2>&1` as a
# single token (the `&`-after-`>` rule above), and vitest-suite-guard.sh's positional-path
# scan now recognises redirection tokens explicitly: a bare operator consumes the
# following filename token, and for an unquoted token containing `<`/`>` only the portion
# before the first redirect character is evaluated as an argv word. That gap was a real
# bypass on 2026-09-02 — the `2>` token in `npx vitest ... 2>&1 | grep foo` was counted as
# a positional test path, so the whole suite ran unguarded. See
# .claude/hooks/vitest-suite-guard.sh's header for the full note.
#
# As above: these hooks are NOT a security boundary against an adversarial caller, only
# a mechanical nudge against the accidental cases the lessons they encode were about.
split_segments() {
  local s="$1"
  local -a out=()
  local cur=""
  local quote=""
  local i c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    if [[ -n "$quote" ]]; then
      if [[ "$quote" == '"' && "$c" == '\' && $((i + 1)) -lt ${#s} ]]; then
        cur+="$c"
        i=$((i + 1))
        cur+="${s:i:1}"
        continue
      fi
      cur+="$c"
      [[ "$c" == "$quote" ]] && quote=""
      continue
    fi
    if [[ "$c" == '\' && $((i + 1)) -lt ${#s} ]]; then
      cur+="$c"
      i=$((i + 1))
      cur+="${s:i:1}"
      continue
    fi
    case "$c" in
      "'" | '"')
        quote="$c"
        cur+="$c"
        ;;
      '&')
        if [[ "${cur: -1}" == '>' || "${cur: -1}" == '<' ]]; then
          cur+="$c"
        else
          out+=("$cur")
          cur=""
        fi
        ;;
      '|' | ';')
        out+=("$cur")
        cur=""
        ;;
      *)
        cur+="$c"
        ;;
    esac
  done
  out+=("$cur")
  printf '%s\0' "${out[@]}"
}
