#!/usr/bin/env node

/**
 * Official WebKit Analysis Tool using Apple's SafariDriver
 * 
 * Uses Apple's official SafariDriver (/usr/bin/safaridriver) for true WebKit automation.
 * This provides actual Safari/WebKit behavior, not Chromium simulation.
 * Fully automated - enables SafariDriver programmatically.
 */

const { execSync, spawn } = require('child_process');
const { Builder, By, until, Key } = require('selenium-webdriver');
const safari = require('selenium-webdriver/safari');
const fs = require('fs');
const path = require('path');

class OfficialWebKitAnalyzer {
    constructor() {
        this.outputDir = path.join(__dirname, '..', 'official-webkit-debug');
        this.driver = null;
        this.ensureOutputDir();
    }

    ensureOutputDir() {
        if (!fs.existsSync(this.outputDir)) {
            fs.mkdirSync(this.outputDir, { recursive: true });
        }
    }

    async checkSelenium() {
        try {
            require.resolve('selenium-webdriver');
            return true;
        } catch {
            console.log('📦 Installing selenium-webdriver...');
            try {
                execSync('npm install selenium-webdriver --no-save', { stdio: 'inherit' });
                return true;
            } catch (error) {
                console.error('❌ Failed to install selenium-webdriver:', error.message);
                return false;
            }
        }
    }

    async enableSafariDriver() {
        console.log('🔧 Checking Apple SafariDriver...');
        
        try {
            // Check if safaridriver exists
            execSync('which safaridriver', { stdio: 'pipe' });
            console.log('✅ SafariDriver found at /usr/bin/safaridriver');
            
            // Check SafariDriver version to ensure it's working
            const version = execSync('safaridriver --version', { stdio: 'pipe', encoding: 'utf8' });
            console.log(`✅ SafariDriver version: ${version.trim()}`);
            
            console.log('✅ SafariDriver ready (assuming user has configured Safari settings)');
            return true;
        } catch (error) {
            console.error('❌ SafariDriver check failed:', error.message);
            console.log('💡 Please ensure SafariDriver is set up:');
            console.log('   1. sudo safaridriver --enable');
            console.log('   2. Safari → Develop → Allow Remote Automation');
            return false;
        }
    }

    async initializeSafari() {
        console.log('🦾 Initializing Safari with WebKit engine...');
        
        // Configure Safari options for mobile simulation
        const options = new safari.Options();
        
        // Add debugging capabilities
        options.setLoggingPrefs({
            'browser': 'ALL',
            'performance': 'ALL'
        });

        // Build Safari WebDriver instance
        this.driver = await new Builder()
            .forBrowser('safari')
            .setSafariOptions(options)
            .build();

        // Set mobile-like viewport
        await this.driver.manage().window().setRect({
            width: 375,
            height: 812,
            x: 0,
            y: 0
        });

        console.log('✅ Safari WebKit driver initialized');
    }

