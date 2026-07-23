#!/usr/bin/env bash
set -euo pipefail

label="com.omiyawaki.osrswiki.samsung-rtl-daily-credits"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plist_source="$script_dir/$label.plist"
plist_target="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
install_bin="$HOME/.local/bin/osrswiki-samsung-rtl-claim-credits"
state_dir="$HOME/.local/share/osrswiki/samsung-rtl-daily-credits"
log_dir="$HOME/Library/Logs/osrswiki/samsung-rtl-daily-credits"
canonical_harness="$script_dir/samsung-rtl-playwright.mjs"
installed_harness="$state_dir/samsung-rtl-playwright.mjs"
canonical_mail_cleanup="$script_dir/samsung-rtl-cleanup-login-mail.py"
installed_mail_cleanup="$state_dir/samsung-rtl-cleanup-login-mail.py"

usage() {
  cat <<USAGE
Usage: $0 [--kickstart]

Installs the Samsung RTL daily credit claim LaunchAgent for the current user.
Use --kickstart to run it once immediately after installation.
USAGE
}

kickstart=0
case "${1:-}" in
  "")
    ;;
  --kickstart)
    kickstart=1
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac

mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$install_bin")" "$state_dir" "$log_dir"

/usr/bin/plutil -lint "$plist_source"

if [[ ! -f "$canonical_harness" ]]; then
  printf 'Missing canonical harness: %s\n' "$canonical_harness" >&2
  exit 78
fi

if [[ ! -f "$canonical_mail_cleanup" ]]; then
  printf 'Missing Samsung login mail cleanup helper: %s\n' "$canonical_mail_cleanup" >&2
  exit 78
fi

/usr/bin/install -m 0755 "$script_dir/samsung-rtl-claim-credits-launchd.sh" "$install_bin"
/usr/bin/install -m 0755 "$canonical_harness" "$installed_harness"
/usr/bin/install -m 0755 "$canonical_mail_cleanup" "$installed_mail_cleanup"

if /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
  /bin/launchctl bootout "$domain/$label"
elif [[ -f "$plist_target" ]]; then
  /bin/launchctl bootout "$domain" "$plist_target" >/dev/null 2>&1 || true
fi

/usr/bin/install -m 0644 "$plist_source" "$plist_target"
/bin/launchctl bootstrap "$domain" "$plist_target"
/bin/launchctl enable "$domain/$label"
/bin/launchctl print "$domain/$label" >/dev/null

if [[ "$kickstart" -eq 1 ]]; then
  /bin/launchctl kickstart -k "$domain/$label"
fi

cat <<INSTALLED
Installed $label
Source: $plist_source
Target: $plist_target
Wrapper: $install_bin
Harness: $installed_harness
Mail cleanup: $installed_mail_cleanup
Schedule: daily at 09:00 local time
Logs: $log_dir
INSTALLED
