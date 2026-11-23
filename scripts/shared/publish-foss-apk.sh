#!/bin/bash
set -euo pipefail

# Build, preflight, and optionally upload the public FOSS APK.
# Always clones a clean osrswiki-android checkout of the requested commit.
# Applies only the F-Droid map_floors.zip prebuild (curl + sha256 + unzip -j).
# Never materializes underground assets and never passes
# -PosrsUndergroundAssetsDir / OSRS_UNDERGROUND_ASSETS_DIR.
# Assemble unsigned, then sign APK Signature Scheme v2 only.
# Upload is opt-in and is refused unless every preflight gate passes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT="$SCRIPT_DIR/foss_apk_preflight.py"
V2_SIGNER="$SCRIPT_DIR/sign_apk_v2_only.py"
PUBLIC_REMOTE="https://github.com/osrswiki/osrswiki-android.git"
PUBLIC_REPO="osrswiki/osrswiki-android"
ALLOWED_SIGNER="27bd896eeefe8f1e831d3113ddb159c637af4f76fb9ef161caceba18d57f1f43"
UNDERGROUND_ENV_NAMES=(
    OSRS_UNDERGROUND_ASSETS_DIR
    OSRS_UNDERGROUND_ASSET_SOURCE_DIR
    OSRS_UNDERGROUND_EVIDENCE_DIR
    OSRS_EXPECTED_UNDERGROUND_MANIFEST_SHA256
    OSRS_UNDERGROUND_GENERATED_DIR
)
usage() {
    cat >&2 <<'EOF'
usage:
  publish-foss-apk.sh --commit SHA --output-dir DIR [--tag vX.Y.Z] [--upload]

Build a FOSS APK from a clean public osrswiki-android checkout of SHA using
exactly the F-Droid map_floors.zip prebuild. Compare it to an independent
second clone. Sign v2-only. Refuse to upload unless every gate passes.

  --commit       Public osrswiki-android commit (tag target)
  --output-dir   Staging directory for APKs and the preflight report
  --tag          Optional tag that must already point at --commit
  --upload       Replace GitHub Releases app-foss-release.apk in place
                 (refused unless FOSS_APK_ALLOW_GITHUB_UPLOAD=1 and preflight
                 passes). Default is stage-only.

This script never uses the private monorepo, the deploy checkout, or the
host underground cache.
EOF
    exit 2
}

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        die "required command is unavailable: $1"
    fi
}

file_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

read_properties_value() {
    local file="$1"
    local key="$2"
    python3 -c '
import sys
from pathlib import Path
path = Path(sys.argv[1])
key = sys.argv[2]
for raw in path.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    name, value = line.split("=", 1)
    if name.strip() == key:
        sys.stdout.write(value.strip())
        break
' "$file" "$key"
}

block_underground_environment() {
    local name
    for name in "${UNDERGROUND_ENV_NAMES[@]}"; do
        if [[ -n "${!name:-}" ]]; then
            log "blocking $name for the FOSS assemble"
            unset "$name"
        fi
    done
    export -n "${UNDERGROUND_ENV_NAMES[@]}" 2>/dev/null || true
}

find_jbr_home() {
    local candidate
    candidate="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    if [[ -x "$candidate/bin/java" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
        printf '%s\n' "$JAVA_HOME"
        return 0
    fi
    die "Android Studio JBR JAVA_HOME is required for a FOSS assemble"
}

find_apksigner() {
    local build_tools latest
    if [[ -n "${APKSIGNER:-}" && -x "$APKSIGNER" ]]; then
        printf '%s\n' "$APKSIGNER"
        return 0
    fi
    if command -v apksigner >/dev/null 2>&1; then
        command -v apksigner
        return 0
    fi
    build_tools="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}/build-tools"
    if [[ -d "$build_tools" ]]; then
        latest="$(ls -1 "$build_tools" | sort -V | tail -n 1)"
        if [[ -x "$build_tools/$latest/apksigner" ]]; then
            printf '%s\n' "$build_tools/$latest/apksigner"
            return 0
        fi
    fi
    die "apksigner is required"
}