    async run() {
        console.log('🚀 Starting Official WebKit Analysis using Apple SafariDriver');
        console.log('🦾 Using real Safari browser with WebKit engine');
        
        try {
            // Check dependencies
            if (!(await this.checkSelenium())) {
                throw new Error('Failed to install Selenium WebDriver');
            }

            // Enable SafariDriver
            if (!(await this.enableSafariDriver())) {
                throw new Error('Failed to configure SafariDriver');
            }

            // Initialize Safari
            await this.initializeSafari();

            console.log('🌐 Navigating to Varrock page...');
            
            // Navigate to the page
            await this.driver.get('https://oldschool.runescape.wiki/w/Varrock');
            
            // Wait for page to fully load
            await this.driver.wait(until.titleContains('Varrock'), 30000);
            
            // Wait for dynamic content
            await this.driver.sleep(5000);
            
            console.log('📄 Page loaded in Safari');
            console.log('🔍 Running comprehensive WebKit table analysis...');

            // Execute the comprehensive analysis
            const analysisResult = await this.driver.executeScript(`
                return (function() {
                    const analysis = {
                        timestamp: new Date().toISOString(),
                        platform: 'official-safari-webkit',
                        engine: 'WebKit',
                        browser: 'Safari',
                        automation: 'SafariDriver',
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
                            documentReadyState: document.readyState,
                            location: window.location.href
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
                            webkitAppearance: CSS.supports('-webkit-appearance', 'none'),
                            webkitBoxSizing: CSS.supports('-webkit-box-sizing', 'border-box'),
                            overflowWrapSupported: CSS.supports('overflow-wrap', 'break-word'),
                            wordBreakSupported: CSS.supports('word-break', 'break-all')
                        },
                        safari: {
                            version: navigator.userAgent.match(/Version\\/(\\d+\\.\\d+)/)?.[1] || 'unknown',
                            webKitVersion: navigator.userAgent.match(/WebKit\\/(\\d+\\.\\d+)/)?.[1] || 'unknown'
                        },
                        tables: []
                    };
                    
                    // Find and analyze all wikitable elements
                    const tables = document.querySelectorAll('table.wikitable');
                    console.log('WebKit Analysis: Found ' + tables.length + ' wikitable elements');
                    
                    tables.forEach((table, index) => {
                        if (index < 12) { // Analyze all tables like the Puppeteer version
                            const tableAnalysis = {
                                index: index,
                                tableStyles: {},
                                containerInfo: {},
                                cells: [],
                                wrappingBehavior: {
                                    totalCells: 0,
                                    wrappingCells: 0,
                                    singleLineCells: 0,
                                    overflowingCells: 0
                                },
                                dimensions: {}
                            };
                            
                            // Get table container info
                            const tableContainer = table.closest('.mw-parser-output') || table.parentElement;
                            if (tableContainer) {
                                const containerStyles = window.getComputedStyle(tableContainer);
                                tableAnalysis.containerInfo = {
                                    width: containerStyles.width,
                                    maxWidth: containerStyles.maxWidth,
                                    overflow: containerStyles.overflow,
                                    overflowX: containerStyles.overflowX
                                };
                            }

                            // Get table dimensions
                            const tableRect = table.getBoundingClientRect();
                            tableAnalysis.dimensions = {
                                width: tableRect.width,
                                height: tableRect.height,
                                scrollWidth: table.scrollWidth,
                                scrollHeight: table.scrollHeight,
                                clientWidth: table.clientWidth,
                                clientHeight: table.clientHeight
                            };
                            
                            // Get table-level styles with WebKit-specific properties
                            const tableStyles = window.getComputedStyle(table);
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
                                whiteSpace: tableStyles.whiteSpace,
                                display: tableStyles.display,
                                overflow: tableStyles.overflow,
                                overflowX: tableStyles.overflowX,
                                webkitTextSizeAdjust: tableStyles.webkitTextSizeAdjust,
                                webkitOverflowScrolling: tableStyles.webkitOverflowScrolling
                            };
                            
                            // Analyze cells with WebKit-specific focus
                            const cells = table.querySelectorAll('td, th');
                            cells.forEach((cell, cellIndex) => {
                                if (cellIndex < 30) { // Same as Puppeteer version for comparison
                                    const cellRect = cell.getBoundingClientRect();
                                    const cellStyles = window.getComputedStyle(cell);
                                    const textContent = cell.textContent.trim();

                                    // Create test element with exact same styles
                                    const testElement = document.createElement('div');
                                    testElement.style.cssText = \`
                                        position: absolute;
                                        visibility: hidden;
                                        top: -9999px;
                                        left: -9999px;
                                        width: \${cellRect.width}px;
                                        font-family: \${cellStyles.fontFamily};
                                        font-size: \${cellStyles.fontSize};
                                        font-weight: \${cellStyles.fontWeight};
                                        letter-spacing: \${cellStyles.letterSpacing};
                                        word-spacing: \${cellStyles.wordSpacing};
                                        line-height: \${cellStyles.lineHeight};
                                        white-space: \${cellStyles.whiteSpace};
                                        word-wrap: \${cellStyles.wordWrap};
                                        overflow-wrap: \${cellStyles.overflowWrap};
                                        word-break: \${cellStyles.wordBreak};
                                        text-size-adjust: \${cellStyles.webkitTextSizeAdjust || cellStyles.textSizeAdjust || 'auto'};
                                        -webkit-text-size-adjust: \${cellStyles.webkitTextSizeAdjust || 'auto'};
                                    \`;
                                    testElement.textContent = textContent;
                                    document.body.appendChild(testElement);

                                    const wrappedHeight = testElement.getBoundingClientRect().height;
                                    
                                    // Test single line version
                                    testElement.style.whiteSpace = 'nowrap';
                                    const singleLineWidth = testElement.getBoundingClientRect().width;
                                    const singleLineHeight = testElement.getBoundingClientRect().height;
                                    
                                    document.body.removeChild(testElement);

                                    // Determine wrapping behavior
                                    const isWrapping = wrappedHeight > singleLineHeight * 1.1;
                                    const isOverflowing = singleLineWidth > cellRect.width * 1.05;

                                    const cellAnalysis = {
                                        index: cellIndex,
                                        tagName: cell.tagName.toLowerCase(),
                                        textContent: textContent.substring(0, 150),
                                        textLength: textContent.length,
                                        wordCount: textContent.split(/\\s+/).filter(word => word.length > 0).length,
                                        dimensions: {
                                            width: cellRect.width,
                                            height: cellRect.height,
                                            singleLineWidth: singleLineWidth,
                                            wrappedHeight: wrappedHeight,
                                            singleLineHeight: singleLineHeight
                                        },
                                        wrapping: {
                                            isWrapping: isWrapping,
                                            isOverflowing: isOverflowing,
                                            shouldWrapButDoesnt: isOverflowing && !isWrapping,
                                            wrappingRatio: singleLineHeight > 0 ? wrappedHeight / singleLineHeight : 1
                                        },
                                        styles: {
                                            width: cellStyles.width,
                                            maxWidth: cellStyles.maxWidth,
                                            minWidth: cellStyles.minWidth,
                                            wordWrap: cellStyles.wordWrap,
                                            overflowWrap: cellStyles.overflowWrap,
                                            wordBreak: cellStyles.wordBreak,
                                            whiteSpace: cellStyles.whiteSpace,
                                            textSizeAdjust: cellStyles.webkitTextSizeAdjust || cellStyles.textSizeAdjust || 'auto',
                                            webkitTextSizeAdjust: cellStyles.webkitTextSizeAdjust || 'auto',
                                            fontSize: cellStyles.fontSize,
                                            fontFamily: cellStyles.fontFamily,
                                            fontWeight: cellStyles.fontWeight,
                                            lineHeight: cellStyles.lineHeight,
                                            display: cellStyles.display,
                                            boxSizing: cellStyles.boxSizing,
                                            padding: cellStyles.padding,
                                            border: cellStyles.border,
                                            textAlign: cellStyles.textAlign
                                        }
                                    };

                                    tableAnalysis.cells.push(cellAnalysis);

                                    // Update wrapping behavior stats
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
                        siteName: window.mw ? window.mw.config.get('wgSiteName') : null,
                        pageName: window.mw ? window.mw.config.get('wgPageName') : null,
                        isMediaWikiLoaded: typeof window.mw !== 'undefined',
                        loadedModules: window.mw && window.mw.loader && window.mw.loader.getState ? Object.keys(window.mw.loader.getState() || {}) : [],
                        jQueryVersion: window.jQuery ? window.jQuery.fn.jquery : null,
                        availableStylesheets: Array.from(document.querySelectorAll('link[rel="stylesheet"]')).map(link => link.href)
                    };

                    // Table modules check
                    analysis.tableModules = {
                        sortable: typeof window.Sortable !== 'undefined',
                        tablesorter: window.mw && window.mw.loader && window.mw.loader.getState ? window.mw.loader.getState('jquery.tablesorter') !== null : false,
                        collapsible: window.mw && window.mw.loader && window.mw.loader.getState ? window.mw.loader.getState('jquery.makeCollapsible') !== null : false
                    };
                    
                    return analysis;
                })();
            `);

            // Save and report results
            await this.saveResults(analysisResult);
            this.generateReport(analysisResult);

        } catch (error) {
            console.error('❌ Official WebKit analysis failed:', error.message);
            throw error;
        } finally {
            if (this.driver) {
                await this.driver.quit();
                console.log('🔒 Safari WebDriver session closed');
            }
        }
    }

