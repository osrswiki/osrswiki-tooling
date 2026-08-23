# Task 8 — Bonuses visual guardrail (Abyssal whip)

Locks the Phase B “not needle-thin” check for live inline critical CSS (Task 7)
and any later critical-bundle enablement (Task 7b).

**Unit-locked now:** probe source + anti-crush CSS tokens (Android/iOS regression
contracts). **Device evidence (screenshots + live probe) deferred** until emu/sim
is free (overnight-calc owns home emus; do not spawn new ones overnight).

## Probe (source of truth)

`tools/qa/bonuses-min-cell-guardrail-probe.js`

Evaluate in the article WebView **after** FirstViewPainted body reveal on
`Abyssal whip`. Fail the intervention if `ok === false` (`minCellWidth < 28`).

## Morning device capture (when emu/sim free)

Tip under test should include Task 7 (`b887564a`+) — record `git rev-parse HEAD`.

### Android (prefer existing session device; do not steal overnight-calc’s 5556)

```bash
cd <worktree-or-fleet-checkout>
./scripts/android/setup-session-device.sh   # only if you need a NEW emu
source .claude-env
./scripts/android/quick-test.sh

# Open Abyssal whip (light + dark spot-check). After reveal:
adb shell am start -a android.intent.action.VIEW  # or navigate in-app
# Inject probe via chrome://inspect / WebView evaluate, or:
# adb exec-out … (prefer chrome DevTools evaluate of the probe file)

# Screenshot bonuses table:
./scripts/android/take-screenshot.sh
# Copy into session artifacts (see Evidence layout).
```

### iOS

```bash
cd <worktree-or-fleet-checkout>
./scripts/ios/setup-session-simulator.sh   # only if you need a NEW sim
source .ios-env
./scripts/ios/quick-test.sh
# Open Abyssal whip; after reveal evaluate probe in Safari Web Inspector.
# Screenshot → session artifacts.
```

### Probe evaluate (both)

Paste contents of `tools/qa/bonuses-min-cell-guardrail-probe.js` into WebView
console / evaluateJavascript. Expect JSON-like `{ ok: true, minCellWidth: ≥28 }`.

## Evidence layout (artifacts, not git binaries)

```text
~/Developer/osrswiki-local-artifacts/artifacts/active/<session>/fvs-task8/
  tip_sha.txt
  android-abyssal-whip-light.png
  android-abyssal-whip-dark.png
  ios-abyssal-whip-light.png          # optional same morning
  probe-android.json                  # {ok,minCellWidth,…}
  probe-ios.json
  notes.md                            # Asia/Tokyo time, device/sim id, pass/fail
```

Optional checked-in pointer only (no PNGs): update
`docs/qa/article-load-fvs-results-YYYYMMDD.md` with tip SHA + `ok` / `minCellWidth`.

## Unit / contract gates (landed with Task 8 docs)

- Probe file exists; contains `infobox-bonuses` and `minW >= 28`.
- `shared/css/fixes.css` still defines `--osrs-bonuses-min-inline-size` and
  `table.infobox-bonuses:not(.main-infobox)` min-width via that var.
- Critical membership unchanged: Task 7 inline path still requires `fixes.css`
  (already covered by Task 7 contracts).

## Relation to Task 9

Task 9 warm p50 measure is separate. Gate shipping further cuts on **both**
warm p50 improvement **and** this guardrail green. Do not enable
`useCriticalArticleBundle` until Task 8 device evidence + Task 9 accept.
