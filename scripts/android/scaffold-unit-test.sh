#!/bin/bash

# Scaffold Unit Test Script
# Generates comprehensive unit test files for Android classes
# Usage: ./scaffold-unit-test.sh "ClassName" [package.path]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ANDROID_ROOT="$PROJECT_ROOT/platforms/android"
SOURCE_DIR="$ANDROID_ROOT/app/src/main/java"
TEST_DIR="$ANDROID_ROOT/app/src/test/java"
BASE_PACKAGE="com.omiyawaki.osrswiki"

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

show_usage() {
    echo "Usage: $0 \"ClassName\" [package.path]"
    echo ""
    echo "Examples:"
    echo "  $0 \"SearchViewModel\""
    echo "  $0 \"PageRepository\" \"page\""
    echo "  $0 \"StringUtil\" \"util\""
    echo ""
    echo "The script will:"
    echo "  1. Find the source class file"
    echo "  2. Analyze its structure and dependencies"
    echo "  3. Generate a comprehensive test file"
    echo "  4. Create proper imports and setup"
    echo "  5. Generate test methods for public functions"
    exit 1
}

find_class_file() {
    local class_name="$1"
    local package_hint="${2:-}"
    
    log_info "Searching for class: $class_name"
    
    # Search for the class file
    local search_pattern="*${class_name}.kt"
    if [[ -n "$package_hint" ]]; then
        search_pattern="*${package_hint}*${class_name}.kt"
    fi
    
    local class_files
    class_files=$(find "$SOURCE_DIR" -name "$search_pattern" -type f)
    
    if [[ -z "$class_files" ]]; then
        log_error "Class file not found: $class_name"
        log_info "Searched in: $SOURCE_DIR"
        exit 1
    fi
    
    if [[ $(echo "$class_files" | wc -l) -gt 1 ]]; then
        log_warning "Multiple files found:"
        echo "$class_files"
        echo ""
        read -rp "Enter the full path of the file to test: " selected_file
        if [[ ! -f "$selected_file" ]]; then
            log_error "Invalid file: $selected_file"
            exit 1
        fi
        echo "$selected_file"
    else
        echo "$class_files"
    fi
}

analyze_class_structure() {
    local class_file="$1"
    local class_name="$2"
    
    log_info "Analyzing class structure: $class_name"
    
    # Extract package declaration
    local package_line
    package_line=$(grep -E "^package " "$class_file" | head -1)
    local package_name
    package_name=$(echo "$package_line" | sed 's/package //' | sed 's/;//')
    
    # Extract imports
    local imports
    imports=$(grep -E "^import " "$class_file" | grep -v "import java.lang" || true)
    
    # Extract class declaration
    local class_declaration
    class_declaration=$(grep -E "^(class|object|interface)" "$class_file" | head -1)
    
    # Find public methods/functions
    local public_methods
    public_methods=$(grep -E "^\s*(public\s+)?fun\s+" "$class_file" | grep -v "private" || true)
    
    # Find constructor parameters
    local constructor_params
    constructor_params=$(grep -A 10 -E "^class.*\(" "$class_file" | grep -E "^\s*.*:" || true)
    
    # Find dependencies (typically constructor injection)
    local dependencies
    dependencies=$(echo "$constructor_params" | grep -oE ":\s*[A-Z][a-zA-Z0-9]*" | sed 's/:\s*//' | sort -u || true)
    
    # Store analysis results
    echo "PACKAGE:$package_name"
    echo "IMPORTS:$imports"
    echo "CLASS_DECLARATION:$class_declaration"
    echo "PUBLIC_METHODS:$public_methods"
    echo "CONSTRUCTOR_PARAMS:$constructor_params"
    echo "DEPENDENCIES:$dependencies"
}

generate_test_imports() {
    local class_package="$1"
    local dependencies="$2"
    
    cat << EOF
package ${class_package}

import androidx.arch.core.executor.testing.InstantTaskExecutorRule
import kotlinx.coroutines.test.runTest
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mock
import org.mockito.MockitoAnnotations
import org.mockito.junit.MockitoJUnitRunner
import org.mockito.kotlin.*
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.test.assertFalse

EOF

    # Add coroutines testing if likely needed
    if echo "$dependencies" | grep -qi -E "(repository|viewmodel|usecase)"; then
        cat << EOF
import kotlinx.coroutines.test.MainDispatcherRule
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher

EOF
    fi
}

