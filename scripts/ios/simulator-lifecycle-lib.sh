#!/bin/bash

if [[ -n "${OSRS_IOS_SIMULATOR_LIFECYCLE_LIB_SOURCED:-}" ]]; then
    return 0
fi
OSRS_IOS_SIMULATOR_LIFECYCLE_LIB_SOURCED=1

OSRS_IOS_LIFECYCLE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSRS_IOS_LIFECYCLE_REPO_ROOT="$(cd "$OSRS_IOS_LIFECYCLE_SCRIPT_DIR/../.." && pwd)"

OSRS_IOS_ENV_FILE="${OSRS_IOS_ENV_FILE:-$OSRS_IOS_LIFECYCLE_REPO_ROOT/.ios-env}"
OSRS_IOS_LEASE_FILE="${OSRS_IOS_LEASE_FILE:-$OSRS_IOS_LIFECYCLE_REPO_ROOT/.simulator-lease.json}"
OSRS_IOS_LEGACY_ENV_FILE="${OSRS_IOS_LEGACY_ENV_FILE:-$OSRS_IOS_LIFECYCLE_REPO_ROOT/.claude-env}"
OSRS_IOS_LEGACY_SESSION_FILE="${OSRS_IOS_LEGACY_SESSION_FILE:-$OSRS_IOS_LIFECYCLE_REPO_ROOT/.claude-session-simulator}"
OSRS_IOS_LEGACY_UDID_FILE="${OSRS_IOS_LEGACY_UDID_FILE:-$OSRS_IOS_LIFECYCLE_REPO_ROOT/.claude-simulator-udid}"
OSRS_IOS_LEGACY_NAME_FILE="${OSRS_IOS_LEGACY_NAME_FILE:-$OSRS_IOS_LIFECYCLE_REPO_ROOT/.claude-simulator-name}"
OSRS_IOS_LEGACY_BUNDLE_FILE="${OSRS_IOS_LEGACY_BUNDLE_FILE:-$OSRS_IOS_LIFECYCLE_REPO_ROOT/.claude-bundle-id}"
OSRS_IOS_SIMULATOR_LEASE_MINUTES="${OSRS_IOS_SIMULATOR_LEASE_MINUTES:-120}"

ios_lifecycle_python() {
    command -v python3 >/dev/null 2>&1
}

