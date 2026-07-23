# CSS Rendering Investigation Workflow

This document describes the comprehensive Puppeteer-based workflow developed to investigate and fix CSS rendering discrepancies between web browsers and mobile WebViews (iOS WKWebView, Android WebView).

## Overview

**Problem Type**: CSS/rendering issues where content displays correctly in desktop browsers but fails to render properly in mobile WebViews.

**Solution**: Evidence-based browser analysis using automated Puppeteer tools to extract exact CSS properties from working web versions, enabling targeted fixes instead of trial-and-error approaches.

**Success Story**: Used to resolve missing table images in OSRS Wiki mobile apps - 526+ item icons that loaded successfully but weren't visually rendered due to incomplete "invisible container" CSS patterns.

## Core Methodology

### 1. Evidence-Based Analysis vs Trial-and-Error

❌ **Avoid**: "Aggressive CSS overrides" and guessing at property fixes
✅ **Use**: Complete browser analysis to understand exact working patterns

**Why this matters**: Mobile WebViews have subtle rendering differences from desktop browsers. Only by understanding the complete working pattern can you implement targeted fixes that address root causes rather than symptoms.

### 2. Three-Phase Investigation Process

#### Phase 1: Problem Confirmation
- Verify issue exists in mobile WebView but not desktop browser
- Confirm asset loading is working (images/resources load successfully)
- Identify that content exists in DOM but isn't visually rendered

#### Phase 2: Browser Analysis
- Use Puppeteer to analyze working desktop version
- Extract complete CSS property chains for all relevant elements
- Document the "working pattern" at multiple DOM levels

#### Phase 3: Targeted Implementation
- Implement comprehensive CSS fix based on working pattern data
- Test iteratively with evidence-based refinements
- Verify complete visual consistency with web version

## Tool Architecture

### Core Analysis Tool: `automated-webkit-analysis.js`

```javascript
class AutomatedWebKitAnalyzer {
    constructor() {
        this.outputDir = path.join(__dirname, '..', 'webkit-debug');
    }

    async run() {
        // 1. Launch browser with mobile Safari settings
        browser = await puppeteer.launch({
            headless: "new",
            args: ['--no-sandbox', '--disable-setuid-sandbox']
        });

        // 2. Set mobile Safari user agent and viewport
        await page.setUserAgent('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0...');
        await page.setViewport({
            width: 375, height: 812, deviceScaleFactor: 3,
            isMobile: true, hasTouch: true
        });

        // 3. Navigate and wait for full page load
        await page.goto(targetUrl, { waitUntil: 'networkidle2' });

        // 4. Execute comprehensive DOM/CSS analysis
        const analysisResult = await page.evaluate(() => {
            // Extract complete CSS property chains
            // Analyze element dimensions and positioning
            // Test text wrapping behavior
            // Document container relationships
        });

        // 5. Save structured data and generate report
        await this.saveResults(analysisResult);
        this.generateReport(analysisResult);
    }
}
```

### Analysis Capabilities

**Environment Detection**:
- User agent, viewport, device pixel ratio
- Media query matching (mobile/tablet/desktop)
- CSS feature support detection
- MediaWiki integration status

**DOM Analysis**:
- Complete element hierarchy
- Computed style extraction for all levels
- Bounding box measurements
- Visibility and positioning analysis

**CSS Pattern Recognition**:
- "Invisible container" pattern detection
- Border collapse and table layout analysis
- Text wrapping behavior measurement
- Background and border consistency checks

## Specific Implementation Example: Table Image Fix

### Problem Context
- **Issue**: 526+ item icons in Products table exist in DOM but not visually rendered
- **Location**: `.products-list` table, first column `.inventory-image` elements  
- **Platforms**: Both iOS WKWebView and Android WebView affected
- **Root Cause**: Incomplete "invisible container" CSS pattern in mobile WebViews

### Analysis Results
Using comprehensive Puppeteer analysis of https://oldschool.runescape.wiki/w/Coins:

**Working Web Pattern** (5-level CSS hierarchy):
```css
/* 1. TABLE-LEVEL: Critical foundation */
.products-list {
    border-collapse: collapse !important;
    table-layout: auto !important;
}

/* 2. CELL-LEVEL: Invisible containers with proper spacing */
.products-list td:first-child {
    visibility: visible !important;
    text-align: center !important;
    overflow: visible !important;
    padding: 2.88px 5.76px !important;
}

/* 3. SPAN-LEVEL: Auto-sizing containers (.inventory-image) */
.products-list .inventory-image {
    display: inline !important;
    width: auto !important;
    height: auto !important;
    background: none !important;
    border: none !important;
}

/* 4. IMAGE-LEVEL: Complete visibility with proper scaling */
.products-list .inventory-image img {
    visibility: visible !important;
    display: inline !important;
    object-fit: contain !important;
    vertical-align: middle !important;
    background-color: transparent !important;
}

/* 5. LINK-LEVEL: Invisible parent anchor containers */
.products-list .inventory-image a {
    display: inline !important;
    overflow: visible !important;
    width: auto !important;
    height: auto !important;
}
```

### Key Discovery: "Invisible Container" Pattern
The working web version uses a complete pattern where:
- All container elements are completely invisible (no visual boundaries)
- Images are fully visible with proper aspect ratios
- Proper centering and alignment through text-align and vertical-align
- Border collapse eliminates cell separation
- Object-fit: contain preserves natural image proportions

## Tool Integration

