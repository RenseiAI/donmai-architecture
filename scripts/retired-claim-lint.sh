#!/usr/bin/env bash
# retired-claim-lint.sh — fails when a claim this corpus has formally retired
# reappears as a live assertion.
#
# Usage: ./retired-claim-lint.sh [--staged] [--all] [--list-rules]
#   --staged      scan only git-staged files (pre-commit mode)
#   --all         scan every tracked file (CI / one-shot mode)
#   --list-rules  print the rule table and exit
#
# WHY THIS EXISTS
#
# An ADR that deletes a false capability claim only deletes the instances its
# author found. ADR-2026-08-07 retired the "cloud-burst" claim in 004 and left
# the identical claim standing in 013 for a full review cycle — in a file the
# same commit had already edited. Prose has no compiler, so a retired claim
# comes back for free. This is the compiler.
#
# THE BACKTICK CONVENTION (the whole design)
#
# A doc that retires a claim must still be able to QUOTE it — epitaphs, ADR
# decision text, and "renamed from" banners all name the thing they killed. So
# the rule is:
#
#   A retired string inside a `code span` is a QUOTATION and is fine.
#   A retired string in running prose or a live table cell is an ASSERTION
#   and fails.
#
# Code spans are stripped from each line before the rules are applied. To keep a
# legitimate mention, put it in backticks — which is also how it should read.
#
# ALLOWLIST
#
# .retired-claim-allowlist, one `<path-substring>:<line-regex>` per line.
# Blanket patterns are REFUSED: an allowlist entry whose regex matches
# everything exempts a whole file forever and silently, which is how a guard
# stops being evidence. Narrow the regex, or fix the line.

set -eo pipefail
# nounset (-u) intentionally omitted: bash 3 treats empty arrays as unbound,
# matching the convention in guard-b-lint.sh.

ALLOWLIST=".retired-claim-allowlist"
EXIT_CODE=0

# ---- Rule definitions: 'ID%regex%retired-by%description' ----
# The field separator is '%', not '|', because a rule regex needs '|' itself
# (BURST_OWNED uses [^|] to stay inside one markdown table cell).
# Regexes are ERE, matched against each line AFTER code spans are stripped.
# Keep them narrow: they must match the affirmative claim, not the subject.
RULES=(
  'BURST_OWNED%✅[^|]*[Bb]urst%ADR-2026-08-07 D7%Ownership cell claiming burst as a shipped capability'
  'BURST_ROUTING_ROW%Capacity-aware burst routing%ADR-2026-08-07 D7%The deleted 004 capability row'
  'BURST_AGGREGATION%cloud.burst aggregation%ADR-2026-08-07 D7%Burst-qualified fleet aggregation'
  'BURST_SCALE_PREMISE%cloud.burst across%ADR-2026-08-07 D7%The "scale by bursting across providers" premise'
  'BURST_TO_CLOUD%burst to (the )?cloud%ADR-2026-08-07 D7%Overflow-to-cloud as a live mechanism; there is none'
  'WORKAREA_POOL_PROSE%local-pool implementation%ADR-2026-08-07 D2.3%Referent-3 pool; renamed to the workarea cache'
  'WORKAREA_POOL_MEMBERS%warm pool members%ADR-2026-08-07 D2.3%Referent-3 pool; cache entries, not pool members'
  'WORKAREA_PROVIDER_POOL%WorkareaProvider local pool%ADR-2026-08-07 D2.3%Referent-3 pool; the workarea cache'
  'CLOSED_BINARY_DAEMON%rensei-daemon%ADR-2026-06-02 brand-neutral runtime%The OSS daemon is donmai; this names the closed composing binary'
  'STRICT_PIN_MODE%strictPinMode|strict pin mode%ADR-2026-08-12 D1.3%Pin strictness as a mode; a pin is hard within the law and there is no non-strict pin'
  'FALLBACK_POOL_LIST%fallback pool (list|ids)%ADR-2026-08-12 D2%A separately authored fallback list; the ordered surviving set IS the fallback set'
  'UNCONDITIONAL_NO_SCORE%[Tt]here is no cost/latency score%ADR-2026-08-12 D3%Unqualified "routing never scores"; the unscored authored order is the DEFAULT ordering policy, not the only one'
)

