# CSS Rendering Investigation Tools

This directory contains browser analysis tools developed to investigate CSS rendering discrepancies between desktop browsers and mobile WebViews.

## Quick Start

### Investigate CSS Rendering Issues

```bash
# Run comprehensive Puppeteer analysis
node automated-webkit-analysis.js

# Or use official Safari WebKit analysis  
node official-webkit-analysis.js

# Check results
ls -la webkit-debug/
```

## Tools Overview

### `automated-webkit-analysis.js`
**Primary tool for CSS rendering investigation**

- Uses Puppeteer with mobile Safari user agent
- Comprehensive DOM and CSS analysis
- Automated element hierarchy extraction
- Text wrapping behavior detection
- Generates structured JSON reports

**Use for**: Initial investigation of rendering issues

### `official-webkit-analysis.js`  
**Apple SafariDriver-based analysis**

- Uses official Safari WebKit engine
- Requires SafariDriver setup (`sudo safaridriver --enable`)
- True WebKit behavior analysis
- iOS-like rendering environment

**Use for**: WebKit-specific behavior verification

### `CSS_RENDERING_INVESTIGATION_WORKFLOW.md`
**Complete methodology documentation**

- Evidence-based debugging approach
- Step-by-step investigation process  
- Success story: Table image fix (526+ icons)
- Best practices and common patterns

## Usage Examples

### Analyze Specific Page
```javascript
// Modify automated-webkit-analysis.js
await page.goto('https://oldschool.runescape.wiki/w/PAGE_NAME', {
    waitUntil: 'networkidle2'
});
```

### Focus on Specific Elements
```javascript  
// Add custom analysis in page.evaluate()
const targetElements = document.querySelectorAll('.your-selector');
targetElements.forEach((element, index) => {
    const styles = window.getComputedStyle(element);
    // Extract specific CSS properties
});
```

### Mobile Viewport Configuration
```javascript
await page.setViewport({
    width: 375,        // iPhone width
    height: 812,       // iPhone height  
    deviceScaleFactor: 3,
    isMobile: true,
    hasTouch: true
});
```

## Output Analysis

### JSON Report Structure
```json
{
    "timestamp": "2025-08-26T22:02:25.387Z",
    "platform": "mobile-safari-puppeteer",
    "environment": {
        "userAgent": "...",
        "viewport": {"width": 375, "height": 812}
    },
    "tables": [
        {
            "tableStyles": {"borderCollapse": "collapse"},
            "cells": [
                {
                    "styles": {"textAlign": "center"},
                    "dimensions": {"width": 32, "height": 32}
                }
            ]
        }
    ]
}
```

### Key Analysis Points
- **Environment**: User agent, viewport, media queries
- **CSS Support**: Feature detection for WebKit properties
- **Element Hierarchy**: Complete DOM structure analysis
- **Style Extraction**: Computed CSS properties at all levels
- **Behavior Testing**: Text wrapping, overflow, positioning

## Common Use Cases

### Missing Visual Content
**Problem**: Content exists in DOM but not rendered visually
**Solution**: Compare working web version CSS with mobile WebView
**Tool**: `automated-webkit-analysis.js`

### Image Rendering Issues  
**Problem**: Images load but appear distorted or invisible
**Solution**: Analyze complete image container hierarchy
**Focus**: `object-fit`, `vertical-align`, container visibility

### Table Layout Problems
**Problem**: Table content wraps incorrectly on mobile
**Solution**: Extract table-level and cell-level CSS patterns
**Focus**: `table-layout`, `border-collapse`, `text-size-adjust`

### Border/Background Inconsistencies
**Problem**: Styling differs between columns or elements
**Solution**: Document inheritance patterns from working version
**Focus**: Background overrides preventing proper inheritance

## Installation Requirements

### Puppeteer (Automatic)
```bash
# Installs automatically on first run
node automated-webkit-analysis.js
```

### SafariDriver (Manual Setup)
```bash  
# Enable SafariDriver
sudo safaridriver --enable

# Safari settings: Develop → Allow Remote Automation
```

## Success Story: Table Image Fix

**Challenge**: 526+ item icons existed in DOM but weren't visually rendered in mobile WebViews

**Investigation**: Comprehensive Puppeteer analysis of working web version revealed incomplete "invisible container" CSS pattern

**Solution**: 5-level CSS hierarchy fix addressing table → cell → span → image → link elements

**Result**: Complete visual consistency between web and mobile versions

**Methodology**: Evidence-based analysis instead of trial-and-error CSS overrides

## Best Practices

1. **Complete Pattern Analysis**: Always analyze entire element hierarchy
2. **Evidence-Based Fixes**: Use browser data rather than assumptions  
3. **Comprehensive Implementation**: Address root patterns, not just symptoms
4. **Iterative Refinement**: Test and refine based on analysis data
5. **Documentation**: Save all analysis files for future reference

## Future Development

### Planned Enhancements
- Cross-platform comparison automation
- MediaWiki-specific pattern library
- iOS WKWebView configuration analysis
- Performance impact measurement

### Integration Opportunities  
- CI/CD pipeline integration for regression detection
- Automated fix suggestion based on pattern library
- Real-time mobile WebView debugging capabilities

## Support

For issues with these tools or methodology questions:
1. Check `CSS_RENDERING_INVESTIGATION_WORKFLOW.md` for detailed guidance
2. Review analysis JSON output for debugging information
3. Verify browser automation setup (Puppeteer/SafariDriver)

This toolkit transforms CSS rendering debugging from guesswork into systematic, evidence-based investigation.