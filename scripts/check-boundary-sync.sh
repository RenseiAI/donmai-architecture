#!/usr/bin/env bash
#
# check-boundary-sync.sh — verify BOUNDARY-SYNC marker pairs are byte-identical
# between this repo and its sibling architecture corpus.
#
# Markers use the paired form documented in BOUNDARY.md § "BOUNDARY-SYNC inline
# marker syntax":
#
#     <!-- BOUNDARY-SYNC-START: <id> -->
#     ... mirrored content ...
#     <!-- BOUNDARY-SYNC-END: <id> -->
#
# Usage:
#     ./scripts/check-boundary-sync.sh                # check all sync pairs
#     ./scripts/check-boundary-sync.sh <marker-id>    # check one specific pair
#
# Exit codes:
#     0 — all pairs match
#     1 — at least one pair drifts (diff printed to stderr)
#     2 — configuration error: marker missing in sibling repo, unbalanced pair,
#         or sibling repo not found
#
# Environment:
#     RENSEI_ARCH_PATH   override path to sibling rensei-architecture repo;
#                        defaults to ../rensei-architecture relative to this repo
#
# Layout assumption: this script ships byte-identical in both
# agentfactory-architecture and rensei-architecture (paired-commit discipline
# per BOUNDARY.md). When invoked from rensei-architecture, the "sibling" is
# agentfactory-architecture and the script auto-detects which repo it's in
# via the .git/config remote URL.

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve this repo's root and the sibling repo's root.
# ---------------------------------------------------------------------------

THIS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THIS_REPO_NAME="$(basename "${THIS_REPO_ROOT}")"

case "${THIS_REPO_NAME}" in
  agentfactory-architecture)
    SIBLING_DEFAULT="${THIS_REPO_ROOT}/../rensei-architecture"
    SIBLING_NAME="rensei-architecture"
    ;;
  rensei-architecture)
    SIBLING_DEFAULT="${THIS_REPO_ROOT}/../agentfactory-architecture"
    SIBLING_NAME="agentfactory-architecture"
    ;;
  *)
    echo "ERROR: this script must be invoked from inside agentfactory-architecture or rensei-architecture (got: ${THIS_REPO_NAME})" >&2
    exit 2
    ;;
esac

SIBLING_REPO_ROOT="${RENSEI_ARCH_PATH:-${SIBLING_DEFAULT}}"

if [ ! -d "${SIBLING_REPO_ROOT}" ]; then
  echo "ERROR: sibling repo not found at ${SIBLING_REPO_ROOT}" >&2
  echo "       set RENSEI_ARCH_PATH to override the default ../${SIBLING_NAME} layout" >&2
  exit 2
fi

SIBLING_REPO_ROOT="$(cd "${SIBLING_REPO_ROOT}" && pwd)"

# ---------------------------------------------------------------------------
# Marker discovery + extraction helpers.
# ---------------------------------------------------------------------------

# enumerate_markers <repo-root>
# Prints "<marker-id>\t<file-path-relative-to-repo>" lines for every
# BOUNDARY-SYNC-START marker found under <repo-root>/*.md.
enumerate_markers() {
  local repo_root="$1"
  # shellcheck disable=SC2016
  grep -RHnE '<!-- BOUNDARY-SYNC-START: [a-zA-Z0-9_-]+ -->' "${repo_root}" \
    --include='*.md' 2>/dev/null \
    | sed -E 's|^([^:]+):[0-9]+:.*BOUNDARY-SYNC-START: ([a-zA-Z0-9_-]+).*|\2'$'\t''\1|' \
    | while IFS=$'\t' read -r marker_id file_path; do
        # rewrite absolute path → repo-relative
        rel="${file_path#${repo_root}/}"
        printf '%s\t%s\n' "${marker_id}" "${rel}"
      done \
    | sort
}

# extract_section <file-path> <marker-id>
# Prints the text BETWEEN the START and END markers (not inclusive of marker
# lines themselves). Output is byte-identical for byte-identical mirrored
# regions.
extract_section() {
  local file="$1"
  local marker_id="$2"
  awk -v id="${marker_id}" '
    BEGIN { inside = 0 }
    $0 ~ ("<!-- BOUNDARY-SYNC-START: " id " -->") { inside = 1; next }
    $0 ~ ("<!-- BOUNDARY-SYNC-END: " id " -->")   { inside = 0; next }
    inside { print }
  ' "${file}"
}

