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
PLAY_CLOSED='https://play.google.com/apps/testing/com.omiyawaki.osrswiki'
PLAY_PRODUCTION='https://play.google.com/store/apps/details?id=com.omiyawaki.osrswiki'
grep -Fq -- "- **Google Play:** [Join early testing]($PLAY_CLOSED)" "$TMP/android/README.md" || {
  echo "FAIL: android README must use Join early testing CTA with closed testing URL" >&2
  exit 1
}
if grep -q "Join closed testing to install Android now" "$TMP/android/README.md"; then
  echo "FAIL: android README must not use the old closed-testing CTA wording" >&2
  exit 1
fi
if grep -q "$PLAY_PRODUCTION" "$TMP/android/README.md"; then
  echo "FAIL: android README must not present the production Play listing as available" >&2
  exit 1
fi
grep -q "F-Droid:.*Coming soon" "$TMP/android/README.md" || {
  echo "FAIL: android README must keep F-Droid as Coming soon" >&2
  exit 1
}
if grep -q "closed-tester gate" "$TMP/android/README.md"; then
  echo "FAIL: android README must not mention Google’s closed-tester gate" >&2
  exit 1
fi
APP_STORE='https://apps.apple.com/us/app/osrs-wiki/id6788651409'
IOS_REPO='https://github.com/osrswiki/osrswiki-ios'
ANDROID_REPO='https://github.com/osrswiki/osrswiki-android'
# Cross-link: Android must point iPhone visitors at the live App Store listing
# and the iOS source tree, right under Install.
grep -Fq -- "Also available on iOS: [Download on the App Store]($APP_STORE) · [Source]($IOS_REPO)" "$TMP/android/README.md" || {
  echo "FAIL: android README must cross-link iOS (App Store + source) under Install" >&2
  exit 1
}
grep -Fq -- "- [iOS app source]($IOS_REPO)" "$TMP/android/README.md" || {
  echo "FAIL: android README Links must include iOS app source" >&2
  exit 1
}
# Anti-slop: no manifesto headers, no buzzword one-liner.
for slop in '^## Why' 'polished' 'in one place'; do
  if grep -Eq -- "$slop" "$TMP/android/README.md"; then
    echo "FAIL: android README contains slop pattern: $slop" >&2
    exit 1
  fi
done
if grep -Eq '\{\{[A-Za-z0-9_]+\}\}|\]\(\s*\)' "$TMP/android/README.md"; then
  echo "FAIL: android README has unresolved placeholder or empty link target" >&2
  exit 1
fi
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
IOS_BADGE='assets/download-on-the-app-store-black.svg'
grep -q "$APP_STORE" "$TMP/ios/README.md" || {
  echo "FAIL: ios README missing live App Store listing URL" >&2
  exit 1
}
grep -q "]($APP_STORE)" "$TMP/ios/README.md" || {
  echo "FAIL: ios README must wire platform badge or install CTA to app_store_listing_url" >&2
  exit 1
}
grep -Fq "[![Download on the App Store]($IOS_BADGE)]($APP_STORE)" "$TMP/ios/README.md" || {
  echo "FAIL: ios Install must use official App Store badge markdown linking to listing URL" >&2
  exit 1
}
test -f "$TMP/ios/$IOS_BADGE" || {
  echo "FAIL: ios landing must copy App Store badge into dest/assets" >&2
  exit 1
}
grep -q "Download_on_the_App_Store_Badge_US-UK_RGB_blk" "$TMP/ios/$IOS_BADGE" || {
  echo "FAIL: ios App Store badge is not Apple’s official black English artwork" >&2
  exit 1
}
if grep -A2 '^## Install' "$TMP/ios/README.md" | grep -q 'Coming soon'; then
  echo "FAIL: ios Install must not say Coming soon while App Store is live" >&2
  exit 1
fi
# Cross-link: iOS must point Android visitors at the early-testing invite (the
# current install path) and the Android source tree, right under Install.
grep -Fq -- "Also available on Android: [Join early testing on Google Play]($PLAY_CLOSED) · [Source]($ANDROID_REPO)" "$TMP/ios/README.md" || {
  echo "FAIL: ios README must cross-link Android (early testing + source) under Install" >&2
  exit 1
}
grep -Fq -- "- [Android app source]($ANDROID_REPO)" "$TMP/ios/README.md" || {
  echo "FAIL: ios README Links must include Android app source" >&2
  exit 1
}
if grep -q "$PLAY_PRODUCTION" "$TMP/ios/README.md"; then
  echo "FAIL: ios README must not present the production Play listing as available" >&2
  exit 1
fi
for slop in '^## Why' 'polished' 'in one place'; do
  if grep -Eq -- "$slop" "$TMP/ios/README.md"; then
    echo "FAIL: ios README contains slop pattern: $slop" >&2
    exit 1
  fi
done
if grep -Eq '\{\{[A-Za-z0-9_]+\}\}|\]\(\s*\)' "$TMP/ios/README.md"; then
  echo "FAIL: ios README has unresolved placeholder or empty link target" >&2
  exit 1
fi
# Render must fail closed when a cross-linked URL is empty, on both platforms.
for case in 'app_store_listing_url:android' 'play_closed_testing_url:ios'; do
  key="${case%%:*}"
  target="${case##*:}"
  BROKEN="$TMP/landing-empty-$key"
  cp -R "$ROOT/docs/public-landing" "$BROKEN"
  sed -i.bak "s|^$key:.*|$key: \"\"|" "$BROKEN/manifest.yaml" && rm -f "$BROKEN/manifest.yaml.bak"
  grep -q "^$key: \"\"" "$BROKEN/manifest.yaml" || {
    echo "FAIL: test setup could not blank $key in temp manifest" >&2
    exit 1
  }
  if "$HELPER" install --target "$target" --dest "$TMP/broken-$target" --landing-root "$BROKEN" 2>/dev/null; then
    echo "FAIL: $target render must fail when $key is empty (would publish a dead cross-link)" >&2
    exit 1
  fi
done
"$HELPER" install --target org --dest "$TMP/org" --landing-root "$ROOT/docs/public-landing"
if grep -Eiq 'mailto:|@gmail\.com|contact\.omiyawaki' "$TMP/org/README.md"; then
  echo "FAIL: org README contains email" >&2
  exit 1
fi
echo "osrs-public-landing-test: PASS"