ios_lifecycle_helper_path() {
    local candidate
    local candidates=()

    if [[ -n "${IOS_SIMULATOR_LIFECYCLE_HELPER:-}" ]]; then
        candidates+=("$IOS_SIMULATOR_LIFECYCLE_HELPER")
    fi
    if [[ -n "${CODEX_HOME:-}" ]]; then
        candidates+=("$CODEX_HOME/hooks/ios_simulator_lifecycle.py")
    fi
    candidates+=("$HOME/.codex/hooks/ios_simulator_lifecycle.py")

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

ios_lifecycle_command() {
    local helper
    if ! helper="$(ios_lifecycle_helper_path)"; then
        echo "iOS simulator lifecycle helper not found. Set IOS_SIMULATOR_LIFECYCLE_HELPER or install agent-recipes hooks." >&2
        return 2
    fi
    if ! ios_lifecycle_python; then
        echo "python3 is required to run the iOS simulator lifecycle helper." >&2
        return 2
    fi
    python3 "$helper" "$@"
}

ios_json_value() {
    local field="$1"
    python3 -c '
import json
import sys

field = sys.argv[1]
try:
    value = json.load(sys.stdin)
except Exception:
    sys.exit(1)

for part in field.split("."):
    if not isinstance(value, dict) or part not in value:
        sys.exit(1)
    value = value[part]

if value is None:
    sys.exit(1)
print(value)
' "$field"
}

ios_lifecycle_project_name() {
    printf '%s\n' "${OSRS_IOS_SIMULATOR_PROJECT:-osrswiki}"
}

ios_lifecycle_thread_id() {
    if [[ -n "${OSRS_IOS_SIMULATOR_THREAD_ID:-}" ]]; then
        printf '%s\n' "$OSRS_IOS_SIMULATOR_THREAD_ID"
        return 0
    fi
    if [[ -n "${CODEX_THREAD_ID:-}" ]]; then
        printf '%s\n' "$CODEX_THREAD_ID"
        return 0
    fi
    if [[ -n "${CODEX_TASK_ID:-}" ]]; then
        printf '%s\n' "$CODEX_TASK_ID"
        return 0
    fi

    git -C "$OSRS_IOS_LIFECYCLE_REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null ||
        basename "$OSRS_IOS_LIFECYCLE_REPO_ROOT"
}

ios_lifecycle_session_id() {
    printf '%s\n' "${OSRS_IOS_SIMULATOR_SESSION_ID:-$(basename "$OSRS_IOS_LIFECYCLE_REPO_ROOT")}"
}

ios_lifecycle_purpose() {
    printf '%s\n' "${OSRS_IOS_SIMULATOR_PURPOSE:-ios simulator session}"
}

ios_lifecycle_owner_id() {
    if [[ -n "${OSRS_IOS_SIMULATOR_OWNER_ID:-}" ]]; then
        printf '%s\n' "$OSRS_IOS_SIMULATOR_OWNER_ID"
        return 0
    fi

    local branch
    branch="$(git -C "$OSRS_IOS_LIFECYCLE_REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    printf 'osrswiki-ios:%s:%s\n' "${branch:-unknown-branch}" "$(basename "$OSRS_IOS_LIFECYCLE_REPO_ROOT")"
}

ios_lifecycle_deterministic_name() {
    local payload
    payload="$(ios_lifecycle_command name \
        --project "$(ios_lifecycle_project_name)" \
        --thread-id "$(ios_lifecycle_thread_id)" \
        --session-id "$(ios_lifecycle_session_id)" \
        --purpose "$(ios_lifecycle_purpose)")"
    printf '%s\n' "$payload" | ios_json_value name
}

ios_write_export() {
    local file="$1"
    local name="$2"
    local value="$3"
    printf 'export %s=%q\n' "$name" "$value" >> "$file"
}

ios_write_session_env() {
    local udid="$1"
    local simulator_name="$2"
    local bundle_id="$3"
    local is_container_env="${4:-false}"
    local device_type="${5:-}"
    local ios_runtime="${6:-}"
    local owner_id="${7:-$(ios_lifecycle_owner_id)}"

    printf '%s\n' "# OSRS iOS simulator session environment" > "$OSRS_IOS_ENV_FILE"
    ios_write_export "$OSRS_IOS_ENV_FILE" IOS_SIMULATOR_UDID "$udid"
    ios_write_export "$OSRS_IOS_ENV_FILE" SIMULATOR_NAME "$simulator_name"
    ios_write_export "$OSRS_IOS_ENV_FILE" BUNDLE_ID "$bundle_id"
    ios_write_export "$OSRS_IOS_ENV_FILE" IS_CONTAINER_ENV "$is_container_env"
    ios_write_export "$OSRS_IOS_ENV_FILE" DEVICE_TYPE "$device_type"
    ios_write_export "$OSRS_IOS_ENV_FILE" IOS_RUNTIME "$ios_runtime"
    ios_write_export "$OSRS_IOS_ENV_FILE" OSRS_IOS_SIMULATOR_OWNER_ID "$owner_id"
    ios_write_export "$OSRS_IOS_ENV_FILE" OSRS_IOS_SIMULATOR_LEASE_FILE "$OSRS_IOS_LEASE_FILE"
    printf '# iOS session metadata created: %s\n' "$(date)" >> "$OSRS_IOS_ENV_FILE"
}

ios_write_session_lease_metadata() {
    local udid="$1"
    local simulator_name="$2"
    local bundle_id="$3"
    local device_type="${4:-}"
    local ios_runtime="${5:-}"
    local owner_id="${6:-$(ios_lifecycle_owner_id)}"
    local acquire_json="${7:-{}}"
    local migrated_from_legacy="${8:-false}"

    IOS_LEASE_FILE="$OSRS_IOS_LEASE_FILE" \
    IOS_LEASE_UDID="$udid" \
    IOS_LEASE_NAME="$simulator_name" \
    IOS_LEASE_BUNDLE_ID="$bundle_id" \
    IOS_LEASE_DEVICE_TYPE="$device_type" \
    IOS_LEASE_RUNTIME="$ios_runtime" \
    IOS_LEASE_OWNER_ID="$owner_id" \
    IOS_LEASE_PURPOSE="$(ios_lifecycle_purpose)" \
    IOS_LEASE_WORKTREE="$OSRS_IOS_LIFECYCLE_REPO_ROOT" \
    IOS_LEASE_MIGRATED="$migrated_from_legacy" \
    IOS_LEASE_ACQUIRE_JSON="$acquire_json" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

try:
    acquire_payload = json.loads(os.environ.get("IOS_LEASE_ACQUIRE_JSON") or "{}")
except json.JSONDecodeError:
    acquire_payload = {}

metadata = {
    "schema_version": 1,
    "metadata_format": "osrs-ios-simulator-lease",
    "udid": os.environ["IOS_LEASE_UDID"],
    "device_name": os.environ["IOS_LEASE_NAME"],
    "bundle_id": os.environ["IOS_LEASE_BUNDLE_ID"],
    "device_type": os.environ["IOS_LEASE_DEVICE_TYPE"],
    "ios_runtime": os.environ["IOS_LEASE_RUNTIME"],
    "owner_id": os.environ["IOS_LEASE_OWNER_ID"],
    "owner_kind": "codex-thread",
    "purpose": os.environ["IOS_LEASE_PURPOSE"],
    "worktree": os.environ["IOS_LEASE_WORKTREE"],
    "migrated_from_legacy": os.environ["IOS_LEASE_MIGRATED"] == "true",
    "lease": acquire_payload.get("lease") if isinstance(acquire_payload, dict) else None,
}

path = Path(os.environ["IOS_LEASE_FILE"])
path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

ios_load_from_lease_file() {
    [[ -f "$OSRS_IOS_LEASE_FILE" ]] || return 1

    local values
    values="$(IOS_LEASE_FILE="$OSRS_IOS_LEASE_FILE" python3 - <<'PY'
import json
import os
from pathlib import Path

try:
    data = json.loads(Path(os.environ["IOS_LEASE_FILE"]).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)

for key, env_name in (
    ("udid", "IOS_SIMULATOR_UDID"),
    ("device_name", "SIMULATOR_NAME"),
    ("bundle_id", "BUNDLE_ID"),
    ("owner_id", "OSRS_IOS_SIMULATOR_OWNER_ID"),
    ("device_type", "DEVICE_TYPE"),
    ("ios_runtime", "IOS_RUNTIME"),
):
    value = data.get(key) or ""
    if value:
        print(f"{env_name}={value}")
PY
)" || return 1

    while IFS='=' read -r name value; do
        case "$name" in
            IOS_SIMULATOR_UDID|SIMULATOR_NAME|BUNDLE_ID|OSRS_IOS_SIMULATOR_OWNER_ID|DEVICE_TYPE|IOS_RUNTIME)
                export "$name=$value"
                ;;
        esac
    done <<< "$values"

    [[ -n "${IOS_SIMULATOR_UDID:-}" ]]
}

