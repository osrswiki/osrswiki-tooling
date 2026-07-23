#!/usr/bin/env node

/**
 * Engine Comparison Analyzer
 * 
 * Compares table rendering behavior between:
 * 1. Chromium/Blink (Puppeteer - Android-like behavior)
 * 2. WebKit (Safari - iOS-like behavior) 
 * 3. iOS WKWebView (when available)
 * 
 * Identifies exact differences causing iOS table rendering issues.
 */

const fs = require('fs');
const path = require('path');

class EngineComparisonAnalyzer {
    constructor() {
        this.outputDir = path.join(__dirname, '..', 'engine-comparison');
        this.chromiumData = null;
        this.webkitData = null;
        this.iosData = null;
        this.ensureOutputDir();
    }

    ensureOutputDir() {
        if (!fs.existsSync(this.outputDir)) {
            fs.mkdirSync(this.outputDir, { recursive: true });
        }
    }

    async loadAnalysisData() {
        console.log('📊 Loading analysis data from all engines...');

        // Load Chromium/Puppeteer data (Android-like behavior)
        const chromiumDir = path.join(__dirname, '..', 'webkit-debug');
        if (fs.existsSync(chromiumDir)) {
            const chromiumFiles = fs.readdirSync(chromiumDir)
                .filter(f => f.startsWith('webkit-analysis-'))
                .sort()
                .reverse(); // Get most recent
            
            if (chromiumFiles.length > 0) {
                const chromiumPath = path.join(chromiumDir, chromiumFiles[0]);
                this.chromiumData = JSON.parse(fs.readFileSync(chromiumPath, 'utf8'));
                console.log(`✅ Loaded Chromium data: ${chromiumFiles[0]}`);
            }
        }

        // Load WebKit/Safari data (desktop Safari behavior)
        const webkitDir = path.join(__dirname, '..', 'official-webkit-debug');
        if (fs.existsSync(webkitDir)) {
            const webkitFiles = fs.readdirSync(webkitDir)
                .filter(f => f.startsWith('official-webkit-analysis-'))
                .sort()
                .reverse();
            
            if (webkitFiles.length > 0) {
                const webkitPath = path.join(webkitDir, webkitFiles[0]);
                this.webkitData = JSON.parse(fs.readFileSync(webkitPath, 'utf8'));
                console.log(`✅ Loaded WebKit data: ${webkitFiles[0]}`);
            }
        }

        // Look for iOS WKWebView data (from iOS app debugging)
        const iosDebugDirs = [
            path.join(__dirname, '..', 'ios-debug'),
            '/Users/miyawaki/Library/Developer/CoreSimulator/Devices'
        ];
        
        // This would be populated when iOS debugging data is available
        console.log('ℹ️  iOS WKWebView data not found (expected - requires iOS app debugging)');
    }

    calculateWrappingStats(tablesData) {
        let totalCells = 0;
        let wrappingCells = 0;
        let singleLineCells = 0;
        let overflowingCells = 0;

        tablesData.forEach(table => {
            if (table.wrappingBehavior) {
                totalCells += table.wrappingBehavior.totalCells || 0;
                wrappingCells += table.wrappingBehavior.wrappingCells || 0;
                singleLineCells += table.wrappingBehavior.singleLineCells || 0;
                overflowingCells += table.wrappingBehavior.overflowingCells || 0;
            }
        });

        return {
            totalCells,
            wrappingCells,
            singleLineCells,
            overflowingCells,
            wrappingPercentage: totalCells > 0 ? Math.round((wrappingCells * 100) / totalCells) : 0,
            overflowPercentage: totalCells > 0 ? Math.round((overflowingCells * 100) / totalCells) : 0
        };
    }

