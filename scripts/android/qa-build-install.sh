#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ANDROID_DIR="$REPO_ROOT/platforms/android"
# shellcheck source=../shared/local-artifact-root.sh
source "$SCRIPT_DIR/../shared/local-artifact-root.sh"
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"
EVIDENCE_DIR="${QA_EVIDENCE_DIR:-$(osrs_new_run_artifact_path android-build-install)}"

usage() {
    cat <<'USAGE'
Usage: scripts/android/qa-build-install.sh [options]

Builds and installs the Android debug APK on the selected ADB device.

Options:
  --output-dir DIR  Evidence directory. Must be under the verified local root.
  -h, --help        Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            EVIDENCE_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

EVIDENCE_DIR="$(osrs_assert_artifact_path "$EVIDENCE_DIR")"
mkdir -p "$EVIDENCE_DIR"

if [[ -z "${ANDROID_SERIAL:-}" && -f "$REPO_ROOT/.claude-env" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.claude-env"
fi

if [[ -z "${ANDROID_SERIAL:-}" ]]; then
    echo "ANDROID_SERIAL not set" >&2
    exit 2
fi

PLAY_UNDERGROUND_DIR="$("$REPO_ROOT/scripts/shared/materialize-play-underground-assets.sh")"
echo "Play underground assets: $PLAY_UNDERGROUND_DIR"

run_gradle() {
    local log_file="$1"
    shift
    (cd "$ANDROID_DIR" && ./gradlew --no-daemon "$@" -PosrsUndergroundAssetsDir="$PLAY_UNDERGROUND_DIR") >"$log_file" 2>&1
}

is_stale_build_failure() {
    local log_file="$1"
    grep -E 'parseDebugLocalResources|NullPointerException|resource|Type .* is defined multiple times| [0-9]+\.dex| [0-9]+\.xml' "$log_file" >/dev/null
}

if run_gradle "$EVIDENCE_DIR/gradle-assemble-install.log" :app:assemblePlayDebug :app:installPlayDebug; then
    echo "Build/install succeeded. Evidence: $EVIDENCE_DIR"
    exit 0
fi

if is_stale_build_failure "$EVIDENCE_DIR/gradle-assemble-install.log"; then
    echo "Initial build/install failed with a stale build-output signature; retrying with clean."
    run_gradle "$EVIDENCE_DIR/gradle-clean-assemble-install.log" clean :app:assemblePlayDebug :app:installPlayDebug
    echo "Clean retry succeeded. Evidence: $EVIDENCE_DIR"
    exit 0
fi

echo "Build/install failed. Evidence: $EVIDENCE_DIR" >&2
exit 1
