#!/usr/bin/env bash
# guard-b-lint.sh — closed-source content linter for this public corpus.
#
# Usage: ./scripts/guard-b-lint.sh [MODE...] [<file>...]
#   --staged            scan git-staged files (pre-commit mode)
#   --all               scan every tracked file (CI mode)
#   --commits <range>   scan the COMMIT MESSAGES of a rev-range, merge commits
#                       included. Commit messages are published with the repo
#                       and a file scan cannot see them.
#   --stdin <label>     scan text arriving on stdin, reported under <label>.
#                       CI uses this for the squash-merge message GitHub
#                       composes from the PR title and body — that text becomes
#                       a published commit and exists in no branch commit.
#   --punch-list        also write violations to GUARD-B-VIOLATIONS.txt
#   <file>...           scan an explicit file list
#
# Exit codes: 0 clean, 1 violations found, 2 usage error or refused allowlist.
#
# Self-test: scripts/guard-b-lint-selftest.sh — proves every rule fires on a
# known-bad sample, stays quiet on a known-good one, and that the engine's
# non-obvious behaviours (merge commits, stdin, binary files, blanket-allowlist
# refusal) actually work. A guard nobody has watched fail is not evidence.
#
# Allowlist: .guard-allowlist in the repo root — one grep -E pattern per line
# (comments with #). Each pattern is matched against the *annotated* violation
# string:
#
#     <location>:<line>:<content>  [rule: <RULE_ID> — <description>]
#
# Every entry MUST be anchored with '^' and MUST name concrete rule IDs after
# '\[rule: '. Both are enforced below and refused with exit 2 — a whole-file
# exemption in a leak guard disables the guard for that file, which is how a
# gate stops being evidence.

set -eo pipefail
# nounset (-u) intentionally omitted: bash 3 treats empty arrays as unbound,
# which fires before we can check ${#ARR[@]}. Portability over strictness.

ALLOWLIST=".guard-allowlist"
PUNCH_LIST_MODE=false

# ---- Rule definitions: "ID|FLAGS|regex|description" ----
# FLAGS: "-" = case-sensitive, "i" = case-insensitive.
# The regex field may itself contain '|' alternation; the description may not.
#
# ── Why the patterns are written with single-character [brackets] ────────────
# Several rules would otherwise match their own definition line, and the only
# way to keep this file green was an allowlist entry covering the rule table —
# which is a whole-file escape wearing a disguise. Bracketing one letter
# (`Rens[e]i`, `/Us[e]rs/`, `/api/cl[i]/`) changes nothing about what the rule
# matches at scan time and makes the definition line itself unmatchable, so
# this script needs no exemption at all. Do not "tidy" the brackets away.
#
# ── Rule IDs are deliberately brand-neutral ─────────────────────────────────
# They used to embed the closed brand and the closed env-var prefix, so every
# place that merely *named* a rule — this file, the CI workflow, the allowlist —
# tripped the rules and had to be exempted. Those exemptions are where the
# whole-file escapes came from.
#
# ── Tracker IDs are covered in all three casings that occur in practice ─────
# The three rules are disjoint by construction (upper / lower / title), so a
# single leak is reported once, by the rule that names its shape:
#   TRACKER_ID            the prose form, all upper case
#   TRACKER_ID_SLUG       the all-lower-case form a branch, worktree directory
#                         or task-list id carries, with its trailing slug
#   TRACKER_ID_TITLECASE  the form a title-cased sentence or a UI label makes
# The marketing team's key collides with calendar strings, so its lower- and
# title-case forms require the trailing slug segment that a branch name always
# carries. A bare month-and-day and a bare month-and-year stay clean; the same
# string followed by a hyphen and a slug word does not.
RULES=(
  'BRAND_NAME|-|\bRens[e]i\b|closed product brand (use Donmai, or allowlist parent-brand attribution)'
  'TRACKER_ID|-|\b(REN2|RENOPS|REN|SUP|MAR)-[0-9]+\b|internal tracker issue ID'
  'TRACKER_ID_SLUG|-|\b((ren2|renops|ren|sup)-[0-9]+\b|mar-[0-9]+-)|internal tracker ID in a branch / worktree / task-list slug'
  'TRACKER_ID_TITLECASE|-|\b((Ren2|RenOps|Renops|Ren|Sup)-[0-9]+\b|Mar-[0-9]+-)|internal tracker ID in title case'
  'TRACKER_URL|-|(^|[^.[:alnum:]-])linear\.app/[A-Za-z0-9_-]+/|internal tracker deep link (any workspace, team key or path)'
  'CLOSED_CLI_ENDPOINT|-|/api/cl[i]/|closed control-plane CLI endpoint (only /api/daemon/* is OSS-shipped)'
  'CLOSED_TUI_REPO|-|rens[e]i-tui|closed-source TUI repo name'
  'CLOSED_PLATFORM|-|rens[e]i-platform|closed-source platform moniker'
  'PARENT_DOMAIN|-|rens[e]i\.ai|parent-company domain (allowlist legitimate parent-brand URLs)'
  'PLATFORM_PATH|-|\bplatform/(src|app|api|lib|components|drizzle|migrations|e2e|sdk|scripts|contracts|types|clickhouse|public|docs|tests)/|internal monorepo path prefix'
  'DEV_ABS_PATH|-|/Us[e]rs/[^/[:space:]]+/|developer absolute path'
  'CLOSED_ENV_VAR|-|RENS[E]I_[A-Z_]+|closed-source environment variable name'
  'PROD_METRIC|-|(([0-9]{1,3}(,[0-9]{3}){2,}|[0-9]{7,})[[:space:]]+([a-z][a-z-]*[[:space:]]+){0,2}(record|row|event|session|run|job|org|organi[sz]ation|tenant|user|deliver(y|ies)|span|dispatch|message|request|invocation|entr(y|ies))(e?s)?\b|\b(in|on|across) production\b[^.]{0,60}[0-9]{1,3}(,[0-9]{3})+)|production measurement of the closed control plane (operational data, not architecture)'
)

