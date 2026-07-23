#!/usr/bin/env node

/**
 * Safari Desktop Configuration Extractor
 * 
 * Extracts the same configuration properties from desktop Safari
 * to create a baseline comparison for WKWebView analysis.
 * Uses Apple's official SafariDriver for accurate WebKit environment.
 */

const { Builder, By, Key, until } = require('selenium-webdriver');
const safari = require('selenium-webdriver/safari');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

class SafariConfigExtractor {
    constructor() {
        this.outputDir = path.join(__dirname, '..', 'safari-config-baseline');
        this.ensureOutputDir();
        this.driver = null;
    }

    ensureOutputDir() {
        if (!fs.existsSync(this.outputDir)) {
            fs.mkdirSync(this.outputDir, { recursive: true });
        }
    }

    async enableSafariDriver() {
        try {
            console.log('🔧 Checking SafariDriver...');
            const version = execSync('safaridriver --version', { stdio: 'pipe', encoding: 'utf8' });
            console.log(`✅ SafariDriver available: ${version.trim()}`);
            
            // Start SafariDriver service
            console.log('🚀 Starting SafariDriver service...');
            this.safariDriverProcess = require('child_process').spawn('safaridriver', ['-p', '9515'], {
                stdio: 'pipe'
            });
            
            // Wait for SafariDriver to start
            await new Promise(resolve => setTimeout(resolve, 2000));
            
            return true;
        } catch (error) {
            console.error('❌ SafariDriver setup failed:', error.message);
            return false;
        }
    }

    async initializeSafari() {
        try {
            console.log('🌐 Initializing Safari WebDriver...');
            
            const safariOptions = new safari.Options();
            safariOptions.setTechnologyPreview(false);
            
            this.driver = await new Builder()
                .forBrowser('safari')
                .setSafariOptions(safariOptions)
                .build();
            
            console.log('✅ Safari WebDriver initialized');
            return true;
            
        } catch (error) {
            console.error('❌ Safari initialization failed:', error.message);
            return false;
        }
    }

    async extractSafariConfiguration() {
        console.log('🔍 Extracting Safari configuration from Varrock page...');
        
        try {
            // Navigate to Varrock page
            const varrockURL = 'https://oldschool.runescape.wiki/w/Varrock';
            await this.driver.get(varrockURL);
            
            console.log('✅ Navigated to Varrock page');
            
            // Wait for page to load completely
            await this.driver.wait(until.titleContains('Varrock'), 10000);
            await new Promise(resolve => setTimeout(resolve, 5000));
            
            // Set mobile viewport simulation
            await this.driver.executeScript(`
                // Simulate mobile viewport for comparison
                Object.defineProperty(window, 'innerWidth', { value: 375, writable: false });
                Object.defineProperty(window, 'innerHeight', { value: 812, writable: false });
            `);
            
            // Execute the same configuration extraction script as WKWebView
            const configData = await this.driver.executeScript(`
                // Safari Configuration Extractor - Identical to WKWebView version
                const config = {
                    timestamp: new Date().toISOString(),
                    environment: 'safari-desktop',
                    
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
            `);
            
            // Extract table-specific styles
            const tableData = await this.driver.executeScript(`
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
            `);
            
            // Combine configuration and table data
            const fullConfig = {
                ...configData,
                tableAnalysis: tableData
            };
            
            // Save configuration
            const filename = `safari-desktop-config-${Date.now()}.json`;
            const filepath = path.join(this.outputDir, filename);
            fs.writeFileSync(filepath, JSON.stringify(fullConfig, null, 2));
            
            console.log(`✅ Safari configuration extracted and saved: ${filename}`);
            return fullConfig;
            
        } catch (error) {
            console.error('❌ Safari configuration extraction failed:', error.message);
            throw error;
        }
    }

    async cleanup() {
        if (this.driver) {
            await this.driver.quit();
        }
        if (this.safariDriverProcess) {
            this.safariDriverProcess.kill();
        }
    }

    async run() {
        console.log('🌐 Starting Safari Desktop Configuration Extraction');
        console.log('🎯 Goal: Create baseline configuration for WKWebView comparison');
        
        try {
            // Setup SafariDriver
            const safariReady = await this.enableSafariDriver();
            if (!safariReady) {
                throw new Error('SafariDriver setup failed');
            }
            
            // Initialize Safari
            const safariInitialized = await this.initializeSafari();
            if (!safariInitialized) {
                throw new Error('Safari initialization failed');
            }
            
            // Extract configuration
            const config = await this.extractSafariConfiguration();
            
            console.log('\n✅ Safari configuration extraction complete!');
            console.log(`📁 Results saved in: ${this.outputDir}`);
            
            return config;
            
        } catch (error) {
            console.error('❌ Safari configuration extraction failed:', error.message);
            throw error;
        } finally {
            await this.cleanup();
        }
    }
}

// Main execution
if (require.main === module) {
    const extractor = new SafariConfigExtractor();
    extractor.run().catch(error => {
        console.error('❌ Extraction failed:', error.message);
        process.exit(1);
    });
}

module.exports = SafariConfigExtractor;