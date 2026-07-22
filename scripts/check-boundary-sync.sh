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
#     2 — configuration error: marker missing in sibling repo, unbalanced or
#         duplicate marker id, sibling repo not found, or helper unavailable
#
# Environment:
#     DONMAI_ARCH_PATH   override path to the sibling corpus repo; defaults to
#                        the first existing of ../<sibling>,
#                        ../../<sibling>.wt/<this-worktree-name>, and
#                        ../../<sibling> — covering side-by-side canonical
#                        checkouts and the <repo>.wt/<name> worktree layout.
#
# Layout assumption: this script ships byte-identical in both
# donmai-architecture and rensei-architecture (paired-commit discipline
# per BOUNDARY.md). When invoked from rensei-architecture, the "sibling" is
# donmai-architecture and the script auto-detects which repo it's in
# via the .git/config remote URL (falling back to the directory basename
# for non-git copies, e.g. the CI checkout).

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve this repo's root and the sibling repo's root.
# ---------------------------------------------------------------------------

THIS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Which corpus is this? Prefer the git remote URL — it is stable across
# worktrees, whatever the checkout directory is named — and fall back to the
# directory basename.
detect_repo_name() {
  local url
  url="$(git -C "${THIS_REPO_ROOT}" config --get remote.origin.url 2>/dev/null || true)"
  case "${url}" in
    *donmai-architecture*) echo "donmai-architecture" ;;
    *rensei-architecture*) echo "rensei-architecture" ;;
    *) basename "${THIS_REPO_ROOT}" ;;
  esac
}
THIS_REPO_NAME="$(detect_repo_name)"

case "${THIS_REPO_NAME}" in
  donmai-architecture)
    SIBLING_NAME="rensei-architecture"
    ;;
  rensei-architecture)
    SIBLING_NAME="donmai-architecture"
    ;;
  *)
    echo "ERROR: this script must be invoked from inside donmai-architecture or rensei-architecture (got: ${THIS_REPO_NAME})" >&2
    exit 2
    ;;
esac

# Default sibling location, first match wins:
#   1. ../<sibling>                       — side-by-side canonical checkouts
#   2. ../../<sibling>.wt/<worktree-name> — the paired worktree under the
#                                           <repo>.wt/<name> convention
#   3. ../../<sibling>                    — canonical, from inside a worktree
SIBLING_DEFAULT=""
for candidate in \
  "${THIS_REPO_ROOT}/../${SIBLING_NAME}" \
  "${THIS_REPO_ROOT}/../../${SIBLING_NAME}.wt/$(basename "${THIS_REPO_ROOT}")" \
  "${THIS_REPO_ROOT}/../../${SIBLING_NAME}"; do
  if [ -d "${candidate}" ]; then
    SIBLING_DEFAULT="${candidate}"
    break
  fi
done

SIBLING_REPO_ROOT="${DONMAI_ARCH_PATH:-${SIBLING_DEFAULT}}"

if [ -z "${SIBLING_REPO_ROOT}" ] || [ ! -d "${SIBLING_REPO_ROOT}" ]; then
  echo "ERROR: sibling ${SIBLING_NAME} repo not found" >&2
  echo "       tried ../${SIBLING_NAME}, ../../${SIBLING_NAME}.wt/$(basename "${THIS_REPO_ROOT}"), ../../${SIBLING_NAME}" >&2
  echo "       set DONMAI_ARCH_PATH to point at its checkout" >&2
  exit 2
fi

SIBLING_REPO_ROOT="$(cd "${SIBLING_REPO_ROOT}" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required for byte-exact BOUNDARY-SYNC checking" >&2
  exit 2
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT
THIS_INVENTORY="${TMP_ROOT}/this-markers.tsv"
SIBLING_INVENTORY="${TMP_ROOT}/sibling-markers.tsv"

# ---------------------------------------------------------------------------
# Marker discovery + extraction helpers.
# ---------------------------------------------------------------------------

# enumerate_markers <repo-root>
# Prints "<marker-id>\t<START|END>\t<relative-file>\t<line>" for every marker
# under <repo-root>/*.md. Discovering both kinds makes orphan END markers and
# marker pairs present only in the sibling visible to the all-pairs union.
enumerate_markers() {
  local repo_root="$1"
  python3 - "${repo_root}" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
pattern = re.compile(rb"<!-- BOUNDARY-SYNC-(START|END): ([a-zA-Z0-9_-]+) -->")
records = []
for path in sorted(root.rglob("*.md")):
    data = path.read_bytes()
    relative = path.relative_to(root).as_posix()
    for line_number, line in enumerate(data.splitlines(keepends=True), 1):
        for match in pattern.finditer(line):
            records.append(
                (
                    match.group(2).decode("ascii"),
                    match.group(1).decode("ascii"),
                    relative,
                    line_number,
                )
            )
for marker_id, kind, relative, line_number in sorted(records):
    print(f"{marker_id}\t{kind}\t{relative}\t{line_number}")
PY
}

