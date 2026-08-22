#!/bin/bash
set -euo pipefail

# Deploy internally: Android to Google Play internal testing and iOS to TestFlight.
# This command builds from the current monorepo checkout. It does not publish git
# history or mutate separate deployment repositories.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INTERNAL_DEPLOY_DIR="$REPO_ROOT/scripts/internal-deploy"

# shellcheck disable=SC1091
source "$INTERNAL_DEPLOY_DIR/common.sh"
# shellcheck disable=SC1091
source "$INTERNAL_DEPLOY_DIR/maplibre-dsym.sh"

usage() {
    cat <<'EOF'
Usage:
  scripts/shared/deploy-internal.sh [--android] [--ios] [--dry-run] [--validate-only] [--no-bump] --bump-marketing MODE [--evidence-dir PATH]

Targets:
  --android        Package and upload Android to Google Play internal testing,
                   then assign the same versionCode to Closed testing Alpha.
  --ios            Archive and upload iOS to TestFlight.
  no platform flag Deploy both Android and iOS.

Safety:
  --dry-run        Print build/upload commands and validate local configuration without uploading.
                   With --dry-run, --bump-marketing is optional (defaults to none for preview).
  --validate-only  Validate tools, paths, and credential file presence only.
                   With --validate-only, --bump-marketing is optional (defaults to none).
  --no-bump        Reuse current Android versionCode and iOS build number.
                   Marketing version still requires explicit --bump-marketing.
  --bump-marketing MODE
                   REQUIRED for real deploys. Bump marketing version: patch, minor, major, or none.
                   Optional for --dry-run and --validate-only (defaults to none when omitted).
  --evidence-dir   Override the verified machine-local evidence path.

Local env:
  OSRSWIKI_INTERNAL_DEPLOY_ENV=/path/to/internal-deploy.env
  Default env search: scripts/internal-deploy/.env, ~/.config/osrswiki/internal-deploy.env, then ~/.config/osrswiki/beta.env.
EOF
}

