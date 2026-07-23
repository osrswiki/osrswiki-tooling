#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"

SIMULATOR_ID="${IOS_SIMULATOR_UDID:-}"
EVIDENCE_ROOT=""
BUNDLE_ID="omiyawaki.osrswiki"

usage() {
  cat <<'USAGE'
Usage: scripts/ios/generate-settings-preview-assets.sh [--simulator UDID] [--evidence-root DIR]

Runs the iOS XCTest app-rendering exporter on a simulator, then writes static
settings preview image resources for iOS and Android from the exported source PNGs.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --simulator)
      SIMULATOR_ID="$2"
      shift 2
      ;;
    --evidence-root)
      EVIDENCE_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$SIMULATOR_ID" ]]; then
  if ! ios_select_simulator; then
    echo "No leased or explicit iOS simulator found. Run setup-session-simulator.sh, source .ios-env, or pass --simulator UDID." >&2
    exit 1
  fi
  SIMULATOR_ID="$IOS_SIMULATOR_UDID"
fi

if ! ios_simulator_exists "$SIMULATOR_ID"; then
  echo "Selected iOS simulator is not available: $SIMULATOR_ID" >&2
  exit 1
fi

cd "$ROOT_DIR"

if [[ -z "$EVIDENCE_ROOT" ]]; then
  EVIDENCE_ROOT="$(ios_local_evidence_path settings-preview-assets)"
fi
EVIDENCE_ROOT="$(ios_validate_evidence_dir "$EVIDENCE_ROOT")"
DERIVED_DATA_PATH="$(ios_make_derived_data_path settings-preview-assets)"
mkdir -p "$EVIDENCE_ROOT" "$DERIVED_DATA_PATH"

echo "Generating app-rendered settings preview sources on simulator $SIMULATOR_ID"
EXPORT_MARKER="$ROOT_DIR/.settings-preview-export-enabled"
cleanup() {
  rm -f "$EXPORT_MARKER"
}
trap cleanup EXIT
: > "$EXPORT_MARKER"

IOS_SIMULATOR_UDID="$SIMULATOR_ID" \
  xcodebuild test \
  -project platforms/ios/osrswiki.xcodeproj \
  -scheme osrswiki \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -only-testing:osrswikiTests/SettingsPreviewAssetGenerationTest/testExportSettingsPreviewSourceImages

APP_CONTAINER="$(xcrun simctl get_app_container "$SIMULATOR_ID" "$BUNDLE_ID" data)"
EXPORT_ROOT="$APP_CONTAINER/Documents/settings_preview_exports"
RAW_ROOT="$EXPORT_ROOT/raw"

if [[ ! -d "$RAW_ROOT" ]]; then
  echo "Expected raw export directory missing: $RAW_ROOT" >&2
  exit 1
fi

POSTPROCESSOR="$ROOT_DIR/tools/settings-preview-assets/process-simulator-preview-screenshot.swift"
if [[ ! -f "$POSTPROCESSOR" ]]; then
  echo "Missing screenshot postprocessor: $POSTPROCESSOR" >&2
  exit 1
fi

TABLE_NAMES=(
  settings_preview_table_light_expanded
  settings_preview_table_light_collapsed
  settings_preview_table_dark_expanded
  settings_preview_table_dark_collapsed
)
TABLE_THEMES=(light light dark dark)
TABLE_COLLAPSED=(false true false true)

