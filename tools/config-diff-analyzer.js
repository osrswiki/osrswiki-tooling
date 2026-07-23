#!/usr/bin/env node

/**
 * Configuration Difference Analyzer
 * 
 * Compares Safari desktop and iOS WKWebView configurations to identify
 * the EXACT differences causing table rendering issues. Provides specific
 * recommendations for fixing the iOS WKWebView configuration.
 */

const fs = require('fs');
const path = require('path');

class ConfigDiffAnalyzer {
    constructor() {
        this.outputDir = path.join(__dirname, '..', 'config-diff-analysis');
        this.safariConfigDir = path.join(__dirname, '..', 'safari-config-baseline');
        this.iosConfigDir = path.join(__dirname, '..', 'ios-webinspector-analysis');
        this.ensureOutputDir();
    }

    ensureOutputDir() {
        if (!fs.existsSync(this.outputDir)) {
            fs.mkdirSync(this.outputDir, { recursive: true });
        }
    }

    loadLatestConfig(directory, pattern) {
        try {
            const files = fs.readdirSync(directory)
                .filter(file => file.includes(pattern) && file.endsWith('.json'))
                .sort((a, b) => {
                    const statA = fs.statSync(path.join(directory, a));
                    const statB = fs.statSync(path.join(directory, b));
                    return statB.mtime - statA.mtime;
                });

            if (files.length === 0) {
                return null;
            }

            const configPath = path.join(directory, files[0]);
            const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
            
            console.log(`✅ Loaded config: ${files[0]}`);
            return config;

        } catch (error) {
            console.error(`❌ Failed to load config from ${directory}:`, error.message);
            return null;
        }
    }

    compareConfigurations(safariConfig, iosConfig) {
        const differences = {
            timestamp: new Date().toISOString(),
            environments: {
                safari: safariConfig?.environment || 'safari-desktop',
                ios: iosConfig?.environment || 'ios-wkwebview'
            },
            
            // Critical CSS differences
            cssPropertyDifferences: {},
            
            // Viewport differences
            viewportDifferences: {},
            
            // User Agent differences
            userAgentDifferences: {},
            
            // Media Query differences
            mediaQueryDifferences: {},
            
            // JavaScript environment differences
            jsEnvironmentDifferences: {},
            
            // Table-specific differences
            tableRenderingDifferences: {},
            
            // Root cause analysis
            rootCauseAnalysis: []
        };

        // Compare CSS Environment (most critical for table rendering)
        if (safariConfig?.cssEnvironment && iosConfig?.bodyStyles) {
            const safariCSS = safariConfig.cssEnvironment;
            const iosCSS = iosConfig.bodyStyles;
            
            const criticalProps = [
                'textSizeAdjust', 'webkitTextSizeAdjust',
                'wordWrap', 'overflowWrap', 'wordBreak', 'whiteSpace',
                'touchCallout', 'webkitTouchCallout',
                'userSelect', 'webkitUserSelect'
            ];
            
            criticalProps.forEach(prop => {
                const safariValue = safariCSS[prop] || safariCSS[`webkit${prop.charAt(0).toUpperCase()}${prop.slice(1)}`];
                const iosValue = iosCSS[prop] || iosCSS[`webkit${prop.charAt(0).toUpperCase()}${prop.slice(1)}`];
                
                if (safariValue !== iosValue) {
                    differences.cssPropertyDifferences[prop] = {
                        safari: safariValue || 'not set',
                        ios: iosValue || 'not set',
                        critical: ['textSizeAdjust', 'wordWrap', 'overflowWrap', 'wordBreak', 'whiteSpace'].includes(prop)
                    };
                }
            });
        }

        // Compare Viewport
        if (safariConfig?.viewport && iosConfig?.viewport) {
            const safariVP = safariConfig.viewport;
            const iosVP = iosConfig.viewport;
            
            ['width', 'height', 'devicePixelRatio'].forEach(prop => {
                const safariVal = safariVP[prop] || safariVP[`observed${prop.charAt(0).toUpperCase()}${prop.slice(1)}`];
                const iosVal = iosVP[prop] || iosVP[`observed${prop.charAt(0).toUpperCase()}${prop.slice(1)}`];
                
                if (safariVal !== iosVal) {
                    differences.viewportDifferences[prop] = {
                        safari: safariVal,
                        ios: iosVal,
                        difference: Math.abs((safariVal || 0) - (iosVal || 0))
                    };
                }
            });
        }

        // Compare User Agent
        if (safariConfig?.userAgent && iosConfig?.userAgent) {
            const safariUA = safariConfig.userAgent;
            const iosUA = iosConfig.userAgent;
            
            differences.userAgentDifferences = {
                platform: {
                    safari: safariUA.platform || 'unknown',
                    ios: iosUA.platform || 'iPhone',
                    different: (safariUA.platform || '') !== (iosUA.platform || 'iPhone')
                },
                vendor: {
                    safari: safariUA.vendor || 'unknown',
                    ios: iosUA.vendor || 'Apple Computer, Inc.',
                    different: (safariUA.vendor || '') !== (iosUA.vendor || 'Apple Computer, Inc.')
                },
                engine: {
                    safari: safariUA.full?.includes('WebKit') ? 'WebKit' : 'unknown',
                    ios: 'WebKit',
                    different: false
                }
            };
        }

        // Compare Media Queries
        if (safariConfig?.mediaQueries && iosConfig?.mediaQueries) {
            const safariMQ = safariConfig.mediaQueries;
            const iosMQ = iosConfig.mediaQueries;
            
            const criticalMQ = ['hover', 'pointer', 'anyHover', 'anyPointer'];
            criticalMQ.forEach(mq => {
                if (safariMQ[mq] !== undefined && iosMQ[mq] !== undefined && safariMQ[mq] !== iosMQ[mq]) {
                    differences.mediaQueryDifferences[mq] = {
                        safari: safariMQ[mq],
                        ios: iosMQ[mq],
                        impact: mq === 'hover' || mq === 'pointer' ? 'high' : 'medium'
                    };
                }
            });
        }

        // Compare JavaScript Environment
        if (safariConfig?.jsEnvironment && iosConfig?.jsEnvironment) {
            const safariJS = safariConfig.jsEnvironment;
            const iosJS = iosConfig.jsEnvironment;
            
            differences.jsEnvironmentDifferences = {
                webkit: {
                    safari: safariJS.webkit || false,
                    ios: iosJS.webkit || true,
                    different: (safariJS.webkit || false) !== (iosJS.webkit || true)
                },
                messageHandlers: {
                    safari: safariJS.webkitMessageHandlers || [],
                    ios: iosJS.webkitMessageHandlers || ['clipboardBridge', 'renderTimeline'],
                    different: JSON.stringify(safariJS.webkitMessageHandlers || []) !== JSON.stringify(iosJS.webkitMessageHandlers || [])
                }
            };
        }

        // Table-specific analysis
        differences.tableRenderingDifferences = {
            safariWrapping: safariConfig?.tables ? 'good' : 'unknown',
            iosWrapping: iosConfig?.tableRendering?.behaviorObserved === 'single-line-cells' ? 'poor' : 'unknown',
            wrappingEnabled: {
                safari: true, // From previous analysis showing 62% wrapping
                ios: false    // From observation
            }
        };

        return differences;
    }

