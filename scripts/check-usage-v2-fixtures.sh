#!/usr/bin/env bash
# Proposed counting-law checks; optional paths support isolated negative tests.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
check() {
  jq -e -s '
    def count: type == "number" and . >= 0 and . <= 9007199254740991 and floor == .;
    def valid:
      . as $v | .usage as $u |
      ($u | type == "object") and
      all($u[]; . == null or count) and
      ($v.token_semantics.cached_in_input | type == "boolean") and
      ($v.token_semantics.reasoning_in_output | type == "boolean") and
      (if $v.token_semantics.cached_in_input then
        all(["cache_read_input_tokens","cache_write_input_tokens"][];
          . as $k | if ($u[$k] | type) == "number" then
            ($u.input_tokens | count) and $u[$k] <= $u.input_tokens else true end)
       else true end) and
      (if $v.token_semantics.reasoning_in_output and ($u.reasoning_output_tokens | type) == "number"
       then ($u.output_tokens | count) and $u.reasoning_output_tokens <= $u.output_tokens else true end) and
      (if ($u.total_tokens | type) == "number" then
        ($v.total_basis == "provider_reported" or
         ($v.total_basis == "derived_input_plus_output" and
          ($u.input_tokens | count) and ($u.output_tokens | count) and
          $u.total_tokens == $u.input_tokens + $u.output_tokens)) else true end);
    length == 1 and (.[0] |
      . as $f | (.attempts | length > 0) and
      ([.attempts[].inference_attempt_id] | unique | length) == (.attempts | length) and
      [.attempts[].attempt_ordinal] == [range(1; (.attempts | length) + 1)] and
      all(.attempts[]; valid) and (.logical | valid) and
      all(.attempts[]; .token_semantics == $f.logical.token_semantics) and
      ([.logical.usage, .attempts[].usage] | map(keys) | add | unique) as $fields |
      all($fields[]; . as $k |
        [$f.attempts[].usage | {present: has($k), value: .[$k]}] as $values |
        if any($values[]; .present | not) then ($f.logical.usage | has($k) | not)
        elif all($values[]; .value == null) then
          ($f.logical.usage | has($k)) and $f.logical.usage[$k] == null
        else $f.logical.usage[$k] == ([$values[].value | select(. != null)] | add) end))
  ' "$1" >/dev/null
}
if [[ "${1:-}" == --selftest ]]; then
  bash "$0" >/dev/null
  mkdir -p .scratch
  scratch=$(mktemp -d .scratch/usage-v2.XXXXXX)
  trap 'rm -rf "$scratch"' EXIT
  # Unknown remains absent; mixed applicable/inapplicable counts sum only numbers.
  jq 'del(.attempts[0].usage.reasoning_output_tokens, .logical.usage.reasoning_output_tokens)' \
    fixtures/usage-v2/retry-fallback.json > "$scratch/states.json"
  check "$scratch/states.json"
  jq '.attempts[0].usage.reasoning_output_tokens = null | .logical.usage.reasoning_output_tokens = 8' \
    fixtures/usage-v2/retry-fallback.json > "$scratch/states.json"
  check "$scratch/states.json"
  # Keep sums consistent so containment, not aggregation, must reject these.
  for field in reasoning_output_tokens cache_read_input_tokens; do
    jq --arg k "$field" '.attempts[0].usage[$k] = 999 |
      .logical.usage[$k] = ([.attempts[].usage[$k]] | add)' \
      fixtures/usage-v2/retry-fallback.json > "$scratch/bad.json"
    if check "$scratch/bad.json"; then echo "FAIL: accepted $field overflow" >&2; exit 1; fi
  done
  jq '.attempts[0].usage as $failed | .attempts[1].usage |= with_entries(.value += $failed[.key])' \
    fixtures/usage-v2/retry-fallback.json > "$scratch/bad.json"
  if check "$scratch/bad.json"; then echo 'FAIL: accepted repeated failed-attempt tokens' >&2; exit 1; fi
  echo 'usage-v2 selftest: PASS (3 corruptions rejected)'
else
  if [[ $# == 0 ]]; then set -- fixtures/usage-v2/*.json; fi
  for fixture in "$@"; do
    check "$fixture" || { echo "FAIL: $fixture" >&2; exit 1; }
  done
  echo "usage-v2 fixtures: PASS ($# fixtures)"
fi
