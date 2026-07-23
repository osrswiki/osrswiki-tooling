#!/usr/bin/env node

/**
 * iOS WKWebView Debugger
 * 
 * Uses Selenium with iOS Simulator to directly load Varrock page in the iOS app
 * and capture WKWebView-specific debugging data for comparison with desktop engines.
 */

const { execSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

class iOSWKWebViewDebugger {
    constructor() {
        this.outputDir = path.join(__dirname, '..', 'ios-wkwebview-debug');
        this.simulatorUDID = '5CEA746D-62CB-45DF-960F-B338BCE85346';
        this.bundleId = 'omiyawaki.osrswiki';
        this.ensureOutputDir();
    }

    ensureOutputDir() {
        if (!fs.existsSync(this.outputDir)) {
            fs.mkdirSync(this.outputDir, { recursive: true });
        }
    }

    async checkAppletoolsSupport() {
        try {
            require.resolve('appium');
            return true;
        } catch {
            console.log('📱 iOS automation requires manual navigation for now');
            return false;
        }
    }

    async launchIOSApp() {
        console.log('📱 Launching iOS app for WKWebView debugging...');
        
        try {
            // Kill existing app instances
            try {
                execSync(`xcrun simctl terminate "${this.simulatorUDID}" "${this.bundleId}"`, { stdio: 'pipe' });
            } catch (e) {
                // App might not be running
            }

            // Launch the app
            const result = execSync(`xcrun simctl launch "${this.simulatorUDID}" "${this.bundleId}"`, { 
                encoding: 'utf8',
                timeout: 10000 
            });
            
            const pidMatch = result.match(/(\d+)/);
            const pid = pidMatch ? pidMatch[1] : 'unknown';
            
            console.log(`✅ iOS app launched with PID: ${pid}`);
            
            // Wait for app to initialize
            await new Promise(resolve => setTimeout(resolve, 3000));
            
            return pid;
        } catch (error) {
            console.error('❌ Failed to launch iOS app:', error.message);
            throw error;
        }
    }

    async navigateToVarrockDirectly() {
        console.log('🌐 Attempting direct navigation to Varrock page...');
        
        try {
            // Try opening Varrock URL directly in the iOS app
            const varrockURL = 'https://oldschool.runescape.wiki/w/Varrock';
            
            // Use the iOS simulator's URL scheme to open in app
            execSync(`xcrun simctl openurl "${this.simulatorUDID}" "${varrockURL}"`, { 
                stdio: 'pipe',
                timeout: 10000 
            });
            
            console.log('✅ Varrock URL opened in iOS app');
            
            // Wait for page to load
            await new Promise(resolve => setTimeout(resolve, 8000));
            
            return true;
        } catch (error) {
            console.log('⚠️  Direct URL navigation failed, will need manual navigation');
            return false;
        }
    }

    async takeIOSScreenshot(label) {
        try {
            const filename = `ios-${label}-${Date.now()}.png`;
            const filepath = path.join(this.outputDir, filename);
            
            execSync(`xcrun simctl io "${this.simulatorUDID}" screenshot "${filepath}"`, { 
                stdio: 'pipe' 
            });
            
            console.log(`📸 Screenshot saved: ${filename}`);
            return filepath;
        } catch (error) {
            console.error('❌ Screenshot failed:', error.message);
            return null;
        }
    }

    async searchForDebugOutput() {
        console.log('🔍 Searching for WKWebView debugging output...');
        
        // Check simulator logs for debugging output
        try {
            const logs = execSync(`xcrun simctl spawn "${this.simulatorUDID}" log show --last 2m --predicate 'subsystem contains "com.omiyawaki" AND message contains "SafariDebugger"'`, { 
                encoding: 'utf8',
                timeout: 10000 
            });
            
            if (logs.includes('SafariDebugger')) {
                console.log('✅ Found WKWebView debugging output in logs!');
                
                // Extract JSON from logs
                const jsonMatches = logs.match(/\{[\s\S]*?\}/g);
                if (jsonMatches && jsonMatches.length > 0) {
                    const debugData = jsonMatches[jsonMatches.length - 1]; // Get latest
                    
                    const filename = `ios-wkwebview-debug-${Date.now()}.json`;
                    const filepath = path.join(this.outputDir, filename);
                    fs.writeFileSync(filepath, debugData);
                    
                    console.log(`💾 iOS WKWebView debug data saved: ${filename}`);
                    return JSON.parse(debugData);
                }
            }
        } catch (error) {
            console.log('⚠️  No debugging output found in logs yet');
        }

        // Check app Documents directory for debug files
        try {
            const containerPath = execSync(`xcrun simctl get_app_container "${this.simulatorUDID}" "${this.bundleId}" data`, { 
                encoding: 'utf8',
                timeout: 5000 
            }).trim();
            
            const documentsPath = path.join(containerPath, 'Documents');
            
            if (fs.existsSync(documentsPath)) {
                const files = fs.readdirSync(documentsPath)
                    .filter(f => f.includes('wkwebview-analysis') || f.includes('debug'))
                    .sort((a, b) => {
                        const statA = fs.statSync(path.join(documentsPath, a));
                        const statB = fs.statSync(path.join(documentsPath, b));
                        return statB.mtime - statA.mtime;
                    });
                
                if (files.length > 0) {
                    const debugFile = path.join(documentsPath, files[0]);
                    const debugData = fs.readFileSync(debugFile, 'utf8');
                    
                    // Copy to our output directory
                    const filename = `ios-wkwebview-analysis-${Date.now()}.json`;
                    const outputPath = path.join(this.outputDir, filename);
                    fs.writeFileSync(outputPath, debugData);
                    
                    console.log(`✅ Found iOS WKWebView debug file: ${files[0]}`);
                    console.log(`💾 Copied to: ${filename}`);
                    
                    return JSON.parse(debugData);
                }
            }
        } catch (error) {
            console.log('⚠️  Could not access app Documents directory');
        }

        return null;
    }

    async analyzeWKWebViewResults(wkwebviewData) {
        if (!wkwebviewData) {
            console.log('❌ No WKWebView data available for analysis');
            return;
        }

        console.log('\n' + '='.repeat(80));
        console.log('📱 iOS WKWEBVIEW ANALYSIS REPORT');
        console.log('='.repeat(80));

        // Environment info
        if (wkwebviewData.environment) {
            console.log('\n📱 WKWebView Environment:');
            console.log(`   User Agent: ${wkwebviewData.environment.userAgent || 'N/A'}`);
            if (wkwebviewData.environment.viewport) {
                const vp = wkwebviewData.environment.viewport;
                console.log(`   Viewport: ${vp.width}x${vp.height} (DPR: ${vp.devicePixelRatio || 1})`);
            }
        }

        // Table analysis
        if (wkwebviewData.tables && Array.isArray(wkwebviewData.tables)) {
            let totalCells = 0;
            let wrappingCells = 0;
            let singleLineCells = 0;
            let overflowingCells = 0;

            wkwebviewData.tables.forEach(table => {
                if (table.wrappingBehavior) {
                    totalCells += table.wrappingBehavior.totalCells || 0;
                    wrappingCells += table.wrappingBehavior.wrappingCells || 0;
                    singleLineCells += table.wrappingBehavior.singleLineCells || 0;
                    overflowingCells += table.wrappingBehavior.overflowingCells || 0;
                }
            });

            const wrappingPercentage = totalCells > 0 ? Math.round((wrappingCells * 100) / totalCells) : 0;

            console.log('\n📊 WKWebView Table Analysis:');
            console.log(`   Tables analyzed: ${wkwebviewData.tables.length}`);
            console.log(`   Total cells: ${totalCells}`);
            console.log(`   Wrapping cells: ${wrappingCells} (${wrappingPercentage}%)`);
            console.log(`   Single-line cells: ${singleLineCells}`);
            console.log(`   Overflowing cells: ${overflowingCells}`);

            // Compare with desktop results
            console.log('\n🔬 Comparison with Desktop Engines:');
            console.log('   Desktop WebKit: 62% text wrapping ✅');
            console.log('   Desktop Chromium: 62% text wrapping ✅');
            console.log(`   iOS WKWebView: ${wrappingPercentage}% text wrapping ${wrappingPercentage < 30 ? '❌' : '✅'}`);

            if (wrappingPercentage < 30) {
                console.log('\n🎯 ISSUE CONFIRMED:');
                console.log('   iOS WKWebView has significantly lower text wrapping than desktop!');
                console.log('   This confirms the reported iOS table rendering problem.');
            } else if (wrappingPercentage > 50) {
                console.log('\n🤔 UNEXPECTED:');
                console.log('   iOS WKWebView shows good text wrapping in this test');
                console.log('   The issue might be specific to certain table configurations');
            }
        }

        console.log('\n' + '='.repeat(80));
    }

    async run() {
        console.log('🚀 Starting iOS WKWebView Debugging Session');
        console.log('📱 Target: iOS Simulator with real WKWebView engine');
        console.log('🎯 Goal: Capture actual iOS table rendering behavior');

        try {
            // Launch iOS app
            const pid = await this.launchIOSApp();
            
            // Take initial screenshot
            await this.takeIOSScreenshot('app-launched');
            
            // Try direct navigation
            const navigated = await this.navigateToVarrockDirectly();
            
            if (navigated) {
                // Take screenshot after navigation
                await this.takeIOSScreenshot('varrock-loaded');
                
                // Wait for debugging script to run
                console.log('⏳ Waiting for WKWebView debugging analysis to complete...');
                await new Promise(resolve => setTimeout(resolve, 10000));
                
                // Search for debug output
                const debugData = await this.searchForDebugOutput();
                
                if (debugData) {
                    await this.analyzeWKWebViewResults(debugData);
                } else {
                    console.log('⚠️  No WKWebView debugging data found automatically');
                    console.log('📱 Manual navigation may be required:');
                    console.log('   1. Open the iOS app (already running)');
                    console.log('   2. Search for "Varrock" or navigate to any page with tables');
                    console.log('   3. The debugging script will automatically capture data');
                }
            } else {
                console.log('📱 Manual navigation required:');
                console.log('   1. iOS app is running in the simulator');
                console.log('   2. Navigate to Varrock page or any page with tables');
                console.log('   3. Debugging will capture data automatically');
                
                // Take screenshot of current state
                await this.takeIOSScreenshot('manual-nav-required');
            }
            
            // Continue monitoring for a bit
            console.log('🔍 Monitoring for debugging output (30 seconds)...');
            let attempts = 0;
            while (attempts < 6) { // 6 attempts * 5 seconds = 30 seconds
                await new Promise(resolve => setTimeout(resolve, 5000));
                const debugData = await this.searchForDebugOutput();
                if (debugData) {
                    await this.analyzeWKWebViewResults(debugData);
                    break;
                }
                attempts++;
                console.log(`⏳ Checking for debug output... (${attempts}/6)`);
            }

        } catch (error) {
            console.error('❌ iOS WKWebView debugging failed:', error.message);
        }

        console.log('✅ iOS WKWebView debugging session complete!');
        console.log(`📁 Output directory: ${this.outputDir}`);
    }
}

// Main execution
if (require.main === module) {
    const iosDebugger = new iOSWKWebViewDebugger();
    iosDebugger.run().catch(error => {
        console.error('❌ iOS debugging failed:', error.message);
        process.exit(1);
    });
}

module.exports = iOSWKWebViewDebugger;