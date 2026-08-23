#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HELPER="$ROOT/scripts/shared/osrs-public-landing.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
test -x "$HELPER"
"$HELPER" install --target android --dest "$TMP/android" --landing-root "$ROOT/docs/public-landing"
test -f "$TMP/android/README.md"
test -f "$TMP/android/LICENSE"
grep -q "GNU GENERAL PUBLIC LICENSE" "$TMP/android/LICENSE"
grep -q "unofficial" "$TMP/android/README.md"
# Public READMEs must not publish contact email
if grep -Eiq 'mailto:|@gmail\.com|contact\.omiyawaki' "$TMP/android/README.md"; then
  echo "FAIL: public android README contains email" >&2
  exit 1
fi
if grep -q "sponsors_status: pending" "$ROOT/docs/public-landing/manifest.yaml"; then
  # pending: no Support section / no Sponsors badge URL noise required
  ! grep -q "GitHub Sponsors" "$TMP/android/README.md" || {
    echo "FAIL: pending sponsors still emits Sponsors in android README" >&2
    exit 1
  }
elif grep -q "sponsors_status: live" "$ROOT/docs/public-landing/manifest.yaml"; then
  grep -q "GitHub Sponsors" "$TMP/android/README.md" || {
    echo "FAIL: live sponsors missing from android README" >&2
    exit 1
  }
  grep -q "https://github.com/sponsors/omiyawaki" "$TMP/android/README.md" || {
    echo "FAIL: live sponsors URL missing from android README" >&2
    exit 1
  }
else
  echo "FAIL: sponsors_status must be live or pending" >&2
  exit 1
fi
"$HELPER" install --target tooling --dest "$TMP/tooling" --landing-root "$ROOT/docs/public-landing"
test -f "$TMP/tooling/LICENSE"
"$HELPER" install --target privacy-policy --dest "$TMP/privacy" --landing-root "$ROOT/docs/public-landing"
test -f "$TMP/privacy/README.md"
test ! -f "$TMP/privacy/LICENSE"
if grep -Eiq 'mailto:|@gmail\.com|contact\.omiyawaki' "$TMP/privacy/README.md"; then
  echo "FAIL: privacy README contains email" >&2
  exit 1
fi
"$HELPER" install --target ios --dest "$TMP/ios" --landing-root "$ROOT/docs/public-landing"
if grep -Eiq 'mailto:|@gmail\.com|contact\.omiyawaki' "$TMP/ios/README.md"; then
  echo "FAIL: public ios README contains email" >&2
  exit 1
fi
"$HELPER" install --target org --dest "$TMP/org" --landing-root "$ROOT/docs/public-landing"
if grep -Eiq 'mailto:|@gmail\.com|contact\.omiyawaki' "$TMP/org/README.md"; then
  echo "FAIL: org README contains email" >&2
  exit 1
fi
echo "osrs-public-landing-test: PASS"
