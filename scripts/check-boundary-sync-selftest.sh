#!/usr/bin/env bash
#
# check-boundary-sync-selftest.sh — fixture-based regression tests for
# check-boundary-sync.sh.
#
# Builds throwaway corpus pairs under mktemp and asserts the checker's
# observable contract:
#
#   1. byte-identical pair  → OK, exit 0
#   2. drifted pair         → DRIFT, exit 1
#   3. no markers at all    → friendly message, exit 0
#      (regression: a no-match grep used to abort the script silently with
#       exit 1 under `set -o pipefail`)
#   4. worktree layout (<repo>.wt/<name>): repo detected from the git remote
#      URL, sibling auto-resolved to the paired worktree → OK, exit 0
#      (regression: basename-only detection rejected every worktree checkout)
#   5. unrecognizable repo  → ERROR, exit 2
#
# Usage:
#     ./scripts/check-boundary-sync-selftest.sh
#
# Exit codes: 0 — all cases pass; 1 — at least one case failed.

set -euo pipefail

CHECKER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-boundary-sync.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

FAIL=0

# write_pair <file> <body> — write a single m1-marked sync section.
write_pair() {
  printf '<!-- BOUNDARY-SYNC-START: m1 -->\n%s\n<!-- BOUNDARY-SYNC-END: m1 -->\n' "$2" > "$1"
}

# run_case <name> <want-exit> <want-output-substring> <script-path>
run_case() {
  local name="$1" want_rc="$2" want_out="$3" script="$4"
  local out rc=0
  out="$(bash "${script}" 2>&1)" || rc=$?
  if [ "${rc}" != "${want_rc}" ]; then
    echo "FAIL ${name}: exit ${rc}, want ${want_rc}" >&2
    printf '%s\n' "${out}" >&2
    FAIL=1
  elif ! printf '%s' "${out}" | grep -qF "${want_out}"; then
    echo "FAIL ${name}: output missing '${want_out}'" >&2
    printf '%s\n' "${out}" >&2
    FAIL=1
  else
    echo "ok   ${name}"
  fi
}

# --- fixture: side-by-side canonical checkouts (basename detection) ---------
SIDE="${TMP}/side"
mkdir -p "${SIDE}/donmai-architecture/scripts" "${SIDE}/rensei-architecture"
cp "${CHECKER}" "${SIDE}/donmai-architecture/scripts/"
FIX_CHECKER="${SIDE}/donmai-architecture/scripts/check-boundary-sync.sh"

write_pair "${SIDE}/donmai-architecture/a.md" "shared"
write_pair "${SIDE}/rensei-architecture/b.md" "shared"
run_case "identical pair → OK"      0 "OK  m1"    "${FIX_CHECKER}"

write_pair "${SIDE}/rensei-architecture/b.md" "drifted"
run_case "drifted pair → DRIFT"     1 "DRIFT  m1" "${FIX_CHECKER}"

echo "plain markdown, no markers" > "${SIDE}/donmai-architecture/a.md"
run_case "no markers → exit 0"      0 "no BOUNDARY-SYNC markers found" "${FIX_CHECKER}"

# --- fixture: <repo>.wt/<name> worktrees (remote-URL detection) -------------
WT="${TMP}/wt"
mkdir -p "${WT}/donmai-architecture.wt/lane/scripts" "${WT}/rensei-architecture.wt/lane"
cp "${CHECKER}" "${WT}/donmai-architecture.wt/lane/scripts/"
git -C "${WT}/donmai-architecture.wt/lane" init --quiet
git -C "${WT}/donmai-architecture.wt/lane" remote add origin \
  "git@github.com:RenseiAI/donmai-architecture.git"

write_pair "${WT}/donmai-architecture.wt/lane/a.md" "shared"
write_pair "${WT}/rensei-architecture.wt/lane/b.md" "shared"
run_case "worktree layout → OK"     0 "OK  m1" \
  "${WT}/donmai-architecture.wt/lane/scripts/check-boundary-sync.sh"

# --- fixture: directory the checker cannot identify --------------------------
mkdir -p "${TMP}/foo/scripts"
cp "${CHECKER}" "${TMP}/foo/scripts/"
run_case "unknown repo → exit 2"    2 "must be invoked from inside" \
  "${TMP}/foo/scripts/check-boundary-sync.sh"

if [ "${FAIL}" -ne 0 ]; then
  echo "selftest: FAILED" >&2
  exit 1
fi
echo "selftest: all cases passed"