# verify_pair_balance <file-path> <marker-id>
# Returns 0 if the file has exactly one START and one END for the marker,
# and the END follows the START. Returns 2 otherwise.
verify_pair_balance() {
  local file="$1"
  local marker_id="$2"
  local starts ends
  starts=$(grep -cE "<!-- BOUNDARY-SYNC-START: ${marker_id} -->" "${file}" || true)
  ends=$(grep -cE "<!-- BOUNDARY-SYNC-END: ${marker_id} -->" "${file}" || true)
  if [ "${starts}" != "1" ] || [ "${ends}" != "1" ]; then
    echo "ERROR: marker '${marker_id}' in ${file} has ${starts} START and ${ends} END (expected 1 each)" >&2
    return 2
  fi
  # Order check: START line number must be < END line number.
  local start_line end_line
  start_line=$(grep -nE "<!-- BOUNDARY-SYNC-START: ${marker_id} -->" "${file}" | head -n1 | cut -d: -f1)
  end_line=$(grep -nE "<!-- BOUNDARY-SYNC-END: ${marker_id} -->" "${file}" | head -n1 | cut -d: -f1)
  if [ "${start_line}" -ge "${end_line}" ]; then
    echo "ERROR: marker '${marker_id}' in ${file}: END (line ${end_line}) appears before START (line ${start_line})" >&2
    return 2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Pair lookup: given a marker id, find the file in this repo + the file in
# the sibling repo that carry the marker pair.
# ---------------------------------------------------------------------------

find_marker_file() {
  local repo_root="$1"
  local marker_id="$2"
  enumerate_markers "${repo_root}" \
    | awk -F'\t' -v id="${marker_id}" '$1 == id { print $2; exit }'
}

# ---------------------------------------------------------------------------
# Main check loop.
# ---------------------------------------------------------------------------

check_one_pair() {
  local marker_id="$1"

  local this_file sibling_file
  this_file="$(find_marker_file "${THIS_REPO_ROOT}" "${marker_id}")"
  sibling_file="$(find_marker_file "${SIBLING_REPO_ROOT}" "${marker_id}")"

  if [ -z "${this_file}" ]; then
    echo "ERROR: marker '${marker_id}' not found in ${THIS_REPO_NAME}" >&2
    return 2
  fi
  if [ -z "${sibling_file}" ]; then
    echo "ERROR: marker '${marker_id}' not found in sibling ${SIBLING_NAME}" >&2
    return 2
  fi

  local this_abs sibling_abs
  this_abs="${THIS_REPO_ROOT}/${this_file}"
  sibling_abs="${SIBLING_REPO_ROOT}/${sibling_file}"

  verify_pair_balance "${this_abs}" "${marker_id}" || return 2
  verify_pair_balance "${sibling_abs}" "${marker_id}" || return 2

  local this_section sibling_section
  this_section="$(extract_section "${this_abs}" "${marker_id}")"
  sibling_section="$(extract_section "${sibling_abs}" "${marker_id}")"

  if [ "${this_section}" = "${sibling_section}" ]; then
    echo "OK  ${marker_id}  (${this_file}  <->  ${SIBLING_NAME}/${sibling_file})"
    return 0
  fi

  echo "DRIFT  ${marker_id}  (${this_file}  <->  ${SIBLING_NAME}/${sibling_file})" >&2
  diff <(printf '%s\n' "${this_section}") <(printf '%s\n' "${sibling_section}") >&2 || true
  return 1
}

main() {
  local target_id="${1:-}"

  if [ -n "${target_id}" ]; then
    check_one_pair "${target_id}"
    return $?
  fi

  # No argument: enumerate every marker in this repo, check the pair.
  local all_ids
  all_ids="$(enumerate_markers "${THIS_REPO_ROOT}" | cut -f1 | sort -u)"

  if [ -z "${all_ids}" ]; then
    echo "no BOUNDARY-SYNC markers found in ${THIS_REPO_NAME}; nothing to check"
    return 0
  fi

  local rc=0 pair_rc
  while IFS= read -r marker_id; do
    [ -z "${marker_id}" ] && continue
    pair_rc=0
    check_one_pair "${marker_id}" || pair_rc=$?
    if [ "${pair_rc}" -ne 0 ]; then
      # configuration errors (rc=2) win over drift (rc=1)
      if [ "${pair_rc}" -gt "${rc}" ]; then
        rc="${pair_rc}"
      fi
    fi
  done <<< "${all_ids}"

  return ${rc}
}

main "$@"
