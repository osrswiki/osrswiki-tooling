#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/ios/assert-xcode-test-manifest.sh <xcresult-path> [manifest-json]

Fails when a broad xcodebuild .xcresult does not contain the critical XCTest
classes listed in the manifest, drops below per-target minimum test counts, or
re-admits legacy classes that are meant to stay quarantined.
USAGE
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 64
fi

xcresult_path="$1"
manifest_path="${2:-scripts/ios/xcode-test-manifest.json}"

if [[ ! -d "$xcresult_path" ]]; then
  echo "error: xcresult bundle not found: $xcresult_path" >&2
  exit 66
fi

if [[ ! -f "$manifest_path" ]]; then
  echo "error: manifest not found: $manifest_path" >&2
  exit 66
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 69
fi

jq empty "$manifest_path"

tests_json="$(mktemp "${TMPDIR:-/tmp}/osrs-xcresult-tests.XXXXXX.json")"
trap 'rm -f "$tests_json"' EXIT

xcrun xcresulttool get test-results tests --path "$xcresult_path" --format json > "$tests_json"

test_case_filter='
  .. | objects | select(.nodeType? == "Test Case")
  | {
      target: (((.nodeIdentifierURL // "") | split("/"))[4] // "unknown"),
      class: (((.nodeIdentifier // .name // "") | split("/"))[0]),
      identifier: (.nodeIdentifier // .name // ""),
      result: (.result // "Unknown")
    }
'

count_class() {
  local target="$1"
  local class_name="$2"

  jq -r --arg target "$target" --arg class "$class_name" "
    [${test_case_filter} | select(.target == \$target and .class == \$class)] | length
  " "$tests_json"
}

count_target_tests() {
  local target="$1"

  jq -r --arg target "$target" "
    [${test_case_filter} | select(.target == \$target)] | length
  " "$tests_json"
}

failures=0

echo "xcode test manifest guard: $xcresult_path"

while IFS=$'\t' read -r target minimum; do
  [[ -n "$target" ]] || continue
  actual="$(count_target_tests "$target")"
  if [[ "$actual" -lt "$minimum" ]]; then
    echo "error: $target executed $actual test cases, expected at least $minimum" >&2
    failures=$((failures + 1))
  else
    echo "$target executed $actual test cases (minimum $minimum)"
  fi
done < <(jq -r '.minimumTestCases // {} | to_entries[] | [.key, .value] | @tsv' "$manifest_path")

while IFS=$'\t' read -r target class_name; do
  [[ -n "$target" ]] || continue
  count="$(count_class "$target" "$class_name")"
  if [[ "$count" -lt 1 ]]; then
    echo "error: required class missing from result bundle: $target/$class_name" >&2
    failures=$((failures + 1))
  else
    echo "required class present: $target/$class_name ($count test case(s))"
  fi
done < <(jq -r '.requiredClasses // {} | to_entries[] | .key as $target | .value[] | [$target, .] | @tsv' "$manifest_path")

while IFS=$'\t' read -r target class_name; do
  [[ -n "$target" ]] || continue
  count="$(count_class "$target" "$class_name")"
  if [[ "$count" -gt 0 ]]; then
    echo "error: forbidden legacy class ran in result bundle: $target/$class_name ($count test case(s))" >&2
    failures=$((failures + 1))
  else
    echo "forbidden legacy class absent: $target/$class_name"
  fi
done < <(jq -r '.forbiddenClasses // {} | to_entries[] | .key as $target | .value[] | [$target, .] | @tsv' "$manifest_path")

if [[ "$failures" -gt 0 ]]; then
  echo "error: xcode test manifest guard found $failures issue(s)" >&2
  exit 65
fi

echo "xcode test manifest guard passed"
