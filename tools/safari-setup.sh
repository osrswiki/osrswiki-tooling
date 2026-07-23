#!/bin/bash

echo "🔧 Safari Automation Setup"
echo "=========================="
echo
echo "To enable Safari automation, please:"
echo "1. Open Safari"
echo "2. Go to Safari → Settings (or Preferences)"
echo "3. Click on 'Advanced' tab"
echo "4. Check 'Show Develop menu in menu bar'"
echo "5. Go to Develop menu → Allow Remote Automation"
echo "6. In Settings → Advanced → Developer section:"
echo "   - Check 'Allow JavaScript from Apple Events'"
echo
echo "Then run: node tools/safari-automation.js"
echo
echo "📱 Alternative: Manual Web Analysis"
echo "==================================="
echo "If automation doesn't work, manually:"
echo "1. Open Safari on your iPhone/iPad or use responsive mode"
echo "2. Navigate to: https://oldschool.runescape.wiki/w/Varrock"
echo "3. Open Developer Tools (Develop → Show Web Inspector)"
echo "4. Use Console to run our analysis JavaScript"
echo
echo "JavaScript to run in console:"
echo "=============================="

cat << 'EOF'

// Analyze table wrapping in Safari
const analyzeTableWrapping = () => {
    const tables = document.querySelectorAll('table.wikitable');
    const results = [];
    
    tables.forEach((table, index) => {
        const cells = table.querySelectorAll('td');
        const cellAnalysis = [];
        
        cells.forEach((cell, cellIndex) => {
            if (cellIndex < 10) { // First 10 cells
                const rect = cell.getBoundingClientRect();
                const styles = window.getComputedStyle(cell);
                const text = cell.textContent;
                
                // Test if text would wrap
                const testSpan = document.createElement('span');
                testSpan.style.cssText = 'position: absolute; visibility: hidden; white-space: nowrap; font-family: inherit; font-size: inherit;';
                testSpan.textContent = text;
                document.body.appendChild(testSpan);
                const singleLineWidth = testSpan.getBoundingClientRect().width;
                document.body.removeChild(testSpan);
                
                cellAnalysis.push({
                    cellIndex,
                    text: text.substring(0, 50),
                    cellWidth: rect.width,
                    singleLineWidth: singleLineWidth,
                    isWrapping: singleLineWidth > rect.width && text.length > 10,
                    styles: {
                        width: styles.width,
                        maxWidth: styles.maxWidth,
                        wordWrap: styles.wordWrap,
                        overflowWrap: styles.overflowWrap,
                        whiteSpace: styles.whiteSpace,
                        textSizeAdjust: styles.webkitTextSizeAdjust
                    }
                });
            }
        });
        
        results.push({
            tableIndex: index,
            cellsAnalyzed: cellAnalysis.length,
            wrappingCells: cellAnalysis.filter(c => c.isWrapping).length,
            cells: cellAnalysis
        });
    });
    
    console.log('🔍 Safari Table Analysis Results:');
    console.log({
        userAgent: navigator.userAgent,
        viewport: { width: window.innerWidth, height: window.innerHeight },
        tables: results
    });
    
    return results;
};

// Run the analysis
analyzeTableWrapping();

EOF

echo
echo "Copy and paste the above JavaScript into Safari's Web Inspector Console"
echo "and compare the results with iOS app behavior."