ios_load_from_legacy_files() {
    if [[ -f "$OSRS_IOS_LEGACY_ENV_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$OSRS_IOS_LEGACY_ENV_FILE"
        return 0
    fi

    if [[ -f "$OSRS_IOS_LEGACY_SESSION_FILE" ]]; then
        local session_info
        session_info="$(cat "$OSRS_IOS_LEGACY_SESSION_FILE")"
        SIMULATOR_NAME="${SIMULATOR_NAME:-${session_info%%:*}}"
        IOS_SIMULATOR_UDID="${IOS_SIMULATOR_UDID:-${session_info#*:}}"
        export SIMULATOR_NAME IOS_SIMULATOR_UDID
    fi
    if [[ -z "${IOS_SIMULATOR_UDID:-}" && -f "$OSRS_IOS_LEGACY_UDID_FILE" ]]; then
        IOS_SIMULATOR_UDID="$(cat "$OSRS_IOS_LEGACY_UDID_FILE")"
        export IOS_SIMULATOR_UDID
    fi
    if [[ -z "${SIMULATOR_NAME:-}" && -f "$OSRS_IOS_LEGACY_NAME_FILE" ]]; then
        SIMULATOR_NAME="$(cat "$OSRS_IOS_LEGACY_NAME_FILE")"
        export SIMULATOR_NAME
    fi
    if [[ -z "${BUNDLE_ID:-}" && -f "$OSRS_IOS_LEGACY_BUNDLE_FILE" ]]; then
        BUNDLE_ID="$(cat "$OSRS_IOS_LEGACY_BUNDLE_FILE")"
        export BUNDLE_ID
    fi

    [[ -n "${IOS_SIMULATOR_UDID:-}" ]]
}

ios_lifecycle_acquire() {
    local udid="$1"
    local simulator_name="$2"
    local owner_id="${3:-$(ios_lifecycle_owner_id)}"
    local purpose="${4:-$(ios_lifecycle_purpose)}"

    ios_lifecycle_command acquire \
        --udid "$udid" \
        --device-name "$simulator_name" \
        --owner-id "$owner_id" \
        --owner-kind codex-thread \
        --purpose "$purpose" \
        --worktree "$OSRS_IOS_LIFECYCLE_REPO_ROOT" \
        --lease-minutes "$OSRS_IOS_SIMULATOR_LEASE_MINUTES"
}

ios_lifecycle_heartbeat() {
    local udid="${1:-${IOS_SIMULATOR_UDID:-}}"
    local owner_id="${2:-$(ios_lifecycle_owner_id)}"
    [[ -n "$udid" ]] || return 1

    ios_lifecycle_command heartbeat \
        --udid "$udid" \
        --owner-id "$owner_id" \
        --lease-minutes "$OSRS_IOS_SIMULATOR_LEASE_MINUTES" >/dev/null
}

ios_lifecycle_release() {
    local udid="$1"
    local owner_id="${2:-$(ios_lifecycle_owner_id)}"
    local apply="${3:-true}"
    local args=(release --udid "$udid" --owner-id "$owner_id" --shutdown)
    if [[ "$apply" == "true" ]]; then
        args+=(--apply)
    fi
    ios_lifecycle_command "${args[@]}"
}

ios_migrate_legacy_session_metadata() {
    [[ -n "${IOS_SIMULATOR_UDID:-}" ]] || return 1

    local simulator_name="${SIMULATOR_NAME:-legacy-ios-simulator}"
    local bundle_id="${BUNDLE_ID:-omiyawaki.osrswiki}"
    local owner_id
    owner_id="$(ios_lifecycle_owner_id)"
    local acquire_json="{}"

    if [[ ! -f "$OSRS_IOS_LEASE_FILE" ]]; then
        acquire_json="$(ios_lifecycle_acquire "$IOS_SIMULATOR_UDID" "$simulator_name" "$owner_id" "legacy iOS simulator metadata migration" 2>/dev/null || printf '{}')"
        ios_write_session_lease_metadata "$IOS_SIMULATOR_UDID" "$simulator_name" "$bundle_id" "${DEVICE_TYPE:-}" "${IOS_RUNTIME:-}" "$owner_id" "$acquire_json" true
    fi

    if [[ ! -f "$OSRS_IOS_ENV_FILE" ]]; then
        ios_write_session_env "$IOS_SIMULATOR_UDID" "$simulator_name" "$bundle_id" "${IS_CONTAINER_ENV:-false}" "${DEVICE_TYPE:-}" "${IOS_RUNTIME:-}" "$owner_id"
    fi
}

ios_load_session_env() {
    if [[ -n "${IOS_SIMULATOR_UDID:-}" ]]; then
        return 0
    fi

    if [[ -f "$OSRS_IOS_ENV_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$OSRS_IOS_ENV_FILE"
        return 0
    fi

    if ios_load_from_lease_file; then
        return 0
    fi

    if ios_load_from_legacy_files; then
        ios_migrate_legacy_session_metadata >/dev/null 2>&1 || true
        return 0
    fi

    return 1
}

ios_simctl_device_line_for_udid() {
    local udid="$1"
    xcrun simctl list devices available | grep -F "$udid" | head -n 1 || true
}

ios_simulator_exists() {
    local udid="$1"
    [[ -n "$udid" ]] || return 1
    [[ -n "$(ios_simctl_device_line_for_udid "$udid")" ]]
}

ios_simulator_udids_by_name() {
    local expected_name="$1"
    IOS_EXPECTED_SIMULATOR_NAME="$expected_name" python3 - <<'PY'
import os
import re
import subprocess
import sys

expected = os.environ["IOS_EXPECTED_SIMULATOR_NAME"]
try:
    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
except FileNotFoundError:
    sys.exit(1)

for line in result.stdout.splitlines():
    match = re.match(r"\s*(.*?) \(([0-9A-Fa-f-]{36})\) \((Booted|Shutdown)\)", line)
    if match and match.group(1) == expected:
        print(match.group(2).upper())
PY
}

ios_resolve_unique_owned_simulator() {
    local expected_name
    if ! expected_name="$(ios_lifecycle_deterministic_name 2>/dev/null)"; then
        return 1
    fi

    local values
    values="$(IOS_EXPECTED_SIMULATOR_NAME="$expected_name" python3 - <<'PY'
import os
import re
import subprocess
import sys

expected = os.environ["IOS_EXPECTED_SIMULATOR_NAME"]
try:
    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
except FileNotFoundError:
    sys.exit(1)

matches = []
for line in result.stdout.splitlines():
    match = re.match(r"\s*(.*?) \(([0-9A-Fa-f-]{36})\) \((Booted|Shutdown)\)", line)
    if match and match.group(1) == expected:
        matches.append((match.group(2).upper(), match.group(3)))

if len(matches) != 1:
    sys.exit(1)
print(f"{matches[0][0]}\t{expected}\t{matches[0][1]}")
PY
)" || return 1

    IOS_SIMULATOR_UDID="${values%%$'\t'*}"
    local rest="${values#*$'\t'}"
    SIMULATOR_NAME="${rest%%$'\t'*}"
    export IOS_SIMULATOR_UDID SIMULATOR_NAME
}

ios_registry_path() {
    local state_dir="${AGENT_RECIPES_STATE_DIR:-$HOME/.local/state/agent-recipes}"
    printf '%s/ios-simulator-leases.json\n' "$state_dir"
}

ios_registry_has_unreleased_owner_lease() {
    local udid="$1"
    local owner_id="${2:-$(ios_lifecycle_owner_id)}"
    IOS_REGISTRY_PATH="$(ios_registry_path)" IOS_UDID="$udid" IOS_OWNER_ID="$owner_id" python3 - <<'PY'
import json
import os
import re
from pathlib import Path

def normalize(value):
    return re.sub(r"[^A-Za-z0-9_.:-]+", "-", value or "").strip("-") or "unknown-owner"

path = Path(os.environ["IOS_REGISTRY_PATH"])
try:
    registry = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)

udid = os.environ["IOS_UDID"]
owner = normalize(os.environ["IOS_OWNER_ID"])
for lease in registry.get("leases", []):
    if (
        isinstance(lease, dict)
        and lease.get("udid") == udid
        and normalize(str(lease.get("owner_id") or "")) == owner
        and lease.get("state") != "released"
    ):
        raise SystemExit(0)
raise SystemExit(1)
PY
}
