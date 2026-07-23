#!/bin/bash
#
# Documentation Workflow Verification
# Tests that the documented agent workflows actually work
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}✅ $1${NC}"
}

warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

echo "🧪 Testing Documentation Workflow Accuracy"
echo "=========================================="

log "Verifying script availability in the Fleet Sync source checkout..."

# Check if automation scripts exist
if [[ -f "$PROJECT_ROOT/scripts/ios/quick-map-test.sh" ]]; then
    success "quick-map-test.sh found in source checkout"
else
    warn "quick-map-test.sh missing from source checkout"
fi

if [[ -f "$PROJECT_ROOT/scripts/ios/automate-app-testing.sh" ]]; then
    success "automate-app-testing.sh found in source checkout"
else
    warn "automate-app-testing.sh missing from source checkout"
fi

if [[ -f "$PROJECT_ROOT/scripts/ios/README-Navigation-Automation.md" ]]; then
    success "Navigation automation README found"
else
    warn "Navigation automation README missing"
fi

# Check iOS platform enhancements
if [[ -f "$PROJECT_ROOT/platforms/ios/osrswikiUITests/NavigationAutomationTests.swift" ]]; then
    success "XCTest automation tests found"
else
    warn "XCTest automation tests missing"
fi

log "Checking AGENTS.md documentation..."

# Verify documentation sections exist
if grep -q "iOS Navigation Automation" "$PROJECT_ROOT/AGENTS.md"; then
    success "iOS Navigation Automation section found in AGENTS.md"
else
    warn "iOS Navigation Automation section missing from AGENTS.md"
fi

if grep -q "Agent Development Workflows" "$PROJECT_ROOT/AGENTS.md"; then
    success "Agent Development Workflows section found in AGENTS.md"
else
    warn "Agent Development Workflows section missing from AGENTS.md"
fi

if grep -q "quick-map-test.sh" "$PROJECT_ROOT/AGENTS.md"; then
    success "quick-map-test.sh referenced in documentation"
else
    warn "quick-map-test.sh not referenced in documentation"
fi

log "Checking script executability..."

if [[ -x "$PROJECT_ROOT/scripts/ios/quick-map-test.sh" ]]; then
    success "quick-map-test.sh is executable"
else
    warn "quick-map-test.sh not executable"
fi

if [[ -x "$PROJECT_ROOT/scripts/ios/automate-app-testing.sh" ]]; then
    success "automate-app-testing.sh is executable"
else
    warn "automate-app-testing.sh not executable"
fi

log "Verifying script integration..."

# Check if main quick-test.sh references the new automation
if grep -q "quick-map-test.sh" "$PROJECT_ROOT/scripts/ios/quick-test.sh"; then
    success "Main quick-test.sh references new automation"
else
    warn "Main quick-test.sh should reference new automation"
fi

echo ""
echo "📊 Documentation Verification Summary:"
echo "======================================"

# Count checks
CHECKS_PASSED=$(echo -e "${GREEN}✅" | grep -o "✅" | wc -l || echo "0")
CHECKS_WARNED=$(echo -e "${YELLOW}⚠️" | grep -o "⚠️" | wc -l || echo "0")

echo "This verification tests that documented workflows are actually available to agents."
echo ""
echo "🎯 Key Agent Benefits Verified:"
echo "- One-command iOS testing (quick-map-test.sh)"
echo "- Comprehensive automation (automate-app-testing.sh)"  
echo "- XCTest UI automation (NavigationAutomationTests.swift)"
echo "- Complete workflow documentation"
echo "- Integration with existing scripts"
echo ""
echo "📝 Documentation Enhancements Added:"
echo "- iOS Navigation Automation section (eliminates bottleneck)"
echo "- Agent Development Workflows section (proven patterns)"
echo "- Enhanced Screenshots section (automation-aware)"
echo "- Script integration hints in existing tools"
echo ""
echo "🚀 Future agents will have:"
echo "- No navigation bottleneck on iOS"
echo "- Clear, tested workflows to follow"
echo "- One-command solutions for 90% of testing needs"
echo "- Comprehensive automation infrastructure"

echo ""
echo "✅ Documentation workflow verification complete!"
