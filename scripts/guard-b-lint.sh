#!/usr/bin/env bash
# guard-b-lint.sh — closed-source content linter
# Usage: ./guard-b-lint.sh [--staged] [--all] [--punch-list]
#   --staged     scan only git-staged files (pre-commit mode)
#   --all        scan entire working tree (migration / one-shot mode)
#   --punch-list write violations to GUARD-B-VIOLATIONS.txt (migration mode)
#
# Allowlist: .guard-allowlist in repo root (one grep-compatible regex per line, comments with #)

set -eo pipefail
# nounset (-u) intentionally omitted: bash 3 treats empty arrays as unbound,
# which fires before we can check ${#ARR[@]}. Portability over strictness.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWLIST=".guard-allowlist"
PUNCH_LIST_MODE=false
EXIT_CODE=0

# ---- Rule definitions: "ID|regex|description" ----
RULES=(
  'RENSEI_BRAND|\bRensei\b|Rensei product brand (use Donmai or allow parent-brand context)'
  'LINEAR_ID|REN-[0-9]+|Linear issue ID (internal tracker reference)'
  'RENSEI_TUI|rensei-tui|Closed-source TUI repo name'
  'RENSEI_PLATFORM|rensei-platform|Closed-source platform moniker'
  'RENSEI_AI_DOMAIN|rensei\.ai|Rensei domain (allowlist legitimate parent-brand URLs)'
  'PLATFORM_PATH|platform/src/|Internal monorepo path prefix'
  'DEV_ABS_PATH|/Users/[^/[:space:]]+/|Developer absolute path'
  'RENSEI_ENV_VAR|RENSEI_[A-Z_]+|Closed-source environment variable name'
)

# ---- Parse args ----
FILES=()
for arg in "$@"; do
  case "$arg" in
    --staged)
      while IFS= read -r f; do
        [[ -n "$f" ]] && FILES+=("$f")
      done < <(git diff --cached --name-only --diff-filter=ACMR)
      ;;
    --all)
      while IFS= read -r f; do
        [[ -n "$f" ]] && FILES+=("$f")
      done < <(git ls-files)
      ;;
    --punch-list)
      PUNCH_LIST_MODE=true
      ;;
  esac
done

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No files to scan. Pass --staged or --all." >&2
  exit 0
fi

# ---- Load allowlist ----
ALLOWLIST_PATTERNS=()
if [[ -f "$ALLOWLIST" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    ALLOWLIST_PATTERNS+=("$line")
  done < "$ALLOWLIST"
fi

# ---- Scan ----
VIOLATIONS=()
for rule in "${RULES[@]}"; do
  IFS='|' read -r rule_id pattern description <<< "$rule"
  for file in "${FILES[@]}"; do
    [[ -f "$file" ]] || continue
    # Skip binary files
    file --mime "$file" | grep -q "charset=binary" && continue
    while IFS= read -r match; do
      # Apply allowlist: skip if match line matches any allowlist pattern
      allowed=false
      for ap in "${ALLOWLIST_PATTERNS[@]}"; do
        if echo "$match" | grep -qE "$ap"; then
          allowed=true
          break
        fi
      done
      $allowed && continue
      VIOLATIONS+=("$match  [rule: $rule_id — $description]")
    done < <(grep -nE "$pattern" "$file" 2>/dev/null | sed "s|^|$file:|" || true)
  done
done

# ---- Output ----
if [[ ${#VIOLATIONS[@]} -eq 0 ]]; then
  echo "guard-b: OK — no closed-source content violations found."
  exit 0
fi

echo ""
echo "guard-b: VIOLATIONS FOUND (${#VIOLATIONS[@]})"
echo "------------------------------------------------------------"
for v in "${VIOLATIONS[@]}"; do
  echo "  $v"
done
echo "------------------------------------------------------------"
echo ""
echo "To allowlist a specific line, add a regex to .guard-allowlist."
echo "Format: match the *full line content* of the violation."
echo "Example: ^docs/MAINTAINERS\\.md:.*hello@rensei\\.ai.*$"
echo ""

if $PUNCH_LIST_MODE; then
  printf '%s\n' "${VIOLATIONS[@]}" > GUARD-B-VIOLATIONS.txt
  echo "Punch list written to GUARD-B-VIOLATIONS.txt"
fi

exit 1
