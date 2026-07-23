#!/bin/bash

echo "🔧 Setting up Apple SafariDriver for WebKit Analysis"
echo "=================================================="
echo

echo "1. Enable SafariDriver (requires admin password):"
echo "sudo safaridriver --enable"
sudo safaridriver --enable
echo

echo "2. Enabling Safari automation settings..."
# Enable Safari remote automation
defaults write com.apple.Safari AllowRemoteAutomation -bool true 2>/dev/null || echo "Safari preferences may be protected by sandboxing"

# Enable Develop menu
defaults write com.apple.Safari IncludeDevelopMenu -bool true 2>/dev/null || echo "Safari preferences may be protected by sandboxing"

echo "3. Manual Safari Configuration Required:"
echo "   - Open Safari"
echo "   - Go to Safari → Settings (or Preferences)"
echo "   - Click Advanced tab"
echo "   - Check 'Show Develop menu in menu bar'"
echo "   - Go to Develop menu → Allow Remote Automation"
echo

echo "4. Test SafariDriver:"
echo "safaridriver --version"
safaridriver --version
echo

echo "✅ SafariDriver setup complete!"
echo "Now you can run: node tools/official-webkit-analysis.js"