find_sign_python() {
    local candidate
    for candidate in \
        "${FOSS_SIGN_PYTHON:-}" \
        "$HOME/Developer/osrswiki-local-artifacts/artifacts/active/fdroid-215-release/fdroid-tools/.pixi/envs/default/bin/python" \
        python3
    do
        [[ -n "$candidate" ]] || continue
        if [[ "$candidate" == */* && ! -x "$candidate" ]]; then
            continue
        fi
        if "$candidate" -c 'from cryptography.hazmat.primitives.serialization import pkcs12' >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    die "FOSS v2-only signing needs a Python with cryptography (set FOSS_SIGN_PYTHON)"
}

find_apksigcopier() {
    local candidate
    if [[ -n "${APKSIGCOPIER:-}" && -x "$APKSIGCOPIER" ]]; then
        printf '%s\n' "$APKSIGCOPIER"
        return 0
    fi
    if command -v apksigcopier >/dev/null 2>&1; then
        command -v apksigcopier
        return 0
    fi
    for candidate in \
        "$HOME/Library/Python/3.14/bin/apksigcopier" \
        "$HOME/Developer/osrswiki-local-artifacts/artifacts/active/fdroid-215-release/fdroid-tools/.pixi/envs/default/bin/apksigcopier"
    do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    die "apksigcopier is required for the reproducible-build compare"
}

refuse_user_gradle_underground_opt_in() {
    local properties="$HOME/.gradle/gradle.properties"
    if [[ -f "$properties" ]] && grep -E 'osrsUndergroundAssetsDir|OSRS_UNDERGROUND_ASSETS_DIR' "$properties" >/dev/null 2>&1; then
        die "refusing FOSS assemble: $properties opts into underground assets"
    fi
}

clone_public_commit() {
    local destination="$1"
    local commit="$2"
    rm -rf "$destination"
    git clone --quiet "$PUBLIC_REMOTE" "$destination"
    git -C "$destination" checkout --quiet --detach "$commit"
    git -C "$destination" rev-parse HEAD | grep -qx "$commit" \
        || die "public checkout is not $commit"
    git -C "$destination" clean -fdx >/dev/null
}

apply_fdroid_map_prebuild() {
    local tree="$1"
    local zip_file="$2"
    local assets="$tree/app/src/main/assets"
    mkdir -p "$assets"
    unzip -o -j "$zip_file" -d "$assets" >/dev/null
    [[ -f "$assets/map_floor_0.mbtiles" ]] || die "F-Droid prebuild did not unpack map_floor_0.mbtiles"
    if [[ -e "$assets/assets" ]]; then
        die "refusing tree with $assets/assets after the F-Droid prebuild"
    fi
    if [[ -e "$assets/underground-realms.json" ]]; then
        die "refusing tree with $assets/underground-realms.json after the F-Droid prebuild"
    fi
}

write_sdk_local_properties() {
    local tree="$1"
    local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
    [[ -d "$sdk" ]] || die "Android SDK not found"
    printf 'sdk.dir=%s\n' "$sdk" > "$tree/local.properties"
}

assemble_unsigned_foss() {
    local tree="$1"
    local missing_signing="$2"
    local jbr="$3"
    local log_file="$4"
    write_sdk_local_properties "$tree"
    (
        cd "$tree"
        env -u OSRSWIKI_ANDROID_KEYSTORE \
            -u OSRSWIKI_ANDROID_KEYSTORE_PASSWORD \
            -u OSRSWIKI_ANDROID_KEY_ALIAS \
            -u OSRSWIKI_ANDROID_KEY_PASSWORD \
            -u OSRS_UNDERGROUND_ASSETS_DIR \
            -u OSRS_UNDERGROUND_ASSET_SOURCE_DIR \
            -u OSRS_UNDERGROUND_EVIDENCE_DIR \
            -u OSRS_EXPECTED_UNDERGROUND_MANIFEST_SHA256 \
            -u OSRS_UNDERGROUND_GENERATED_DIR \
            JAVA_HOME="$jbr" \
            OSRSWIKI_ANDROID_SIGNING_PROPERTIES="$missing_signing" \
            ./gradlew --no-daemon --console=plain :app:assembleFossRelease
    ) >"$log_file" 2>&1
}

sign_v2_only() {
    local unsigned_apk="$1"
    local signed_apk="$2"
    local sign_python="$3"
    local properties="$4"
    OSRSWIKI_ANDROID_SIGNING_PROPERTIES="$properties" \
        "$sign_python" "$V2_SIGNER" "$unsigned_apk" "$signed_apk"
}

COMMIT=""
OUTPUT_DIR=""
TAG=""
UPLOAD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --commit)
            COMMIT="${2:-}"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2:-}"
            shift 2
            ;;
        --tag)
            TAG="${2:-}"
            shift 2
            ;;
        --upload)
            UPLOAD=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

[[ -n "$COMMIT" && -n "$OUTPUT_DIR" ]] || usage
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "commit must be a 40-character SHA: $COMMIT"
[[ "$OUTPUT_DIR" == /* ]] || die "output-dir must be absolute: $OUTPUT_DIR"
case "$OUTPUT_DIR" in
    "$HOME/Developer/osrswiki-local-artifacts"/*) ;;
    *)
        die "output-dir must stay under ~/Developer/osrswiki-local-artifacts: $OUTPUT_DIR"
        ;;
esac

require_command git
require_command curl
require_command jq
require_command unzip
require_command python3
[[ -f "$PREFLIGHT" ]] || die "missing $PREFLIGHT"
[[ -f "$V2_SIGNER" ]] || die "missing $V2_SIGNER"

block_underground_environment
refuse_user_gradle_underground_opt_in

JBR_HOME="$(find_jbr_home)"
APKSIGNER="$(find_apksigner)"
SIGN_PYTHON="$(find_sign_python)"
APKSIGCOPIER="$(find_apksigcopier)"
SIGNING_PROPERTIES="${OSRSWIKI_FOSS_SIGNING_PROPERTIES:-$HOME/.config/osrswiki/android-signing.properties}"
[[ -f "$SIGNING_PROPERTIES" ]] || die "signing properties are missing: $SIGNING_PROPERTIES"

mkdir -p "$OUTPUT_DIR"
BUILD_ROOT="$OUTPUT_DIR/build"
mkdir -p "$BUILD_ROOT"
MISSING_SIGNING="$BUILD_ROOT/missing-signing.properties"
rm -f "$MISSING_SIGNING"
CLONE_A="$BUILD_ROOT/osrswiki-android-a"
CLONE_B="$BUILD_ROOT/osrswiki-android-b"
ZIP_FILE="$BUILD_ROOT/map_floors.zip"
ASSEMBLE_A_LOG="$BUILD_ROOT/assemble-a.log"
ASSEMBLE_B_LOG="$BUILD_ROOT/assemble-b.log"

log "cloning public osrswiki-android at $COMMIT"
clone_public_commit "$CLONE_A" "$COMMIT"
if [[ -n "$TAG" ]]; then
    remote_tag="$(git ls-remote --tags "$PUBLIC_REMOTE" "refs/tags/$TAG^{}" | awk '{print $1}')"
    if [[ -z "$remote_tag" ]]; then
        remote_tag="$(git ls-remote --tags "$PUBLIC_REMOTE" "refs/tags/$TAG" | awk '{print $1}')"
    fi
    [[ "$remote_tag" == "$COMMIT" ]] || die "tag $TAG points at ${remote_tag:-missing}, not $COMMIT"
fi

PYTHONPATH="$SCRIPT_DIR" python3 - "$CLONE_A" <<'PY'
import sys
from pathlib import Path
from foss_apk_preflight import check_source_tree
errors = check_source_tree(Path(sys.argv[1]))
if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY

MANIFEST="$CLONE_A/map-assets-manifest.json"
[[ -f "$MANIFEST" ]] || die "public tree is missing map-assets-manifest.json"
BUNDLE_NAME="$(jq -r '.bundle.name' "$MANIFEST")"
BUNDLE_SHA="$(jq -r '.bundle.sha256' "$MANIFEST")"
RELEASE_TAG="$(jq -r '.release_tag' "$MANIFEST")"
REPOSITORY="$(jq -r '.repository' "$MANIFEST")"
[[ "$BUNDLE_NAME" == "map_floors.zip" ]] || die "unexpected map bundle name: $BUNDLE_NAME"
DOWNLOAD_URL="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/$BUNDLE_NAME"
log "F-Droid prebuild $DOWNLOAD_URL"
curl --fail --location --retry 3 --retry-all-errors --output "$ZIP_FILE" "$DOWNLOAD_URL"
ACTUAL_SHA="$(file_sha256 "$ZIP_FILE")"
[[ "$ACTUAL_SHA" == "$BUNDLE_SHA" ]] || die "map_floors.zip sha256 mismatch: expected $BUNDLE_SHA got $ACTUAL_SHA"

apply_fdroid_map_prebuild "$CLONE_A" "$ZIP_FILE"
rm -rf "$CLONE_B"
git clone --quiet --no-local "$CLONE_A" "$CLONE_B"
git -C "$CLONE_B" checkout --quiet --detach "$COMMIT"
git -C "$CLONE_B" clean -fdx >/dev/null
apply_fdroid_map_prebuild "$CLONE_B" "$ZIP_FILE"
PYTHONPATH="$SCRIPT_DIR" python3 - "$CLONE_A" "$CLONE_B" <<'PY'
import sys
from pathlib import Path
from foss_apk_preflight import check_source_tree
for tree in sys.argv[1:]:
    errors = check_source_tree(Path(tree))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        raise SystemExit(1)
PY

log "assemble unsigned FOSS (clone A)"
assemble_unsigned_foss "$CLONE_A" "$MISSING_SIGNING" "$JBR_HOME" "$ASSEMBLE_A_LOG"
log "assemble unsigned FOSS (clone B, independent rebuild)"
assemble_unsigned_foss "$CLONE_B" "$MISSING_SIGNING" "$JBR_HOME" "$ASSEMBLE_B_LOG"

UNSIGNED_A="$CLONE_A/app/build/outputs/apk/foss/release/app-foss-release-unsigned.apk"
UNSIGNED_B="$CLONE_B/app/build/outputs/apk/foss/release/app-foss-release-unsigned.apk"
[[ -f "$UNSIGNED_A" && -f "$UNSIGNED_B" ]] || die "unsigned FOSS APKs were not produced"

cp "$UNSIGNED_A" "$OUTPUT_DIR/app-foss-release-unsigned.apk"
cp "$UNSIGNED_B" "$OUTPUT_DIR/app-foss-release-unsigned-rebuild.apk"
cp "$ASSEMBLE_A_LOG" "$OUTPUT_DIR/assemble-a.log"
cp "$ASSEMBLE_B_LOG" "$OUTPUT_DIR/assemble-b.log"
SIGNED_APK="$OUTPUT_DIR/app-foss-release.apk"
log "signing v2-only with $V2_SIGNER"
sign_v2_only "$OUTPUT_DIR/app-foss-release-unsigned.apk" "$SIGNED_APK" "$SIGN_PYTHON" "$SIGNING_PROPERTIES"

REPORT="$OUTPUT_DIR/preflight-report.txt"
log "running FOSS preflight"
set +e
PYTHONPATH="$SCRIPT_DIR" python3 "$PREFLIGHT" \
    --apk "$SIGNED_APK" \
    --unsigned-apk "$OUTPUT_DIR/app-foss-release-unsigned.apk" \
    --reference-unsigned-apk "$OUTPUT_DIR/app-foss-release-unsigned-rebuild.apk" \
    --source-tree "$CLONE_A" \
    --apksigner "$APKSIGNER" \
    --apksigcopier "$APKSIGCOPIER" \
    --report "$REPORT"
PREFLIGHT_STATUS=$?
set -e
cat "$REPORT"
[[ "$PREFLIGHT_STATUS" -eq 0 ]] || die "FOSS preflight failed; refusing to upload"

ASSETS_LISTING="$OUTPUT_DIR/assets-listing.txt"
python3 - "$SIGNED_APK" "$ASSETS_LISTING" <<'PY'
import sys
import zipfile
from pathlib import Path
apk = Path(sys.argv[1])
out = Path(sys.argv[2])
with zipfile.ZipFile(apk) as archive:
    names = sorted(name for name in archive.namelist() if name.startswith("assets/"))
leaked = [name for name in names if name == "assets/assets" or name.startswith("assets/assets/")]
lines = [f"apk={apk}", f"assets_count={len(names)}", f"assets_assets_count={len(leaked)}"]
lines.extend(names)
out.write_text("\n".join(lines) + "\n", encoding="utf-8")
if leaked:
    raise SystemExit("assets listing still contains assets/assets/")
PY

if [[ "$UPLOAD" -eq 1 ]]; then
    if [[ "${FOSS_APK_ALLOW_GITHUB_UPLOAD:-}" != "1" ]]; then
        die "refusing --upload without FOSS_APK_ALLOW_GITHUB_UPLOAD=1"
    fi
    [[ -n "$TAG" ]] || die "--upload requires --tag"
    require_command gh
    log "uploading $SIGNED_APK to $PUBLIC_REPO $TAG"
    gh release upload "$TAG" "$SIGNED_APK" --repo "$PUBLIC_REPO" --clobber
else
    log "staged only (no GitHub upload). Replace in place with:"
    log "gh release upload ${TAG:-vVERSION} $SIGNED_APK --repo $PUBLIC_REPO --clobber"
fi

log "pruning public clones and Gradle build trees"
rm -rf "$CLONE_A" "$CLONE_B" "$ZIP_FILE"
log "FOSS APK staged at $SIGNED_APK"
log "preflight report: $REPORT"
log "allowed signer $ALLOWED_SIGNER"