### Directory Structure
```
tools/
├── debugging/
│   ├── CSS_RENDERING_INVESTIGATION_WORKFLOW.md  # This documentation
│   ├── automated-webkit-analysis.js             # Main Puppeteer tool
│   ├── official-webkit-analysis.js              # SafariDriver version  
│   └── analysis-templates/                      # Reusable templates
├── css/
│   ├── css-extractor.py                        # CSS extraction utilities
│   └── css-comparator.js                       # Web vs mobile comparison
└── output/                                      # Analysis results
    ├── webkit-analysis-{timestamp}.json
    └── analysis-reports/
```

### Usage Instructions

#### 1. Run Basic Analysis
```bash
# Navigate to tools directory
cd tools/debugging/

# Run automated analysis (installs Puppeteer if needed)
node automated-webkit-analysis.js

# Check results
ls -la ../output/webkit-analysis-*.json
```

#### 2. Target Specific Pages
```javascript
// Modify automated-webkit-analysis.js
await page.goto('https://oldschool.runescape.wiki/w/Coins', {
    waitUntil: 'networkidle2',
    timeout: 30000
});
```

#### 3. Focus on Specific Elements
```javascript
// Add custom selector analysis
const tables = document.querySelectorAll('table.products-list');
const images = table.querySelectorAll('.inventory-image img');
```

### Analysis Output Format

```json
{
    "timestamp": "2025-08-26T22:02:25.387Z",
    "platform": "mobile-safari-puppeteer", 
    "environment": {
        "userAgent": "Mozilla/5.0 (iPhone...)",
        "viewport": {"width": 375, "height": 812, "devicePixelRatio": 3}
    },
    "tables": [
        {
            "index": 0,
            "tableStyles": {
                "borderCollapse": "collapse",
                "tableLayout": "auto",
                "textSizeAdjust": "auto"
            },
            "cells": [
                {
                    "index": 0,
                    "dimensions": {"width": 32, "height": 32},
                    "styles": {
                        "textAlign": "center",
                        "overflow": "visible", 
                        "padding": "2.88px 5.76px"
                    }
                }
            ]
        }
    ]
}
```

## Best Practices

### 1. Complete Pattern Analysis
- Always analyze entire element hierarchy (table → cell → span → image → link)
- Document CSS properties at each level, don't focus on single elements
- Pay attention to container relationships and inheritance

### 2. Evidence-Based Implementation
- Use actual browser data rather than assumptions
- Implement comprehensive fixes that address the complete pattern
- Avoid partial CSS overrides that only fix symptoms

### 3. Iterative Refinement
- Test initial comprehensive fix
- Use analysis data to refine specific properties (aspect ratios, borders, backgrounds)
- Verify final result matches web version exactly

### 4. Documentation and Reproducibility
- Save all analysis JSON files for reference
- Document the complete workflow for future similar issues  
- Create reusable tools rather than one-off scripts

## Common Mobile WebView Issues

### Missing "Invisible Container" Patterns
- **Symptom**: Content exists in DOM but not visually rendered
- **Cause**: Mobile WebViews require explicit visibility and positioning properties
- **Solution**: Complete CSS property chain from containers to final elements

### Aspect Ratio Problems  
- **Symptom**: Images appear vertically compressed or distorted
- **Cause**: `object-fit: fill` stretching vs `object-fit: contain` preservation
- **Solution**: Use `contain` for natural proportions, `fill` only when stretching intended

### Border and Background Inconsistencies
- **Symptom**: First column styling differs from other columns
- **Cause**: CSS overrides preventing inheritance of table styling
- **Solution**: Remove unnecessary background/border overrides to allow inheritance

### Text Size Adjustment Issues
- **Symptom**: Text rendering differently between web and mobile
- **Cause**: WebKit-specific `-webkit-text-size-adjust` property differences
- **Solution**: Explicit text-size-adjust declarations in analysis and fixes

## Future Usage Guidelines

### When to Use This Workflow
1. **CSS/rendering discrepancies** between web and mobile WebViews
2. **Content exists in DOM** but isn't visually rendered
3. **Asset loading works** but display fails
4. **Complex nested element** styling issues

### When NOT to Use This Workflow
1. **Asset loading failures** (use network debugging instead)
2. **JavaScript execution errors** (use console debugging)  
3. **Performance issues** (use profiling tools)
4. **Simple property fixes** that can be identified through inspection

### Expansion Opportunities
1. **iOS WKWebView-specific** analysis using SafariDriver
2. **Android WebView configuration** comparison tools  
3. **Cross-platform rendering** comparison automation
4. **MediaWiki-specific** pattern library development

## Success Metrics

For the table image fix that inspired this workflow:
- ✅ **526+ images** now render correctly in mobile WebViews
- ✅ **Complete visual consistency** with desktop browser achieved
- ✅ **Evidence-based approach** eliminated trial-and-error debugging
- ✅ **Comprehensive solution** prevents regression of similar issues
- ✅ **Reusable methodology** documented for future CSS rendering investigations

## Conclusion

This evidence-based browser analysis workflow transforms CSS rendering debugging from guesswork into systematic investigation. By understanding complete working patterns rather than guessing at fixes, mobile WebView issues can be resolved comprehensively and reliably.

The methodology is particularly powerful for complex nested element hierarchies where mobile WebViews have subtle rendering differences from desktop browsers. Future agents encountering similar web-to-mobile rendering discrepancies should follow this documented workflow for optimal results.