# resolve_marker_file <inventory> <corpus-name> <marker-id>
# Prints the unique file carrying one ordered START/END pair. Returns 2 for an
# orphan, duplicate id anywhere in the corpus, split-file pair, or reversed pair.
resolve_marker_file() {
  local inventory="$1"
  local corpus_name="$2"
  local marker_id="$3"
  local starts ends start_file end_file start_line end_line

  starts="$(awk -F $'\t' -v id="${marker_id}" '$1 == id && $2 == "START" { count++ } END { print count + 0 }' "${inventory}")"
  ends="$(awk -F $'\t' -v id="${marker_id}" '$1 == id && $2 == "END" { count++ } END { print count + 0 }' "${inventory}")"
  if [ "${starts}" != "1" ] || [ "${ends}" != "1" ]; then
    echo "ERROR: marker '${marker_id}' in ${corpus_name} has ${starts} START and ${ends} END across the corpus (expected 1 each)" >&2
    return 2
  fi

  start_file="$(awk -F $'\t' -v id="${marker_id}" '$1 == id && $2 == "START" { print $3 }' "${inventory}")"
  end_file="$(awk -F $'\t' -v id="${marker_id}" '$1 == id && $2 == "END" { print $3 }' "${inventory}")"
  if [ "${start_file}" != "${end_file}" ]; then
    echo "ERROR: marker '${marker_id}' in ${corpus_name} starts in ${start_file} but ends in ${end_file}" >&2
    return 2
  fi

  start_line="$(awk -F $'\t' -v id="${marker_id}" '$1 == id && $2 == "START" { print $4 }' "${inventory}")"
  end_line="$(awk -F $'\t' -v id="${marker_id}" '$1 == id && $2 == "END" { print $4 }' "${inventory}")"
  if [ "${start_line}" -ge "${end_line}" ]; then
    echo "ERROR: marker '${marker_id}' in ${corpus_name}/${start_file}: END (line ${end_line}) does not follow START (line ${start_line})" >&2
    return 2
  fi

  printf '%s\n' "${start_file}"
}

# extract_section <file-path> <marker-id> <output-path>
# Writes the exact bytes on lines BETWEEN the START and END marker lines. The
# temporary file avoids command substitution, which strips trailing newlines.
extract_section() {
  local file="$1"
  local marker_id="$2"
  local output="$3"
  python3 - "${file}" "${marker_id}" "${output}" <<'PY'
import sys
from pathlib import Path

file_path = Path(sys.argv[1])
marker_id = sys.argv[2].encode("ascii")
output_path = Path(sys.argv[3])
start_marker = b"<!-- BOUNDARY-SYNC-START: " + marker_id + b" -->"
end_marker = b"<!-- BOUNDARY-SYNC-END: " + marker_id + b" -->"
lines = file_path.read_bytes().splitlines(keepends=True)
start_index = next(i for i, line in enumerate(lines) if start_marker in line)
end_index = next(i for i, line in enumerate(lines) if end_marker in line)
output_path.write_bytes(b"".join(lines[start_index + 1 : end_index]))
PY
}

# ---------------------------------------------------------------------------
# Main check loop.
# ---------------------------------------------------------------------------

check_one_pair() {
  local marker_id="$1"
  local this_file sibling_file

  if ! this_file="$(resolve_marker_file "${THIS_INVENTORY}" "${THIS_REPO_NAME}" "${marker_id}")"; then
    return 2
  fi
  if ! sibling_file="$(resolve_marker_file "${SIBLING_INVENTORY}" "${SIBLING_NAME}" "${marker_id}")"; then
    return 2
  fi

  local this_section sibling_section
  this_section="${TMP_ROOT}/${marker_id}.this"
  sibling_section="${TMP_ROOT}/${marker_id}.sibling"
  extract_section "${THIS_REPO_ROOT}/${this_file}" "${marker_id}" "${this_section}"
  extract_section "${SIBLING_REPO_ROOT}/${sibling_file}" "${marker_id}" "${sibling_section}"

  if cmp -s "${this_section}" "${sibling_section}"; then
    echo "OK  ${marker_id}  (${this_file}  <->  ${SIBLING_NAME}/${sibling_file})"
    return 0
  fi

  echo "DRIFT  ${marker_id}  (${this_file}  <->  ${SIBLING_NAME}/${sibling_file})" >&2
  diff -u "${this_section}" "${sibling_section}" >&2 || true
  return 1
}

main() {
  local target_id="${1:-}"

  if [ "$#" -gt 1 ]; then
    echo "ERROR: expected zero arguments or one marker id" >&2
    return 2
  fi
  if [ -n "${target_id}" ] && [[ ! "${target_id}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: invalid marker id '${target_id}'" >&2
    return 2
  fi

  if ! enumerate_markers "${THIS_REPO_ROOT}" > "${THIS_INVENTORY}"; then
    echo "ERROR: failed to enumerate markers in ${THIS_REPO_NAME}" >&2
    return 2
  fi
  if ! enumerate_markers "${SIBLING_REPO_ROOT}" > "${SIBLING_INVENTORY}"; then
    echo "ERROR: failed to enumerate markers in ${SIBLING_NAME}" >&2
    return 2
  fi

  if [ -n "${target_id}" ]; then
    check_one_pair "${target_id}"
    return $?
  fi

  # No argument: check the union of START and END ids in both corpora. This is
  # what exposes END-only, sibling-only, and otherwise malformed marker sets.
  local all_ids
  all_ids="$({ cut -f1 "${THIS_INVENTORY}"; cut -f1 "${SIBLING_INVENTORY}"; } | LC_ALL=C sort -u)"

  if [ -z "${all_ids}" ]; then
    echo "no BOUNDARY-SYNC markers found in ${THIS_REPO_NAME} or ${SIBLING_NAME}; nothing to check"
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

  return "${rc}"
}

main "$@"
