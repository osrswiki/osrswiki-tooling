#!/usr/bin/env node

/**
 * Automated WebKit Analysis Tool
 * 
 * This tool uses Puppeteer to create a mobile Safari-like environment,
 * loads the Varrock page, and automatically analyzes table rendering.
 * Fully automated - no manual intervention required.
 */

const puppeteer = require('puppeteer');
const fs = require('fs');
const path = require('path');

class AutomatedWebKitAnalyzer {
    constructor() {
        this.outputDir = path.join(__dirname, '..', 'webkit-debug');
        this.ensureOutputDir();
    }

    ensureOutputDir() {
        if (!fs.existsSync(this.outputDir)) {
            fs.mkdirSync(this.outputDir, { recursive: true });
        }
    }

    async run() {
        console.log('🚀 Starting automated WebKit analysis...');
        console.log('🌐 Creating mobile Safari-like environment...');

        let browser;
        try {
            // Launch browser with mobile Safari settings
            browser = await puppeteer.launch({
                headless: "new", // Use new headless mode
                args: [
                    '--no-sandbox',
                    '--disable-setuid-sandbox',
                    '--disable-web-security',
                    '--disable-features=VizDisplayCompositor'
                ]
            });

            const page = await browser.newPage();

            // Set mobile Safari user agent and viewport
            await page.setUserAgent('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1');
            await page.setViewport({
                width: 375,
                height: 812,
                deviceScaleFactor: 3,
                isMobile: true,
                hasTouch: true
            });

            console.log('📱 Viewport: 375x812 (iPhone size, 3x scale factor)');
            console.log('🌐 Loading: https://oldschool.runescape.wiki/w/Varrock');

            // Navigate to Varrock page
            await page.goto('https://oldschool.runescape.wiki/w/Varrock', {
                waitUntil: 'networkidle2',
                timeout: 30000
            });

            console.log('📄 Page loaded successfully');
            console.log('🔍 Starting automated table analysis...');

            // Wait for any dynamic content
            await new Promise(resolve => setTimeout(resolve, 3000));

            // Run the comprehensive analysis
            const analysisResult = await page.evaluate(() => {
                return new Promise((resolve) => {
                    const analysis = {
                        timestamp: new Date().toISOString(),
                        platform: 'mobile-safari-puppeteer',
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
                        css: {
                            textSizeAdjustSupported: CSS.supports('-webkit-text-size-adjust', '100%'),
                            fontDisplaySupported: CSS.supports('font-display', 'swap'),
                            overflowWrapSupported: CSS.supports('overflow-wrap', 'break-word'),
                            wordBreakSupported: CSS.supports('word-break', 'break-all')
                        },
                        tables: []
                    };

                    // Find and analyze all wikitable elements
                    const tables = document.querySelectorAll('table.wikitable');
                    console.log(`🔍 Found ${tables.length} wikitable elements`);

                    tables.forEach((table, index) => {
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

                        // Get table-level styles
                        const tableComputedStyle = window.getComputedStyle(table);
                        tableAnalysis.tableStyles = {
                            width: tableComputedStyle.width,
                            maxWidth: tableComputedStyle.maxWidth,
                            tableLayout: tableComputedStyle.tableLayout,
                            borderCollapse: tableComputedStyle.borderCollapse,
                            fontSize: tableComputedStyle.fontSize,
                            fontFamily: tableComputedStyle.fontFamily,
                            textSizeAdjust: tableComputedStyle.webkitTextSizeAdjust || tableComputedStyle.textSizeAdjust || 'auto',
                            wordWrap: tableComputedStyle.wordWrap,
                            overflowWrap: tableComputedStyle.overflowWrap,
                            wordBreak: tableComputedStyle.wordBreak,
                            whiteSpace: tableComputedStyle.whiteSpace,
                            display: tableComputedStyle.display,
                            overflow: tableComputedStyle.overflow,
                            overflowX: tableComputedStyle.overflowX
                        };

                        // Analyze each cell
                        const cells = table.querySelectorAll('td, th');
                        cells.forEach((cell, cellIndex) => {
                            if (cellIndex < 30) { // Analyze first 30 cells for comprehensive data
                                const cellRect = cell.getBoundingClientRect();
                                const cellStyles = window.getComputedStyle(cell);
                                const textContent = cell.textContent.trim();

                                // Create test element to measure text wrapping behavior
                                const testElement = document.createElement('div');
                                testElement.style.cssText = `
                                    position: absolute;
                                    visibility: hidden;
                                    top: -9999px;
                                    left: -9999px;
                                    width: ${cellRect.width}px;
                                    font-family: ${cellStyles.fontFamily};
                                    font-size: ${cellStyles.fontSize};
                                    font-weight: ${cellStyles.fontWeight};
                                    letter-spacing: ${cellStyles.letterSpacing};
                                    word-spacing: ${cellStyles.wordSpacing};
                                    line-height: ${cellStyles.lineHeight};
                                    white-space: ${cellStyles.whiteSpace};
                                    word-wrap: ${cellStyles.wordWrap};
                                    overflow-wrap: ${cellStyles.overflowWrap};
                                    word-break: ${cellStyles.wordBreak};
                                    text-size-adjust: ${cellStyles.webkitTextSizeAdjust || cellStyles.textSizeAdjust || 'auto'};
                                `;
                                testElement.textContent = textContent;
                                document.body.appendChild(testElement);

                                const wrappedHeight = testElement.getBoundingClientRect().height;
                                
                                // Test single line version
                                testElement.style.whiteSpace = 'nowrap';
                                const singleLineWidth = testElement.getBoundingClientRect().width;
                                const singleLineHeight = testElement.getBoundingClientRect().height;
                                
                                document.body.removeChild(testElement);

                                // Determine wrapping behavior
                                const isWrapping = wrappedHeight > singleLineHeight * 1.1; // Allow for some line-height variance
                                const isOverflowing = singleLineWidth > cellRect.width * 1.05; // 5% tolerance
                                const shouldWrapButDoesnt = isOverflowing && !isWrapping;

                                const cellAnalysis = {
                                    index: cellIndex,
                                    tagName: cell.tagName.toLowerCase(),
                                    textContent: textContent.substring(0, 150), // More text for analysis
                                    textLength: textContent.length,
                                    wordCount: textContent.split(/\s+/).filter(word => word.length > 0).length,
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
                                        shouldWrapButDoesnt: shouldWrapButDoesnt,
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
                    });

                    // Check for MediaWiki-specific elements and functionality
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

                    // Check for table-specific JavaScript modules
                    analysis.tableModules = {
                        sortable: typeof window.Sortable !== 'undefined',
                        tablesorter: window.mw && window.mw.loader && window.mw.loader.getState ? window.mw.loader.getState('jquery.tablesorter') !== null : false,
                        collapsible: window.mw && window.mw.loader && window.mw.loader.getState ? window.mw.loader.getState('jquery.makeCollapsible') !== null : false
                    };

                    resolve(analysis);
                });
            });

            // Save results and generate report
            await this.saveResults(analysisResult);
            this.generateReport(analysisResult);

        } catch (error) {
            console.error('❌ Analysis failed:', error.message);
            throw error;
        } finally {
            if (browser) {
                await browser.close();
            }
        }
    }

    async saveResults(analysis) {
        const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
        const filename = `webkit-analysis-${timestamp}.json`;
        const filepath = path.join(this.outputDir, filename);

        try {
            await fs.promises.writeFile(filepath, JSON.stringify(analysis, null, 2));
            console.log(`💾 Analysis saved to: ${filepath}`);
            return filepath;
        } catch (error) {
            console.error('❌ Failed to save analysis:', error.message);
            throw error;
        }
    }

    generateReport(analysis) {
        console.log('\n' + '='.repeat(70));
        console.log('📊 AUTOMATED WEBKIT ANALYSIS REPORT');
        console.log('='.repeat(70));

        // Environment info
        console.log('\n🌐 Environment:');
        console.log(`   Platform: ${analysis.platform}`);
        console.log(`   User Agent: ${analysis.environment.userAgent}`);
        console.log(`   Viewport: ${analysis.environment.viewport.width}x${analysis.environment.viewport.height} (DPR: ${analysis.environment.viewport.devicePixelRatio})`);
        
        // Media queries
        console.log('\n📱 Media Queries:');
        Object.entries(analysis.mediaQueries).forEach(([query, matches]) => {
            console.log(`   ${query}: ${matches ? '✅ matches' : '❌ no match'}`);
        });

        // CSS support
        console.log('\n🎨 CSS Feature Support:');
        Object.entries(analysis.css).forEach(([feature, supported]) => {
            console.log(`   ${feature}: ${supported ? '✅ supported' : '❌ not supported'}`);
        });

        // MediaWiki info
        console.log('\n📚 MediaWiki:');
        console.log(`   MediaWiki loaded: ${analysis.mediaWiki.isMediaWikiLoaded ? '✅ yes' : '❌ no'}`);
        if (analysis.mediaWiki.version) {
            console.log(`   Version: ${analysis.mediaWiki.version}`);
        }
        if (analysis.mediaWiki.skin) {
            console.log(`   Skin: ${analysis.mediaWiki.skin}`);
        }
        if (analysis.mediaWiki.pageName) {
            console.log(`   Page: ${analysis.mediaWiki.pageName}`);
        }

        // Table analysis
        console.log('\n📊 Table Analysis:');
        console.log(`   Tables found: ${analysis.tables.length}`);

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
            const overflowingPercentage = behavior.totalCells > 0 ? Math.round((behavior.overflowingCells * 100) / behavior.totalCells) : 0;

            console.log(`\n   Table ${index + 1}:`);
            console.log(`     - Dimensions: ${Math.round(table.dimensions.width)}x${Math.round(table.dimensions.height)}px`);
            console.log(`     - Table layout: ${table.tableStyles.tableLayout}`);
            console.log(`     - Text size adjust: ${table.tableStyles.textSizeAdjust}`);
            console.log(`     - Total cells analyzed: ${behavior.totalCells}`);
            console.log(`     - Wrapping cells: ${behavior.wrappingCells} (${wrappingPercentage}%)`);
            console.log(`     - Single-line cells: ${behavior.singleLineCells}`);
            console.log(`     - Overflowing cells: ${behavior.overflowingCells} (${overflowingPercentage}%)`);

            // Highlight potential issues
            if (behavior.overflowingCells > 0 && behavior.wrappingCells === 0) {
                console.log(`     ⚠️  ISSUE: ${behavior.overflowingCells} cells overflow but none wrap!`);
            }
            if (behavior.wrappingCells === 0 && behavior.singleLineCells > 5) {
                console.log(`     🔍 PATTERN: All cells display as single lines (iOS-like behavior)`);
            }
            if (wrappingPercentage > 50) {
                console.log(`     ✅ GOOD: Text wrapping is working properly`);
            }
        });

        // Overall summary
        const overallWrappingPercentage = totalCells > 0 ? Math.round((totalWrappingCells * 100) / totalCells) : 0;
        const overallOverflowingPercentage = totalCells > 0 ? Math.round((totalOverflowingCells * 100) / totalCells) : 0;

        console.log('\n📈 Overall Summary:');
        console.log(`   Total cells analyzed: ${totalCells}`);
        console.log(`   Cells with text wrapping: ${totalWrappingCells} (${overallWrappingPercentage}%)`);
        console.log(`   Cells with single-line text: ${totalSingleLineCells}`);
        console.log(`   Cells with overflow: ${totalOverflowingCells} (${overallOverflowingPercentage}%)`);

        // Conclusions
        console.log('\n🎯 Analysis Conclusions:');
        if (overallWrappingPercentage < 20 && totalOverflowingCells > 0) {
            console.log('   🚨 CRITICAL: Low text wrapping with overflowing content detected!');
            console.log('   📱 This matches the iOS table rendering issue.');
        } else if (overallWrappingPercentage > 60) {
            console.log('   ✅ GOOD: Text wrapping is working as expected.');
            console.log('   🌐 This represents proper web/Android behavior.');
        } else {
            console.log('   ⚠️  MIXED: Some text wrapping detected, but may need investigation.');
        }

        console.log('\n✅ Automated analysis complete!');
        console.log('💾 Check the JSON file for detailed technical data.');
        console.log('='.repeat(70));
    }
}

// Check if Puppeteer is available
async function checkPuppeteer() {
    try {
        require.resolve('puppeteer');
        return true;
    } catch {
        console.log('📦 Puppeteer not found. Installing...');
        const { execSync } = require('child_process');
        try {
            execSync('npm install puppeteer --no-save', { stdio: 'inherit' });
            return true;
        } catch (error) {
            console.error('❌ Failed to install Puppeteer:', error.message);
            return false;
        }
    }
}

// Main execution
if (require.main === module) {
    (async () => {
        if (await checkPuppeteer()) {
            const analyzer = new AutomatedWebKitAnalyzer();
            try {
                await analyzer.run();
            } catch (error) {
                console.error('❌ Analysis failed:', error.message);
                process.exit(1);
            }
        } else {
            console.error('❌ Could not install required dependencies');
            process.exit(1);
        }
    })();
}

module.exports = AutomatedWebKitAnalyzer;