capture_table_preview_sources() {
  local ready_root="$APP_CONTAINER/Documents/settings_preview_capture_ready"
  local capture_root
  capture_root="$EVIDENCE_ROOT/assets/simulator-screenshots"

  mkdir -p "$capture_root"
  rm -rf "$ready_root"
  mkdir -p "$ready_root"

  for index in "${!TABLE_NAMES[@]}"; do
    local name="${TABLE_NAMES[$index]}"
    local theme="${TABLE_THEMES[$index]}"
    local collapsed="${TABLE_COLLAPSED[$index]}"
    local ready_file="$ready_root/$name.json"
    local screenshot_file="$capture_root/$name-full.png"
    local metadata_copy="$capture_root/$name-metadata.json"

    rm -f "$ready_file" "$screenshot_file" "$metadata_copy"

    echo "Launching app-rendered table preview capture: $name theme=$theme collapsed=$collapsed"
    xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID" \
      -settingsPreviewExport table \
      -settingsPreviewExportName "$name" \
      -settingsPreviewExportTheme "$theme" \
      -settingsPreviewExportCollapsed "$collapsed" \
      -disableBackgroundPreloading

    local ready=false
    for _ in {1..100}; do
      if [[ -f "$ready_file" ]]; then
        ready=true
        break
      fi
      sleep 0.25
    done

    if [[ "$ready" != true ]]; then
      echo "Timed out waiting for settings preview capture metadata: $ready_file" >&2
      exit 1
    fi

    sleep 0.3
    xcrun simctl io "$SIMULATOR_ID" screenshot "$screenshot_file" >/dev/null
    cp "$ready_file" "$metadata_copy"

    swift "$POSTPROCESSOR" \
      --input "$screenshot_file" \
      --metadata "$ready_file" \
      --output "$RAW_ROOT/$name.png" \
      --width 328 \
      --height 480
  done

  xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

capture_table_preview_sources

IOS_ASSET_ROOT="$ROOT_DIR/platforms/ios/osrswiki/Assets.xcassets"
ANDROID_RES_ROOT="$ROOT_DIR/platforms/android/app/src/main/res"

ASSET_NAMES=(
  settings_preview_theme_light
  settings_preview_theme_dark
  settings_preview_theme_auto
  settings_preview_table_light_expanded
  settings_preview_table_light_collapsed
  settings_preview_table_dark_expanded
  settings_preview_table_dark_collapsed
)

resize_png() {
  local input="$1"
  local output="$2"
  local width="$3"
  local height="$4"

  mkdir -p "$(dirname "$output")"
  sips -s format png -z "$height" "$width" "$input" --out "$output" >/dev/null
}

write_ios_contents_json() {
  local imageset="$1"
  local name="$2"

  cat > "$imageset/Contents.json" <<JSON
{
  "images" : [
    {
      "filename" : "$name.png",
      "idiom" : "universal",
      "scale" : "1x"
    },
    {
      "filename" : "$name@2x.png",
      "idiom" : "universal",
      "scale" : "2x"
    },
    {
      "filename" : "$name@3x.png",
      "idiom" : "universal",
      "scale" : "3x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
}

for name in "${ASSET_NAMES[@]}"; do
  source="$RAW_ROOT/$name.png"
  if [[ ! -f "$source" ]]; then
    echo "Missing exported source image: $source" >&2
    exit 1
  fi

  imageset="$IOS_ASSET_ROOT/$name.imageset"
  mkdir -p "$imageset"
  resize_png "$source" "$imageset/$name.png" 82 120
  resize_png "$source" "$imageset/$name@2x.png" 164 240
  resize_png "$source" "$imageset/$name@3x.png" 246 360
  write_ios_contents_json "$imageset" "$name"

  resize_png "$source" "$ANDROID_RES_ROOT/drawable-mdpi/$name.png" 82 120
  resize_png "$source" "$ANDROID_RES_ROOT/drawable-hdpi/$name.png" 123 180
  resize_png "$source" "$ANDROID_RES_ROOT/drawable-xhdpi/$name.png" 164 240
  resize_png "$source" "$ANDROID_RES_ROOT/drawable-xxhdpi/$name.png" 246 360
  resize_png "$source" "$ANDROID_RES_ROOT/drawable-xxxhdpi/$name.png" 328 480
done

if [[ -n "$EVIDENCE_ROOT" ]]; then
  mkdir -p "$EVIDENCE_ROOT/assets/raw"
  ditto "$RAW_ROOT" "$EVIDENCE_ROOT/assets/raw"
  cp "$EXPORT_ROOT/manifest.json" "$EVIDENCE_ROOT/assets/export-manifest.json"
  {
    echo "Generated settings preview asset dimensions"
    echo
    find "$IOS_ASSET_ROOT" "$ANDROID_RES_ROOT" -path '*settings_preview_*.png' -type f | sort | while read -r file; do
      printf '%s ' "${file#$ROOT_DIR/}"
      sips -g pixelWidth -g pixelHeight "$file" 2>/dev/null | awk '/pixel/ { printf "%s=%s ", $1, $2 } END { print "" }'
    done
  } > "$EVIDENCE_ROOT/asset-dimensions.txt"
fi

echo "Generated app-rendered settings preview assets from simulator export:"
echo "  source: $RAW_ROOT"
echo "  iOS:    $IOS_ASSET_ROOT/settings_preview_*.imageset"
echo "  Android:$ANDROID_RES_ROOT/drawable-*/settings_preview_*.png"
