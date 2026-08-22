#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"

EVIDENCE_DIR="${QA_EVIDENCE_DIR:-$(ios_local_evidence_path ios-donation-smoke)}"

usage() {
    cat <<'USAGE'
Usage: scripts/ios/donation-service-smoke.sh [options]

Records StoreKit/PassKit donation readiness evidence and verifies the Donate
route can be launched without starting a payment sheet.

Options:
  --output-dir DIR  Evidence directory.
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

EVIDENCE_DIR="$(ios_validate_evidence_dir "$EVIDENCE_DIR")"
mkdir -p "$EVIDENCE_DIR"
SUMMARY="$EVIDENCE_DIR/donation-smoke-summary.properties"
: > "$SUMMARY"

fact() {
    printf '%s=%s\n' "$1" "$2" | tee -a "$SUMMARY" >/dev/null
}

ios_require_macos
ios_select_simulator
ios_boot_selected_simulator
BUNDLE_ID="$(ios_resolve_bundle_id)"
export BUNDLE_ID

fact "started_utc" "$(ios_utc_now)"
fact "evidence_dir" "$EVIDENCE_DIR"
fact "ios_simulator_udid" "$IOS_SIMULATOR_UDID"
fact "bundle_id" "$BUNDLE_ID"

if grep -q 'import StoreKit' "$OSRS_IOS_DIR/osrswiki/Models/osrsStoreKitDonationGateway.swift"; then
    fact "storekit_import" "present"
else
    fact "storekit_import" "missing"
    exit 1
fi

if grep -q 'osrsStoreKitDonationGateway()' "$OSRS_IOS_DIR/osrswiki/Models/osrsDonationPaymentGateway.swift"; then
    fact "default_gateway" "storekit2"
else
    fact "default_gateway" "missing_storekit2"
    exit 1
fi

if grep -q 'donate_1_usd' "$OSRS_IOS_DIR/osrswiki/Models/osrsDonationProductIds.swift" \
    && grep -q 'donate_5_usd' "$OSRS_IOS_DIR/osrswiki/Models/osrsDonationProductIds.swift" \
    && grep -q 'donate_10_usd' "$OSRS_IOS_DIR/osrswiki/Models/osrsDonationProductIds.swift" \
    && grep -q 'donate_25_usd' "$OSRS_IOS_DIR/osrswiki/Models/osrsDonationProductIds.swift"; then
    fact "donation_product_ids" "donate_1_usd,donate_5_usd,donate_10_usd,donate_25_usd"
else
    fact "donation_product_ids" "missing"
    exit 1
fi

if grep -q 'apple-pay-donation' "$OSRS_IOS_DIR/osrswiki/Views/DonateView.swift" \
    || grep -q 'apple-pay-donation' "$OSRS_IOS_DIR/osrswiki/Models/osrsDonationManager.swift"; then
    fact "synthetic_apple_pay_product_id" "present"
    exit 1
else
    fact "synthetic_apple_pay_product_id" "removed"
fi

if grep -q 'import PassKit' "$OSRS_IOS_DIR/osrswiki/Views/DonateView.swift"; then
    fact "passkit_import" "present"
else
    fact "passkit_import" "absent_direct_payment_disabled"
fi

if grep -q 'merchant.com.omiyawaki.osrswiki' "$OSRS_IOS_DIR/osrswiki/Views/DonateView.swift"; then
    fact "merchant_identifier_reference" "present"
else
    fact "merchant_identifier_reference" "missing_direct_merchant_removed"
fi

if grep -q 'osrsUnavailableDonationGateway' "$OSRS_IOS_DIR/osrswiki/Models/osrsDonationPaymentGateway.swift"; then
    fact "unavailable_stub" "retained_for_tests_and_launch_argument"
else
    fact "unavailable_stub" "missing"
fi

if grep -q 'contact.omiyawaki@gmail.com' "$OSRS_IOS_DIR/osrswiki/Models/osrsStoreKitDonationGateway.swift"; then
    fact "sandbox_account_documented" "present"
else
    fact "sandbox_account_documented" "missing"
fi

if grep -q 'merchant.com.omiyawaki.osrswiki' "$OSRS_IOS_DIR/osrswiki/osrswiki.entitlements"; then
    fact "entitlements_merchant_identifier" "present"
else
    fact "entitlements_merchant_identifier" "missing"
fi

if grep -q 'CODE_SIGN_ENTITLEMENTS' "$OSRS_IOS_DIR/osrswiki.xcodeproj/project.pbxproj"; then
    fact "project_code_sign_entitlements" "present"
else
    fact "project_code_sign_entitlements" "missing"
fi

if xcrun simctl get_app_container "$IOS_SIMULATOR_UDID" "$BUNDLE_ID" app >/dev/null 2>&1; then
    xcrun simctl terminate "$IOS_SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    ios_run_capture "$EVIDENCE_DIR/donate-launch.log" \
        xcrun simctl launch "$IOS_SIMULATOR_UDID" "$BUNDLE_ID" \
            -disableBackgroundPreloading \
            -screenshotMode \
            -startTab more \
            -startMoreDestination donate || true
    sleep 3
    xcrun simctl io "$IOS_SIMULATOR_UDID" screenshot "$EVIDENCE_DIR/donate-route.png" >/dev/null 2>&1 || true
    fact "donate_route_launch" "attempted"
else
    fact "donate_route_launch" "skipped_app_not_installed"
fi

fact "finished_utc" "$(ios_utc_now)"
echo "iOS donation service smoke complete. Evidence: $EVIDENCE_DIR"
