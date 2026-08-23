# FirstViewportSettled baseline capture (home sim/emu)

How to capture cold/warm baselines on the **home** machine using the locked protocol in  
`docs/qa/article-load-first-viewport-settled-protocol.md`.

## Preconditions

- Tip includes Phase A harness (Tasks 1–3): JS emits `FirstViewportSettled`; Android/iOS log `LOAD-MINMAX first_viewport_settled`.
- Record tip SHA before runs: `git rev-parse HEAD`
- Prefer session device/sim helpers; tear down sims/emus you create when done.

## Android (home emu)

```bash
cd <worktree>   # or parent fleet-sync checkout
./scripts/android/setup-session-device.sh
source .claude-env
./scripts/android/quick-test.sh

adb logcat -c
adb logcat -s "*:D" | tee /tmp/fvs-android.log
```

Manually open articles per the protocol (warm N=11 discard first; cold N=10 with force-quit), **or** when available:

```bash
./gradlew :app:connectedPlayDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.OSRS_GLORY_TIMING=1 \
  -Pandroid.testInstrumentationRunnerArguments.class=com.omiyawaki.osrswiki.page.osrsFirstViewGloryTimingInstrumentedTest
```

Glory timing today covers Amulet of glory; extend later for multi-article. For Phase A baselines, **manual navigation + logcat is acceptable**.

Extract rows matching:

```text
LOAD-MINMAX first_viewport_settled|LOAD-MINMAX first_viewport|LOAD-MINMAX open
```

## iOS (home sim)

```bash
cd <worktree>
./scripts/ios/setup-session-simulator.sh
source .ios-env
./scripts/ios/quick-test.sh

xcrun simctl spawn booted log stream --predicate eventMessage CONTAINS LOAD-MINMAX \
  | tee /tmp/fvs-ios.log
```

Optional Glory UITest:

```bash
TEST_RUNNER_OSRS_GLORY_TIMING=1 xcodebuild test \
  -project platforms/ios/osrswiki.xcodeproj -scheme osrswiki \
  -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" \
  -only-testing:osrswikiUITests/osrsFirstViewGloryTimingUITests
```

## Recording results

Per trial CSV columns (suggested):

```text
tip_sha,platform,cold_or_warm,title,theme,first_viewport_ms,first_viewport_settled_ms,notes
```

Store under the active session artifact dir, e.g.:

```text
~/Developer/osrswiki-local-artifacts/artifacts/active/<session>/fvs-baseline/
  android.log
  ios.log
  trials.csv
  notes.md   # tip SHA, device/sim UDID, date (Asia/Tokyo)
```

## Teardown

```bash
# iOS session sim (if created)
./scripts/ios/cleanup-session-simulator.sh   # or setup script teardown path

# Android session emu
./scripts/android/cleanup-session-device.sh   # if present; else adb emu kill + avd cleanup per AGENTS
```

Do not leave overnight sims/emus running.

## Phase B comparison

1. Capture baseline on tip with Phase A harness **before** live `inlineFirstPaintCss`.
2. Capture again after Task 7 on the **same** devices/sim/emu.
3. Gate on warm p50 `first_viewport_settled`; keep Task 8 bonuses guardrail green
   (`tools/qa/article-load-fvs-task8-guardrail.md` + `tools/qa/bonuses-min-cell-guardrail-probe.js`).