# ---- Parse args ----
FILES=()
COMMIT_RANGE=""
STDIN_LABEL=""
WANT=""
for arg in "$@"; do
  if [[ -n "$WANT" ]]; then
    case "$WANT" in
      range) COMMIT_RANGE="$arg" ;;
      label) STDIN_LABEL="$arg" ;;
    esac
    WANT=""
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
    --commits) WANT=range ;;
    --stdin) WANT=label ;;
    --punch-list) PUNCH_LIST_MODE=true ;;
    -*)
      echo "guard-b: unknown flag: $arg" >&2
      exit 2
      ;;
    *) FILES+=("$arg") ;;
  esac
done

if [[ -n "$WANT" ]]; then
  echo "guard-b: --${WANT/range/commits} requires an argument." >&2
  exit 2
fi

if [[ ${#FILES[@]} -eq 0 && -z "$COMMIT_RANGE" && -z "$STDIN_LABEL" ]]; then
  echo "No files to scan. Pass --staged, --all, --commits <range>, --stdin <label>, or file paths." >&2
  exit 0
fi

STDIN_TEXT=""
if [[ -n "$STDIN_LABEL" ]]; then
  STDIN_TEXT="$(cat)"
fi

# ---- Load allowlist, refusing blanket entries ----
# Precedent: scripts/retired-claim-lint.sh, which refuses blanket patterns for
# the same reason. Both headers used to merely *declare* the no-whole-file rule;
# nothing enforced it, and a `<file>:.*` entry survived three review rounds.
refuse_allowlist() {
  local lineno="$1" why="$2" entry="$3"
  echo "guard-b: $ALLOWLIST:$lineno — REFUSED: $why" >&2
  echo "  entry: $entry" >&2
  echo "" >&2
  echo "  Every allowlist entry must:" >&2
  echo "    (a) be anchored with '^' so it names a specific file, and" >&2
  echo "    (b) carry a concrete rule scope, e.g. '\\[rule: BRAND_NAME' or" >&2
  echo "        '\\[rule: (BRAND_NAME|PLATFORM_PATH)'." >&2
  echo "  An entry that omits either one exempts every rule on the line it" >&2
  echo "  matches — and a '<file>:.*' entry exempts an entire file forever," >&2
  echo "  silently. That is how a gate stops being evidence. Narrow it, or fix" >&2
  echo "  the line it was protecting." >&2
  exit 2
}

ALLOWLIST_PATTERNS=()
if [[ -f "$ALLOWLIST" ]]; then
  al_lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    al_lineno=$((al_lineno + 1))
    [[ "$line" =~ ^[[:space:]]*# || -z "$line" ]] && continue
    [[ "$line" == '^'* ]] || refuse_allowlist "$al_lineno" "entry is not anchored with '^'" "$line"
    case "$line" in
      *'\[rule: '*) ;;
      *) refuse_allowlist "$al_lineno" "entry is not scoped to a rule" "$line" ;;
    esac
    al_scope="$(printf '%s' "$line" | sed 's/.*\\\[rule: //')"
    [[ "$al_scope" =~ ^(\(|[A-Z_]) ]] || \
      refuse_allowlist "$al_lineno" "rule scope must name concrete rule IDs, not a wildcard" "$line"
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

# ---- Binary files: scanned as text, and named ----
# `grep -I` used to be in the flag set, so a single NUL byte anywhere in a file
# made grep report no matches for the whole file and the guard said nothing
# about the skip — a silent, file-sized hole. We scan with -a instead and list
# every binary file in scope so a reviewer can see what was text-scanned.
BINARY_FILES=()
for file in "${FILES[@]}"; do
  [[ -f "$file" && -s "$file" ]] || continue
  LC_ALL=C grep -qI -- '' "$file" 2>/dev/null || BINARY_FILES+=("$file")
done
if [[ ${#BINARY_FILES[@]} -gt 0 ]]; then
  echo "guard-b: NOTICE — ${#BINARY_FILES[@]} binary file(s) in scope, scanned as text (-a):"
  printf '  %s\n' "${BINARY_FILES[@]}"
fi

# ---- Non-file sources, flattened once ----
# Commit messages and the composed squash message are published text that is
# not a file, so a file scan cannot see them. Flattening once here rather than
# re-reading inside the rule loop keeps the cost at one `git log` per commit
# instead of one per commit per rule.
#
# Content and location go to two PARALLEL files, line for line, and the rules
# are matched against the content only. Prefixing the content with its location
# would let the location itself match — a branch name in a `Merge branch ...`
# subject would flag every line of that commit's body.
NONFILE_SRC="$(mktemp)"
NONFILE_LOC="$(mktemp)"
trap 'rm -f "$NONFILE_SRC" "$NONFILE_LOC"' EXIT

# Merge commits are NOT excluded. `--no-merges` used to be on this rev-list, and
# a merge commit is the one place a branch slug lands in published history —
# precisely the shape TRACKER_ID_SLUG exists to catch.
if [[ -n "$COMMIT_RANGE" ]]; then
  while IFS= read -r sha; do
    [[ -n "$sha" ]] || continue
    git log -1 --format='%s%n%b' "$sha" > "$NONFILE_SRC.one"
    cat "$NONFILE_SRC.one" >> "$NONFILE_SRC"
    awk -v p="commit-message:${sha:0:12}" '{ print p ":" NR }' "$NONFILE_SRC.one" >> "$NONFILE_LOC"
  done < <(git rev-list "$COMMIT_RANGE" 2>/dev/null || true)
  rm -f "$NONFILE_SRC.one"
fi

if [[ -n "$STDIN_LABEL" ]]; then
  printf '%s\n' "$STDIN_TEXT" >> "$NONFILE_SRC"
  printf '%s\n' "$STDIN_TEXT" | awk -v p="$STDIN_LABEL" '{ print p ":" NR }' >> "$NONFILE_LOC"
fi

# ---- Scan ----
VIOLATIONS=()
for rule in "${RULES[@]}"; do
  rule_id="${rule%%|*}"
  rest="${rule#*|}"
  flags="${rest%%|*}"
  rest="${rest#*|}"
  description="${rest##*|}"
  pattern="${rest%|*}"

  file_flags=(-n -H -E -a)
  # -n only: the location comes from the parallel index, keyed on that number.
  text_flags=(-n -E -a)
  if [[ "$flags" == "i" ]]; then
    file_flags+=(-i)
    text_flags+=(-i)
  fi

  # --- files ---
  for file in "${FILES[@]}"; do
    [[ -f "$file" ]] || continue
    while IFS= read -r match; do
      [[ -n "$match" ]] || continue
      annotated="$match  [rule: $rule_id — $description]"
      is_allowed "$annotated" && continue
      VIOLATIONS+=("$annotated")
    done < <(grep "${file_flags[@]}" -- "$pattern" "$file" 2>/dev/null || true)
  done

  # --- commit messages and the composed squash message (already flattened) ---
  if [[ -s "$NONFILE_SRC" ]]; then
    while IFS= read -r match; do
      [[ -n "$match" ]] || continue
      nf_n="${match%%:*}"
      nf_content="${match#*:}"
      nf_loc="$(awk -v n="$nf_n" 'NR == n { print; exit }' "$NONFILE_LOC")"
      annotated="$nf_loc:$nf_content  [rule: $rule_id — $description]"
      is_allowed "$annotated" && continue
      VIOLATIONS+=("$annotated")
    done < <(grep "${text_flags[@]}" -- "$pattern" "$NONFILE_SRC" || true)
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
echo "trackers, repos, endpoints, hosts or production measurements. To allowlist"
echo "a specific line, add a grep -E pattern to .guard-allowlist matching the"
echo "full annotated violation string:"
echo "  <location>:<line>:<content>  [rule: <RULE_ID> — <description>]"
echo "Anchor it with ^, name the file, and scope it to concrete rule IDs."
echo "Unanchored or unscoped entries are refused outright."
echo ""

if $PUNCH_LIST_MODE; then
  printf '%s\n' "${VIOLATIONS[@]}" > GUARD-B-VIOLATIONS.txt
  echo "Punch list written to GUARD-B-VIOLATIONS.txt"
fi

exit 1
