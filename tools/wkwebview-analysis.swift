#!/usr/bin/env swift

/**
 * WKWebView Configuration Analysis
 * 
 * This Swift script analyzes potential differences between WKWebView configuration
 * in our iOS app versus mobile Safari that could affect table rendering.
 */

import Foundation
import WebKit

// Analyze WKWebView configuration differences
class WKWebViewAnalyzer {
    
    func analyzeDefaultConfiguration() {
        print("🔍 WKWebView Configuration Analysis")
        print(String(repeating: "=", count: 50))
        
        let config = WKWebViewConfiguration()
        
        print("\n📱 Default WKWebView Configuration:")
        print("- suppressesIncrementalRendering: \(config.suppressesIncrementalRendering)")
        
        if #available(iOS 14.0, *) {
            print("- limitsNavigationsToAppBoundDomains: \(config.limitsNavigationsToAppBoundDomains)")
        }
        
        // Web page preferences
        if let webPagePrefs = config.defaultWebpagePreferences {
            print("\n🌐 Default Webpage Preferences:")
            print("- allowsContentJavaScript: \(webPagePrefs.allowsContentJavaScript)")
            
            if #available(iOS 14.0, *) {
                print("- preferredContentMode: \(webPagePrefs.preferredContentMode.rawValue)")
            }
        }
        
        // User content controller
        print("\n📜 User Content Controller:")
        print("- User scripts count: \(config.userContentController.userScripts.count)")
        
        // Process pool
        print("\n⚙️ Process Pool:")
        print("- Process pool: \(type(of: config.processPool))")
        
        // Website data store
        print("\n💾 Website Data Store:")
        print("- isPersistent: \(config.websiteDataStore.isPersistent)")
        
        print("\n" + String(repeating: "=", count: 50))
        print("🎯 Key Differences to Investigate:")
        print("1. User Agent String")
        print("2. Viewport Settings") 
        print("3. CSS Media Queries")
        print("4. JavaScript Engine Configuration")
        print("5. Font Rendering Settings")
        print("6. Text Size Adjustment Behavior")
    }
    
    func generateConfigurationComparison() {
        print("\n🔬 Configuration Recommendations:")
        print("- Check if app uses custom User-Agent")
        print("- Verify viewport meta tag handling")
        print("- Compare CSS media query evaluation")
        print("- Check for custom font loading")
        print("- Analyze text size adjustment defaults")
        
        print("\n📝 Potential WKWebView Issues:")
        print("1. Different default viewport behavior")
        print("2. Different text size adjustment algorithms")
        print("3. Different CSS cascade handling")
        print("4. Different table layout engine behavior")
        print("5. Missing MediaWiki JavaScript modules")
    }
    
    func suggestDebuggingSteps() {
        print("\n🛠️ Debugging Steps:")
        print("1. Add WKWebView debugging to iOS app")
        print("2. Compare User-Agent strings")
        print("3. Log CSS media query matches")
        print("4. Capture computed styles in both environments")
        print("5. Check for JavaScript errors in WKWebView")
        print("6. Compare font loading behavior")
        
        print("\n💡 Code to Add to iOS App:")
        print("""
        // In your WKWebView setup:
        
        // 1. Enable debugging
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        
        // 2. Log user agent
        webView.evaluateJavaScript("navigator.userAgent") { result, error in
            print("User Agent: \\(result ?? "unknown")")
        }
        
        // 3. Log viewport info
        webView.evaluateJavaScript(\"\"\"
            JSON.stringify({
                innerWidth: window.innerWidth,
                innerHeight: window.innerHeight,
                devicePixelRatio: window.devicePixelRatio,
                screen: { width: screen.width, height: screen.height }
            })
        \"\"\") { result, error in
            print("Viewport Info: \\(result ?? "unknown")")
        }
        
        // 4. Log table CSS after page load
        webView.evaluateJavaScript(\"\"\"
            const table = document.querySelector('table.wikitable');
            if (table) {
                const styles = window.getComputedStyle(table);
                const cellStyles = window.getComputedStyle(table.querySelector('td'));
                JSON.stringify({
                    tableLayout: styles.tableLayout,
                    wordWrap: cellStyles.wordWrap,
                    overflowWrap: cellStyles.overflowWrap,
                    textSizeAdjust: cellStyles.webkitTextSizeAdjust
                });
            }
        \"\"\") { result, error in
            print("Table Styles: \\(result ?? "unknown")")
        }
        """)
    }
}

// Run the analysis
let analyzer = WKWebViewAnalyzer()
analyzer.analyzeDefaultConfiguration()
analyzer.generateConfigurationComparison()
analyzer.suggestDebuggingSteps()