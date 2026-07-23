#!/bin/bash

# Coverage Gap Analysis Script
# Analyzes test coverage and identifies classes/methods that need tests
# Usage: ./analyze-coverage-gaps.sh [--detailed] [--package package.name]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ANDROID_ROOT="$PROJECT_ROOT/platforms/android"
SOURCE_DIR="$ANDROID_ROOT/app/src/main/java"
TEST_DIR="$ANDROID_ROOT/app/src/test/java"
BASE_PACKAGE="com.omiyawaki.osrswiki"

# Coverage thresholds
MINIMUM_COVERAGE=65
TARGET_COVERAGE=75
CRITICAL_COVERAGE=90

# Auto-load session environment if available
if [[ -f "$PROJECT_ROOT/.claude-env" ]]; then
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/.claude-env"
fi

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_header() {
    echo -e "${BOLD}${CYAN}$1${NC}"
}

show_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --detailed          Show detailed analysis with method-level gaps"
    echo "  --package PKG       Analyze specific package only"
    echo "  --priority          Show only high-priority gaps"
    echo "  --suggest-tests     Generate specific test suggestions"
    echo ""
    echo "Examples:"
    echo "  $0                              # Quick overview"
    echo "  $0 --detailed                   # Detailed analysis"
    echo "  $0 --package search             # Analyze search package only"
    echo "  $0 --priority --suggest-tests   # High-priority gaps with suggestions"
    exit 1
}

generate_coverage_report() {
    log_info "Generating coverage report..."
    
    cd "$ANDROID_ROOT"
    
    # Run tests (Kover tasks not available in current configuration)
    if ! ./gradlew testDebugUnitTest --quiet; then
        log_warning "Some tests failed, but continuing with analysis"
    fi
    
    # Note: Kover coverage is not configured - using basic test results
    local coverage_xml="$ANDROID_ROOT/app/build/reports/kover/report.xml"
    local coverage_html="$ANDROID_ROOT/app/build/reports/kover/html/index.html"
    
    if [[ ! -f "$coverage_xml" ]]; then
        log_warning "Kover coverage not configured. Add kover plugin to build.gradle.kts for coverage analysis."
        log_info "Analyzing test results without coverage data..."
        return 0
    fi
    
    log_success "Coverage reports generated:"
    log_info "  XML: $coverage_xml"
    log_info "  HTML: $coverage_html"
    
    echo "$coverage_xml"
}

parse_coverage_percentage() {
    local coverage_xml="$1"
    
    # Extract overall coverage percentage
    local coverage_percent
    if command -v xmllint >/dev/null 2>&1; then
        coverage_percent=$(xmllint --xpath "string(//report/counter[@type='INSTRUCTION']/@covered)" "$coverage_xml" 2>/dev/null || echo "0")
        local total_instructions
        total_instructions=$(xmllint --xpath "string(//report/counter[@type='INSTRUCTION']/@missed)" "$coverage_xml" 2>/dev/null || echo "1")
        total_instructions=$((coverage_percent + total_instructions))
        
        if [[ $total_instructions -gt 0 ]]; then
            coverage_percent=$((coverage_percent * 100 / total_instructions))
        else
            coverage_percent=0
        fi
    else
        # Fallback parsing without xmllint
        coverage_percent=$(grep -oE 'covered="[0-9]+"' "$coverage_xml" | head -1 | grep -oE '[0-9]+' || echo "0")
        local total_instructions
        total_instructions=$(grep -oE 'missed="[0-9]+"' "$coverage_xml" | head -1 | grep -oE '[0-9]+' || echo "1")
        total_instructions=$((coverage_percent + total_instructions))
        
        if [[ $total_instructions -gt 0 ]]; then
            coverage_percent=$((coverage_percent * 100 / total_instructions))
        else
            coverage_percent=0
        fi
    fi
    
    echo "$coverage_percent"
}