generate_test_class_setup() {
    local class_name="$1"
    local dependencies="$2"
    
    cat << EOF
@RunWith(MockitoJUnitRunner::class)
class ${class_name}Test {

    @get:Rule
    val instantExecutorRule = InstantTaskExecutorRule()

EOF

    # Add coroutines rule if needed
    if echo "$dependencies" | grep -qi -E "(repository|viewmodel|usecase)"; then
        cat << EOF
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val testScope = TestScope()

EOF
    fi

    # Generate mock dependencies
    if [[ -n "$dependencies" ]]; then
        echo "    // Mock dependencies"
        while IFS= read -r dep; do
            if [[ -n "$dep" ]]; then
                echo "    @Mock"
                echo "    private lateinit var mock${dep}: ${dep}"
            fi
        done <<< "$dependencies"
        echo ""
    fi

    cat << EOF
    private lateinit var ${class_name,,}: ${class_name}

    @Before
    fun setUp() {
        MockitoAnnotations.openMocks(this)
EOF

    # Generate constructor call with mocks
    if [[ -n "$dependencies" ]]; then
        local constructor_args=""
        while IFS= read -r dep; do
            if [[ -n "$dep" ]]; then
                if [[ -n "$constructor_args" ]]; then
                    constructor_args="$constructor_args, mock$dep"
                else
                    constructor_args="mock$dep"
                fi
            fi
        done <<< "$dependencies"
        
        cat << EOF
        ${class_name,,} = ${class_name}($constructor_args)
EOF
    else
        cat << EOF
        ${class_name,,} = ${class_name}()
EOF
    fi

    cat << EOF
    }
EOF
}

generate_test_methods() {
    local class_name="$1"
    local public_methods="$2"
    local dependencies="$3"
    
    echo ""
    echo "    // Test methods"
    
    # Generate basic instantiation test
    cat << EOF

    @Test
    fun \`constructor_validParameters_createsInstance\`() {
        // Arrange & Act
        // Instance created in setUp()
        
        // Assert
        assertNotNull(${class_name,,})
    }
EOF

    # Parse and generate tests for public methods
    if [[ -n "$public_methods" ]]; then
        while IFS= read -r method; do
            if [[ -n "$method" ]]; then
                # Extract method name
                local method_name
                method_name=$(echo "$method" | grep -oE "fun\s+[a-zA-Z][a-zA-Z0-9]*" | sed 's/fun\s*//')
                
                if [[ -n "$method_name" ]]; then
                    # Generate success test
                    cat << EOF

    @Test
    fun \`${method_name}_validInput_returnsExpectedResult\`() {
        // Arrange
        // TODO: Set up test data and mock behaviors
        
        // Act
        val result = ${class_name,,}.${method_name}(/* TODO: Add parameters */)
        
        // Assert
        // TODO: Verify expected behavior
        assertNotNull(result)
    }

    @Test
    fun \`${method_name}_errorCondition_handlesGracefully\`() {
        // Arrange
        // TODO: Set up error condition
        
        // Act & Assert
        // TODO: Test error handling
    }
EOF
                fi
            fi
        done <<< "$public_methods"
    fi

    # Generate additional tests based on class type
    if echo "$class_name" | grep -qi "viewmodel"; then
        generate_viewmodel_tests "$class_name" "$dependencies"
    elif echo "$class_name" | grep -qi "repository"; then
        generate_repository_tests "$class_name" "$dependencies"
    elif echo "$class_name" | grep -qi "util"; then
        generate_utility_tests "$class_name"
    fi
}

generate_viewmodel_tests() {
    local class_name="$1"
    local dependencies="$2"
    
    cat << EOF

    // ViewModel-specific tests
    @Test
    fun \`initialState_isEmpty\`() = runTest {
        // Assert initial state
        // TODO: Verify initial UI state
    }

    @Test
    fun \`loadData_success_emitsSuccessState\`() = runTest {
        // Arrange
        // TODO: Mock successful data loading
        
        // Act
        ${class_name,,}.loadData()
        
        // Assert
        // TODO: Verify success state emission
    }

    @Test
    fun \`loadData_error_emitsErrorState\`() = runTest {
        // Arrange
        // TODO: Mock error condition
        
        // Act
        ${class_name,,}.loadData()
        
        // Assert
        // TODO: Verify error state emission
    }
EOF
}

generate_repository_tests() {
    local class_name="$1"
    local dependencies="$2"
    
    cat << EOF

    // Repository-specific tests
    @Test
    fun \`getData_cacheHit_returnsFromCache\`() = runTest {
        // Arrange
        // TODO: Set up cache with data
        
        // Act
        val result = ${class_name,,}.getData()
        
        // Assert
        // TODO: Verify cache was used
    }

    @Test
    fun \`getData_cacheMiss_fetchesFromRemote\`() = runTest {
        // Arrange
        // TODO: Set up empty cache and mock remote
        
        // Act
        val result = ${class_name,,}.getData()
        
        // Assert
        // TODO: Verify remote fetch and cache update
    }
EOF
}

generate_utility_tests() {
    local class_name="$1"
    
    cat << EOF

    // Utility-specific tests
    @Test
    fun \`utilityMethod_edgeCase_handlesCorrectly\`() {
        // Arrange
        // TODO: Set up edge case input
        
        // Act
        val result = ${class_name,,}.utilityMethod(/* edge case input */)
        
        // Assert
        // TODO: Verify edge case handling
    }

    @Test
    fun \`utilityMethod_nullInput_handlesGracefully\`() {
        // Arrange
        val nullInput = null
        
        // Act & Assert
        // TODO: Test null handling
    }
EOF
}

create_test_file() {
    local class_name="$1"
    local analysis_data="$2"
    
    # Parse analysis data
    local package_name
    package_name=$(echo "$analysis_data" | grep "^PACKAGE:" | cut -d: -f2-)
    local dependencies
    dependencies=$(echo "$analysis_data" | grep "^DEPENDENCIES:" | cut -d: -f2-)
    local public_methods
    public_methods=$(echo "$analysis_data" | grep "^PUBLIC_METHODS:" | cut -d: -f2-)
    
    # Calculate test file path
    local package_path
    package_path=$(echo "$package_name" | tr '.' '/')
    local test_file_path="$TEST_DIR/$package_path/${class_name}Test.kt"
    
    log_info "Creating test file: $test_file_path"
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$test_file_path")"
    
    # Check if test file already exists
    if [[ -f "$test_file_path" ]]; then
        log_warning "Test file already exists: $test_file_path"
        read -rp "Overwrite? (y/N): " overwrite
        if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            log_info "Skipping test generation"
            return 0
        fi
    fi
    
    # Generate test file content
    {
        generate_test_imports "$package_name" "$dependencies"
        generate_test_class_setup "$class_name" "$dependencies"
        generate_test_methods "$class_name" "$public_methods" "$dependencies"
        echo "}"
    } > "$test_file_path"
    
    log_success "Test file created: $test_file_path"
    
    # Verify the test compiles
    log_info "Verifying test compilation..."
    if cd "$ANDROID_ROOT" && ./gradlew compileDebugUnitTestKotlin --quiet; then
        log_success "Test compiles successfully"
    else
        log_warning "Test compilation failed - may need manual fixes"
    fi
    
    echo "$test_file_path"
}

main() {
    if [[ $# -lt 1 ]]; then
        show_usage
    fi
    
    local class_name="$1"
    local package_hint="${2:-}"
    
    log_info "Scaffolding unit test for: $class_name"
    
    # Find the class file
    local class_file
    class_file=$(find_class_file "$class_name" "$package_hint")
    
    # Analyze the class structure
    local analysis_data
    analysis_data=$(analyze_class_structure "$class_file" "$class_name")
    
    # Create the test file
    local test_file
    test_file=$(create_test_file "$class_name" "$analysis_data")
    
    log_success "Test scaffolding complete!"
    echo ""
    echo "Next steps:"
    echo "1. Review the generated test: $test_file"
    echo "2. Fill in TODO comments with actual test logic"
    echo "3. Run tests: cd platforms/android && ./gradlew testDebugUnitTest"
    echo "4. Verify tests pass: ./gradlew testDebugUnitTest"
}

# Run main function
main "$@"