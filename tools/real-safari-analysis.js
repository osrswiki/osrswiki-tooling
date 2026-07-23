#!/usr/bin/env node

/**
 * Real Safari WebKit Analysis Tool
 * 
 * This tool uses actual Safari browser (WebKit engine) via AppleScript automation
 * to get true WebKit behavior, not Chromium simulation.
 * Fully automated - enables required Safari settings programmatically.
 */

const { execSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

class RealSafariAnalyzer {
    constructor() {
        this.outputDir = path.join(__dirname, '..', 'safari-webkit-debug');
        this.ensureOutputDir();
    }

    ensureOutputDir() {
        if (!fs.existsSync(this.outputDir)) {
            fs.mkdirSync(this.outputDir, { recursive: true });
        }
    }

    async enableSafariAutomation() {
        console.log('🔧 Automatically enabling Safari automation...');
        
        try {
            // Enable Develop menu
            execSync('defaults write com.apple.Safari IncludeDevelopMenu -bool true', { stdio: 'pipe' });
            
            // Enable Remote Automation
            execSync('defaults write com.apple.Safari AllowRemoteAutomation -bool true', { stdio: 'pipe' });
            
            // Enable JavaScript from Apple Events
            execSync('defaults write com.apple.Safari AllowJavaScriptFromAppleEvents -bool true', { stdio: 'pipe' });
            
            console.log('✅ Safari automation settings enabled');
            
            // Restart Safari to apply settings
            try {
                execSync('killall Safari', { stdio: 'pipe' });
                await new Promise(resolve => setTimeout(resolve, 2000));
            } catch (e) {
                // Safari might not be running
            }
            
            return true;
        } catch (error) {
            console.error('❌ Failed to enable Safari automation:', error.message);
            return false;
        }
    }

    async runAppleScript(script) {
        try {
            const result = execSync(`osascript -e '${script.replace(/'/g, "'\"'\"'")}'`, { 
                encoding: 'utf8',
                timeout: 30000 
            });
            return result.trim();
        } catch (error) {
            throw new Error(`AppleScript error: ${error.message}`);
        }
    }

    async run() {
        console.log('🚀 Starting Real Safari WebKit Analysis...');
        console.log('🦾 Using actual Safari browser with WebKit engine');

        // Enable automation settings
        if (!(await this.enableSafariAutomation())) {
            throw new Error('Failed to enable Safari automation');
        }

        console.log('🌐 Opening Safari and navigating to Varrock...');

        // Open Safari and navigate
        const navigationScript = `
            tell application "Safari"
                activate
                
                -- Close any existing tabs and create fresh window
                set windowCount to count of windows
                if windowCount > 0 then
                    close every window
                end if
                
                -- Create new window and navigate
                make new document with properties {URL:"https://oldschool.runescape.wiki/w/Varrock"}
                
                -- Wait for page to load
                set loadTimeout to 0
                repeat while (do JavaScript "document.readyState" in front document) ≠ "complete"
                    delay 0.5
                    set loadTimeout to loadTimeout + 1
                    if loadTimeout > 60 then
                        error "Page load timeout"
                    end if
                end repeat
                
                -- Wait for dynamic content
                delay 5
                
                return "Navigation complete"
            end tell
        `;

        await this.runAppleScript(navigationScript);
        console.log('📄 Page loaded in Safari');

        console.log('🔍 Running comprehensive WebKit table analysis...');

        // Run the analysis in Safari
        const analysisScript = `
            tell application "Safari"
                set analysisJS to "
                (function() {
                    const analysis = {
                        timestamp: new Date().toISOString(),
                        platform: 'real-safari-webkit',
                        engine: 'WebKit',
                        browser: 'Safari',
                        environment: {
                            userAgent: navigator.userAgent,
                            viewport: {
                                width: window.innerWidth,
                                height: window.innerHeight,
                                devicePixelRatio: window.devicePixelRatio || 1
                            },
                            screen: {
                                width: screen.width,
                                height: screen.height,
                                availWidth: screen.availWidth,
                                availHeight: screen.availHeight
                            },
                            documentReadyState: document.readyState
                        },
                        mediaQueries: {
                            mobile: window.matchMedia('(max-width: 768px)').matches,
                            tablet: window.matchMedia('(min-width: 768px) and (max-width: 1024px)').matches,
                            desktop: window.matchMedia('(min-width: 1024px)').matches,
                            retina: window.matchMedia('(-webkit-min-device-pixel-ratio: 2)').matches,
                            portrait: window.matchMedia('(orientation: portrait)').matches
                        },
                        webkit: {
                            textSizeAdjustSupported: CSS.supports('-webkit-text-size-adjust', '100%'),
                            webkitOverflowScrolling: CSS.supports('-webkit-overflow-scrolling', 'touch'),
                            webkitTransform: CSS.supports('-webkit-transform', 'scale(1)'),
                            webkitAppearance: CSS.supports('-webkit-appearance', 'none')
                        },
                        tables: []
                    };
                    
                    // Find and analyze all wikitable elements
                    const tables = document.querySelectorAll('table.wikitable');
                    console.log('Found ' + tables.length + ' wikitable elements');
                    
                    tables.forEach((table, index) => {
                        if (index < 10) { // Analyze first 10 tables to avoid timeout
                            const tableAnalysis = {
                                index: index,
                                tableStyles: {},
                                cells: [],
                                wrappingBehavior: {
                                    totalCells: 0,
                                    wrappingCells: 0,
                                    singleLineCells: 0,
                                    overflowingCells: 0
                                }
                            };
                            
                            // Get table dimensions and styles
                            const tableRect = table.getBoundingClientRect();
                            const tableStyles = window.getComputedStyle(table);
                            
                            tableAnalysis.dimensions = {
                                width: tableRect.width,
                                height: tableRect.height
                            };
                            
                            tableAnalysis.tableStyles = {
                                width: tableStyles.width,
                                maxWidth: tableStyles.maxWidth,
                                tableLayout: tableStyles.tableLayout,
                                borderCollapse: tableStyles.borderCollapse,
                                fontSize: tableStyles.fontSize,
                                fontFamily: tableStyles.fontFamily,
                                textSizeAdjust: tableStyles.webkitTextSizeAdjust || tableStyles.textSizeAdjust || 'auto',
                                wordWrap: tableStyles.wordWrap,
                                overflowWrap: tableStyles.overflowWrap,
                                wordBreak: tableStyles.wordBreak,
                                whiteSpace: tableStyles.whiteSpace
                            };
                            
                            // Analyze cells
                            const cells = table.querySelectorAll('td, th');
                            cells.forEach((cell, cellIndex) => {
                                if (cellIndex < 20) { // First 20 cells per table
                                    const cellRect = cell.getBoundingClientRect();
                                    const cellStyles = window.getComputedStyle(cell);
                                    const textContent = cell.textContent.trim();
                                    
                                    // Test for text wrapping using temporary element
                                    const testEl = document.createElement('div');
                                    testEl.style.cssText = 'position: absolute; visibility: hidden; top: -9999px; width: ' + cellRect.width + 'px; font-family: inherit; font-size: inherit; word-wrap: inherit; overflow-wrap: inherit; word-break: inherit; white-space: inherit;';
                                    testEl.textContent = textContent;
                                    document.body.appendChild(testEl);
                                    
                                    const wrappedHeight = testEl.getBoundingClientRect().height;
                                    
                                    testEl.style.whiteSpace = 'nowrap';
                                    const singleLineWidth = testEl.getBoundingClientRect().width;
                                    const singleLineHeight = testEl.getBoundingClientRect().height;
                                    
                                    document.body.removeChild(testEl);
                                    
                                    const isWrapping = wrappedHeight > singleLineHeight * 1.1;
                                    const isOverflowing = singleLineWidth > cellRect.width * 1.05;
                                    
                                    tableAnalysis.cells.push({
                                        index: cellIndex,
                                        textContent: textContent.substring(0, 100),
                                        textLength: textContent.length,
                                        dimensions: {
                                            width: cellRect.width,
                                            height: cellRect.height,
                                            singleLineWidth: singleLineWidth,
                                            wrappedHeight: wrappedHeight
                                        },
                                        wrapping: {
                                            isWrapping: isWrapping,
                                            isOverflowing: isOverflowing
                                        },
                                        styles: {
                                            wordWrap: cellStyles.wordWrap,
                                            overflowWrap: cellStyles.overflowWrap,
                                            wordBreak: cellStyles.wordBreak,
                                            whiteSpace: cellStyles.whiteSpace,
                                            textSizeAdjust: cellStyles.webkitTextSizeAdjust || cellStyles.textSizeAdjust || 'auto',
                                            fontSize: cellStyles.fontSize,
                                            fontFamily: cellStyles.fontFamily
                                        }
                                    });
                                    
                                    tableAnalysis.wrappingBehavior.totalCells++;
                                    if (isWrapping) {
                                        tableAnalysis.wrappingBehavior.wrappingCells++;
                                    } else {
                                        tableAnalysis.wrappingBehavior.singleLineCells++;
                                    }
                                    if (isOverflowing) {
                                        tableAnalysis.wrappingBehavior.overflowingCells++;
                                    }
                                }
                            });
                            
                            analysis.tables.push(tableAnalysis);
                        }
                    });
                    
                    // MediaWiki analysis
                    analysis.mediaWiki = {
                        version: window.mw ? window.mw.config.get('wgVersion') : null,
                        skin: window.mw ? window.mw.config.get('skin') : null,
                        isMediaWikiLoaded: typeof window.mw !== 'undefined',
                        jQueryVersion: window.jQuery ? window.jQuery.fn.jquery : null
                    };
                    
                    return JSON.stringify(analysis);
                })();
                "
                
                set result to do JavaScript analysisJS in front document
                return result
            end tell
        `;

        const jsonResult = await this.runAppleScript(analysisScript);
        const analysis = JSON.parse(jsonResult);

        // Save and report results
        await this.saveResults(analysis);
        this.generateReport(analysis);

        // Close Safari
        try {
            await this.runAppleScript('tell application "Safari" to close every window');
        } catch (e) {
            // Ignore errors when closing
        }

        console.log('✅ Real Safari WebKit analysis complete!');
    }

    async saveResults(analysis) {
        const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
        const filename = `safari-webkit-analysis-${timestamp}.json`;
        const filepath = path.join(this.outputDir, filename);

        try {
            await fs.promises.writeFile(filepath, JSON.stringify(analysis, null, 2));
            console.log(`💾 Safari WebKit analysis saved to: ${filepath}`);
            return filepath;
        } catch (error) {
            console.error('❌ Failed to save Safari analysis:', error.message);
            throw error;
        }
    }

    generateReport(analysis) {
        console.log('\n' + '='.repeat(70));
        console.log('🦾 REAL SAFARI WEBKIT ANALYSIS REPORT');
        console.log('='.repeat(70));

        console.log('\n🌐 Environment:');
        console.log(`   Platform: ${analysis.platform}`);
        console.log(`   Engine: ${analysis.engine}`);
        console.log(`   Browser: ${analysis.browser}`);
        console.log(`   User Agent: ${analysis.environment.userAgent}`);
        console.log(`   Viewport: ${analysis.environment.viewport.width}x${analysis.environment.viewport.height} (DPR: ${analysis.environment.viewport.devicePixelRatio})`);

        // WebKit-specific features
        console.log('\n🦾 WebKit Features:');
        Object.entries(analysis.webkit).forEach(([feature, supported]) => {
            console.log(`   ${feature}: ${supported ? '✅ supported' : '❌ not supported'}`);
        });

        // MediaWiki
        console.log('\n📚 MediaWiki:');
        console.log(`   MediaWiki loaded: ${analysis.mediaWiki.isMediaWikiLoaded ? '✅ yes' : '❌ no'}`);
        if (analysis.mediaWiki.version) {
            console.log(`   Version: ${analysis.mediaWiki.version}`);
        }
        if (analysis.mediaWiki.skin) {
            console.log(`   Skin: ${analysis.mediaWiki.skin}`);
        }

        // Table analysis
        console.log('\n📊 Table Analysis:');
        console.log(`   Tables analyzed: ${analysis.tables.length}`);

        let totalCells = 0;
        let totalWrappingCells = 0;
        let totalSingleLineCells = 0;
        let totalOverflowingCells = 0;

        analysis.tables.forEach((table, index) => {
            const behavior = table.wrappingBehavior;
            totalCells += behavior.totalCells;
            totalWrappingCells += behavior.wrappingCells;
            totalSingleLineCells += behavior.singleLineCells;
            totalOverflowingCells += behavior.overflowingCells;

            const wrappingPercentage = behavior.totalCells > 0 ? Math.round((behavior.wrappingCells * 100) / behavior.totalCells) : 0;

            console.log(`\n   Table ${index + 1}:`);
            console.log(`     - Dimensions: ${Math.round(table.dimensions.width)}x${Math.round(table.dimensions.height)}px`);
            console.log(`     - Table layout: ${table.tableStyles.tableLayout}`);
            console.log(`     - Text size adjust: ${table.tableStyles.textSizeAdjust}`);
            console.log(`     - Cells analyzed: ${behavior.totalCells}`);
            console.log(`     - Wrapping cells: ${behavior.wrappingCells} (${wrappingPercentage}%)`);
            console.log(`     - Single-line cells: ${behavior.singleLineCells}`);
            console.log(`     - Overflowing cells: ${behavior.overflowingCells}`);

            if (behavior.overflowingCells > 0 && behavior.wrappingCells === 0) {
                console.log(`     ⚠️  WEBKIT ISSUE: Content overflows but doesn't wrap!`);
            }
        });

        // Summary
        const overallWrappingPercentage = totalCells > 0 ? Math.round((totalWrappingCells * 100) / totalCells) : 0;
        
        console.log('\n📈 WebKit Summary:');
        console.log(`   Total cells: ${totalCells}`);
        console.log(`   Wrapping cells: ${totalWrappingCells} (${overallWrappingPercentage}%)`);
        console.log(`   Single-line cells: ${totalSingleLineCells}`);
        console.log(`   Overflowing cells: ${totalOverflowingCells}`);

        console.log('\n🎯 WebKit vs Chromium Comparison:');
        console.log('   This is REAL WebKit behavior (same engine as iOS WKWebView)');
        console.log('   Compare these results with the Puppeteer/Chromium analysis');
        
        console.log('\n' + '='.repeat(70));
    }
}

// Main execution
if (require.main === module) {
    const analyzer = new RealSafariAnalyzer();
    analyzer.run().catch(error => {
        console.error('❌ Real Safari analysis failed:', error.message);
        process.exit(1);
    });
}

module.exports = RealSafariAnalyzer;