# ---- Parse args ----
FILES=()
for arg in "$@"; do
  case "$arg" in
    --list-rules)
      printf '%-24s %-34s %s\n' "RULE" "RETIRED BY" "DESCRIPTION"
      for rule in "${RULES[@]}"; do
        IFS='%' read -r id _re by desc <<< "$rule"
        printf '%-24s %-34s %s\n' "$id" "$by" "$desc"
      done
      exit 0
      ;;
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
  esac
done

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No files to scan. Pass --staged or --all." >&2
  exit 0
fi

# ---- Load allowlist, refusing blanket patterns ----
ALLOW_PATHS=()
ALLOW_REGEXES=()
if [[ -f "$ALLOWLIST" ]]; then
  ln=0
  while IFS= read -r line; do
    ln=$((ln + 1))
    [[ "$line" =~ ^[[:space:]]*# || -z "$line" ]] && continue
    apath="${line%%:*}"
    aregex="${line#*:}"
    if [[ -z "$apath" || -z "$aregex" || "$apath" == "$line" ]]; then
      echo "retired-claim-lint: $ALLOWLIST:$ln — malformed entry (want <path-substring>:<line-regex>): $line" >&2
      exit 2
    fi
    case "$aregex" in
      '.*'|'.+'|'^.*$'|'.'|'')
        echo "retired-claim-lint: $ALLOWLIST:$ln — REFUSED blanket pattern '$aregex' for '$apath'." >&2
        echo "  A whole-file exemption makes this gate stop being evidence. Narrow it or fix the line." >&2
        exit 2
        ;;
    esac
    ALLOW_PATHS+=("$apath")
    ALLOW_REGEXES+=("$aregex")
  done < "$ALLOWLIST"
fi

is_allowed() {
  local f="$1" text="$2" i
  for ((i = 0; i < ${#ALLOW_PATHS[@]}; i++)); do
    case "$f" in
      *"${ALLOW_PATHS[$i]}"*) ;;
      *) continue ;;
    esac
    if printf '%s' "$text" | grep -qE "${ALLOW_REGEXES[$i]}"; then
      return 0
    fi
  done
  return 1
}

# ---- Narrow to scannable files ----
SCAN=()
for file in "${FILES[@]}"; do
  [[ -f "$file" ]] || continue
  case "$file" in
    *.md) ;;
    *) continue ;;
  esac
  SCAN+=("$file")
done

if [[ ${#SCAN[@]} -eq 0 ]]; then
  echo "retired-claim-lint: OK — no markdown files in scope."
  exit 0
fi

# ---- Scan: one grep per rule over the whole file set, then re-test each hit ----
# The re-test is what enforces the backtick convention; grep alone cannot, since
# it has no notion of a code span. Hits are rare, so the cost stays in the greps.
VIOLATIONS=()
for rule in "${RULES[@]}"; do
  IFS='%' read -r rule_id pattern retired_by description <<< "$rule"
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    hfile="${hit%%:*}"
    rest="${hit#*:}"
    hline="${rest%%:*}"
    raw="${rest#*:}"
    # Strip `code spans` — a quoted retired claim is a citation, not an assertion.
    stripped="$(printf '%s' "$raw" | sed 's/`[^`]*`//g')"
    printf '%s' "$stripped" | grep -qE "$pattern" || continue
    is_allowed "$hfile" "$raw" && continue
    VIOLATIONS+=("$hfile:$hline:$raw  [rule: $rule_id — $description; retired by $retired_by]")
    EXIT_CODE=1
  done < <(grep -nE "$pattern" "${SCAN[@]}" /dev/null || true)
done

# ---- Report ----
if [[ ${#VIOLATIONS[@]} -gt 0 ]]; then
  echo "retired-claim-lint: VIOLATIONS FOUND (${#VIOLATIONS[@]})"
  for v in "${VIOLATIONS[@]}"; do
    echo "  $v"
  done
  echo ""
  echo "Each line above asserts something this corpus formally retired."
  echo "If the mention is a deliberate citation (an epitaph, a renamed-from"
  echo "banner, ADR decision text), wrap the retired string in \`backticks\` —"
  echo "quotation is always permitted. If it is a live claim, delete it."
  exit "$EXIT_CODE"
fi

echo "retired-claim-lint: OK — no retired claims asserted."
exit 0