find_untested_classes() {
    local package_filter="${1:-}"
    
    log_info "Analyzing untested classes..."
    
    local source_files
    if [[ -n "$package_filter" ]]; then
        source_files=$(find "$SOURCE_DIR" -name "*.kt" -path "*${package_filter}*" -type f)
    else
        source_files=$(find "$SOURCE_DIR" -name "*.kt" -type f)
    fi
    
    local untested_classes=()
    local total_classes=0
    local tested_classes=0
    
    while IFS= read -r source_file; do
        if [[ -n "$source_file" ]]; then
            total_classes=$((total_classes + 1))
            
            # Extract class name and package
            local class_name
            class_name=$(basename "$source_file" .kt)
            
            local package_path
            package_path=$(dirname "$source_file")
            package_path=${package_path#$SOURCE_DIR/}
            
            # Check if test file exists
            local test_file="$TEST_DIR/${package_path}/${class_name}Test.kt"
            
            if [[ -f "$test_file" ]]; then
                tested_classes=$((tested_classes + 1))
            else
                # Skip certain files that typically don't need tests
                if [[ ! "$class_name" =~ ^(BuildConfig|R|.*Activity|.*Fragment)$ ]]; then
                    untested_classes+=("$source_file")
                fi
            fi
        fi
    done <<< "$source_files"
    
    # Calculate test coverage by file count
    local file_coverage=0
    if [[ $total_classes -gt 0 ]]; then
        file_coverage=$((tested_classes * 100 / total_classes))
    fi
    
    echo "TOTAL_CLASSES:$total_classes"
    echo "TESTED_CLASSES:$tested_classes"
    echo "FILE_COVERAGE:$file_coverage"
    echo "UNTESTED_CLASSES:$(IFS=$'\n'; echo "${untested_classes[*]}")"
}

classify_class_priority() {
    local class_file="$1"
    local class_name
    class_name=$(basename "$class_file" .kt)
    
    # Analyze class content to determine priority
    local priority="LOW"
    
    # High priority patterns
    if [[ "$class_name" =~ (ViewModel|Repository|UseCase|Manager|Service|Api)$ ]]; then
        priority="HIGH"
    elif grep -q "class.*(" "$class_file" 2>/dev/null; then
        # Classes with constructor parameters (likely have dependencies)
        priority="MEDIUM"
    elif grep -q -E "(suspend fun|Flow|LiveData)" "$class_file" 2>/dev/null; then
        # Async/reactive code
        priority="HIGH"
    elif [[ "$class_name" =~ Util$ ]]; then
        # Utility classes
        priority="MEDIUM"
    fi
    
    # Critical business logic indicators
    if grep -q -E "(search|page|article|wiki)" "$class_file" 2>/dev/null; then
        if [[ "$priority" == "MEDIUM" ]]; then
            priority="HIGH"
        elif [[ "$priority" == "LOW" ]]; then
            priority="MEDIUM"
        fi
    fi
    
    echo "$priority"
}

analyze_class_complexity() {
    local class_file="$1"
    
    # Count public methods
    local public_methods
    public_methods=$(grep -c -E "^\s*(public\s+)?fun\s+" "$class_file" 2>/dev/null || echo "0")
    
    # Count conditional statements (complexity indicators)
    local conditionals
    conditionals=$(grep -c -E "(if|when|while|for)\s*\(" "$class_file" 2>/dev/null || echo "0")
    
    # Count exception handling
    local exception_handling
    exception_handling=$(grep -c -E "(try|catch|throw)" "$class_file" 2>/dev/null || echo "0")
    
    local complexity="LOW"
    local total_complexity=$((public_methods + conditionals + exception_handling))
    
    if [[ $total_complexity -gt 15 ]]; then
        complexity="HIGH"
    elif [[ $total_complexity -gt 5 ]]; then
        complexity="MEDIUM"
    fi
    
    echo "METHODS:$public_methods,CONDITIONALS:$conditionals,EXCEPTIONS:$exception_handling,COMPLEXITY:$complexity"
}

generate_test_suggestions() {
    local class_file="$1"
    local detailed="${2:-false}"
    
    local class_name
    class_name=$(basename "$class_file" .kt)
    
    local suggestions=()
    
    # Analyze class type and suggest appropriate tests
    if [[ "$class_name" =~ ViewModel$ ]]; then
        suggestions+=("Test initial state and LiveData/StateFlow emissions")
        suggestions+=("Test user interaction methods and state changes")
        suggestions+=("Test error handling and loading states")
    elif [[ "$class_name" =~ Repository$ ]]; then
        suggestions+=("Test data source coordination (local vs remote)")
        suggestions+=("Test caching logic and invalidation")
        suggestions+=("Test error propagation from data sources")
    elif [[ "$class_name" =~ Util$ ]]; then
        suggestions+=("Test all public utility methods")
        suggestions+=("Test edge cases and boundary conditions")
        suggestions+=("Test null and empty input handling")
    elif [[ "$class_name" =~ (Api|Service)$ ]]; then
        suggestions+=("Test successful API responses")
        suggestions+=("Test error responses and network failures")
        suggestions+=("Test request parameter validation")
    else
        suggestions+=("Test public method functionality")
        suggestions+=("Test constructor and initialization")
        suggestions+=("Test error handling scenarios")
    fi
    
    if [[ "$detailed" == "true" ]]; then
        # Add method-specific suggestions
        local public_methods
        public_methods=$(grep -E "^\s*(public\s+)?fun\s+" "$class_file" | grep -v "private" || true)
        
        if [[ -n "$public_methods" ]]; then
            while IFS= read -r method; do
                if [[ -n "$method" ]]; then
                    local method_name
                    method_name=$(echo "$method" | grep -oE "fun\s+[a-zA-Z][a-zA-Z0-9]*" | sed 's/fun\s*//')
                    if [[ -n "$method_name" ]]; then
                        suggestions+=("Test $method_name() with valid and invalid inputs")
                    fi
                fi
            done <<< "$public_methods"
        fi
    fi
    
    IFS=$'\n'
    echo "${suggestions[*]}"
}

show_coverage_summary() {
    local coverage_xml="$1"
    
    log_header "=== COVERAGE SUMMARY ==="
    
    local overall_coverage
    overall_coverage=$(parse_coverage_percentage "$coverage_xml")
    
    echo -e "Overall Coverage: ${BOLD}$overall_coverage%${NC}"
    
    if [[ $overall_coverage -ge $TARGET_COVERAGE ]]; then
        log_success "✓ Exceeds target coverage ($TARGET_COVERAGE%)"
    elif [[ $overall_coverage -ge $MINIMUM_COVERAGE ]]; then
        log_warning "⚠ Meets minimum but below target ($TARGET_COVERAGE%)"
    else
        log_error "✗ Below minimum coverage ($MINIMUM_COVERAGE%)"
    fi
    
    echo ""
}

show_untested_classes() {
    local analysis_data="$1"
    local show_detailed="${2:-false}"
    local show_priority="${3:-false}"
    local show_suggestions="${4:-false}"
    local package_filter="${5:-}"
    
    local total_classes
    total_classes=$(echo "$analysis_data" | grep "^TOTAL_CLASSES:" | cut -d: -f2)
    local tested_classes
    tested_classes=$(echo "$analysis_data" | grep "^TESTED_CLASSES:" | cut -d: -f2)
    local file_coverage
    file_coverage=$(echo "$analysis_data" | grep "^FILE_COVERAGE:" | cut -d: -f2)
    local untested_classes
    untested_classes=$(echo "$analysis_data" | grep "^UNTESTED_CLASSES:" | cut -d: -f2-)
    
    log_header "=== CLASS COVERAGE ANALYSIS ==="
    echo -e "Total Classes: ${BOLD}$total_classes${NC}"
    echo -e "Tested Classes: ${BOLD}$tested_classes${NC}"
    echo -e "File Coverage: ${BOLD}$file_coverage%${NC}"
    echo ""
    
    if [[ -z "$untested_classes" ]]; then
        log_success "All classes have corresponding test files!"
        return 0
    fi
    
    local priority_counts=("HIGH:0" "MEDIUM:0" "LOW:0")
    local high_priority_classes=()
    local medium_priority_classes=()
    local low_priority_classes=()
    
    # Classify classes by priority
    while IFS= read -r class_file; do
        if [[ -n "$class_file" ]]; then
            local priority
            priority=$(classify_class_priority "$class_file")
            local class_name
            class_name=$(basename "$class_file" .kt)
            
            case "$priority" in
                "HIGH")
                    high_priority_classes+=("$class_file")
                    priority_counts[0]="HIGH:$((${priority_counts[0]#HIGH:} + 1))"
                    ;;
                "MEDIUM")
                    medium_priority_classes+=("$class_file")
                    priority_counts[1]="MEDIUM:$((${priority_counts[1]#MEDIUM:} + 1))"
                    ;;
                "LOW")
                    low_priority_classes+=("$class_file")
                    priority_counts[2]="LOW:$((${priority_counts[2]#LOW:} + 1))"
                    ;;
            esac
        fi
    done <<< "$untested_classes"
    
    # Show priority summary
    log_header "Priority Breakdown:"
    for count in "${priority_counts[@]}"; do
        local priority="${count%:*}"
        local num="${count#*:}"
        case "$priority" in
            "HIGH") echo -e "  ${RED}● HIGH Priority: $num classes${NC}" ;;
            "MEDIUM") echo -e "  ${YELLOW}● MEDIUM Priority: $num classes${NC}" ;;
            "LOW") echo -e "  ${BLUE}● LOW Priority: $num classes${NC}" ;;
        esac
    done
    echo ""
    
    # Show classes by priority
    show_priority_classes() {
        local priority="$1"
        local color="$2"
        local classes=("${@:3}")
        
        if [[ ${#classes[@]} -eq 0 ]]; then
            return 0
        fi
        
        if [[ "$show_priority" == "true" && "$priority" != "HIGH" ]]; then
            return 0
        fi
        
        echo -e "${color}${BOLD}$priority Priority Classes:${NC}"
        
        for class_file in "${classes[@]}"; do
            local class_name
            class_name=$(basename "$class_file" .kt)
            local package_path
            package_path=$(dirname "$class_file")
            package_path=${package_path#$SOURCE_DIR/}
            package_path=$(echo "$package_path" | tr '/' '.')
            
            echo -e "  ${color}●${NC} $class_name ($package_path)"
            
            if [[ "$show_detailed" == "true" ]]; then
                local complexity_data
                complexity_data=$(analyze_class_complexity "$class_file")
                local complexity
                complexity=$(echo "$complexity_data" | grep -oE "COMPLEXITY:[A-Z]+" | cut -d: -f2)
                local methods
                methods=$(echo "$complexity_data" | grep -oE "METHODS:[0-9]+" | cut -d: -f2)
                
                echo "    Complexity: $complexity, Public Methods: $methods"
            fi
            
            if [[ "$show_suggestions" == "true" ]]; then
                local suggestions
                suggestions=$(generate_test_suggestions "$class_file" "$show_detailed")
                echo "    Suggested tests:"
                while IFS= read -r suggestion; do
                    if [[ -n "$suggestion" ]]; then
                        echo "      - $suggestion"
                    fi
                done <<< "$suggestions"
            fi
            
            echo ""
        done
    }
    
    show_priority_classes "HIGH" "$RED" "${high_priority_classes[@]}"
    show_priority_classes "MEDIUM" "$YELLOW" "${medium_priority_classes[@]}"
    show_priority_classes "LOW" "$BLUE" "${low_priority_classes[@]}"
}

show_recommendations() {
    local coverage_xml="$1"
    local analysis_data="$2"
    
    log_header "=== RECOMMENDATIONS ==="
    
    local overall_coverage
    overall_coverage=$(parse_coverage_percentage "$coverage_xml")
    local untested_classes
    untested_classes=$(echo "$analysis_data" | grep "^UNTESTED_CLASSES:" | cut -d: -f2-)
    
    if [[ $overall_coverage -lt $MINIMUM_COVERAGE ]]; then
        echo "🎯 Focus on reaching $MINIMUM_COVERAGE% minimum coverage:"
        echo "   1. Start with HIGH priority classes"
        echo "   2. Use: /scaffold [ClassName] to generate tests"
        echo "   3. Run: ./gradlew testDebugUnitTest"
    elif [[ $overall_coverage -lt $TARGET_COVERAGE ]]; then
        echo "🎯 Improve coverage toward $TARGET_COVERAGE% target:"
        echo "   1. Add tests for MEDIUM priority classes"
        echo "   2. Improve existing test coverage"
        echo "   3. Focus on complex business logic"
    else
        echo "✅ Coverage is good! Consider:"
        echo "   1. Adding edge case tests"
        echo "   2. Integration tests for critical flows"
        echo "   3. Performance tests for key components"
    fi
    
    echo ""
    echo "Quick actions:"
    echo "  ./scripts/android/scaffold-unit-test.sh \"ClassName\""
    echo "  /scaffold --priority"
    echo "  cd platforms/android && ./gradlew testDebugUnitTest"
    echo ""
}

main() {
    local show_detailed=false
    local show_priority=false
    local show_suggestions=false
    local package_filter=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --detailed)
                show_detailed=true
                shift
                ;;
            --priority)
                show_priority=true
                shift
                ;;
            --suggest-tests)
                show_suggestions=true
                shift
                ;;
            --package)
                package_filter="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                ;;
        esac
    done
    
    log_info "Analyzing test coverage gaps..."
    
    # Generate coverage report
    local coverage_xml
    coverage_xml=$(generate_coverage_report)
    
    # Find untested classes
    local analysis_data
    analysis_data=$(find_untested_classes "$package_filter")
    
    # Show results
    show_coverage_summary "$coverage_xml"
    show_untested_classes "$analysis_data" "$show_detailed" "$show_priority" "$show_suggestions" "$package_filter"
    show_recommendations "$coverage_xml" "$analysis_data"
}

# Run main function
main "$@"