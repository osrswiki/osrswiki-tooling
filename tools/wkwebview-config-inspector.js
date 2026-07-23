#!/usr/bin/env node

/**
 * WKWebView Configuration Inspector
 * 
 * Captures the EXACT WKWebView configuration from the running iOS app
 * to identify specific settings causing table rendering differences.
 * This tool extracts every possible WKWebView property for analysis.
 */

const { execSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

class WKWebViewConfigInspector {
    constructor() {
        this.outputDir = path.join(__dirname, '..', 'wkwebview-config-analysis');
        this.simulatorUDID = '5CEA746D-62CB-45DF-960F-B338BCE85346';
        this.bundleId = 'omiyawaki.osrswiki';
        this.ensureOutputDir();
    }

    ensureOutputDir() {
        if (!fs.existsSync(this.outputDir)) {
            fs.mkdirSync(this.outputDir, { recursive: true });
        }
    }

    async injectConfigurationExtractor() {
        console.log('💉 Injecting WKWebView configuration extractor into iOS app...');
        
        const configExtractorScript = `
        // WKWebView Configuration Extractor - Comprehensive Analysis
        window.WKWebViewConfigExtractor = {
            extractAllConfigurations: function() {
                const config = {
                    timestamp: new Date().toISOString(),
                    
                    // Viewport and Display Properties
                    viewport: {
                        width: window.innerWidth,
                        height: window.innerHeight,
                        devicePixelRatio: window.devicePixelRatio,
                        availWidth: screen.availWidth,
                        availHeight: screen.availHeight,
                        colorDepth: screen.colorDepth,
                        pixelDepth: screen.pixelDepth
                    },
                    
                    // User Agent Analysis
                    userAgent: {
                        full: navigator.userAgent,
                        platform: navigator.platform,
                        vendor: navigator.vendor,
                        appName: navigator.appName,
                        appVersion: navigator.appVersion,
                        cookieEnabled: navigator.cookieEnabled,
                        onLine: navigator.onLine,
                        language: navigator.language,
                        languages: navigator.languages
                    },
                    
                    // CSS Environment Detection
                    cssEnvironment: {
                        // CSS Environment Variables
                        safeAreaTop: getComputedStyle(document.documentElement).getPropertyValue('env(safe-area-inset-top)'),
                        safeAreaRight: getComputedStyle(document.documentElement).getPropertyValue('env(safe-area-inset-right)'),
                        safeAreaBottom: getComputedStyle(document.documentElement).getPropertyValue('env(safe-area-inset-bottom)'),
                        safeAreaLeft: getComputedStyle(document.documentElement).getPropertyValue('env(safe-area-inset-left)'),
                        
                        // WebKit Specific Properties
                        textSizeAdjust: getComputedStyle(document.body).getPropertyValue('-webkit-text-size-adjust'),
                        touchCallout: getComputedStyle(document.body).getPropertyValue('-webkit-touch-callout'),
                        userSelect: getComputedStyle(document.body).getPropertyValue('-webkit-user-select'),
                        tapHighlightColor: getComputedStyle(document.body).getPropertyValue('-webkit-tap-highlight-color'),
                        
                        // Text and Word Wrapping
                        wordWrap: getComputedStyle(document.body).getPropertyValue('word-wrap'),
                        overflowWrap: getComputedStyle(document.body).getPropertyValue('overflow-wrap'),
                        wordBreak: getComputedStyle(document.body).getPropertyValue('word-break'),
                        whiteSpace: getComputedStyle(document.body).getPropertyValue('white-space'),
                        textOverflow: getComputedStyle(document.body).getPropertyValue('text-overflow')
                    },
                    
                    // Media Query Environment
                    mediaQueries: {
                        // Device characteristics
                        hover: window.matchMedia('(hover: hover)').matches,
                        pointer: window.matchMedia('(pointer: fine)').matches ? 'fine' : 'coarse',
                        anyHover: window.matchMedia('(any-hover: hover)').matches,
                        anyPointer: window.matchMedia('(any-pointer: fine)').matches ? 'fine' : 'coarse',
                        
                        // Display characteristics
                        orientation: window.matchMedia('(orientation: portrait)').matches ? 'portrait' : 'landscape',
                        
                        // Color scheme
                        prefersColorScheme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light',
                        prefersReducedMotion: window.matchMedia('(prefers-reduced-motion: reduce)').matches,
                        
                        // WebKit specific
                        webkitMinDevicePixelRatio: window.matchMedia('(-webkit-min-device-pixel-ratio: 2)').matches ? '2+' : '1'
                    },
                    
                    // JavaScript Environment
                    jsEnvironment: {
                        // Engine detection
                        v8: typeof window.chrome !== 'undefined',
                        webkit: typeof window.webkit !== 'undefined',
                        
                        // WebKit message handlers
                        webkitMessageHandlers: typeof window.webkit !== 'undefined' && typeof window.webkit.messageHandlers === 'object' 
                            ? Object.keys(window.webkit.messageHandlers) : [],
                        
                        // Feature detection
                        touchEvents: 'ontouchstart' in window,
                        gestureEvents: 'ongesturestart' in window,
                        deviceMotion: 'ondevicemotion' in window,
                        deviceOrientation: 'ondeviceorientation' in window,
                        
                        // Storage
                        localStorage: typeof Storage !== 'undefined',
                        sessionStorage: typeof sessionStorage !== 'undefined',
                        indexedDB: typeof indexedDB !== 'undefined'
                    },
                    
                    // Document Properties
                    document: {
                        compatMode: document.compatMode,
                        designMode: document.designMode,
                        domain: document.domain,
                        readyState: document.readyState,
                        referrer: document.referrer,
                        characterSet: document.characterSet,
                        contentType: document.contentType,
                        doctype: document.doctype ? document.doctype.name : null
                    },
                    
                    // Window Properties
                    window: {
                        name: window.name,
                        status: window.status,
                        defaultStatus: window.defaultStatus,
                        closed: window.closed,
                        isSecureContext: window.isSecureContext,
                        origin: window.origin,
                        
                        // Performance
                        performance: typeof window.performance !== 'undefined',
                        requestAnimationFrame: typeof window.requestAnimationFrame !== 'undefined',
                        requestIdleCallback: typeof window.requestIdleCallback !== 'undefined'
                    }
                };
                
                return config;
            },
            
            // Extract table-specific CSS computed styles
            extractTableStyles: function() {
                const tables = document.querySelectorAll('table');
                const tableAnalysis = [];
                
                tables.forEach((table, index) => {
                    const tableStyles = window.getComputedStyle(table);
                    const cells = table.querySelectorAll('td, th');
                    const cellStyles = [];
                    
                    // Sample first few cells for detailed analysis
                    for (let i = 0; i < Math.min(5, cells.length); i++) {
                        const cell = cells[i];
                        const styles = window.getComputedStyle(cell);
                        
                        cellStyles.push({
                            cellIndex: i,
                            textContent: cell.textContent.trim().substring(0, 50),
                            styles: {
                                // Layout
                                display: styles.display,
                                width: styles.width,
                                minWidth: styles.minWidth,
                                maxWidth: styles.maxWidth,
                                
                                // Text wrapping
                                whiteSpace: styles.whiteSpace,
                                wordWrap: styles.wordWrap,
                                overflowWrap: styles.overflowWrap,
                                wordBreak: styles.wordBreak,
                                textOverflow: styles.textOverflow,
                                
                                // WebKit specific
                                webkitTextSizeAdjust: styles['-webkit-text-size-adjust'],
                                webkitUserSelect: styles['-webkit-user-select'],
                                webkitTouchCallout: styles['-webkit-touch-callout'],
                                
                                // Box model
                                padding: styles.padding,
                                margin: styles.margin,
                                border: styles.border,
                                
                                // Overflow
                                overflow: styles.overflow,
                                overflowX: styles.overflowX,
                                overflowY: styles.overflowY
                            }
                        });
                    }
                    
                    tableAnalysis.push({
                        tableIndex: index,
                        cellCount: cells.length,
                        tableStyles: {
                            width: tableStyles.width,
                            tableLayout: tableStyles.tableLayout,
                            borderCollapse: tableStyles.borderCollapse,
                            whiteSpace: tableStyles.whiteSpace
                        },
                        cellStyles: cellStyles
                    });
                });
                
                return {
                    timestamp: new Date().toISOString(),
                    tablesFound: tables.length,
                    tableAnalysis: tableAnalysis
                };
            }
        };
        
        // Auto-execute configuration extraction
        console.log('WKWebViewConfigExtractor: Starting comprehensive analysis...');
        const configData = window.WKWebViewConfigExtractor.extractAllConfigurations();
        const tableData = window.WKWebViewConfigExtractor.extractTableStyles();
        
        // Combine data
        const fullAnalysis = {
            ...configData,
            tableAnalysis: tableData
        };
        
        // Output via console for log capture
        console.log('WKWEBVIEW_CONFIG_START');
        console.log(JSON.stringify(fullAnalysis, null, 2));
        console.log('WKWEBVIEW_CONFIG_END');
        
        console.log('WKWebViewConfigExtractor: Analysis complete!');
        `;
        
        // Write the script to a temporary file for injection
        const scriptPath = path.join(this.outputDir, 'config-extractor-script.js');
        fs.writeFileSync(scriptPath, configExtractorScript);
        
        console.log('✅ Configuration extractor script prepared');
        return scriptPath;
    }

    async launchAppAndInjectScript() {
        console.log('🚀 Launching iOS app for configuration inspection...');
        
        try {
            // Kill existing app
            try {
                execSync(`xcrun simctl terminate "${this.simulatorUDID}" "${this.bundleId}"`, { stdio: 'pipe' });
            } catch (e) {}
            
            // Launch app
            const result = execSync(`xcrun simctl launch "${this.simulatorUDID}" "${this.bundleId}"`, { 
                encoding: 'utf8',
                timeout: 10000 
            });
            
            const pidMatch = result.match(/(\d+)/);
            const pid = pidMatch ? pidMatch[1] : 'unknown';
            console.log(`✅ iOS app launched with PID: ${pid}`);
            
            // Wait for initialization
            await new Promise(resolve => setTimeout(resolve, 4000));
            
            // Navigate to Varrock page
            const varrockURL = 'https://oldschool.runescape.wiki/w/Varrock';
            execSync(`xcrun simctl openurl "${this.simulatorUDID}" "${varrockURL}"`, { 
                stdio: 'pipe',
                timeout: 10000 
            });
            
            console.log('✅ Navigated to Varrock page');
            
            // Wait for page load
            await new Promise(resolve => setTimeout(resolve, 8000));
            
            return pid;
            
        } catch (error) {
            console.error('❌ Failed to launch app:', error.message);
            throw error;
        }
    }

    async captureConfigurationData() {
        console.log('🔍 Capturing WKWebView configuration data...');
        
        // Start log stream to capture JavaScript console output
        const logProcess = spawn('xcrun', [
            'simctl', 'spawn', this.simulatorUDID,
            'log', 'stream',
            '--level', 'debug',
            '--predicate', 'subsystem contains "com.omiyawaki" OR message contains "WKWebViewConfigExtractor" OR message contains "WKWEBVIEW_CONFIG"',
            '--style', 'compact'
        ]);
        
        let configData = '';
        let capturing = false;
        
        logProcess.stdout.on('data', (data) => {
            const output = data.toString();
            
            if (output.includes('WKWEBVIEW_CONFIG_START')) {
                capturing = true;
                configData = '';
                console.log('📡 Started capturing configuration data...');
            } else if (output.includes('WKWEBVIEW_CONFIG_END')) {
                capturing = false;
                console.log('✅ Configuration data capture complete');
            } else if (capturing && output.trim()) {
                // Extract JSON from log line (remove timestamp and process info)
                const jsonMatch = output.match(/\{[\s\S]*?\}/);
                if (jsonMatch) {
                    configData += jsonMatch[0];
                }
            }
        });
        
        // Give time for configuration to be captured
        console.log('⏳ Monitoring for configuration data (30 seconds)...');
        
        return new Promise((resolve) => {
            setTimeout(() => {
                logProcess.kill();
                
                if (configData) {
                    try {
                        const parsedConfig = JSON.parse(configData);
                        
                        // Save configuration data
                        const filename = `wkwebview-config-${Date.now()}.json`;
                        const filepath = path.join(this.outputDir, filename);
                        fs.writeFileSync(filepath, JSON.stringify(parsedConfig, null, 2));
                        
                        console.log(`💾 WKWebView configuration saved: ${filename}`);
                        resolve(parsedConfig);
                    } catch (error) {
                        console.error('❌ Failed to parse configuration data:', error.message);
                        console.log('Raw data captured:', configData);
                        resolve(null);
                    }
                } else {
                    console.log('⚠️  No configuration data captured automatically');
                    resolve(null);
                }
            }, 30000);
        });
    }

    async analyzeConfiguration(config) {
        if (!config) {
            console.log('❌ No configuration data to analyze');
            return;
        }

        console.log('\n' + '='.repeat(80));
        console.log('🔍 WKWEBVIEW CONFIGURATION ANALYSIS');
        console.log('='.repeat(80));

        // Viewport Analysis
        if (config.viewport) {
            console.log('\n📱 Viewport Configuration:');
            Object.entries(config.viewport).forEach(([key, value]) => {
                console.log(`   ${key}: ${value}`);
            });
        }

        // CSS Environment Critical Properties
        if (config.cssEnvironment) {
            console.log('\n🎨 Critical CSS Properties:');
            const critical = ['textSizeAdjust', 'wordWrap', 'overflowWrap', 'wordBreak', 'whiteSpace'];
            critical.forEach(prop => {
                const value = config.cssEnvironment[prop];
                console.log(`   -webkit-${prop}: ${value || 'not set'}`);
            });
        }

        // User Agent Analysis
        if (config.userAgent) {
            console.log('\n🌐 User Agent Information:');
            console.log(`   Full: ${config.userAgent.full}`);
            console.log(`   Platform: ${config.userAgent.platform}`);
            console.log(`   Vendor: ${config.userAgent.vendor}`);
        }

        // Media Query Environment
        if (config.mediaQueries) {
            console.log('\n📺 Media Query Environment:');
            Object.entries(config.mediaQueries).forEach(([key, value]) => {
                console.log(`   ${key}: ${value}`);
            });
        }

        // Table-Specific Analysis
        if (config.tableAnalysis && config.tableAnalysis.tableAnalysis) {
            console.log('\n📊 Table-Specific Style Analysis:');
            config.tableAnalysis.tableAnalysis.forEach(table => {
                console.log(`   Table ${table.tableIndex}: ${table.cellCount} cells`);
                
                if (table.cellStyles && table.cellStyles.length > 0) {
                    console.log('   First cell styles:');
                    const firstCell = table.cellStyles[0];
                    const criticalStyles = ['whiteSpace', 'wordWrap', 'overflowWrap', 'wordBreak'];
                    criticalStyles.forEach(style => {
                        console.log(`     ${style}: ${firstCell.styles[style]}`);
                    });
                }
            });
        }

        console.log('\n' + '='.repeat(80));
    }

    async run() {
        console.log('🔍 Starting WKWebView Configuration Inspection');
        console.log('🎯 Goal: Identify EXACT configuration differences causing table issues');
        
        try {
            // Prepare injection script
            await this.injectConfigurationExtractor();
            
            // Launch app and navigate
            await this.launchAppAndInjectScript();
            
            // Capture configuration
            const config = await this.captureConfigurationData();
            
            // Analyze results
            await this.analyzeConfiguration(config);
            
            console.log(`\n✅ WKWebView configuration inspection complete!`);
            console.log(`📁 Results saved in: ${this.outputDir}`);
            
            return config;
            
        } catch (error) {
            console.error('❌ Configuration inspection failed:', error.message);
            throw error;
        }
    }
}

// Main execution
if (require.main === module) {
    const inspector = new WKWebViewConfigInspector();
    inspector.run().catch(error => {
        console.error('❌ Inspection failed:', error.message);
        process.exit(1);
    });
}

module.exports = WKWebViewConfigInspector;