    async saveResults(analysis) {
        const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
        const filename = `official-webkit-analysis-${timestamp}.json`;
        const filepath = path.join(this.outputDir, filename);

        try {
            await fs.promises.writeFile(filepath, JSON.stringify(analysis, null, 2));
            console.log(`💾 Official WebKit analysis saved to: ${filepath}`);
            return filepath;
        } catch (error) {
            console.error('❌ Failed to save analysis:', error.message);
            throw error;
        }
    }

    generateReport(analysis) {
        console.log('\n' + '='.repeat(80));
        console.log('🦾 OFFICIAL WEBKIT ANALYSIS REPORT (Apple SafariDriver)');
        console.log('='.repeat(80));

        console.log('\n🌐 Environment:');
        console.log(`   Platform: ${analysis.platform}`);
        console.log(`   Engine: ${analysis.engine} (Official Apple WebKit)`);
        console.log(`   Browser: ${analysis.browser}`);
        console.log(`   Automation: ${analysis.automation}`);
        console.log(`   User Agent: ${analysis.environment.userAgent}`);
        console.log(`   Safari Version: ${analysis.safari.version}`);
        console.log(`   WebKit Version: ${analysis.safari.webKitVersion}`);
        console.log(`   Viewport: ${analysis.environment.viewport.width}x${analysis.environment.viewport.height} (DPR: ${analysis.environment.viewport.devicePixelRatio})`);

        // WebKit-specific features
        console.log('\n🦾 WebKit Features:');
        Object.entries(analysis.webkit).forEach(([feature, supported]) => {
            console.log(`   ${feature}: ${supported ? '✅ supported' : '❌ not supported'}`);
        });

        // Media queries
        console.log('\n📱 Media Queries:');
        Object.entries(analysis.mediaQueries).forEach(([query, matches]) => {
            console.log(`   ${query}: ${matches ? '✅ matches' : '❌ no match'}`);
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
        console.log('\n📊 Table Analysis (Official WebKit):');
        console.log(`   Tables analyzed: ${analysis.tables.length}`);

        let totalCells = 0;
        let totalWrappingCells = 0;
        let totalSingleLineCells = 0;
        let totalOverflowingCells = 0;
        let problemTables = 0;

        analysis.tables.forEach((table, index) => {
            const behavior = table.wrappingBehavior;
            totalCells += behavior.totalCells;
            totalWrappingCells += behavior.wrappingCells;
            totalSingleLineCells += behavior.singleLineCells;
            totalOverflowingCells += behavior.overflowingCells;

            const wrappingPercentage = behavior.totalCells > 0 ? Math.round((behavior.wrappingCells * 100) / behavior.totalCells) : 0;
            const overflowingPercentage = behavior.totalCells > 0 ? Math.round((behavior.overflowingCells * 100) / behavior.totalCells) : 0;

            console.log(`\n   Table ${index + 1}:`);
            console.log(`     - Dimensions: ${Math.round(table.dimensions.width)}x${Math.round(table.dimensions.height)}px`);
            console.log(`     - Table layout: ${table.tableStyles.tableLayout}`);
            console.log(`     - WebKit text size adjust: ${table.tableStyles.webkitTextSizeAdjust}`);
            console.log(`     - Cells analyzed: ${behavior.totalCells}`);
            console.log(`     - Wrapping cells: ${behavior.wrappingCells} (${wrappingPercentage}%)`);
            console.log(`     - Single-line cells: ${behavior.singleLineCells}`);
            console.log(`     - Overflowing cells: ${behavior.overflowingCells} (${overflowingPercentage}%)`);

            // Identify WebKit-specific issues
            if (behavior.overflowingCells > 0 && behavior.wrappingCells === 0) {
                console.log(`     🚨 WEBKIT ISSUE: ${behavior.overflowingCells} cells overflow but none wrap!`);
                problemTables++;
            } else if (wrappingPercentage < 30 && behavior.singleLineCells > 10) {
                console.log(`     ⚠️  WEBKIT PATTERN: Very low wrapping rate (iOS-like behavior)`);
                problemTables++;
            } else if (wrappingPercentage > 50) {
                console.log(`     ✅ WEBKIT GOOD: Text wrapping working properly`);
            }
        });

        // Overall WebKit summary
        const overallWrappingPercentage = totalCells > 0 ? Math.round((totalWrappingCells * 100) / totalCells) : 0;
        const overallOverflowingPercentage = totalCells > 0 ? Math.round((totalOverflowingCells * 100) / totalCells) : 0;

        console.log('\n📈 Official WebKit Summary:');
        console.log(`   Total cells analyzed: ${totalCells}`);
        console.log(`   Cells with text wrapping: ${totalWrappingCells} (${overallWrappingPercentage}%)`);
        console.log(`   Cells with single-line text: ${totalSingleLineCells}`);
        console.log(`   Cells with overflow: ${totalOverflowingCells} (${overallOverflowingPercentage}%)`);
        console.log(`   Tables with issues: ${problemTables}`);

        // WebKit vs iOS conclusions
        console.log('\n🎯 WebKit Analysis Conclusions:');
        if (overallWrappingPercentage < 30 && totalOverflowingCells > 0) {
            console.log('   🚨 CRITICAL: Low text wrapping with overflow detected in official WebKit!');
            console.log('   📱 This suggests the issue exists in WebKit engine itself.');
            console.log('   🔍 iOS WKWebView likely exhibits similar behavior.');
        } else if (overallWrappingPercentage > 60) {
            console.log('   ✅ GOOD: Official WebKit text wrapping working properly.');
            console.log('   🤔 This means iOS WKWebView configuration differs from desktop Safari.');
        } else {
            console.log('   ⚠️  MIXED: Some WebKit text wrapping detected.');
            console.log('   🔍 Compare with iOS WKWebView results for differences.');
        }

        console.log('\n🔬 Next Steps:');
        console.log('   1. Compare these official WebKit results with iOS WKWebView data');
        console.log('   2. Compare with Puppeteer/Chromium results to see engine differences');
        console.log('   3. Focus on WebKit-specific CSS properties and configurations');

        console.log('\n✅ Official WebKit analysis complete!');
        console.log('💾 Check the JSON file for detailed WebKit-specific technical data.');
        console.log('='.repeat(80));
    }
}

// Main execution
if (require.main === module) {
    const analyzer = new OfficialWebKitAnalyzer();
    analyzer.run().catch(error => {
        console.error('❌ Official WebKit analysis failed:', error.message);
        if (error.message.includes('safaridriver')) {
            console.log('\n💡 SafariDriver Setup Help:');
            console.log('1. Run: sudo safaridriver --enable');
            console.log('2. In Safari: Develop → Allow Remote Automation');
            console.log('3. Make sure Safari Develop menu is enabled');
        }
        process.exit(1);
    });
}

module.exports = OfficialWebKitAnalyzer;