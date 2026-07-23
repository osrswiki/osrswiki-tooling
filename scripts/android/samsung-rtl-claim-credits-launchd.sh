#!/usr/bin/env bash
set -euo pipefail

export HOME="/Users/miyawaki"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

state_dir="${SAMSUNG_RTL_LAUNCHD_STATE_DIR:-/Users/miyawaki/.local/share/osrswiki/samsung-rtl-daily-credits}"
canonical_harness="${SAMSUNG_RTL_CANONICAL_HARNESS:-$state_dir/samsung-rtl-playwright.mjs}"
mail_cleanup="${SAMSUNG_RTL_MAIL_CLEANUP:-$state_dir/samsung-rtl-cleanup-login-mail.py}"
harness_dir="/Users/miyawaki/.codex/tmp/samsung-rtl-playwright-harness"
node_bin="/opt/homebrew/bin/node"
log_dir="${SAMSUNG_RTL_LAUNCHD_LOG_DIR:-/Users/miyawaki/Library/Logs/osrswiki/samsung-rtl-daily-credits}"
lock_dir="${TMPDIR:-/tmp}/com.omiyawaki.osrswiki.samsung-rtl-daily-credits.lock"

export SAMSUNG_RTL_EVIDENCE_DIR="${SAMSUNG_RTL_EVIDENCE_DIR:-$log_dir/evidence}"
export SAMSUNG_RTL_DOWNLOAD_DIR="${SAMSUNG_RTL_DOWNLOAD_DIR:-$log_dir/downloads}"

mkdir -p "$log_dir" "$harness_dir" "$SAMSUNG_RTL_EVIDENCE_DIR" "$SAMSUNG_RTL_DOWNLOAD_DIR"

run_id="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
log_path="$log_dir/$run_id.log"
latest_log="$log_dir/latest.log"

if ! mkdir "$lock_dir" 2>/dev/null; then
  {
    printf '[%s] samsung-rtl daily credit claim skipped: another run holds %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$lock_dir"
  } >>"$log_path" 2>&1
  ln -sfn "$log_path" "$latest_log"
  exit 0
fi

cleanup() {
  rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT

status=0
{
  printf '[%s] samsung-rtl daily credit claim starting\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[env] node=%s\n' "$node_bin"
  printf '[env] harness_dir=%s\n' "$harness_dir"
  printf '[env] canonical_harness=%s\n' "$canonical_harness"
  printf '[env] mail_cleanup=%s\n' "$mail_cleanup"
  printf '[env] evidence_dir=%s\n' "$SAMSUNG_RTL_EVIDENCE_DIR"

  if [[ ! -x "$node_bin" ]]; then
    printf '[error] node binary is not executable: %s\n' "$node_bin"
    exit 78
  fi

  if [[ ! -f "$canonical_harness" ]]; then
    printf '[error] canonical Samsung RTL harness is missing: %s\n' "$canonical_harness"
    exit 78
  fi

  if [[ ! -d "$harness_dir/node_modules/playwright" ]]; then
    printf '[error] Playwright dependency is missing: %s\n' "$harness_dir/node_modules/playwright"
    printf '[hint] Recreate the harness with npm install in %s before relying on launchd.\n' "$harness_dir"
    exit 78
  fi

  cp "$canonical_harness" "$harness_dir/samsung-rtl-playwright.mjs"
  chmod 0755 "$harness_dir/samsung-rtl-playwright.mjs"

  cd "$harness_dir"
  claim_started_epoch="$(date +%s)"
  "$node_bin" samsung-rtl-playwright.mjs claim-credits-auto || status=$?
  if [[ "$status" -eq 0 ]]; then
    if [[ -x "$mail_cleanup" ]]; then
      "$mail_cleanup" --move-to-trash --since-epoch "$claim_started_epoch" || {
        cleanup_status=$?
        printf '[warn] Samsung login mail cleanup failed status=%s\n' "$cleanup_status"
      }
    else
      printf '[warn] Samsung login mail cleanup helper is not executable: %s\n' "$mail_cleanup"
    fi
  else
    printf '[warn] Samsung login mail cleanup skipped because credit claim failed status=%s\n' "$status"
  fi
  printf '[%s] samsung-rtl daily credit claim finished status=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status"
  exit "$status"
} >>"$log_path" 2>&1 || status=$?

ln -sfn "$log_path" "$latest_log"
exit "$status"
