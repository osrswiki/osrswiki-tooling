#!/bin/bash
set -euo pipefail

# LaunchAgent wrapper. Logs to a dated file, runs map-auto-update.sh from the
# fleet checkout, and opens a GitHub issue on failure. No email or chat.

export HOME="${HOME:-/Users/miyawaki}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [[ -z "${JAVA_HOME:-}" ]]; then
    for java_home in \
        /opt/homebrew/opt/openjdk@25/libexec/openjdk.jdk/Contents/Home \
        /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home
    do
        if [[ -x "$java_home/bin/java" ]]; then
            export JAVA_HOME="$java_home"
            break
        fi
    done
fi
if [[ -n "${JAVA_HOME:-}" ]]; then
    export PATH="$JAVA_HOME/bin:$PATH"
fi
export OSRS_LOCAL_ARTIFACT_ROOT="${OSRS_LOCAL_ARTIFACT_ROOT:-$HOME/Developer/osrswiki-local-artifacts}"
export OSRS_CACHE_ROOT="${OSRS_CACHE_ROOT:-$OSRS_LOCAL_ARTIFACT_ROOT/cache}"

FLEET_ROOT="${OSRS_FLEET_ROOT:-$HOME/Developer/fleet-sync/git/osrswiki}"
LOG_DIR="${OSRS_MAP_AUTO_UPDATE_LOG_DIR:-$HOME/Library/Logs/osrswiki/map-auto-update}"
mkdir -p "$LOG_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOG_DIR/run-$STAMP.log"
ln -sfn "$LOG" "$LOG_DIR/latest.log"

exec >>"$LOG" 2>&1

echo "map-auto-update launchd start $STAMP"
echo "fleet: $FLEET_ROOT"
echo "cache: $OSRS_CACHE_ROOT"

if [[ ! -x "$FLEET_ROOT/scripts/shared/map-auto-update.sh" ]]; then
    echo "map-auto-update.sh is not on this checkout yet; skip until the pipeline lands on main"
    exit 0
fi

cd "$FLEET_ROOT"
if git rev-parse --abbrev-ref HEAD >/dev/null 2>&1; then
    git fetch origin main || true
    branch="$(git rev-parse --abbrev-ref HEAD)"
    if [[ "$branch" == "main" && -z "$(git status --porcelain)" ]]; then
        git merge --ff-only origin/main || true
    fi
fi

set +e
"$FLEET_ROOT/scripts/shared/map-auto-update.sh"
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
    echo "map-auto-update failed with status $status"
    if command -v gh >/dev/null 2>&1; then
        TITLE="map-auto-update failed on mini ($STAMP)"
        BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/osrs-map-auto-update-issue.XXXXXX")"
        {
            echo "Weekly map-auto-update failed on mini."
            echo
            echo "- log: \`$LOG\`"
            echo "- exit status: \`$status\`"
            echo "- time: \`$STAMP\`"
            echo
            echo "Tail of the log:"
            echo '```'
            tail -n 80 "$LOG"
            echo '```'
        } > "$BODY_FILE"
        EXISTING="$(gh issue list --repo omiyawaki/osrswiki-fleet --search "map-auto-update failed" --state open --json number --jq '.[0].number // empty' || true)"
        if [[ -n "$EXISTING" ]]; then
            gh issue comment "$EXISTING" --repo omiyawaki/osrswiki-fleet --body-file "$BODY_FILE" || true
        else
            gh issue create --repo omiyawaki/osrswiki-fleet --title "$TITLE" --body-file "$BODY_FILE" || true
        fi
        rm -f "$BODY_FILE"
    fi
    exit "$status"
fi

echo "map-auto-update launchd finished ok"
exit 0
