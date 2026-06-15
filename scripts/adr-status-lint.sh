#!/usr/bin/env bash
# adr-status-lint.sh — ADR status linter for donmai-architecture
#
# Usage:
#   ./scripts/adr-status-lint.sh [--staged] [--all]
#
#   --staged   scan only git-staged ADR-*.md files (pre-commit mode)
#   --all      scan all git-tracked ADR-*.md files
#
# Exit codes:
#   0  all statuses valid (warnings may have been emitted)
#   1  one or more ADR files carry an invalid status value
#
# Status detection (in priority order):
#   1. YAML front-matter `status:` field (between --- fences)
#   2. Markdown bold `**Status:** Value` in the document body
#      (pre-template ADRs that predate the YAML frontmatter convention)
#
# Valid status values:
#   Proposed | Accepted | Superseded | Deprecated | Mirrored | Active | Template
#
# Warnings (non-fatal):
#   - ADR file on disk that has no entry in README.md (unlisted)
#   - README.md entry that does not correspond to a file on disk (ghost)

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VALID_STATUSES="Proposed|Accepted|Superseded|Deprecated|Mirrored|Active|Template"

EXIT_CODE=0
WARN_COUNT=0
HARD_FAIL_COUNT=0

# ---- Parse args ----
FILES=()
for arg in "$@"; do
  case "$arg" in
    --staged)
      while IFS= read -r f; do
        [[ -n "$f" && "$f" == ADR-*.md ]] && FILES+=("$f")
      done < <(git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR)
      ;;
    --all)
      while IFS= read -r f; do
        [[ -n "$f" && "$f" == ADR-*.md ]] && FILES+=("$f")
      done < <(git -C "$REPO_ROOT" ls-files 'ADR-*.md')
      ;;
  esac
done

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "adr-status-lint: no ADR-*.md files to scan. Pass --staged or --all." >&2
  exit 0
fi

# ---- Validate status values ----
echo "adr-status-lint: checking ${#FILES[@]} file(s) for valid status values..."

for rel_file in "${FILES[@]}"; do
  abs_file="$REPO_ROOT/$rel_file"
  [[ -f "$abs_file" ]] || continue

  status_val=""
  status_src=""

  # --- Strategy 1: YAML front-matter `status:` field ---
  # Read lines between the opening and closing --- fences.
  in_fm=false
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      if ! $in_fm; then
        in_fm=true
        continue
      else
        break   # closing fence — stop
      fi
    fi
    if $in_fm && [[ "$line" =~ ^status:[[:space:]]*(.*) ]]; then
      raw="${BASH_REMATCH[1]}"
      # Strip inline YAML comments (everything after ' #' or tab-#)
      raw="${raw%% #*}"
      raw="${raw%%	#*}"
      # Trim surrounding whitespace
      raw="${raw#"${raw%%[![:space:]]*}"}"
      raw="${raw%"${raw##*[![:space:]]}"}"
      status_val="$raw"
      status_src="frontmatter"
      break
    fi
  done < "$abs_file"

  # --- Strategy 2: Markdown bold `**Status:** Value` in body ---
  # Used by pre-template ADRs that lack YAML fences.
  if [[ -z "$status_val" ]]; then
    raw=$(grep -m1 '^\*\*Status:\*\*' "$abs_file" 2>/dev/null || true)
    if [[ -n "$raw" ]]; then
      # Extract text after '**Status:**' and trim
      raw="${raw#\*\*Status:\*\*}"
      raw="${raw#"${raw%%[![:space:]]*}"}"
      # Keep only the first word (value may be followed by prose)
      status_val="${raw%% *}"
      status_val="${status_val%%	*}"
      status_src="body-bold"
    fi
  fi

  # --- Report ---
  if [[ -z "$status_val" ]]; then
    echo "  FAIL  $rel_file — no status found (add 'status:' to YAML front-matter)"
    HARD_FAIL_COUNT=$((HARD_FAIL_COUNT + 1))
    continue
  fi

  if echo "$status_val" | grep -qE "^($VALID_STATUSES)$"; then
    echo "  ok    $rel_file — status: $status_val  [via $status_src]"
  else
    echo "  FAIL  $rel_file — invalid status: '$status_val' (allowed: $VALID_STATUSES)  [via $status_src]"
    HARD_FAIL_COUNT=$((HARD_FAIL_COUNT + 1))
  fi
done

# ---- README slug drift (non-fatal warnings) ----
README="$REPO_ROOT/README.md"
if [[ -f "$README" ]]; then
  echo ""
  echo "adr-status-lint: checking README.md vs on-disk drift..."

  # Extract ADR slugs from README using only POSIX-compatible grep + sed.
  # Match lines that contain ADR-YYYY-MM-DD-<slug>.md and strip to just the slug.
  readme_slugs=()
  while IFS= read -r slug; do
    [[ -n "$slug" ]] && readme_slugs+=("$slug")
  done < <(grep -oE 'ADR-[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+\.md' "$README" \
           | sed 's/\.md$//' \
           | sort -u)

  # Slugs on disk (git-tracked, excluding the template)
  disk_slugs=()
  while IFS= read -r f; do
    slug="${f%.md}"
    [[ "$slug" != "ADR-template" ]] && disk_slugs+=("$slug")
  done < <(git -C "$REPO_ROOT" ls-files 'ADR-*.md' | grep -v '^ADR-template\.md$' | sort)

  # Ghost entries: in README but not on disk
  for slug in "${readme_slugs[@]}"; do
    on_disk=false
    for ds in "${disk_slugs[@]}"; do
      [[ "$slug" == "$ds" ]] && on_disk=true && break
    done
    if ! $on_disk; then
      echo "  WARN  ghost README entry (no file on disk): $slug.md"
      WARN_COUNT=$((WARN_COUNT + 1))
    fi
  done

  # Unlisted entries: on disk but not in README
  for slug in "${disk_slugs[@]}"; do
    in_readme=false
    for rs in "${readme_slugs[@]}"; do
      [[ "$slug" == "$rs" ]] && in_readme=true && break
    done
    if ! $in_readme; then
      echo "  WARN  on-disk ADR not listed in README: $slug.md"
      WARN_COUNT=$((WARN_COUNT + 1))
    fi
  done

  if [[ $WARN_COUNT -eq 0 ]]; then
    echo "  ok    README index matches on-disk ADR files"
  fi
fi

# ---- Summary ----
echo ""
if [[ $HARD_FAIL_COUNT -gt 0 ]]; then
  echo "adr-status-lint: FAILED — $HARD_FAIL_COUNT invalid status value(s). Add or fix 'status:' frontmatter."
  echo "  Allowed values: $VALID_STATUSES"
  EXIT_CODE=1
else
  echo "adr-status-lint: OK — all status values are valid."
fi

if [[ $WARN_COUNT -gt 0 ]]; then
  echo "adr-status-lint: $WARN_COUNT README drift warning(s) — non-fatal (update README.md index to resolve)."
fi

exit $EXIT_CODE
