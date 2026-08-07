#!/usr/bin/env bash
# guard-b-lint.sh — closed-source content linter
#
# Usage: ./scripts/guard-b-lint.sh [--staged] [--all] [--commits <range>] [--punch-list] [<file>...]
#   --staged           scan only git-staged files (pre-commit mode)
#   --all              scan entire tracked tree (migration / CI mode)
#   --commits <range>  scan the *commit messages* of a rev-range (e.g. origin/main..HEAD).
#                      Commit messages are published with the repo but are not files,
#                      so --all cannot see them.
#   --punch-list       write violations to GUARD-B-VIOLATIONS.txt (migration mode)
#   <file>...          scan an explicit file list
#
# Self-test: scripts/guard-b-lint-selftest.sh (proves each rule fires on a
# known-bad sample and stays quiet on a known-good one).
#
# Allowlist: .guard-allowlist in the repo root — one grep -E pattern per line
# (comments with #). Each pattern is matched against the *annotated* violation
# string:
#
#     <file>:<line>:<content>  [rule: <RULE_ID> — <description>]
#
# so an exemption can be scoped to a file AND a rule, e.g.
#     ^ADR-2026-01-01-foo\.md:[0-9]+:.*\[rule: BRAND_NAME
# Blanket `<file>:.*` exemptions are forbidden: a whole-file exemption in a
# leak guard defeats the guard. Scope every entry to a rule, and to the
# specific line content or identifier it was added for.

set -eo pipefail
# nounset (-u) intentionally omitted: bash 3 treats empty arrays as unbound,
# which fires before we can check ${#ARR[@]}. Portability over strictness.

ALLOWLIST=".guard-allowlist"
PUNCH_LIST_MODE=false

# ---- Rule definitions: "ID|FLAGS|regex|description" ----
# FLAGS: "-" = case-sensitive, "i" = case-insensitive.
# The regex field may itself contain '|' alternation; the description may not.
#
# Rule IDs are deliberately brand-neutral. They used to embed the closed brand
# and the closed env-var prefix, which meant every place that merely *named* a
# rule — this file, the CI workflow, the allowlist — tripped the rules and had
# to be exempted, and those exemptions were what widened into whole-file
# escapes. Neutral IDs remove that class outright and match the sibling OSS
# repo's leak-guard vocabulary.
#
# TRACKER_ID covers every tracker key the org actually issues. The set was
# established from the tracker workspace's team keys, not guessed: the platform
# team, the smoke team, the ops team, the founding-workspace team and the
# personal team. Before 2026-08-07 this rule was 'REN-[0-9]+' alone, so
# REN2- / RENOPS- / SUP- / MAR- IDs reached the public repo silently.
#
# TRACKER_ID_SLUG is the same set in the lowercase form that branch names,
# worktree directories and task-list IDs use. It is a separate, case-sensitive
# rule rather than an -i flag on TRACKER_ID so that calendar strings
# ("Mar-2026", "mar-15") cannot false-positive on the MAR- prefix.
RULES=(
  'BRAND_NAME|-|\bRensei\b|closed product brand (use Donmai, or allowlist parent-brand attribution)'
  'TRACKER_ID|-|\b(REN2|RENOPS|REN|SUP|MAR)-[0-9]+\b|internal tracker issue ID'
  'TRACKER_ID_SLUG|-|\b(ren2|renops|ren|sup)-[0-9]+\b|internal tracker ID in a branch / worktree / directory slug'
  'TRACKER_URL|-|linear\.app/[A-Za-z0-9_-]+/(issue|team|project|document|view)/|internal tracker deep link (any workspace or team key)'
  'CLOSED_TUI_REPO|-|rensei-tui|closed-source TUI repo name'
  'CLOSED_PLATFORM|-|rensei-platform|closed-source platform moniker'
  'PARENT_DOMAIN|-|rensei\.ai|parent-company domain (allowlist legitimate parent-brand URLs)'
  'PLATFORM_PATH|-|platform/src/|internal monorepo path prefix'
  'DEV_ABS_PATH|-|/Users/[^/[:space:]]+/|developer absolute path'
  'CLOSED_ENV_VAR|-|RENSEI_[A-Z_]+|closed-source environment variable name'
)

# ---- Parse args ----
FILES=()
COMMIT_RANGE=""
WANT_RANGE=false
for arg in "$@"; do
  if $WANT_RANGE; then
    COMMIT_RANGE="$arg"
    WANT_RANGE=false
    continue
  fi
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
    --commits)
      WANT_RANGE=true
      ;;
    --punch-list)
      PUNCH_LIST_MODE=true
      ;;
    -*)
      echo "guard-b: unknown flag: $arg" >&2
      exit 2
      ;;
    *)
      FILES+=("$arg")
      ;;
  esac
done

if $WANT_RANGE; then
  echo "guard-b: --commits requires a rev-range argument." >&2
  exit 2
fi

if [[ ${#FILES[@]} -eq 0 && -z "$COMMIT_RANGE" ]]; then
  echo "No files to scan. Pass --staged, --all, --commits <range>, or file paths." >&2
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

# is_allowed <annotated-violation> — 0 if an allowlist pattern covers it.
is_allowed() {
  local ap
  for ap in "${ALLOWLIST_PATTERNS[@]}"; do
    if printf '%s\n' "$1" | grep -qE "$ap"; then
      return 0
    fi
  done
  return 1
}

# ---- Scan ----
VIOLATIONS=()
for rule in "${RULES[@]}"; do
  rule_id="${rule%%|*}"
  rest="${rule#*|}"
  flags="${rest%%|*}"
  rest="${rest#*|}"
  description="${rest##*|}"
  pattern="${rest%|*}"

  grep_flags="-nIHE"
  [[ "$flags" == "i" ]] && grep_flags="-nIHEi"

  # --- files ---
  for file in "${FILES[@]}"; do
    [[ -f "$file" ]] || continue
    while IFS= read -r match; do
      [[ -n "$match" ]] || continue
      annotated="$match  [rule: $rule_id — $description]"
      is_allowed "$annotated" && continue
      VIOLATIONS+=("$annotated")
    done < <(grep $grep_flags -- "$pattern" "$file" 2>/dev/null || true)
  done

  # --- commit messages (published with the repo, invisible to a file scan) ---
  if [[ -n "$COMMIT_RANGE" ]]; then
    while IFS= read -r sha; do
      [[ -n "$sha" ]] || continue
      while IFS= read -r match; do
        [[ -n "$match" ]] || continue
        annotated="commit-message:${sha:0:12}:$match  [rule: $rule_id — $description]"
        is_allowed "$annotated" && continue
        VIOLATIONS+=("$annotated")
      done < <(git log -1 --format='%s%n%b' "$sha" | grep ${grep_flags/H/} -- "$pattern" || true)
    done < <(git rev-list --no-merges "$COMMIT_RANGE" 2>/dev/null || true)
  fi
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
echo "Rewrite the content to describe the behaviour instead of citing internal"
echo "trackers, repos or hosts. To allowlist a specific line, add a grep -E"
echo "pattern to .guard-allowlist matching the full annotated violation string:"
echo "  <file>:<line>:<content>  [rule: <RULE_ID> — <description>]"
echo "Scope it to the file AND the rule. Whole-file '<file>:.*' entries are not"
echo "acceptable — they disable the guard for that file."
echo ""

if $PUNCH_LIST_MODE; then
  printf '%s\n' "${VIOLATIONS[@]}" > GUARD-B-VIOLATIONS.txt
  echo "Punch list written to GUARD-B-VIOLATIONS.txt"
fi

exit 1
