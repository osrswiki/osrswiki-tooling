#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HELPER="$ROOT/scripts/shared/osrs-public-landing.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Expect helper exists
test -x "$HELPER"
"$HELPER" install --target android --dest "$TMP/android" --landing-root "$ROOT/docs/public-landing"
test -f "$TMP/android/README.md"
test -f "$TMP/android/LICENSE"
grep -q "GNU GENERAL PUBLIC LICENSE" "$TMP/android/LICENSE"
grep -q "unofficial" "$TMP/android/README.md"
# pending sponsors should not emit a live sponsors badge URL requirement failure
if grep -q "sponsors_status: pending" "$ROOT/docs/public-landing/manifest.yaml"; then
  grep -q "Sponsors is being set up\|mailto:contact.omiyawaki@gmail.com\|contact.omiyawaki@gmail.com" "$TMP/android/README.md"
fi
"$HELPER" install --target tooling --dest "$TMP/tooling" --landing-root "$ROOT/docs/public-landing"
test -f "$TMP/tooling/LICENSE"
"$HELPER" install --target privacy-policy --dest "$TMP/privacy" --landing-root "$ROOT/docs/public-landing"
test -f "$TMP/privacy/README.md"
test ! -f "$TMP/privacy/LICENSE"
echo "osrs-public-landing-test: PASS"
