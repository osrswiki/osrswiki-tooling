#!/usr/bin/env bash
set -euo pipefail

label="com.omiyawaki.osrswiki.map-auto-update"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plist_source="$script_dir/$label.plist"
plist_target="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
install_bin="$HOME/.local/bin/osrswiki-map-auto-update"
log_dir="$HOME/Library/Logs/osrswiki/map-auto-update"

usage() {
  cat <<USAGE
Usage: $0 [--kickstart]

Installs the weekly OSRS map-auto-update LaunchAgent for the current user.
The job runs Wednesday at 14:00 local time (a few hours after the usual
Wednesday OSRS game update). Use --kickstart to run it once immediately
after installation. Credentials come from the existing gh auth session;
this installer does not write secrets.
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

mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$install_bin")" "$log_dir"

/usr/bin/plutil -lint "$plist_source"

if [[ ! -f "$script_dir/map-auto-update-launchd.sh" ]]; then
  printf 'Missing launchd wrapper: %s\n' "$script_dir/map-auto-update-launchd.sh" >&2
  exit 78
fi

/usr/bin/install -m 0755 "$script_dir/map-auto-update-launchd.sh" "$install_bin"

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
Schedule: Wednesday 14:00 local time
Logs: $log_dir
INSTALLED
