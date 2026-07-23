#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/ios/assert-xcode-tests-ran.sh <xcodebuild-log> [minimum-tests]

Fails when an xcodebuild test log did not execute at least minimum-tests tests.
Use after -only-testing runs before accepting the log or xcresult as green QA evidence.
USAGE
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 64
fi

log_file="$1"
minimum_tests="${2:-1}"

if [[ ! -f "$log_file" ]]; then
  echo "error: xcodebuild log not found: $log_file" >&2
  exit 66
fi

if [[ ! "$minimum_tests" =~ ^[0-9]+$ || "$minimum_tests" -lt 1 ]]; then
  echo "error: minimum-tests must be a positive integer" >&2
  exit 64
fi

executed_tests="$(
  awk '
    /Executed [0-9]+ tests?/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "Executed") {
          count = $(i + 1)
          gsub(/[^0-9]/, "", count)
          if ((count + 0) > max) {
            max = count + 0
          }
        }
      }
    }
    END { print max + 0 }
  ' "$log_file"
)"

if [[ "$executed_tests" -lt "$minimum_tests" ]]; then
  echo "error: xcodebuild executed $executed_tests tests, expected at least $minimum_tests" >&2
  grep -E "Executed [0-9]+ tests?" "$log_file" >&2 || true
  exit 65
fi

echo "xcodebuild executed $executed_tests tests (minimum $minimum_tests)"
