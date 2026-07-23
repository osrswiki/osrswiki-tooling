#!/usr/bin/env swift

import Foundation
import WebKit

/**
 * Automated iOS WKWebView Analysis Tool
 * 
 * This tool creates a headless WKWebView, loads the Varrock page,
 * and automatically analyzes table rendering differences.
 * No manual intervention required - just like Playwright.
 */

class AutomatedWebKitAnalyzer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView!
    private var analysisComplete = false
    // Output directory: use WEBKIT_ANALYSIS_OUTPUT env var or default to current working directory
    private let outputDir: String = ProcessInfo.processInfo.environment["WEBKIT_ANALYSIS_OUTPUT"]
        ?? FileManager.default.currentDirectoryPath + "/webkit-debug"
    
    override init() {
        super.init()
        setupWebView()
        createOutputDirectory()
    }
    
    private func createOutputDirectory() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: outputDir) {
            try? fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        }
    }
    
    private func setupWebView() {
        let config = WKWebViewConfiguration()
        
        // Enable debugging
        if #available(macOS 13.3, iOS 16.4, *) {
            config.isInspectable = true
        }
        
        // Create headless WebView
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 812), configuration: config)
        webView.navigationDelegate = self
        
        print("🔧 WKWebView configured for automated analysis")
        print("📱 Viewport: 375x812 (iPhone size)")
        print("🔍 Debug mode: enabled")
    }
    
    func run() {
        print("🚀 Starting automated WKWebView analysis...")
        print("🌐 Loading: https://oldschool.runescape.wiki/w/Varrock")
        
        guard let url = URL(string: "https://oldschool.runescape.wiki/w/Varrock") else {
            print("❌ Invalid URL")
            exit(1)
        }
        
        let request = URLRequest(url: url)
        webView.load(request)
        
        // Run the runloop to process the navigation
        let runLoop = RunLoop.current
        while !analysisComplete && runLoop.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) {
            // Keep running until analysis is complete
        }
        
        print("✅ Analysis completed successfully!")
    }
    
    // MARK: - WKNavigationDelegate
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("📄 Page loaded successfully")
        
        // Wait a bit for dynamic content
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.performAutomatedAnalysis()
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("❌ Navigation failed: \(error.localizedDescription)")
        analysisComplete = true
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("❌ Provisional navigation failed: \(error.localizedDescription)")
        analysisComplete = true
    }
    
    private func performAutomatedAnalysis() {
        print("🔍 Starting automated table analysis...")
        
        let analysisScript = """
        (function() {
            const analysis = {
                timestamp: new Date().toISOString(),
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
                    }
                },
                mediaQueries: {
                    mobile: window.matchMedia('(max-width: 768px)').matches,
                    tablet: window.matchMedia('(min-width: 768px) and (max-width: 1024px)').matches,
                    desktop: window.matchMedia('(min-width: 1024px)').matches,
                    retina: window.matchMedia('(-webkit-min-device-pixel-ratio: 2)').matches
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
                    cells: [],
                    wrappingBehavior: {
                        totalCells: 0,
                        wrappingCells: 0,
                        singleLineCells: 0
                    }
                };
                
                // Get table-level styles
                const tableComputedStyle = window.getComputedStyle(table);
                tableAnalysis.tableStyles = {
                    width: tableComputedStyle.width,
                    tableLayout: tableComputedStyle.tableLayout,
                    borderCollapse: tableComputedStyle.borderCollapse,
                    fontSize: tableComputedStyle.fontSize,
                    fontFamily: tableComputedStyle.fontFamily,
                    textSizeAdjust: tableComputedStyle.webkitTextSizeAdjust || tableComputedStyle.textSizeAdjust || 'auto'
                };
                
                // Analyze each cell
                const cells = table.querySelectorAll('td, th');
                cells.forEach((cell, cellIndex) => {
                    if (cellIndex < 20) { // Analyze first 20 cells for performance
                        const cellRect = cell.getBoundingClientRect();
                        const cellStyles = window.getComputedStyle(cell);
                        const textContent = cell.textContent.trim();
                        
                        // Test if text would wrap by measuring single-line width
                        const testElement = document.createElement('span');
                        testElement.style.cssText = `
                            position: absolute;
                            visibility: hidden;
                            white-space: nowrap;
                            font-family: ${cellStyles.fontFamily};
                            font-size: ${cellStyles.fontSize};
                            font-weight: ${cellStyles.fontWeight};
                            letter-spacing: ${cellStyles.letterSpacing};
                        `;
                        testElement.textContent = textContent;
                        document.body.appendChild(testElement);
                        
                        const singleLineWidth = testElement.getBoundingClientRect().width;
                        document.body.removeChild(testElement);
                        
                        const isWrapping = textContent.length > 20 && singleLineWidth > cellRect.width * 0.95;
                        
                        tableAnalysis.cells.push({
                            index: cellIndex,
                            tagName: cell.tagName.toLowerCase(),
                            textContent: textContent.substring(0, 100),
                            textLength: textContent.length,
                            dimensions: {
                                width: cellRect.width,
                                height: cellRect.height,
                                singleLineWidth: singleLineWidth
                            },
                            isWrapping: isWrapping,
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
                                display: cellStyles.display,
                                boxSizing: cellStyles.boxSizing,
                                padding: cellStyles.padding,
                                border: cellStyles.border
                            }
                        });
                        
                        tableAnalysis.wrappingBehavior.totalCells++;
                        if (isWrapping) {
                            tableAnalysis.wrappingBehavior.wrappingCells++;
                        } else {
                            tableAnalysis.wrappingBehavior.singleLineCells++;
                        }
                    }
                });
                
                analysis.tables.push(tableAnalysis);
            });
            
            // Check for MediaWiki-specific elements
            analysis.mediaWiki = {
                version: window.mw ? window.mw.config.get('wgVersion') : null,
                skin: window.mw ? window.mw.config.get('skin') : null,
                isMediaWikiLoaded: typeof window.mw !== 'undefined',
                loadedModules: window.mw ? Object.keys(window.mw.loader.getState()) : [],
                jQueryVersion: window.jQuery ? window.jQuery.fn.jquery : null
            };
            
            console.log('📊 Analysis Results:', analysis);
            return JSON.stringify(analysis, null, 2);
        })();
        """
        
        webView.evaluateJavaScript(analysisScript) { [weak self] result, error in
            if let error = error {
                print("❌ JavaScript analysis failed: \(error.localizedDescription)")
                self?.analysisComplete = true
                return
            }
            
            guard let jsonString = result as? String else {
                print("❌ Failed to get JSON result from analysis")
                self?.analysisComplete = true
                return
            }
            
            self?.saveAnalysisResults(jsonString)
            self?.generateReport(jsonString)
            self?.analysisComplete = true
        }
    }
    
    private func saveAnalysisResults(_ jsonString: String) {
        let filename = "wkwebview-analysis-\(Int(Date().timeIntervalSince1970)).json"
        let filepath = "\(outputDir)/\(filename)"
        
        do {
            try jsonString.write(toFile: filepath, atomically: true, encoding: .utf8)
            print("💾 Analysis saved to: \(filepath)")
        } catch {
            print("❌ Failed to save analysis: \(error.localizedDescription)")
        }
    }
    
    private func generateReport(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let analysis = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("❌ Failed to parse analysis results")
            return
        }
        
        print("\n" + String(repeating: "=", count: 60))
        print("📊 AUTOMATED WKWEBVIEW ANALYSIS REPORT")
        print(String(repeating: "=", count: 60))
        
        // Environment info
        if let env = analysis["environment"] as? [String: Any] {
            print("\n🌐 Environment:")
            if let userAgent = env["userAgent"] as? String {
                print("   User Agent: \(userAgent)")
            }
            if let viewport = env["viewport"] as? [String: Any] {
                let width = viewport["width"] ?? "unknown"
                let height = viewport["height"] ?? "unknown"
                let dpr = viewport["devicePixelRatio"] ?? "unknown"
                print("   Viewport: \(width)x\(height) (DPR: \(dpr))")
            }
        }
        
        // MediaWiki info
        if let mw = analysis["mediaWiki"] as? [String: Any] {
            print("\n📚 MediaWiki:")
            let isLoaded = mw["isMediaWikiLoaded"] as? Bool ?? false
            print("   MediaWiki loaded: \(isLoaded)")
            if let version = mw["version"] as? String {
                print("   Version: \(version)")
            }
            if let skin = mw["skin"] as? String {
                print("   Skin: \(skin)")
            }
        }
        
        // Table analysis
        if let tables = analysis["tables"] as? [[String: Any]] {
            print("\n📊 Table Analysis:")
            print("   Tables found: \(tables.count)")
            
            for (index, table) in tables.enumerated() {
                if let wrapping = table["wrappingBehavior"] as? [String: Any] {
                    let total = wrapping["totalCells"] as? Int ?? 0
                    let wrappingCells = wrapping["wrappingCells"] as? Int ?? 0
                    let singleLine = wrapping["singleLineCells"] as? Int ?? 0
                    let wrappingPercentage = total > 0 ? (wrappingCells * 100 / total) : 0
                    
                    print("   Table \(index + 1):")
                    print("     - Total cells: \(total)")
                    print("     - Wrapping cells: \(wrappingCells) (\(wrappingPercentage)%)")
                    print("     - Single-line cells: \(singleLine)")
                    
                    if wrappingCells == 0 && singleLine > 0 {
                        print("     ⚠️  NO TEXT WRAPPING DETECTED - This matches the reported iOS issue!")
                    }
                }
                
                if let tableStyles = table["tableStyles"] as? [String: Any] {
                    if let textSizeAdjust = tableStyles["textSizeAdjust"] as? String {
                        print("     - Text size adjust: \(textSizeAdjust)")
                    }
                    if let tableLayout = tableStyles["tableLayout"] as? String {
                        print("     - Table layout: \(tableLayout)")
                    }
                }
            }
        }
        
        print("\n✅ Analysis complete - check JSON file for detailed data")
        print(String(repeating: "=", count: 60))
    }
}

// Main execution
let analyzer = AutomatedWebKitAnalyzer()
analyzer.run()