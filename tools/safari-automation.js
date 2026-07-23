#!/usr/bin/env node

/**
 * Safari Web Automation Tool for OSRS Wiki
 * 
 * This tool uses Safari's automation capabilities to:
 * 1. Load the Varrock page in mobile Safari
 * 2. Capture HTML structure and CSS properties of tables
 * 3. Compare rendering behavior with iOS WKWebView app
 * 
 * Prerequisites:
 * - Safari → Develop → Allow Remote Automation enabled
 * - Safari → Advanced → Show Develop menu enabled
 */

const { execSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

class SafariAutomation {
    constructor() {
        this.outputDir = path.join(__dirname, '..', 'safari-debug');
        this.ensureOutputDir();
    }

    ensureOutputDir() {
        if (!fs.existsSync(this.outputDir)) {
            fs.mkdirSync(this.outputDir, { recursive: true });
        }
    }

    async runAppleScript(script) {
        try {
            const result = execSync(`osascript -e '${script}'`, { 
                encoding: 'utf8',
                timeout: 30000 
            });
            return result.trim();
        } catch (error) {
            console.error('AppleScript error:', error.message);
            throw error;
        }
    }

    async openSafariAndNavigate() {
        console.log('🚀 Opening Safari and navigating to Varrock page...');
        
        const script = `
            tell application "Safari"
                activate
                
                -- Create new document if none exists
                if (count of documents) = 0 then
                    make new document
                end if
                
                -- Navigate to Varrock page
                set URL of front document to "https://oldschool.runescape.wiki/w/Varrock"
                
                -- Wait for page to load
                repeat while (do JavaScript "document.readyState" in front document) ≠ "complete"
                    delay 0.5
                end repeat
                
                -- Additional wait for dynamic content
                delay 3
                
                return "Navigation complete"
            end tell
        `;

        return await this.runAppleScript(script);
    }

    async executeJavaScript(jsCode) {
        const escapedCode = jsCode.replace(/"/g, '\\"').replace(/\n/g, '\\n');
        const script = `
            tell application "Safari"
                set result to do JavaScript "${escapedCode}" in front document
                return result
            end tell
        `;

        return await this.runAppleScript(script);
    }

    async captureTableStructure() {
        console.log('📊 Capturing table structure and CSS properties...');

        const jsCode = `
            // Find all wikitable elements
            const tables = document.querySelectorAll('table.wikitable');
            const results = [];
            
            tables.forEach((table, index) => {
                const tableInfo = {
                    index: index,
                    outerHTML: table.outerHTML.substring(0, 2000), // Truncate for safety
                    computedStyles: {},
                    cellInfo: []
                };
                
                // Get computed styles for the table
                const tableStyles = window.getComputedStyle(table);
                tableInfo.computedStyles.table = {
                    width: tableStyles.width,
                    tableLayout: tableStyles.tableLayout,
                    borderCollapse: tableStyles.borderCollapse,
                    wordWrap: tableStyles.wordWrap,
                    overflowWrap: tableStyles.overflowWrap,
                    whiteSpace: tableStyles.whiteSpace
                };
                
                // Get info about first few cells
                const cells = table.querySelectorAll('td, th');
                for (let i = 0; i < Math.min(cells.length, 10); i++) {
                    const cell = cells[i];
                    const cellStyles = window.getComputedStyle(cell);
                    tableInfo.cellInfo.push({
                        index: i,
                        tagName: cell.tagName,
                        textContent: cell.textContent.substring(0, 100),
                        computedStyles: {
                            width: cellStyles.width,
                            maxWidth: cellStyles.maxWidth,
                            minWidth: cellStyles.minWidth,
                            wordWrap: cellStyles.wordWrap,
                            overflowWrap: cellStyles.overflowWrap,
                            wordBreak: cellStyles.wordBreak,
                            whiteSpace: cellStyles.whiteSpace,
                            textSizeAdjust: cellStyles.webkitTextSizeAdjust || cellStyles.textSizeAdjust,
                            display: cellStyles.display
                        }
                    });
                }
                
                results.push(tableInfo);
            });
            
            // Also capture viewport and user agent info
            const debugInfo = {
                userAgent: navigator.userAgent,
                viewport: {
                    width: window.innerWidth,
                    height: window.innerHeight,
                    devicePixelRatio: window.devicePixelRatio
                },
                documentReadyState: document.readyState,
                tablesFound: results.length
            };
            
            JSON.stringify({ debugInfo, tables: results });
        `;

        const result = await this.executeJavaScript(jsCode);
        return JSON.parse(result);
    }

    async captureMediaWikiConfig() {
        console.log('🔧 Capturing MediaWiki configuration...');

        const jsCode = `
            const config = {
                mwConfig: window.mw ? window.mw.config.get() : null,
                mwVersion: window.mw ? window.mw.loader.getVersion() : null,
                loadedScripts: [],
                loadedStylesheets: []
            };
            
            // Capture loaded scripts
            document.querySelectorAll('script[src]').forEach(script => {
                config.loadedScripts.push(script.src);
            });
            
            // Capture loaded stylesheets
            document.querySelectorAll('link[rel="stylesheet"]').forEach(link => {
                config.loadedStylesheets.push(link.href);
            });
            
            // Check for table-specific scripts
            config.tableScripts = {
                sortable: typeof window.Sortable !== 'undefined',
                jquery: typeof window.jQuery !== 'undefined',
                mwTableSorter: window.mw ? typeof window.mw.loader.getState('jquery.tablesorter') !== null : false
            };
            
            JSON.stringify(config);
        `;

        const result = await this.executeJavaScript(jsCode);
        return JSON.parse(result);
    }

    async captureViewportScreenshot() {
        console.log('📸 Taking Safari screenshot...');

        // This uses the built-in screenshot functionality
        const script = `
            tell application "Safari"
                tell front document
                    -- Take screenshot using built-in functionality if available
                    -- This is a simplified approach; actual implementation may vary
                    return "Screenshot functionality would need native implementation"
                end tell
            end tell
        `;

        return await this.runAppleScript(script);
    }

    async investigateTableWrapping() {
        console.log('🔍 Investigating specific table wrapping behavior...');

        const jsCode = `
            // Focus on the first wikitable and analyze its text wrapping
            const firstTable = document.querySelector('table.wikitable');
            if (!firstTable) {
                return JSON.stringify({ error: 'No wikitable found' });
            }
            
            const cells = firstTable.querySelectorAll('td');
            const wrappingAnalysis = [];
            
            cells.forEach((cell, index) => {
                if (index < 20) { // Analyze first 20 cells
                    const rect = cell.getBoundingClientRect();
                    const styles = window.getComputedStyle(cell);
                    const textContent = cell.textContent;
                    
                    // Check if text appears to be wrapping
                    const tempSpan = document.createElement('span');
                    tempSpan.style.cssText = 'position: absolute; visibility: hidden; white-space: nowrap; font: inherit;';
                    tempSpan.textContent = textContent;
                    document.body.appendChild(tempSpan);
                    const singleLineWidth = tempSpan.getBoundingClientRect().width;
                    document.body.removeChild(tempSpan);
                    
                    const isWrapping = singleLineWidth > rect.width && textContent.length > 10;
                    
                    wrappingAnalysis.push({
                        index: index,
                        textLength: textContent.length,
                        textPreview: textContent.substring(0, 50),
                        cellWidth: rect.width,
                        singleLineWidth: singleLineWidth,
                        isWrapping: isWrapping,
                        computedStyles: {
                            width: styles.width,
                            maxWidth: styles.maxWidth,
                            wordWrap: styles.wordWrap,
                            overflowWrap: styles.overflowWrap,
                            whiteSpace: styles.whiteSpace
                        }
                    });
                }
            });
            
            JSON.stringify({
                tableFound: true,
                cellsAnalyzed: wrappingAnalysis.length,
                wrappingCells: wrappingAnalysis.filter(cell => cell.isWrapping).length,
                analysis: wrappingAnalysis
            });
        `;

        const result = await this.executeJavaScript(jsCode);
        return JSON.parse(result);
    }

    saveResults(filename, data) {
        const filepath = path.join(this.outputDir, filename);
        fs.writeFileSync(filepath, JSON.stringify(data, null, 2));
        console.log(`💾 Saved results to: ${filepath}`);
        return filepath;
    }

    async run() {
        try {
            console.log('🔍 Safari Web Automation Tool - OSRS Wiki Analysis');
            console.log('='.repeat(60));

            // Step 1: Open Safari and navigate
            await this.openSafariAndNavigate();

            // Step 2: Capture table structure
            const tableData = await this.captureTableStructure();
            this.saveResults('safari-table-structure.json', tableData);

            // Step 3: Capture MediaWiki configuration
            const mwConfig = await this.captureMediaWikiConfig();
            this.saveResults('safari-mediawiki-config.json', mwConfig);

            // Step 4: Investigate table wrapping behavior
            const wrappingData = await this.investigateTableWrapping();
            this.saveResults('safari-table-wrapping.json', wrappingData);

            console.log('✅ Safari analysis complete!');
            console.log(`📁 Results saved in: ${this.outputDir}`);

            // Summary
            console.log('\n📊 SUMMARY:');
            console.log(`- Tables found: ${tableData.debugInfo.tablesFound}`);
            console.log(`- User Agent: ${tableData.debugInfo.userAgent}`);
            console.log(`- Viewport: ${tableData.debugInfo.viewport.width}x${tableData.debugInfo.viewport.height}`);
            console.log(`- MediaWiki loaded: ${mwConfig.mwConfig ? 'Yes' : 'No'}`);
            console.log(`- Wrapping cells found: ${wrappingData.wrappingCells || 0}`);

        } catch (error) {
            console.error('❌ Error during Safari automation:', error.message);
            throw error;
        }
    }
}

// CLI usage
if (require.main === module) {
    const automation = new SafariAutomation();
    automation.run().catch(error => {
        console.error('Fatal error:', error);
        process.exit(1);
    });
}

module.exports = SafariAutomation;