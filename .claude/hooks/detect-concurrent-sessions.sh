#!/usr/bin/env bash
# SessionStart hook: detect other live Claude Code sessions in this same folder
# and nudge the agent to isolate its work in a git worktree before editing.
#
# Why it matters here specifically: this repo is 14 flat, mutually-referencing
# workflow files plus 3 composite actions. Two concurrent sessions in one checkout
# race on the working tree and the git index — and the failure modes are worse than
# ordinary overwrites:
#   • both sessions bump the same SHA self-reference pins to different commits
#   • one stages a workflow while the other's .githook/pre-commit (gitleaks) scans a
#     half-staged index
#   • an interleaved edit lands a workflow that passes actionlint but pairs a leaf's
#     new input with the other session's version of the master pipeline
# Catching it at SessionStart lets the agent call EnterWorktree first. A linked
# worktree shares the repo config, so core.hooksPath=.githook keeps working there.
#
# Strategy: per-cwd lock file under ~/.claude/locks/, keyed by hash($PWD).
# Each file holds one PID per line. On every SessionStart we:
#   1. read existing PIDs, keep only those still alive (kill -0)
#   2. if any live one is NOT us, emit an additionalContext warning
#   3. append our $PPID (the Claude Code process) and rewrite the file
# Dead PIDs from crashed sessions are pruned on the next run, so no SessionEnd
# cleanup is required.
#
# Vendored into the repo (rather than referencing ~/.claude/hooks) so it travels
# with the project for every teammate who checks it out. Depends only on python3,
# which the sibling post-workflow-edit.sh hook already requires.

set -uo pipefail

CWD="$PWD"
LOCK_DIR="$HOME/.claude/locks"
mkdir -p "$LOCK_DIR"

# shasum on macOS, sha256sum on most Linux boxes.
if command -v shasum >/dev/null 2>&1; then
  HASH=$(printf '%s' "$CWD" | shasum -a 256 | cut -c1-12)
elif command -v sha256sum >/dev/null 2>&1; then
  HASH=$(printf '%s' "$CWD" | sha256sum | cut -c1-12)
else
  exit 0
fi
LOCK_FILE="$LOCK_DIR/session-${HASH}.lock"

declare -a LIVE_OTHER=()
declare -a KEEP=()

if [[ -f "$LOCK_FILE" ]]; then
  while IFS= read -r pid || [[ -n "$pid" ]]; do
    [[ -z "$pid" ]] && continue
    # Non-numeric lines are corruption from an interleaved write; drop them.
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      KEEP+=("$pid")
      if [[ "$pid" != "$PPID" && "$pid" != "$$" ]]; then
        LIVE_OTHER+=("$pid")
      fi
    fi
  done < "$LOCK_FILE"
fi

# Add our own PPID (the parent of this hook shell — typically the Claude Code process)
KEEP+=("$PPID")

# Rewrite lock file with deduped live PIDs
printf '%s\n' "${KEEP[@]}" | sort -u > "$LOCK_FILE"

if (( ${#LIVE_OTHER[@]} > 0 )); then
  PRETTY_CWD="${CWD/#$HOME/~}"
  COUNT=${#LIVE_OTHER[@]}
  PIDS_STR=$(IFS=,; echo "${LIVE_OTHER[*]}")
  MSG="⚠️ WARNING: We have detected ${COUNT} other active Claude Code session(s) in this folder (${PRETTY_CWD}). Concurrent PIDs: ${PIDS_STR}. In this repo that risks two sessions bumping the same composite-action SHA pins to different commits, gitleaks scanning a half-staged index, or a leaf workflow's new input landing against the other session's master-maven-pipeline.yml. Use the EnterWorktree tool to work in a separate Git worktree before making any changes — the worktree shares this repo's config, so core.hooksPath=.githook still applies there."
  MSG="$MSG" python3 -c "
import json, os
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'SessionStart', 'additionalContext': os.environ['MSG']}}))
"
fi

exit 0
