# iOS Testing Guide for LLM Agents

## Overview
Use the strongest workflow for the current iOS task. XCTest is preferred for repeatable assertions and regression coverage, but exploratory UI/UX review is a first-class activity: use the Simulator, accessibility inspection, `xcrun simctl`, logs, screenshots/video, direct gestures, and focused manual judgment when they expose issues faster.

Existing tests may be run at any time. You do not need to create a new test before running an existing test suite. Add or update tests when you find a durable bug, change behavior, or need a reproducible guardrail.

## Testing Toolkit

### Automated XCTest
- **When to use**: Regression checks, changed behavior, repeatable UI flows, bug reproductions, and performance measurements that fit XCTest.
- **Tools**: XCTest framework, `xcodebuild test`, project scripts.
- **Benefits**: Reliable, repeatable, programmatic validation.

#### Quick Commands:
```bash
# Quick map verification (most common)
./scripts/ios/automate-app-testing.sh quick-map

# Unit tests only
./scripts/ios/automate-app-testing.sh unit-tests

# Full UI test suite
./scripts/ios/automate-app-testing.sh full-test
```

#### Direct XCTest Commands:
```bash
# Run all tests
xcodebuild test -project platforms/ios/osrswiki.xcodeproj -scheme osrswiki -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID"

# Run specific test class
xcodebuild test -project platforms/ios/osrswiki.xcodeproj -scheme osrswiki -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" -only-testing:osrswikiUITests/MapLibreEmbedVerificationTest

# Run unit tests only
xcodebuild test -project platforms/ios/osrswiki.xcodeproj -scheme osrswiki -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" -only-testing:osrswikiTests
```

### Direct Simulator and Exploratory Testing
- **When to use**: Broad UI/UX audits, gesture-heavy flows, visual polish checks, navigation discovery, permission/system sheet behavior, and debugging test failures.
- **Tools**: Simulator UI, `xcrun simctl`, accessibility inspection, screenshots/video, logs, interactive gestures, Browser/Chrome/Computer Use when useful.
- **Purpose**: Discover unexpected, unintuitive, unresponsive, or visually broken behavior that scripted tests may miss.

```bash
# Launch to specific tab for debugging
./scripts/ios/automate-app-testing.sh launch map
./scripts/ios/automate-app-testing.sh launch search
```

### Screenshots and Visual Evidence
- **When to use**: Bug documentation, visual QA, before/after comparisons, responsive layout checks, and final evidence.
- **Purpose**: Preserve exactly what the user would see. Pair screenshots with interaction notes, logs, accessibility state, or tests when behavior matters.

```bash
# Only use for bug documentation
./scripts/ios/take-screenshot.sh "bug-description-here"
```

## Available Test Suites

### UI Tests (osrswikiUITests)
Located in: `platforms/ios/osrswikiUITests/`

Key test classes:
- `MapLibreEmbedVerificationTest` - Map functionality
- `NavigationAutomationTests` - Tab navigation
- `SearchHighlightingUITests` - Search functionality
- `BottomBarNavigationTimingUITests` - Navigation timing
- `TabBarThemingTest` - UI theming

### Unit Tests (osrswikiTests)
Located in: `platforms/ios/osrswikiTests/`

Key test classes:
- `MapLibreBridgeTests` - Map integration
- `SearchHighlightingTests` - Search logic
- `RuneScapeFontTests` - Font handling
- `ThemeCachingTest` - Theme management

## Agent Workflow

### For New Feature Development:
1. Build app: `./scripts/ios/quick-test.sh`
2. Add XCTests for new or changed behavior when a repeatable assertion is practical.
   - Create test files in `platforms/ios/osrswikiUITests/` for UI tests
   - Create test files in `platforms/ios/osrswikiTests/` for unit tests
   - Follow existing test patterns and naming conventions
3. Run the relevant existing tests before and after risky changes.
4. Use targeted launch, interactive simulator testing, logs, and screenshots to debug or inspect behavior.
5. Document bugs with concise reproduction steps and evidence.

