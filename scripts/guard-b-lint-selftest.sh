#!/usr/bin/env bash
# guard-b-lint-selftest.sh — prove guard-b actually fires.
#
# A leak guard that has never been shown to fail is not evidence of anything.
# This runs guard-b-lint.sh against synthetic files: every BAD sample must be
# flagged, every GOOD sample must pass. Each BAD sample carries the rule it is
# meant to trip, and the test asserts that rule is the one named in the output —
# so a rule cannot silently stop working while a neighbouring rule keeps the
# suite green.
#
# Usage: scripts/guard-b-lint-selftest.sh
# Exit 0 = all samples behaved; exit 1 = at least one rule is not working.

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO_ROOT/scripts/guard-b-lint.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# run_guard <file> — run guard-b from the repo root against one file.
run_guard() {
  (cd "$REPO_ROOT" && "$GUARD" "$1" 2>&1)
}

# expect_flagged <RULE_ID> <sample-text>
expect_flagged() {
  local want_rule="$1" sample="$2" f out
  f="$TMP/bad-$PASS-$FAIL-$RANDOM.txt"
  printf '%s\n' "$sample" > "$f"
  if out="$(run_guard "$f")"; then
    echo "self-test FAIL: not flagged at all [$want_rule]: $sample" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  if ! printf '%s\n' "$out" | grep -q "rule: $want_rule "; then
    echo "self-test FAIL: flagged, but not by $want_rule: $sample" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    FAIL=$((FAIL + 1))
    return
  fi
  PASS=$((PASS + 1))
}

# expect_clean <sample-text>
expect_clean() {
  local sample="$1" f out
  f="$TMP/good-$PASS-$FAIL-$RANDOM.txt"
  printf '%s\n' "$sample" > "$f"
  if out="$(run_guard "$f")"; then
    PASS=$((PASS + 1))
  else
    echo "self-test FAIL: false positive: $sample" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    FAIL=$((FAIL + 1))
  fi
}

# ---- BAD: every rule must fire ----------------------------------------------
expect_flagged BRAND_NAME       'built by the Rensei team'
expect_flagged CLOSED_TUI_REPO  'see rensei-tui for the composed binary'
expect_flagged CLOSED_PLATFORM  'the rensei-platform owns dispatch'
expect_flagged PARENT_DOMAIN    'POST https://app.rensei.ai/api/workers'
expect_flagged PLATFORM_PATH    'writer lives in platform/src/lib/dispatch.ts'
expect_flagged DEV_ABS_PATH     'cloned at /Users/someone/Developer/org/repo'
expect_flagged CLOSED_ENV_VAR   'export RENSEI_DAEMON_JWT=secret'

# ---- BAD: every tracker prefix the org issues, upper and lower case ----------
# The pre-2026-08-07 rule was 'REN-[0-9]+' and let all of these through.
expect_flagged TRACKER_ID 'fixes REN-1234 regression'
expect_flagged TRACKER_ID 'ported from REN2-17'
expect_flagged TRACKER_ID 'see SUP-1840 for the credential surface'
expect_flagged TRACKER_ID 'raised as MAR-42'
expect_flagged TRACKER_ID 'ops escalation RENOPS-38'
expect_flagged TRACKER_ID_SLUG 'branch agent/ren-2034 carries the fix'
expect_flagged TRACKER_ID_SLUG 'worktree sup-1840-cred-surface'
expect_flagged TRACKER_ID_SLUG 'directory ren2-110-node-matrix'
expect_flagged TRACKER_ID_SLUG 'taskListId renops-38-ops'

# ---- BAD: tracker deep links, any workspace or team key ---------------------
expect_flagged TRACKER_URL 'tracked at https://linear.app/acme-workspace/issue/ABC-9/some-slug'
expect_flagged TRACKER_URL 'board https://linear.app/acme-workspace/team/ABC/active'

# ---- GOOD: must not fire ----------------------------------------------------
expect_clean 'fixes the ENG-1234 fixture'
expect_clean 'CVE-2026-1234 hardening, RFC-7519 tokens, SHA-256 digests'
expect_clean 'the ADR-2026-06-07 ruling and ISO-8601 timestamps'
expect_clean 'import "github.com/RenseiAI/donmai/agent"'
expect_clean 'consumed by github.com/RenseiAI/tui-components'
expect_clean 'export DONMAI_DAEMON_JWT=secret'
expect_clean 'docs at donmai-architecture/002-provider-base-contract.md'
expect_clean 'cross-ref: rensei-architecture/004-platform-extensions.md'
expect_clean 'the GraphQL endpoint is api.linear.app/graphql'
expect_clean 'planning window Mar-2026, review on mar-15'
expect_clean 'renders a summary; supports up to 40 rows'

# ---- Report -----------------------------------------------------------------
echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "guard-b self-test: OK — $PASS/$PASS samples behaved as specified."
  exit 0
fi
echo "guard-b self-test: FAILED — $FAIL failing, $PASS passing." >&2
exit 1
