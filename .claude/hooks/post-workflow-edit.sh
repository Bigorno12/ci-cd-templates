#!/usr/bin/env bash
# PostToolUse hook: runs after editing a workflow or composite action under .github/.
#   1. Stale-pin guard: editing .github/actions/* changes nothing until the
#      SHA-pinned self-references in .github/workflows/ are bumped
#   2. Local-action guard: `uses: ./.github/actions/...` inside a reusable workflow
#      resolves against the CONSUMER's checkout, not this repo
#   3. Pin guard: every third-party `uses:` must be a full 40-hex commit SHA
#   4. Control coverage: harden-runner / timeout-minutes / permissions per runner job,
#      and persist-credentials on every checkout
#   5. Surfaces actionlint + yamllint findings for the edited file, when installed
#
# NOTE: this hook is strictly read-only. Nothing here rewrites the file — reformatting
# right after an edit invalidates Claude's read cache (the file changes on disk behind
# the agent's back). zizmor stays a manual/CI step: it is slower, needs network for its
# online audits, and is not installed locally.

set -uo pipefail

INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" 2>/dev/null || true)

[[ -n "$FILE" && -f "$FILE" ]] || exit 0

# Only .github YAML: reusable workflows and composite actions. Everything else in this
# repo (docs, .githook shell, .claude config) is out of scope.
printf '%s' "$FILE" | grep -qE '/\.github/(workflows/[^/]+\.ya?ml|actions/[^/]+/action\.ya?ml)$' || exit 0

REPO_ROOT=$(git -C "$(dirname "$FILE")" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")
REL="${FILE#"$REPO_ROOT"/}"
IS_ACTION=0
printf '%s' "$REL" | grep -q '^\.github/actions/' && IS_ACTION=1

NOTES=()

# ── 1. Composite action edited → the pins still point at the old commit ───────
if (( IS_ACTION )); then
    ACTION=$(basename "$(dirname "$FILE")")
    SITES=$(grep -rlE "ci-cd-templates/\.github/actions/${ACTION}@" "$REPO_ROOT/.github/workflows" 2>/dev/null | wc -l | tr -d ' ')
    PINS=$(grep -rhoE "ci-cd-templates/\.github/actions/${ACTION}@[0-9a-f]{7,40}" "$REPO_ROOT/.github/workflows" 2>/dev/null | sed 's/.*@//' | sort -u | tr '\n' ' ')
    if [[ -n "${SITES:-}" && "$SITES" != "0" ]]; then
        NOTES+=("Edited the '$ACTION' composite action. It is consumed by SHA-pinned self-reference, so this change is INERT until the pins move: $SITES workflow file(s) still pin ${PINS:-<unknown>}. Merge the action change first, then a second commit bumping every pin. Find them with: grep -rn \"ci-cd-templates/.github/actions/${ACTION}@\" .github/")
    fi
fi

# ── 2. A local action ref inside a reusable workflow silently breaks consumers ─
LOCAL_ACTION=$(grep -nE 'uses:[[:space:]]*\./\.github/actions/' "$FILE" 2>/dev/null || true)
if [[ -n "$LOCAL_ACTION" ]]; then
    NOTES+=("Local composite-action ref in $REL:
$LOCAL_ACTION
Inside a reusable workflow, a relative action path resolves against the checked-out workspace — the CONSUMER's repo — not this one, so it fails for every caller. Use the absolute pinned form: Bigorno12/ci-cd-templates/.github/actions/<name>@<sha>. ('uses: ./' is correct only for workflow_call refs between workflows.)")
fi

# ── 3. Unpinned uses: ─────────────────────────────────────────────────────────
UNPINNED=$(grep -nE '^[[:space:]]*-?[[:space:]]*uses:' "$FILE" 2>/dev/null \
    | grep -vE 'uses:[[:space:]]*\./' \
    | grep -vE '@[0-9a-f]{40}[[:space:]]*(#.*)?$' \
    || true)
if [[ -n "$UNPINNED" ]]; then
    NOTES+=("Unpinned action reference(s) in $REL — every third-party 'uses:' must be a full 40-character commit SHA (zizmor fails the build on tags/branches):
$UNPINNED")
fi

# ── 4. Control coverage (workflows with real runner jobs only) ────────────────
if (( ! IS_ACTION )); then
    JOBS=$(grep -cE '^[[:space:]]+runs-on:' "$FILE" 2>/dev/null || true)
    JOBS=${JOBS:-0}
    if (( JOBS > 0 )); then
        HR=$(grep -c 'step-security/harden-runner' "$FILE" 2>/dev/null || true)
        TO=$(grep -cE '^[[:space:]]+timeout-minutes:' "$FILE" 2>/dev/null || true)
        PERM=$(grep -cE '^[[:space:]]*permissions:' "$FILE" 2>/dev/null || true)
        CO=$(grep -c 'actions/checkout@' "$FILE" 2>/dev/null || true)
        PC=$(grep -cE '^[[:space:]]+persist-credentials:' "$FILE" 2>/dev/null || true)

        (( ${HR:-0} < JOBS ))   && NOTES+=("$REL has $JOBS runner job(s) but ${HR:-0} harden-runner step(s). Every job starts with step-security/harden-runner (disable-sudo: true) plus an allowed-endpoints list when the policy is block.")
        (( ${TO:-0} < JOBS ))   && NOTES+=("$REL has $JOBS runner job(s) but ${TO:-0} timeout-minutes. Every job carries one (5 for gates/tagging, 10-15 for builds, 30 for CodeQL).")
        (( ${PERM:-0} < JOBS )) && NOTES+=("$REL has $JOBS runner job(s) but ${PERM:-0} permissions block(s). Declare least-privilege permissions per job — an unset permission defaults to none, and permissions intersect with the caller's.")
        (( ${CO:-0} > 0 && ${PC:-0} < ${CO:-0} )) && NOTES+=("$REL has ${CO:-0} checkout step(s) but ${PC:-0} persist-credentials setting(s). Use persist-credentials: false unless the job genuinely pushes (only tag.yml and deploy-gitops.yml do).")
    fi
fi

# ── 5. Linters, if installed (read-only; both are optional) ───────────────────
if (( ! IS_ACTION )) && command -v actionlint >/dev/null 2>&1; then
    AL=$(cd "$REPO_ROOT" && actionlint -no-color "$REL" 2>&1 || true)
    [[ -n "$AL" ]] && NOTES+=("actionlint on $REL:
$AL")
fi

if command -v yamllint >/dev/null 2>&1; then
    YL_ARGS=()
    [[ -f "$REPO_ROOT/.yamllint.yml" ]] && YL_ARGS=(-c "$REPO_ROOT/.yamllint.yml")
    YL=$(yamllint --strict "${YL_ARGS[@]+${YL_ARGS[@]}}" "$FILE" 2>&1 || true)
    [[ -n "$YL" ]] && NOTES+=("yamllint on $REL:
$YL")
fi

(( ${#NOTES[@]} == 0 )) && exit 0

MSG=$(printf '%s\n\n' "${NOTES[@]}")
MSG="$MSG" python3 -c "
import json, os
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PostToolUse', 'additionalContext': os.environ['MSG'].strip()}}))
"
exit 0