    compareEngines() {
        const comparison = {
            timestamp: new Date().toISOString(),
            engines: {},
            differences: {},
            conclusions: {}
        };

        // Analyze Chromium (Android-like behavior)
        if (this.chromiumData) {
            const chromiumStats = this.calculateWrappingStats(this.chromiumData.tables);
            comparison.engines.chromium = {
                platform: this.chromiumData.platform,
                userAgent: this.chromiumData.environment.userAgent,
                viewport: this.chromiumData.environment.viewport,
                tablesAnalyzed: this.chromiumData.tables.length,
                stats: chromiumStats,
                behavior: chromiumStats.wrappingPercentage > 50 ? 'good_wrapping' : 'poor_wrapping'
            };
        }

        // Analyze WebKit (Desktop Safari behavior)
        if (this.webkitData) {
            const webkitStats = this.calculateWrappingStats(this.webkitData.tables);
            comparison.engines.webkit = {
                platform: this.webkitData.platform,
                userAgent: this.webkitData.environment.userAgent,
                viewport: this.webkitData.environment.viewport,
                tablesAnalyzed: this.webkitData.tables.length,
                stats: webkitStats,
                behavior: webkitStats.wrappingPercentage > 50 ? 'good_wrapping' : 'poor_wrapping'
            };
        }

        // Compare engines if we have both
        if (this.chromiumData && this.webkitData) {
            const chromiumStats = comparison.engines.chromium.stats;
            const webkitStats = comparison.engines.webkit.stats;

            comparison.differences = {
                wrappingPercentageDiff: Math.abs(chromiumStats.wrappingPercentage - webkitStats.wrappingPercentage),
                overflowDiff: Math.abs(chromiumStats.overflowPercentage - webkitStats.overflowPercentage),
                totalCellsDiff: Math.abs(chromiumStats.totalCells - webkitStats.totalCells),
                
                // CSS differences (if available)
                cssFeatures: this.compareCSSFeatures(),
                
                // Environment differences
                viewportDiff: this.compareViewports(),
                
                // MediaWiki differences
                mediaWikiDiff: this.compareMediaWiki()
            };

            // Generate conclusions
            if (comparison.differences.wrappingPercentageDiff > 20) {
                comparison.conclusions.wrappingIssue = {
                    severity: 'high',
                    description: 'Significant text wrapping difference between engines',
                    chromiumBetter: chromiumStats.wrappingPercentage > webkitStats.wrappingPercentage,
                    recommendation: 'Focus on WebKit-specific CSS properties and table layout differences'
                };
            }

            if (webkitStats.overflowPercentage > 10 && chromiumStats.overflowPercentage < 5) {
                comparison.conclusions.overflowIssue = {
                    severity: 'medium',
                    description: 'WebKit has more cells with overflow issues',
                    recommendation: 'Check WebKit table layout algorithms and word-wrapping CSS'
                };
            }
        }

        return comparison;
    }

    compareCSSFeatures() {
        if (!this.chromiumData || !this.webkitData) return null;

        const chromiumCSS = this.chromiumData.css || {};
        const webkitCSS = this.webkitData.webkit || {};

        return {
            textSizeAdjust: {
                chromium: chromiumCSS.textSizeAdjustSupported,
                webkit: webkitCSS.textSizeAdjustSupported,
                differs: chromiumCSS.textSizeAdjustSupported !== webkitCSS.textSizeAdjustSupported
            },
            overflowWrap: {
                chromium: chromiumCSS.overflowWrapSupported,
                webkit: webkitCSS.overflowWrapSupported,
                differs: chromiumCSS.overflowWrapSupported !== webkitCSS.overflowWrapSupported
            },
            wordBreak: {
                chromium: chromiumCSS.wordBreakSupported,
                webkit: webkitCSS.wordBreakSupported,
                differs: chromiumCSS.wordBreakSupported !== webkitCSS.wordBreakSupported
            }
        };
    }

    compareViewports() {
        if (!this.chromiumData || !this.webkitData) return null;

        const chromiumVP = this.chromiumData.environment.viewport;
        const webkitVP = this.webkitData.environment.viewport;

        return {
            widthDiff: Math.abs(chromiumVP.width - webkitVP.width),
            heightDiff: Math.abs(chromiumVP.height - webkitVP.height),
            dprDiff: Math.abs(chromiumVP.devicePixelRatio - webkitVP.devicePixelRatio),
            significant: Math.abs(chromiumVP.width - webkitVP.width) > 50
        };
    }

    compareMediaWiki() {
        if (!this.chromiumData || !this.webkitData) return null;

        const chromiumMW = this.chromiumData.mediaWiki || {};
        const webkitMW = this.webkitData.mediaWiki || {};

        return {
            versionDiff: chromiumMW.version !== webkitMW.version,
            skinDiff: chromiumMW.skin !== webkitMW.skin,
            loadedDiff: chromiumMW.isMediaWikiLoaded !== webkitMW.isMediaWikiLoaded,
            moduleCountDiff: Math.abs((chromiumMW.loadedModules || []).length - (webkitMW.loadedModules || []).length)
        };
    }