RUN_ANDROID=false
RUN_IOS=false
DRY_RUN=false
VALIDATE_ONLY=false
NO_BUMP=false
BUMP_MARKETING=""
BUMP_MARKETING_EXPLICIT=false
EVIDENCE_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --android) RUN_ANDROID=true ;;
        --ios) RUN_IOS=true ;;
        --dry-run) DRY_RUN=true ;;
        --validate-only) VALIDATE_ONLY=true ;;
        --no-bump) NO_BUMP=true ;;
        --bump-marketing)
            shift
            if [[ $# -eq 0 ]]; then
                print_error "--bump-marketing requires a mode (patch|minor|major|none)"
                exit 1
            fi
            BUMP_MARKETING="$1"
            BUMP_MARKETING_EXPLICIT=true
            ;;
        --evidence-dir)
            shift
            if [[ $# -eq 0 ]]; then
                print_error "--evidence-dir requires a path"
                exit 1
            fi
            EVIDENCE_DIR="$1"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

if [[ "$RUN_ANDROID" == false && "$RUN_IOS" == false ]]; then
    RUN_ANDROID=true
    RUN_IOS=true
fi

# Require explicit marketing bump for real uploads
if [[ "$DRY_RUN" == false && "$VALIDATE_ONLY" == false && "$BUMP_MARKETING_EXPLICIT" == false ]]; then
    print_error "Real internal deploys require an explicit --bump-marketing flag (patch|minor|major|none)"
    exit 1
fi

# Default to none for dry-run and validate-only when not explicit
if [[ "$BUMP_MARKETING_EXPLICIT" == false ]]; then
    BUMP_MARKETING="none"
fi

load_internal_deploy_env

print_header "OSRS Wiki internal deployment"
echo "Android target: Google Play internal testing, then Closed testing Alpha"
echo "iOS target: TestFlight"
echo "Repo: $REPO_ROOT"
echo "Dry run: $DRY_RUN"
echo "Validate only: $VALIDATE_ONLY"
echo ""

validation_failed=false

mark_failed() {
    validation_failed=true
}

validate_repo() {
    print_phase "Repository validation"
    if [[ ! -d "$REPO_ROOT/.git" && ! -f "$REPO_ROOT/.git" ]]; then
        print_error "Not running from a git checkout: $REPO_ROOT"
        mark_failed
    fi
    if [[ ! -f "$REPO_ROOT/AGENTS.md" ]]; then
        print_error "AGENTS.md not found at repo root"
        mark_failed
    fi
    if [[ "$DRY_RUN" == false && "$VALIDATE_ONLY" == false ]]; then
        if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
            print_error "Working tree must be clean before a real internal deploy"
            mark_failed
        fi
    fi
    if git -C "$REPO_ROOT" remote 2>/dev/null | grep -Eq '^(android|ios|tooling)$'; then
        print_error "Platform deployment remotes must not be attached to this checkout"
        mark_failed
    fi
}

validate_android() {
    print_phase "Android validation"
    if [[ ! -d "$ANDROID_PLATFORM_DIR" ]]; then
        print_error "Android platform directory missing: $ANDROID_PLATFORM_DIR"
        mark_failed
        return
    fi
    if [[ ! -x "$ANDROID_PLATFORM_DIR/gradlew" ]]; then
        print_error "Android Gradle wrapper missing or not executable: $ANDROID_PLATFORM_DIR/gradlew"
        mark_failed
    fi
    if [[ ! -f "$ANDROID_BUILD_GRADLE" ]]; then
        print_error "Android app build file missing: $ANDROID_BUILD_GRADLE"
        mark_failed
    fi
    if ! android_signing_configured; then
        if [[ "$DRY_RUN" == true ]]; then
            print_warning "Android release signing is not configured; real upload will fail"
        else
            print_android_signing_setup
            mark_failed
        fi
    fi
    if ! android_play_credentials_configured; then
        if [[ "$DRY_RUN" == true ]]; then
            print_warning "PLAY_SERVICE_ACCOUNT_JSON is missing or not found; real upload will fail"
        else
            print_android_play_setup
            mark_failed
        fi
    fi
    if ! android_play_python_configured; then
        if [[ "$DRY_RUN" == true || "$VALIDATE_ONLY" == true ]]; then
            print_warning "Python Google API packages are missing for $PYTHON_BIN; real Android upload will fail"
            echo "Install google-api-python-client and google-auth, or set OSRSWIKI_INTERNAL_DEPLOY_PYTHON."
        else
            print_error "Python Google API packages are missing for $PYTHON_BIN"
            echo "Install google-api-python-client and google-auth, or set OSRSWIKI_INTERNAL_DEPLOY_PYTHON."
            mark_failed
        fi
    fi
}

validate_ios() {
    print_phase "iOS validation"
    if [[ "$(uname)" != "Darwin" ]]; then
        print_error "iOS TestFlight upload requires macOS"
        mark_failed
    fi
    if [[ ! -d "$IOS_PROJECT" ]]; then
        print_error "iOS Xcode project missing: $IOS_PROJECT"
        mark_failed
    fi
    if ! command -v xcodebuild >/dev/null 2>&1; then
        print_error "xcodebuild not found"
        mark_failed
    fi
    if ! ios_api_credentials_configured; then
        if [[ "$DRY_RUN" == true ]]; then
            print_warning "ASC_API_* credentials are missing or not found; real upload will fail"
        else
            print_ios_testflight_setup
            mark_failed
        fi
    fi
}

bump_android_version_code_if_needed() {
    local current next
    current="$(read_android_version_code)"
    if [[ "$NO_BUMP" == true ]]; then
        echo "$current"
        return
    fi
    next=$((current + 1))
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[dry-run] would bump Android versionCode $current -> $next" >&2
    else
        write_android_version_code "$next"
        print_success "Android versionCode bumped: $current -> $next" >&2
    fi
    echo "$next"
}

bump_ios_build_number_if_needed() {
    local current next
    current="$(read_ios_build_number)"
    if [[ "$NO_BUMP" == true ]]; then
        echo "$current"
        return
    fi
    next=$((current + 1))
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[dry-run] would bump iOS build number $current -> $next" >&2
    else
        write_ios_build_number "$next"
        print_success "iOS build number bumped: $current -> $next" >&2
    fi
    echo "$next"
}

bump_and_apply_marketing_version() {
    local mode="$1"
    local current new
    
    current="$(read_marketing_version_from_manifest)"
    if [[ -z "$current" ]]; then
        print_error "Could not read current marketing version from manifest"
        return 1
    fi
    
    if [[ "$mode" == "none" ]]; then
        new="$current"
    else
        new="$(bump_marketing_version "$mode")"
        if [[ -z "$new" ]]; then
            print_error "Failed to bump marketing version"
            return 1
        fi
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$mode" == "none" ]]; then
            print_info "[dry-run] would keep marketing version at $current" >&2
        else
            print_info "[dry-run] would bump marketing version $current -> $new ($mode)" >&2
        fi
        print_info "[dry-run] would write marketing $new to both Android versionName and iOS MARKETING_VERSION" >&2
    else
        if [[ "$mode" != "none" ]]; then
            write_marketing_version_to_manifest "$new"
            print_success "Marketing version bumped in manifest: $current -> $new ($mode)" >&2
        fi
        apply_marketing_version_to_platforms "$new"
        print_success "Marketing version $new applied to both platforms" >&2
    fi
    
    echo "$new"
}

deploy_android_internal() {
    print_phase "Android package and upload"
    local version_code version_name aab_path service_account_json play_track
    local -a upload_cmd
    
    version_code="$(bump_android_version_code_if_needed)"
    version_name="$(read_android_version_name)"
    
    aab_path="$ANDROID_PLATFORM_DIR/app/build/outputs/bundle/release/app-release.aab"
    service_account_json="${PLAY_SERVICE_ACCOUNT_JSON:-$CONFIG_DIR/play-service-account.json}"
    play_track="${PLAY_TRACK:-internal}"
    # Xperia testers are on Closed testing Alpha, not the internal opt-in.
    # Every internal upload must also assign that same versionCode to alpha.
    upload_cmd=(
        "$PYTHON_BIN"
        "$INTERNAL_DEPLOY_DIR/upload-android-play.py"
        --aab "$aab_path"
        --package-name "$ANDROID_PACKAGE_NAME"
        --service-account-json "$service_account_json"
        --track "$play_track"
        --version-code "$version_code"
        --evidence-dir "$EVIDENCE_DIR"
    )
    if [[ "$play_track" == "internal" ]]; then
        upload_cmd+=(--also-assign-track alpha)
    fi

    if [[ "$DRY_RUN" == true ]]; then
        print_info "[dry-run] cd $ANDROID_PLATFORM_DIR && ./gradlew --no-daemon :app:bundleRelease --console=plain"
        print_info "[dry-run] ${upload_cmd[*]} --dry-run"
    else
        (
            cd "$ANDROID_PLATFORM_DIR"
            ./gradlew --no-daemon :app:bundleRelease --console=plain
        )
        if [[ ! -f "$aab_path" ]]; then
            print_error "Expected AAB not found: $aab_path"
            exit 1
        fi
        "${upload_cmd[@]}"
    fi

    {
        echo "marketing_version=$MARKETING_VERSION"
        echo "version_code=$version_code"
        echo "version_name=$version_name"
        echo "aab_path=$aab_path"
        echo "play_track=$play_track"
        if [[ "$play_track" == "internal" ]]; then
            echo "also_assign_track=alpha"
        fi
        echo "dry_run=$DRY_RUN"
    } >"$EVIDENCE_DIR/android-summary.txt"
}

deploy_ios_internal() {
    print_phase "iOS archive and upload"
    local ios_team build_number archive_dir archive_path export_dir export_options ipa_path
    ios_team="${IOS_DEVELOPMENT_TEAM:-8M2762LWD7}"
    build_number="$(bump_ios_build_number_if_needed)"
    archive_dir="$EVIDENCE_DIR/archive"
    archive_path="$archive_dir/osrswiki.xcarchive"
    export_dir="$EVIDENCE_DIR/export"
    export_options="$INTERNAL_DEPLOY_DIR/ExportOptions.plist"
    ipa_path="$export_dir/osrswiki.ipa"

    mkdir -p "$archive_dir" "$export_dir"

    # Ensure xcodebuild uses macOS system rsync, not Homebrew rsync.
    # xcodebuild's IDEDistributionCreateIPAStep fails with Homebrew rsync 3.4.4.
    # Prepend /usr/bin to PATH so /usr/bin/rsync is found first.
    local safe_path="/usr/bin:/bin:/usr/sbin:/sbin"
    if [[ -n "${PATH:-}" ]]; then
        safe_path="$safe_path:$PATH"
    fi

    # Automatic signing must pick the archive identity. Forcing
    # CODE_SIGN_IDENTITY="Apple Distribution" conflicts with
    # CODE_SIGN_STYLE=Automatic and fails the archive. ExportOptions.plist
    # still requests Apple Distribution for the TestFlight upload.
    archive_cmd=(
        env PATH="$safe_path"
        xcodebuild archive
        -project "$IOS_PROJECT"
        -scheme "$IOS_SCHEME"
        -configuration Release
        -destination "generic/platform=iOS"
        -archivePath "$archive_path"
        CODE_SIGN_STYLE=Automatic
        DEVELOPMENT_TEAM="$ios_team"
        -allowProvisioningUpdates
    )

    export_cmd=(
        env PATH="$safe_path"
        xcodebuild -exportArchive
        -archivePath "$archive_path"
        -exportOptionsPlist "$export_options"
        -exportPath "$export_dir"
        -allowProvisioningUpdates
    )

    if [[ -n "${ASC_API_KEY_PATH:-}" && -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_ISSUER_ID:-}" ]]; then
        archive_cmd+=(
            -authenticationKeyPath "$ASC_API_KEY_PATH"
            -authenticationKeyID "$ASC_API_KEY_ID"
            -authenticationKeyIssuerID "$ASC_API_ISSUER_ID"
        )
        export_cmd+=(
            -authenticationKeyPath "$ASC_API_KEY_PATH"
            -authenticationKeyID "$ASC_API_KEY_ID"
            -authenticationKeyIssuerID "$ASC_API_ISSUER_ID"
        )
    fi

    if [[ "$DRY_RUN" == true ]]; then
        dry_archive_cmd=("${archive_cmd[@]}")
        dry_export_cmd=("${export_cmd[@]}")
        for i in "${!dry_archive_cmd[@]}"; do
            case "${dry_archive_cmd[$i]}" in
                "${ASC_API_KEY_PATH:-__unset_asc_api_key_path__}") dry_archive_cmd[$i]='${ASC_API_KEY_PATH}' ;;
                "${ASC_API_KEY_ID:-__unset_asc_api_key_id__}") dry_archive_cmd[$i]='${ASC_API_KEY_ID}' ;;
                "${ASC_API_ISSUER_ID:-__unset_asc_api_issuer_id__}") dry_archive_cmd[$i]='${ASC_API_ISSUER_ID}' ;;
            esac
        done
        for i in "${!dry_export_cmd[@]}"; do
            case "${dry_export_cmd[$i]}" in
                "${ASC_API_KEY_PATH:-__unset_asc_api_key_path__}") dry_export_cmd[$i]='${ASC_API_KEY_PATH}' ;;
                "${ASC_API_KEY_ID:-__unset_asc_api_key_id__}") dry_export_cmd[$i]='${ASC_API_KEY_ID}' ;;
                "${ASC_API_ISSUER_ID:-__unset_asc_api_issuer_id__}") dry_export_cmd[$i]='${ASC_API_ISSUER_ID}' ;;
            esac
        done
        print_info "[dry-run] ${dry_archive_cmd[*]}"
        maplibre_print_dsym_dry_run_plan "$archive_path" "${LOG_FILE:-}"
        print_info "[dry-run] ${dry_export_cmd[*]}"
        print_info "[dry-run] export uses destination=upload in ExportOptions.plist"
    else
        "${archive_cmd[@]}"
        if [[ ! -d "$archive_path" ]]; then
            print_error "Archive not found: $archive_path"
            exit 1
        fi
        maplibre_inject_dsym_into_archive "$archive_path" "${LOG_FILE:-}" "$EVIDENCE_DIR"
        "${export_cmd[@]}"
        print_success "Upload delegated to xcodebuild -exportArchive"
        rm -rf "$archive_dir" "$export_dir"
        print_success "Removed local iOS archive/export payloads after successful upload"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        {
            echo "bundle_id=$IOS_BUNDLE_ID"
            echo "marketing_version=$MARKETING_VERSION"
            echo "build_number=$build_number"
            echo "archive_path=$archive_path"
            echo "export_dir=$export_dir"
            echo "maplibre_dsym_injection=dry_run_after_archive_before_export"
            echo "dry_run=$DRY_RUN"
        } >"$EVIDENCE_DIR/ios-summary.txt"
    else
        {
            echo "bundle_id=$IOS_BUNDLE_ID"
            echo "marketing_version=$MARKETING_VERSION"
            echo "build_number=$build_number"
            echo "upload_mode=exportArchive-upload"
            echo "archive_path=removed_after_successful_upload"
            echo "export_dir=removed_after_successful_upload"
            echo "maplibre_dsym_manifest=$EVIDENCE_DIR/maplibre-dsym-manifest.json"
            echo "dry_run=$DRY_RUN"
        } >"$EVIDENCE_DIR/ios-summary.txt"
    fi
}

validate_repo
if [[ "$RUN_ANDROID" == true ]]; then
    validate_android
fi
if [[ "$RUN_IOS" == true ]]; then
    validate_ios
fi

if [[ "$validation_failed" == true ]]; then
    print_error "Internal deploy validation failed"
    exit 1
fi

if [[ "$VALIDATE_ONLY" == true ]]; then
    print_success "Internal deploy validation complete"
    exit 0
fi

init_evidence_dir "internal"
record_inventory_snapshot

# Bump and apply marketing version once if either platform is being deployed
if [[ "$RUN_ANDROID" == true || "$RUN_IOS" == true ]]; then
    MARKETING_VERSION="$(bump_and_apply_marketing_version "$BUMP_MARKETING")"
fi

if [[ "$RUN_ANDROID" == true ]]; then
    deploy_android_internal
fi
if [[ "$RUN_IOS" == true ]]; then
    deploy_ios_internal
fi

print_success "Internal deployment workflow finished"
echo "Evidence: $EVIDENCE_DIR"