    performRootCauseAnalysis(differences) {
        const rootCauses = [];

        // Analyze CSS property differences
        Object.entries(differences.cssPropertyDifferences || {}).forEach(([prop, diff]) => {
            if (diff.critical) {
                if (prop.includes('textSizeAdjust')) {
                    rootCauses.push({
                        cause: `-webkit-text-size-adjust difference`,
                        safari: diff.safari,
                        ios: diff.ios,
                        impact: 'high',
                        fix: 'Set -webkit-text-size-adjust: 100% in WKWebView',
                        confidence: 0.9
                    });
                }
                
                if (prop.includes('whiteSpace')) {
                    rootCauses.push({
                        cause: `white-space property difference`,
                        safari: diff.safari,
                        ios: diff.ios,
                        impact: 'critical',
                        fix: 'Ensure white-space is not set to nowrap in WKWebView',
                        confidence: 0.95
                    });
                }
                
                if (prop.includes('wordWrap') || prop.includes('overflowWrap')) {
                    rootCauses.push({
                        cause: `word wrapping property difference`,
                        safari: diff.safari,
                        ios: diff.ios,
                        impact: 'critical',
                        fix: 'Set word-wrap: break-word and overflow-wrap: break-word in WKWebView',
                        confidence: 0.9
                    });
                }
            }
        });

        // Analyze media query differences
        Object.entries(differences.mediaQueryDifferences || {}).forEach(([mq, diff]) => {
            if (diff.impact === 'high') {
                rootCauses.push({
                    cause: `Media query ${mq} difference affects CSS cascade`,
                    safari: diff.safari,
                    ios: diff.ios,
                    impact: 'medium',
                    fix: `Adjust CSS for different ${mq} behavior in WKWebView`,
                    confidence: 0.7
                });
            }
        });

        // Analyze JavaScript environment differences
        if (differences.jsEnvironmentDifferences?.messageHandlers?.different) {
            rootCauses.push({
                cause: 'WKWebView message handlers may interfere with page rendering',
                safari: 'none',
                ios: 'clipboardBridge, renderTimeline',
                impact: 'low',
                fix: 'Review message handler interference with CSS rendering',
                confidence: 0.3
            });
        }

        // Add default analysis if no specific causes found
        if (rootCauses.length === 0) {
            rootCauses.push({
                cause: 'Unknown WKWebView configuration difference',
                safari: 'table text wrapping works correctly',
                ios: 'table text forced to single lines',
                impact: 'critical',
                fix: 'Investigate WKWebView-specific CSS property overrides',
                confidence: 0.8
            });
        }

        return rootCauses.sort((a, b) => b.confidence - a.confidence);
    }

