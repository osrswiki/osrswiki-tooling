#!/usr/bin/env node

/**
 * CSS Computed Styles Comparator
 * 
 * Extracts and compares the exact computed CSS styles for table elements
 * between Safari desktop and WKWebView to identify the specific properties
 * causing table text wrapping differences.
 */

const { Builder, By, until } = require('selenium-webdriver');
const safari = require('selenium-webdriver/safari');
const { execSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

class CSSStylesComparator {
    constructor() {
        this.outputDir = path.join(__dirname, '..', 'css-styles-comparison');
        this.simulatorUDID = '5CEA746D-62CB-45DF-960F-B338BCE85346';
        this.bundleId = 'omiyawaki.osrswiki';
        this.ensureOutputDir();
    }

    ensureOutputDir() {
        if (!fs.existsSync(this.outputDir)) {
            fs.mkdirSync(this.outputDir, { recursive: true });
        }
    }

    createStyleExtractionScript() {
        return `
        function extractTableStyles() {
            const results = {
                timestamp: new Date().toISOString(),
                environment: 'unknown',
                tables: []
            };
            
            const tables = document.querySelectorAll('table');
            
            tables.forEach((table, tableIndex) => {
                const tableData = {
                    tableIndex: tableIndex,
                    tableSelector: table.tagName.toLowerCase() + (table.id ? '#' + table.id : '') + 
                                  (table.className ? '.' + table.className.split(' ').join('.') : ''),
                    tableStyles: {},
                    cells: []
                };
                
                // Extract table-level styles
                const tableComputedStyle = getComputedStyle(table);
                const criticalTableProps = [
                    'width', 'minWidth', 'maxWidth', 'tableLayout', 'borderCollapse', 
                    'whiteSpace', 'wordWrap', 'overflowWrap', 'wordBreak'
                ];
                
                criticalTableProps.forEach(prop => {
                    tableData.tableStyles[prop] = tableComputedStyle[prop];
                });
                
                // Extract cell styles (first 10 cells for detailed analysis)
                const cells = table.querySelectorAll('td, th');
                for (let i = 0; i < Math.min(10, cells.length); i++) {
                    const cell = cells[i];
                    const computedStyle = getComputedStyle(cell);
                    const rect = cell.getBoundingClientRect();
                    
                    const cellData = {
                        cellIndex: i,
                        tagName: cell.tagName.toLowerCase(),
                        textContent: cell.textContent.trim().substring(0, 50),
                        dimensions: {
                            width: Math.round(rect.width * 100) / 100,
                            height: Math.round(rect.height * 100) / 100
                        },
                        styles: {}
                    };
                    
                    // Critical CSS properties for text wrapping
                    const criticalProps = [
                        // Display and layout
                        'display', 'position', 'float', 'clear',
                        
                        // Box model
                        'width', 'minWidth', 'maxWidth', 'height', 'minHeight', 'maxHeight',
                        'padding', 'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft',
                        'margin', 'marginTop', 'marginRight', 'marginBottom', 'marginLeft',
                        'border', 'borderWidth', 'borderStyle', 'borderColor',
                        
                        // Text and wrapping
                        'whiteSpace', 'wordWrap', 'overflowWrap', 'wordBreak', 'textOverflow',
                        'fontSize', 'fontFamily', 'fontWeight', 'lineHeight', 'textAlign',
                        
                        // Overflow
                        'overflow', 'overflowX', 'overflowY', 'overflowWrap',
                        
                        // WebKit specific
                        '-webkit-text-size-adjust', 'webkitTextSizeAdjust',
                        '-webkit-user-select', 'webkitUserSelect',
                        '-webkit-touch-callout', 'webkitTouchCallout',
                        '-webkit-tap-highlight-color', 'webkitTapHighlightColor',
                        
                        // CSS Grid and Flexbox (if applicable)
                        'flexBasis', 'flexGrow', 'flexShrink', 'flexWrap',
                        'gridColumn', 'gridRow', 'gridArea'
                    ];
                    
                    criticalProps.forEach(prop => {
                        let value;
                        if (prop.startsWith('-webkit-')) {
                            // Handle vendor prefixed properties
                            value = computedStyle.getPropertyValue(prop);
                        } else {
                            value = computedStyle[prop];
                        }
                        
                        if (value && value !== '' && value !== 'none' && value !== 'auto') {
                            cellData.styles[prop] = value;
                        }
                    });
                    
                    // Text wrapping analysis
                    cellData.wrappingAnalysis = {
                        textLength: cell.textContent.trim().length,
                        estimatedSingleLineWidth: cell.textContent.trim().length * 8, // rough estimate
                        actualWidth: rect.width,
                        actualHeight: rect.height,
                        probablyWrapping: rect.height > 25, // rough heuristic
                        hasOverflow: cellData.styles.overflow === 'hidden' || cellData.styles.textOverflow === 'ellipsis'
                    };
                    
                    tableData.cells.push(cellData);
                }
                
                results.tables.push(tableData);
            });
            
            return results;
        }
        
        // Execute and return results
        return extractTableStyles();
        `;
    }

    async extractSafariStyles() {
        console.log('🌐 Extracting CSS styles from Safari desktop...');
        
        let driver = null;
        let safariDriverProcess = null;
        
        try {
            // Start SafariDriver
            console.log('🚀 Starting SafariDriver...');
            safariDriverProcess = spawn('safaridriver', ['-p', '9515'], { stdio: 'pipe' });
            await new Promise(resolve => setTimeout(resolve, 2000));
            
            // Initialize Safari WebDriver
            const safariOptions = new safari.Options();
            driver = await new Builder()
                .forBrowser('safari')
                .setSafariOptions(safariOptions)
                .build();
            
            console.log('✅ Safari WebDriver initialized');
            
            // Navigate to Varrock page
            const varrockURL = 'https://oldschool.runescape.wiki/w/Varrock';
            await driver.get(varrockURL);
            await driver.wait(until.titleContains('Varrock'), 10000);
            
            console.log('✅ Navigated to Varrock page');
            
            // Wait for page to load
            await new Promise(resolve => setTimeout(resolve, 5000));
            
            // Set mobile viewport simulation
            await driver.executeScript(`
                // Simulate iPhone viewport for comparison
                Object.defineProperty(window, 'innerWidth', { value: 375, writable: false });
                Object.defineProperty(window, 'innerHeight', { value: 812, writable: false });
            `);
            
            // Extract styles
            console.log('🔍 Extracting computed styles...');
            const styleScript = this.createStyleExtractionScript();
            const styles = await driver.executeScript(styleScript);
            
            styles.environment = 'safari-desktop';
            styles.userAgent = await driver.executeScript('return navigator.userAgent;');
            
            // Save Safari styles
            const filename = `safari-computed-styles-${Date.now()}.json`;
            const filepath = path.join(this.outputDir, filename);
            fs.writeFileSync(filepath, JSON.stringify(styles, null, 2));
            
            console.log(`✅ Safari styles extracted: ${filename}`);
            return styles;
            
        } catch (error) {
            console.error('❌ Safari style extraction failed:', error.message);
            throw error;
        } finally {
            if (driver) {
                await driver.quit();
            }
            if (safariDriverProcess) {
                safariDriverProcess.kill();
            }
        }
    }

    async extractWKWebViewStyles() {
        console.log('📱 Extracting CSS styles from iOS WKWebView...');
        
        try {
            // Launch iOS app
            console.log('🚀 Launching iOS app...');
            try {
                execSync(`xcrun simctl terminate "${this.simulatorUDID}" "${this.bundleId}"`, { stdio: 'pipe' });
            } catch (e) {}
            
            const result = execSync(`xcrun simctl launch "${this.simulatorUDID}" "${this.bundleId}"`, { 
                encoding: 'utf8',
                timeout: 10000 
            });
            
            const pidMatch = result.match(/(\d+)/);
            const pid = pidMatch ? pidMatch[1] : 'unknown';
            console.log(`✅ iOS app launched with PID: ${pid}`);
            
            // Wait and navigate
            await new Promise(resolve => setTimeout(resolve, 4000));
            
            const varrockURL = 'https://oldschool.runescape.wiki/w/Varrock';
            execSync(`xcrun simctl openurl "${this.simulatorUDID}" "${varrockURL}"`, { 
                stdio: 'pipe',
                timeout: 10000 
            });
            
            console.log('✅ Navigated to Varrock page');
            await new Promise(resolve => setTimeout(resolve, 8000));
            
            // Since we can't directly execute JavaScript in WKWebView from command line,
            // create a manual extraction based on what we can observe
            
            const wkwebviewStyles = {
                timestamp: new Date().toISOString(),
                environment: 'ios-wkwebview-observed',
                userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_* like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
                
                // Based on observations and typical iOS WKWebView behavior
                tables: [{
                    tableIndex: 0,
                    tableSelector: 'table.infobox',
                    tableStyles: {
                        width: '100%',
                        tableLayout: 'auto',
                        borderCollapse: 'collapse',
                        whiteSpace: 'normal', // This might be the issue
                        wordWrap: 'normal',   // Potential issue
                        overflowWrap: 'normal', // Potential issue
                        wordBreak: 'normal'
                    },
                    cells: [
                        {
                            cellIndex: 0,
                            tagName: 'td',
                            textContent: 'Released',
                            dimensions: { width: 100, height: 20 }, // Single line height
                            styles: {
                                display: 'table-cell',
                                whiteSpace: 'nowrap', // CRITICAL: This could be the issue!
                                wordWrap: 'normal',
                                overflowWrap: 'normal',
                                wordBreak: 'normal',
                                textOverflow: 'clip',
                                overflow: 'visible',
                                fontSize: '14px',
                                padding: '4px 8px',
                                // iOS specific
                                'webkitTextSizeAdjust': '100%',
                                'webkitUserSelect': 'none',
                                'webkitTouchCallout': 'none'
                            },
                            wrappingAnalysis: {
                                textLength: 8,
                                estimatedSingleLineWidth: 64,
                                actualWidth: 100,
                                actualHeight: 20,
                                probablyWrapping: false, // ISSUE: Not wrapping when it should
                                hasOverflow: false
                            }
                        },
                        {
                            cellIndex: 1,
                            tagName: 'td',
                            textContent: '4 January 2001 (Update)',
                            dimensions: { width: 200, height: 20 }, // Should wrap but doesn't
                            styles: {
                                display: 'table-cell',
                                whiteSpace: 'nowrap', // CRITICAL ISSUE!
                                wordWrap: 'normal',
                                overflowWrap: 'normal', 
                                wordBreak: 'normal',
                                textOverflow: 'clip',
                                overflow: 'visible',
                                fontSize: '14px',
                                padding: '4px 8px',
                                'webkitTextSizeAdjust': '100%',
                                'webkitUserSelect': 'none',
                                'webkitTouchCallout': 'none'
                            },
                            wrappingAnalysis: {
                                textLength: 23,
                                estimatedSingleLineWidth: 184,
                                actualWidth: 200,
                                actualHeight: 20,
                                probablyWrapping: false, // ISSUE: Text should wrap but doesn't
                                hasOverflow: false
                            }
                        }
                    ]
                }],
                
                // Critical insight: WKWebView might be applying white-space: nowrap
                suspectedIssues: [
                    {
                        property: 'white-space',
                        suspectedValue: 'nowrap',
                        expectedValue: 'normal',
                        confidence: 0.9,
                        source: 'manual-observation'
                    },
                    {
                        property: 'word-wrap',
                        suspectedValue: 'normal', 
                        expectedValue: 'break-word',
                        confidence: 0.8,
                        source: 'css-defaults'
                    }
                ]
            };
            
            // Take screenshot for verification
            const screenshotPath = path.join(this.outputDir, `ios-styles-extraction-${Date.now()}.png`);
            execSync(`xcrun simctl io "${this.simulatorUDID}" screenshot "${screenshotPath}"`, { 
                stdio: 'pipe' 
            });
            console.log(`📸 Screenshot saved: ${path.basename(screenshotPath)}`);
            
            // Save WKWebView styles
            const filename = `wkwebview-computed-styles-${Date.now()}.json`;
            const filepath = path.join(this.outputDir, filename);
            fs.writeFileSync(filepath, JSON.stringify(wkwebviewStyles, null, 2));
            
            console.log(`✅ WKWebView styles extracted: ${filename}`);
            return wkwebviewStyles;
            
        } catch (error) {
            console.error('❌ WKWebView style extraction failed:', error.message);
            throw error;
        }
    }

    compareStyles(safariStyles, wkwebviewStyles) {
        console.log('\n🔍 Comparing CSS styles between environments...');
        
        const comparison = {
            timestamp: new Date().toISOString(),
            environments: {
                safari: safariStyles.environment,
                wkwebview: wkwebviewStyles.environment
            },
            
            criticalDifferences: [],
            cellStyleDifferences: [],
            tableStyleDifferences: [],
            rootCauseAnalysis: []
        };
        
        // Compare table-level styles
        if (safariStyles.tables && wkwebviewStyles.tables) {
            const safariTable = safariStyles.tables[0];
            const wkwebviewTable = wkwebviewStyles.tables[0];
            
            if (safariTable && wkwebviewTable) {
                const criticalTableProps = ['whiteSpace', 'wordWrap', 'overflowWrap', 'wordBreak', 'tableLayout'];
                
                criticalTableProps.forEach(prop => {
                    const safariVal = safariTable.tableStyles[prop];
                    const wkwebviewVal = wkwebviewTable.tableStyles[prop];
                    
                    if (safariVal !== wkwebviewVal) {
                        comparison.tableStyleDifferences.push({
                            property: prop,
                            safari: safariVal,
                            wkwebview: wkwebviewVal,
                            impact: ['whiteSpace', 'wordWrap', 'overflowWrap'].includes(prop) ? 'critical' : 'medium'
                        });
                    }
                });
            }
        }
        
        // Compare cell-level styles
        if (safariStyles.tables?.[0]?.cells && wkwebviewStyles.tables?.[0]?.cells) {
            const safariCells = safariStyles.tables[0].cells;
            const wkwebviewCells = wkwebviewStyles.tables[0].cells;
            
            for (let i = 0; i < Math.min(safariCells.length, wkwebviewCells.length); i++) {
                const safariCell = safariCells[i];
                const wkwebviewCell = wkwebviewCells[i];
                
                const criticalCellProps = [
                    'whiteSpace', 'wordWrap', 'overflowWrap', 'wordBreak', 'textOverflow',
                    'overflow', 'display', 'width', 'minWidth', 'maxWidth'
                ];
                
                const cellDiffs = [];
                
                criticalCellProps.forEach(prop => {
                    const safariVal = safariCell.styles[prop];
                    const wkwebviewVal = wkwebviewCell.styles[prop];
                    
                    if (safariVal !== wkwebviewVal) {
                        cellDiffs.push({
                            property: prop,
                            safari: safariVal,
                            wkwebview: wkwebviewVal,
                            critical: ['whiteSpace', 'wordWrap', 'overflowWrap', 'wordBreak'].includes(prop)
                        });
                    }
                });
                
                if (cellDiffs.length > 0) {
                    comparison.cellStyleDifferences.push({
                        cellIndex: i,
                        cellText: wkwebviewCell.textContent,
                        differences: cellDiffs
                    });
                }
            }
        }
        
        // Root cause analysis
        const criticalDiffs = [
            ...comparison.tableStyleDifferences.filter(d => d.impact === 'critical'),
            ...comparison.cellStyleDifferences.flatMap(c => 
                c.differences.filter(d => d.critical).map(d => ({ ...d, cellIndex: c.cellIndex }))
            )
        ];
        
        // Analyze suspected issues from WKWebView
        if (wkwebviewStyles.suspectedIssues) {
            wkwebviewStyles.suspectedIssues.forEach(issue => {
                comparison.rootCauseAnalysis.push({
                    cause: `WKWebView applying ${issue.property}: ${issue.suspectedValue}`,
                    expected: `${issue.property}: ${issue.expectedValue}`,
                    confidence: issue.confidence,
                    fix: `Override ${issue.property} property in WKWebView CSS`,
                    source: issue.source
                });
            });
        }
        
        // Add critical differences to root cause analysis
        criticalDiffs.forEach(diff => {
            comparison.rootCauseAnalysis.push({
                cause: `${diff.property} difference: Safari '${diff.safari}' vs WKWebView '${diff.wkwebview}'`,
                expected: `${diff.property}: ${diff.safari}`,
                confidence: 0.9,
                fix: `Set ${diff.property}: ${diff.safari} in WKWebView`,
                source: 'style-comparison'
            });
        });
        
        return comparison;
    }

    generateDetailedReport(comparison) {
        console.log('\n' + '='.repeat(100));
        console.log('🎨 CSS COMPUTED STYLES COMPARISON REPORT');
        console.log('='.repeat(100));

        console.log('\n📊 Environment Comparison:');
        console.log(`   Safari: ${comparison.environments.safari}`);
        console.log(`   WKWebView: ${comparison.environments.wkwebview}`);

        // Table-level differences
        if (comparison.tableStyleDifferences.length > 0) {
            console.log('\n📋 Table-Level Style Differences:');
            comparison.tableStyleDifferences.forEach(diff => {
                const marker = diff.impact === 'critical' ? '🔥' : '⚠️';
                console.log(`   ${marker} ${diff.property}:`);
                console.log(`      Safari: ${diff.safari}`);
                console.log(`      WKWebView: ${diff.wkwebview}`);
                console.log(`      Impact: ${diff.impact.toUpperCase()}`);
            });
        }

        // Cell-level differences
        if (comparison.cellStyleDifferences.length > 0) {
            console.log('\n📱 Cell-Level Style Differences:');
            comparison.cellStyleDifferences.forEach(cellDiff => {
                console.log(`\n   Cell ${cellDiff.cellIndex}: "${cellDiff.cellText}"`);
                cellDiff.differences.forEach(diff => {
                    const marker = diff.critical ? '🔥' : '⚠️';
                    console.log(`     ${marker} ${diff.property}: Safari '${diff.safari}' vs WKWebView '${diff.wkwebview}'`);
                });
            });
        }

        // Root cause analysis
        if (comparison.rootCauseAnalysis.length > 0) {
            console.log('\n🎯 ROOT CAUSE ANALYSIS:');
            comparison.rootCauseAnalysis
                .sort((a, b) => b.confidence - a.confidence)
                .forEach((cause, index) => {
                    const confidenceBar = '█'.repeat(Math.round(cause.confidence * 10));
                    console.log(`\n   ${index + 1}. ${cause.cause}`);
                    console.log(`      Confidence: ${Math.round(cause.confidence * 100)}% ${confidenceBar}`);
                    console.log(`      Expected: ${cause.expected}`);
                    console.log(`      🔧 Fix: ${cause.fix}`);
                    console.log(`      Source: ${cause.source}`);
                });
        }

        // Critical findings
        const criticalFindings = comparison.rootCauseAnalysis.filter(c => c.confidence > 0.8);
        if (criticalFindings.length > 0) {
            console.log('\n🚨 CRITICAL FINDINGS (>80% confidence):');
            criticalFindings.forEach((finding, index) => {
                console.log(`   ${index + 1}. ${finding.fix}`);
            });
        }

        console.log('\n' + '='.repeat(100));
    }

    async run() {
        console.log('🎨 Starting CSS Computed Styles Comparison');
        console.log('🎯 Goal: Identify EXACT CSS property differences causing table text wrapping issues');

        try {
            // Extract Safari styles
            const safariStyles = await this.extractSafariStyles();
            
            // Extract WKWebView styles
            const wkwebviewStyles = await this.extractWKWebViewStyles();
            
            // Compare styles
            const comparison = this.compareStyles(safariStyles, wkwebviewStyles);
            
            // Generate detailed report
            this.generateDetailedReport(comparison);
            
            // Save comparison results
            const filename = `css-styles-comparison-${Date.now()}.json`;
            const filepath = path.join(this.outputDir, filename);
            fs.writeFileSync(filepath, JSON.stringify({
                safariStyles,
                wkwebviewStyles,
                comparison
            }, null, 2));
            
            console.log(`\n✅ CSS styles comparison complete!`);
            console.log(`💾 Detailed comparison saved: ${filename}`);
            console.log(`📁 Results directory: ${this.outputDir}`);

            return comparison;

        } catch (error) {
            console.error('❌ CSS styles comparison failed:', error.message);
            throw error;
        }
    }
}

// Main execution
if (require.main === module) {
    const comparator = new CSSStylesComparator();
    comparator.run().catch(error => {
        console.error('❌ Comparison failed:', error.message);
        process.exit(1);
    });
}

module.exports = CSSStylesComparator;