    generateReport(comparison) {
        console.log('\n' + '='.repeat(80));
        console.log('🔬 ENGINE COMPARISON ANALYSIS REPORT');
        console.log('='.repeat(80));

        // Engine summary
        console.log('\n📊 Engine Analysis Summary:');
        Object.entries(comparison.engines).forEach(([engine, data]) => {
            console.log(`\n🔧 ${engine.toUpperCase()} Engine:`);
            console.log(`   Platform: ${data.platform}`);
            console.log(`   Tables analyzed: ${data.tablesAnalyzed}`);
            console.log(`   Total cells: ${data.stats.totalCells}`);
            console.log(`   Text wrapping: ${data.stats.wrappingCells} cells (${data.stats.wrappingPercentage}%)`);
            console.log(`   Single-line cells: ${data.stats.singleLineCells}`);
            console.log(`   Overflowing cells: ${data.stats.overflowingCells} (${data.stats.overflowPercentage}%)`);
            console.log(`   Behavior: ${data.behavior === 'good_wrapping' ? '✅ Good wrapping' : '❌ Poor wrapping'}`);
        });

        // Differences analysis
        if (comparison.differences && Object.keys(comparison.differences).length > 0) {
            console.log('\n🔍 Engine Differences:');
            
            if (comparison.differences.wrappingPercentageDiff !== undefined) {
                console.log(`   Text wrapping difference: ${comparison.differences.wrappingPercentageDiff}%`);
                if (comparison.differences.wrappingPercentageDiff > 20) {
                    console.log('   ⚠️  SIGNIFICANT difference in text wrapping behavior!');
                }
            }

            if (comparison.differences.overflowDiff !== undefined) {
                console.log(`   Overflow behavior difference: ${comparison.differences.overflowDiff}%`);
            }

            // CSS features comparison
            if (comparison.differences.cssFeatures) {
                console.log('\n🎨 CSS Feature Support Differences:');
                Object.entries(comparison.differences.cssFeatures).forEach(([feature, diff]) => {
                    if (diff && diff.differs) {
                        console.log(`   ${feature}: Chromium=${diff.chromium}, WebKit=${diff.webkit} ${diff.differs ? '⚠️ DIFFERS' : '✅'}`);
                    }
                });
            }

            // Viewport differences
            if (comparison.differences.viewportDiff) {
                const vp = comparison.differences.viewportDiff;
                console.log('\n📱 Viewport Differences:');
                console.log(`   Width difference: ${vp.widthDiff}px`);
                console.log(`   Height difference: ${vp.heightDiff}px`);
                console.log(`   Device pixel ratio difference: ${vp.dprDiff}`);
                if (vp.significant) {
                    console.log('   ⚠️  Significant viewport size difference detected!');
                }
            }
        }

        // Conclusions
        if (comparison.conclusions && Object.keys(comparison.conclusions).length > 0) {
            console.log('\n🎯 Analysis Conclusions:');
            
            Object.entries(comparison.conclusions).forEach(([issue, conclusion]) => {
                console.log(`\n${conclusion.severity === 'high' ? '🚨' : '⚠️'} ${issue.toUpperCase()}:`);
                console.log(`   ${conclusion.description}`);
                if (conclusion.recommendation) {
                    console.log(`   💡 Recommendation: ${conclusion.recommendation}`);
                }
                if (conclusion.chromiumBetter !== undefined) {
                    console.log(`   Better engine: ${conclusion.chromiumBetter ? 'Chromium (Android-like)' : 'WebKit (Safari-like)'}`);
                }
            });
        }

        // Overall assessment
        console.log('\n📋 Overall Assessment:');
        
        if (comparison.engines.chromium && comparison.engines.webkit) {
            const chromiumBehavior = comparison.engines.chromium.behavior;
            const webkitBehavior = comparison.engines.webkit.behavior;
            
            if (chromiumBehavior === 'good_wrapping' && webkitBehavior === 'poor_wrapping') {
                console.log('🎯 FINDING: Chromium (Android-like) has better text wrapping than WebKit (iOS-like)');
                console.log('📱 This confirms the reported iOS vs Android table rendering difference');
                console.log('🔧 Solution: Apply Chromium text wrapping techniques to iOS WKWebView');
            } else if (chromiumBehavior === webkitBehavior) {
                console.log('✅ Both engines show similar text wrapping behavior');
                console.log('🤔 iOS-specific issue may be in WKWebView configuration, not WebKit engine');
            } else {
                console.log('⚠️  Mixed results - further investigation needed');
            }
        } else {
            console.log('ℹ️  Run both Chromium and WebKit analyses for complete comparison');
        }

        console.log('\n🔬 Next Steps:');
        console.log('1. If WebKit shows poor wrapping: Focus on WebKit-specific CSS fixes');
        console.log('2. If both engines wrap well: Investigate iOS WKWebView configuration differences');
        console.log('3. Run iOS WKWebView debugging to get actual iOS device data');
        console.log('4. Compare CSS computed styles between working and broken engines');

        console.log('\n' + '='.repeat(80));
    }

    async run() {
        console.log('🚀 Starting Engine Comparison Analysis...');
        
        await this.loadAnalysisData();
        
        if (!this.chromiumData && !this.webkitData) {
            console.log('❌ No analysis data found. Please run the analysis tools first:');
            console.log('   node tools/automated-webkit-analysis.js  (Chromium/Android-like)');
            console.log('   node tools/official-webkit-analysis.js   (WebKit/Safari-like)');
            return;
        }

        const comparison = this.compareEngines();
        
        // Save detailed comparison data
        const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
        const filename = `engine-comparison-${timestamp}.json`;
        const filepath = path.join(this.outputDir, filename);
        
        fs.writeFileSync(filepath, JSON.stringify(comparison, null, 2));
        console.log(`💾 Detailed comparison saved to: ${filepath}`);
        
        // Generate human-readable report
        this.generateReport(comparison);
        
        console.log('✅ Engine comparison analysis complete!');
    }
}

// Main execution
if (require.main === module) {
    const analyzer = new EngineComparisonAnalyzer();
    analyzer.run().catch(error => {
        console.error('❌ Engine comparison failed:', error.message);
        process.exit(1);
    });
}

module.exports = EngineComparisonAnalyzer;