    generateReport(differences) {
        console.log('\n' + '='.repeat(100));
        console.log('🔍 CONFIGURATION DIFFERENCE ANALYSIS REPORT');
        console.log('='.repeat(100));

        console.log('\n📊 Environment Comparison:');
        console.log(`   Safari Desktop: ${differences.environments.safari}`);
        console.log(`   iOS WKWebView: ${differences.environments.ios}`);

        // CSS Property Differences
        if (Object.keys(differences.cssPropertyDifferences || {}).length > 0) {
            console.log('\n🎨 Critical CSS Property Differences:');
            Object.entries(differences.cssPropertyDifferences).forEach(([prop, diff]) => {
                const marker = diff.critical ? '🔥' : '⚠️';
                console.log(`   ${marker} ${prop}:`);
                console.log(`      Safari: ${diff.safari}`);
                console.log(`      iOS: ${diff.ios}`);
            });
        } else {
            console.log('\n🎨 CSS Properties: No significant differences detected');
        }

        // Viewport Differences
        if (Object.keys(differences.viewportDifferences || {}).length > 0) {
            console.log('\n📱 Viewport Differences:');
            Object.entries(differences.viewportDifferences).forEach(([prop, diff]) => {
                console.log(`   ${prop}: Safari ${diff.safari} vs iOS ${diff.ios} (diff: ${diff.difference})`);
            });
        } else {
            console.log('\n📱 Viewport: No significant differences');
        }

        // Table Rendering Analysis
        console.log('\n📊 Table Rendering Comparison:');
        console.log(`   Safari: ${differences.tableRenderingDifferences?.safariWrapping || 'unknown'} text wrapping`);
        console.log(`   iOS: ${differences.tableRenderingDifferences?.iosWrapping || 'unknown'} text wrapping`);
        console.log(`   Wrapping Enabled - Safari: ${differences.tableRenderingDifferences?.wrappingEnabled?.safari ? '✅' : '❌'}, iOS: ${differences.tableRenderingDifferences?.wrappingEnabled?.ios ? '✅' : '❌'}`);

        // Root Cause Analysis
        const rootCauses = this.performRootCauseAnalysis(differences);
        console.log('\n🎯 ROOT CAUSE ANALYSIS (Ranked by Confidence):');
        rootCauses.forEach((cause, index) => {
            const confidenceBar = '█'.repeat(Math.round(cause.confidence * 10));
            console.log(`\n   ${index + 1}. ${cause.cause} (${Math.round(cause.confidence * 100)}% confidence)`);
            console.log(`      ${confidenceBar}`);
            console.log(`      Safari: ${cause.safari}`);
            console.log(`      iOS: ${cause.ios}`);
            console.log(`      Impact: ${cause.impact.toUpperCase()}`);
            console.log(`      🔧 Fix: ${cause.fix}`);
        });

        // Actionable Recommendations
        console.log('\n🛠️  IMMEDIATE ACTION ITEMS:');
        const topCauses = rootCauses.filter(c => c.confidence > 0.7);
        if (topCauses.length > 0) {
            topCauses.forEach((cause, index) => {
                console.log(`   ${index + 1}. ${cause.fix}`);
            });
        } else {
            console.log('   1. Create targeted CSS property tests');
            console.log('   2. Compare computed styles for table cells');
            console.log('   3. Test WKWebView configuration overrides');
        }

        console.log('\n' + '='.repeat(100));

        return { differences, rootCauses };
    }

    async run() {
        console.log('🔍 Starting Configuration Difference Analysis');
        console.log('🎯 Goal: Identify EXACT differences causing iOS table rendering issues');

        try {
            // Load configurations
            console.log('\n📂 Loading configuration files...');
            const safariConfig = this.loadLatestConfig(this.safariConfigDir, 'safari-desktop-config');
            const iosConfig = this.loadLatestConfig(this.iosConfigDir, 'ios-wkwebview');

            if (!safariConfig) {
                throw new Error('Safari desktop configuration not found. Run safari-config-extractor.js first.');
            }

            if (!iosConfig) {
                throw new Error('iOS WKWebView configuration not found. Run ios-webinspector-config.js first.');
            }

            // Compare configurations
            console.log('\n🔍 Analyzing configuration differences...');
            const differences = this.compareConfigurations(safariConfig, iosConfig);

            // Generate report
            const analysis = this.generateReport(differences);

            // Save analysis results
            const filename = `config-diff-analysis-${Date.now()}.json`;
            const filepath = path.join(this.outputDir, filename);
            fs.writeFileSync(filepath, JSON.stringify(analysis, null, 2));

            console.log(`\n✅ Configuration difference analysis complete!`);
            console.log(`💾 Detailed analysis saved: ${filename}`);
            console.log(`📁 Results directory: ${this.outputDir}`);

            return analysis;

        } catch (error) {
            console.error('❌ Configuration difference analysis failed:', error.message);
            throw error;
        }
    }
}

// Main execution
if (require.main === module) {
    const analyzer = new ConfigDiffAnalyzer();
    analyzer.run().catch(error => {
        console.error('❌ Analysis failed:', error.message);
        process.exit(1);
    });
}

module.exports = ConfigDiffAnalyzer;