### For Bug Fixes:
1. Reproduce the bug with the fastest reliable method: an existing test, a new focused test, direct simulator interaction, logs, or a combination.
2. Implement fix
3. Add or update a failing test when the bug can be captured durably.
4. Verify with targeted tests first, then broader tests when risk warrants it.

### For Verification Tasks:
1. Run relevant existing tests freely.
2. Use direct simulator exploration for workflows, gestures, visual layout, responsiveness, permissions, sheets, and cross-view state.
3. Add temporary exploratory XCTests when they speed up broad coverage; delete them before finishing unless they are useful regression coverage.
4. Promote important discoveries into durable tests or issue notes.

## Common Mistakes to Avoid

- Avoid treating one method as mandatory for every task.
- Avoid relying on screenshots alone for behavior that can regress silently.
- Do not ignore visual, gesture, focus, keyboard, permission, or sheet behavior just because existing XCTests pass.
- Do not leave temporary exploratory test files behind unless they are intentionally converted into regression tests.

- Run existing tests whenever they answer the question.
- Create or update tests for new behavior, bug fixes, and high-risk regressions.
- Use interactive simulator testing for exploratory UI/UX discovery.
- Capture evidence: screenshots, videos, logs, timing notes, accessibility state, and reproduction steps.
- Update this guide when a better agent workflow emerges.

## Writing XCTests

Write new test files when the task needs new coverage:

#### UI Test Example (platforms/ios/osrswikiUITests/):
```swift
import XCTest

class MyFeatureUITest: XCTestCase {
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }
    
    func testMyNewFeature() {
        // Test the specific functionality you implemented
        let button = app.buttons["MyButton"]
        XCTAssertTrue(button.exists)
        button.tap()
        
        let result = app.staticTexts["ExpectedResult"]
        XCTAssertTrue(result.exists)
    }
}
```

#### Unit Test Example (platforms/ios/osrswikiTests/):
```swift
import XCTest
@testable import osrswiki

class MyFeatureTests: XCTestCase {
    
    func testMyFunctionality() {
        // Test your implementation
        let result = MyClass.myMethod()
        XCTAssertEqual(result, expectedValue)
    }
    
    func testEdgeCases() {
        // Test edge cases and error conditions
        XCTAssertThrowsError(try MyClass.methodThatShouldThrow())
    }
}
```

### Test Writing Workflow:
1. **Identify what to test** - specific functionality you're implementing/fixing
2. **Choose test type** - UI test for user interactions, unit test for logic
3. **Create test file** - follow naming conventions (FeatureNameTest.swift)
4. **Write test methods** - start with `test` prefix, use descriptive names
5. **Run tests** - only after writing them

## Test Execution Examples

### Testing UI Changes:
```bash
# Test bottom bar navigation changes
xcodebuild test -project platforms/ios/osrswiki.xcodeproj -scheme osrswiki -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" -only-testing:osrswikiUITests/BottomBarNavigationTimingUITests

# Test search functionality
xcodebuild test -project platforms/ios/osrswiki.xcodeproj -scheme osrswiki -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" -only-testing:osrswikiUITests/SearchHighlightingUITests
```

### Testing Backend Changes:
```bash
# Test map integration
xcodebuild test -project platforms/ios/osrswiki.xcodeproj -scheme osrswiki -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" -only-testing:osrswikiTests/MapLibreBridgeTests

# Test theme handling
xcodebuild test -project platforms/ios/osrswiki.xcodeproj -scheme osrswiki -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" -only-testing:osrswikiTests/ThemeCachingTest
```

## Environment Setup

Always ensure environment is loaded before testing:
```bash
source .ios-env
echo "Simulator: $IOS_SIMULATOR_UDID"
echo "Bundle ID: $BUNDLE_ID"
```

## Integration with Session Workflow

The `/start` command now emphasizes XCTest workflow:
1. Session setup creates or reuses an exact leased simulator
2. Environment variables are loaded
3. XCTest becomes the primary testing method
4. Screenshots are demoted to debugging-only role
