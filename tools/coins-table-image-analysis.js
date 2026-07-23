#!/usr/bin/env node

/**
 * Coins Page Table Image Analysis Tool
 * 
 * This tool uses Puppeteer to analyze the working Coins page in a browser,
 * specifically focusing on the Products table images that should appear
 * in the first column but are missing in mobile WebView.
 * 
 * Purpose: Identify the exact CSS properties that make images visible
 * in the working web version vs. hidden in mobile WebView.
 */

const puppeteer = require('puppeteer');
const fs = require('fs');
const path = require('path');

class CoinsTableImageAnalyzer {
    constructor() {
        this.outputDir = path.join(__dirname, '..', 'webkit-debug');
        this.ensureOutputDir();
    }

    ensureOutputDir() {
        if (!fs.existsSync(this.outputDir)) {
            fs.mkdirSync(this.outputDir, { recursive: true });
        }
    }

    async run() {
        console.log('🚀 Starting Coins page image analysis...');
        console.log('🎯 Target: Products table first column images');
        console.log('🌐 Creating desktop browser environment...');

        let browser;
        try {
            // Launch browser with desktop settings to see working images
            browser = await puppeteer.launch({
                headless: "new",
                args: [
                    '--no-sandbox',
                    '--disable-setuid-sandbox',
                    '--disable-web-security'
                ]
            });

            const page = await browser.newPage();

            // Set desktop viewport to see working version
            await page.setViewport({
                width: 1200,
                height: 800
            });

            console.log('🌐 Loading: https://oldschool.runescape.wiki/w/Coins');

            // Navigate to Coins page
            await page.goto('https://oldschool.runescape.wiki/w/Coins', {
                waitUntil: 'networkidle2',
                timeout: 30000
            });

            console.log('📄 Page loaded successfully');
            console.log('🔍 Starting Products table image analysis...');

            // Wait for dynamic content and images to load
            await new Promise(resolve => setTimeout(resolve, 5000));

            // Run the comprehensive image analysis
            const analysisResult = await page.evaluate(() => {
                return new Promise((resolve) => {
                    const analysis = {
                        timestamp: new Date().toISOString(),
                        platform: 'desktop-browser-puppeteer',
                        environment: {
                            userAgent: navigator.userAgent,
                            viewport: {
                                width: window.innerWidth,
                                height: window.innerHeight,
                                devicePixelRatio: window.devicePixelRatio || 1
                            },
                            documentReadyState: document.readyState
                        },
                        pageInfo: {
                            title: document.title,
                            url: window.location.href,
                            totalImages: document.querySelectorAll('img').length,
                            totalTables: document.querySelectorAll('table').length
                        },
                        productsTable: null,
                        firstColumnImages: [],
                        cssAnalysis: {
                            inventoryImageSpans: [],
                            imageContainers: [],
                            commonImageStyles: {}
                        }
                    };

                    // Find the Products table specifically
                    const allTables = document.querySelectorAll('table.wikitable');
                    console.log(`🔍 Found ${allTables.length} wikitable elements`);

                    let productsTable = null;
                    allTables.forEach((table, index) => {
                        const className = table.className;
                        console.log(`Table ${index}: ${className}`);
                        if (className.includes('products-list')) {
                            productsTable = table;
                            console.log(`✅ Found Products table at index ${index}`);
                        }
                    });

                    if (!productsTable) {
                        // Look for any table containing product items
                        allTables.forEach((table, index) => {
                            const firstCell = table.querySelector('td, th');
                            if (firstCell) {
                                const text = firstCell.textContent.toLowerCase();
                                if (text.includes('accursed') || text.includes('antipoison') || text.includes('item')) {
                                    productsTable = table;
                                    console.log(`✅ Found potential Products table at index ${index} by content`);
                                }
                            }
                        });
                    }

                    if (!productsTable) {
                        analysis.error = "Products table not found";
                        resolve(analysis);
                        return;
                    }

                    // Analyze the Products table
                    const tableRect = productsTable.getBoundingClientRect();
                    const tableStyles = window.getComputedStyle(productsTable);
                    
                    analysis.productsTable = {
                        found: true,
                        className: productsTable.className,
                        dimensions: {
                            width: tableRect.width,
                            height: tableRect.height
                        },
                        styles: {
                            display: tableStyles.display,
                            visibility: tableStyles.visibility,
                            opacity: tableStyles.opacity,
                            tableLayout: tableStyles.tableLayout,
                            borderCollapse: tableStyles.borderCollapse
                        },
                        rowCount: productsTable.querySelectorAll('tr').length,
                        columnCount: productsTable.querySelector('tr') ? productsTable.querySelector('tr').querySelectorAll('td, th').length : 0
                    };

                    // Analyze first column cells (where images should be)
                    const rows = productsTable.querySelectorAll('tr');
                    rows.forEach((row, rowIndex) => {
                        if (rowIndex === 0) return; // Skip header row
                        
                        const firstCell = row.querySelector('td:first-child, th:first-child');
                        if (!firstCell || rowIndex > 20) return; // Limit to first 20 items for detailed analysis

                        const cellRect = firstCell.getBoundingClientRect();
                        const cellStyles = window.getComputedStyle(firstCell);

                        // Find images in this cell
                        const images = firstCell.querySelectorAll('img');
                        const spans = firstCell.querySelectorAll('span');
                        const inventoryImageSpans = firstCell.querySelectorAll('span.inventory-image, span[class*="image"]');

                        const cellAnalysis = {
                            rowIndex: rowIndex,
                            textContent: firstCell.textContent.trim().substring(0, 100),
                            dimensions: {
                                width: cellRect.width,
                                height: cellRect.height,
                                top: cellRect.top,
                                left: cellRect.left
                            },
                            cellStyles: {
                                display: cellStyles.display,
                                visibility: cellStyles.visibility,
                                opacity: cellStyles.opacity,
                                overflow: cellStyles.overflow,
                                position: cellStyles.position,
                                width: cellStyles.width,
                                height: cellStyles.height,
                                padding: cellStyles.padding,
                                textAlign: cellStyles.textAlign
                            },
                            images: [],
                            spans: [],
                            inventoryImageSpans: []
                        };

                        // Analyze each image in this cell
                        images.forEach((img, imgIndex) => {
                            const imgRect = img.getBoundingClientRect();
                            const imgStyles = window.getComputedStyle(img);
                            
                            const imageAnalysis = {
                                index: imgIndex,
                                src: img.src,
                                alt: img.alt,
                                className: img.className,
                                dimensions: {
                                    width: imgRect.width,
                                    height: imgRect.height,
                                    naturalWidth: img.naturalWidth,
                                    naturalHeight: img.naturalHeight,
                                    top: imgRect.top,
                                    left: imgRect.left
                                },
                                isVisible: imgRect.width > 0 && imgRect.height > 0 && imgStyles.opacity !== '0' && imgStyles.visibility !== 'hidden',
                                styles: {
                                    display: imgStyles.display,
                                    visibility: imgStyles.visibility,
                                    opacity: imgStyles.opacity,
                                    position: imgStyles.position,
                                    width: imgStyles.width,
                                    height: imgStyles.height,
                                    maxWidth: imgStyles.maxWidth,
                                    maxHeight: imgStyles.maxHeight,
                                    minWidth: imgStyles.minWidth,
                                    minHeight: imgStyles.minHeight,
                                    objectFit: imgStyles.objectFit,
                                    zIndex: imgStyles.zIndex,
                                    transform: imgStyles.transform,
                                    margin: imgStyles.margin,
                                    padding: imgStyles.padding,
                                    border: imgStyles.border,
                                    backgroundColor: imgStyles.backgroundColor,
                                    boxSizing: imgStyles.boxSizing,
                                    float: imgStyles.float,
                                    verticalAlign: imgStyles.verticalAlign
                                },
                                parentElement: {
                                    tagName: img.parentElement.tagName,
                                    className: img.parentElement.className,
                                    styles: {}
                                }
                            };

                            // Get parent element styles
                            const parentStyles = window.getComputedStyle(img.parentElement);
                            imageAnalysis.parentElement.styles = {
                                display: parentStyles.display,
                                visibility: parentStyles.visibility,
                                opacity: parentStyles.opacity,
                                position: parentStyles.position,
                                overflow: parentStyles.overflow,
                                width: parentStyles.width,
                                height: parentStyles.height
                            };

                            cellAnalysis.images.push(imageAnalysis);
                        });

                        // Analyze spans that might contain images
                        inventoryImageSpans.forEach((span, spanIndex) => {
                            const spanRect = span.getBoundingClientRect();
                            const spanStyles = window.getComputedStyle(span);
                            
                            const spanAnalysis = {
                                index: spanIndex,
                                className: span.className,
                                innerHTML: span.innerHTML.substring(0, 200),
                                dimensions: {
                                    width: spanRect.width,
                                    height: spanRect.height,
                                    top: spanRect.top,
                                    left: spanRect.left
                                },
                                isVisible: spanRect.width > 0 && spanRect.height > 0 && spanStyles.opacity !== '0' && spanStyles.visibility !== 'hidden',
                                styles: {
                                    display: spanStyles.display,
                                    visibility: spanStyles.visibility,
                                    opacity: spanStyles.opacity,
                                    position: spanStyles.position,
                                    width: spanStyles.width,
                                    height: spanStyles.height,
                                    backgroundImage: spanStyles.backgroundImage,
                                    backgroundSize: spanStyles.backgroundSize,
                                    backgroundPosition: spanStyles.backgroundPosition,
                                    backgroundRepeat: spanStyles.backgroundRepeat
                                },
                                childImages: span.querySelectorAll('img').length
                            };

                            cellAnalysis.inventoryImageSpans.push(spanAnalysis);
                        });

                        analysis.firstColumnImages.push(cellAnalysis);
                    });

                    // Find all .inventory-image spans on the page for pattern analysis
                    const allInventorySpans = document.querySelectorAll('.inventory-image, span[class*="inventory"], span[class*="image"]');
                    allInventorySpans.forEach((span, index) => {
                        if (index < 50) { // Analyze first 50 for patterns
                            const spanRect = span.getBoundingClientRect();
                            const spanStyles = window.getComputedStyle(span);
                            
                            analysis.cssAnalysis.inventoryImageSpans.push({
                                index: index,
                                className: span.className,
                                tagName: span.tagName,
                                isVisible: spanRect.width > 0 && spanRect.height > 0 && spanStyles.opacity !== '0' && spanStyles.visibility !== 'hidden',
                                dimensions: {
                                    width: spanRect.width,
                                    height: spanRect.height
                                },
                                styles: {
                                    display: spanStyles.display,
                                    visibility: spanStyles.visibility,
                                    opacity: spanStyles.opacity,
                                    width: spanStyles.width,
                                    height: spanStyles.height,
                                    backgroundImage: spanStyles.backgroundImage !== 'none' ? 'HAS_BACKGROUND' : 'none'
                                },
                                childImages: span.querySelectorAll('img').length,
                                innerHTML: span.innerHTML.substring(0, 100)
                            });
                        }
                    });

                    resolve(analysis);
                });
            });

            // Take a screenshot of the working page
            const screenshotPath = path.join(this.outputDir, `coins-page-working-${Date.now()}.png`);
            await page.screenshot({ 
                path: screenshotPath,
                fullPage: true 
            });
            console.log(`📸 Screenshot saved: ${screenshotPath}`);

            // Save results and generate report
            await this.saveResults(analysisResult);
            this.generateReport(analysisResult);

        } catch (error) {
            console.error('❌ Analysis failed:', error.message);
            throw error;
        } finally {
            if (browser) {
                await browser.close();
            }
        }
    }

    async saveResults(analysis) {
        const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
        const filename = `coins-image-analysis-${timestamp}.json`;
        const filepath = path.join(this.outputDir, filename);

        try {
            await fs.promises.writeFile(filepath, JSON.stringify(analysis, null, 2));
            console.log(`💾 Analysis saved to: ${filepath}`);
            return filepath;
        } catch (error) {
            console.error('❌ Failed to save analysis:', error.message);
            throw error;
        }
    }

    generateReport(analysis) {
        console.log('\n' + '='.repeat(70));
        console.log('🖼️  COINS PAGE IMAGE ANALYSIS REPORT');
        console.log('='.repeat(70));

        // Environment info
        console.log('\n🌐 Environment:');
        console.log(`   Platform: ${analysis.platform}`);
        console.log(`   Viewport: ${analysis.environment.viewport.width}x${analysis.environment.viewport.height}`);
        console.log(`   Page URL: ${analysis.pageInfo.url}`);
        console.log(`   Total images on page: ${analysis.pageInfo.totalImages}`);
        console.log(`   Total tables on page: ${analysis.pageInfo.totalTables}`);

        if (analysis.error) {
            console.log(`\n❌ ERROR: ${analysis.error}`);
            return;
        }

        // Products table info
        console.log('\n📊 Products Table:');
        if (analysis.productsTable.found) {
            console.log(`   ✅ Found Products table`);
            console.log(`   Class: ${analysis.productsTable.className}`);
            console.log(`   Dimensions: ${Math.round(analysis.productsTable.dimensions.width)}x${Math.round(analysis.productsTable.dimensions.height)}px`);
            console.log(`   Rows: ${analysis.productsTable.rowCount}`);
            console.log(`   Columns: ${analysis.productsTable.columnCount}`);
            console.log(`   Display: ${analysis.productsTable.styles.display}`);
            console.log(`   Visibility: ${analysis.productsTable.styles.visibility}`);
            console.log(`   Opacity: ${analysis.productsTable.styles.opacity}`);
        }

        // First column analysis
        console.log('\n🖼️  First Column Image Analysis:');
        console.log(`   Analyzed cells: ${analysis.firstColumnImages.length}`);

        let totalImages = 0;
        let visibleImages = 0;
        let totalInventorySpans = 0;
        let visibleInventorySpans = 0;

        analysis.firstColumnImages.forEach((cell, index) => {
            totalImages += cell.images.length;
            visibleImages += cell.images.filter(img => img.isVisible).length;
            totalInventorySpans += cell.inventoryImageSpans.length;
            visibleInventorySpans += cell.inventoryImageSpans.filter(span => span.isVisible).length;

            if (index < 10) { // Show details for first 10 cells
                console.log(`\n   Cell ${cell.rowIndex} (${cell.textContent.substring(0, 30)}...):`);
                console.log(`     - Images: ${cell.images.length} (${cell.images.filter(img => img.isVisible).length} visible)`);
                console.log(`     - Inventory spans: ${cell.inventoryImageSpans.length} (${cell.inventoryImageSpans.filter(span => span.isVisible).length} visible)`);
                console.log(`     - Cell display: ${cell.cellStyles.display}`);
                console.log(`     - Cell visibility: ${cell.cellStyles.visibility}`);
                console.log(`     - Cell opacity: ${cell.cellStyles.opacity}`);

                // Show details of first image in this cell
                if (cell.images.length > 0) {
                    const img = cell.images[0];
                    console.log(`     - First image src: ${img.src.substring(img.src.lastIndexOf('/') + 1)}`);
                    console.log(`     - Image visible: ${img.isVisible ? '✅ YES' : '❌ NO'}`);
                    console.log(`     - Image dimensions: ${img.dimensions.width}x${img.dimensions.height}px (natural: ${img.dimensions.naturalWidth}x${img.dimensions.naturalHeight})`);
                    console.log(`     - Image display: ${img.styles.display}`);
                    console.log(`     - Image visibility: ${img.styles.visibility}`);
                    console.log(`     - Image opacity: ${img.styles.opacity}`);
                }
            }
        });

        console.log(`\n📈 Summary:`)
        console.log(`   Total images in first column: ${totalImages}`);
        console.log(`   Visible images: ${visibleImages} (${Math.round((visibleImages/totalImages)*100)}%)`);
        console.log(`   Total inventory spans: ${totalInventorySpans}`);
        console.log(`   Visible inventory spans: ${visibleInventorySpans}`);

        // Pattern analysis
        console.log('\n🎨 CSS Pattern Analysis:');
        console.log(`   Total .inventory-image spans found: ${analysis.cssAnalysis.inventoryImageSpans.length}`);
        
        const visiblePatternSpans = analysis.cssAnalysis.inventoryImageSpans.filter(span => span.isVisible).length;
        console.log(`   Visible inventory spans: ${visiblePatternSpans} (${Math.round((visiblePatternSpans/analysis.cssAnalysis.inventoryImageSpans.length)*100)}%)`);

        // Show common CSS patterns for working images
        if (analysis.firstColumnImages.length > 0 && totalImages > 0) {
            console.log('\n🔍 Working Image CSS Properties:');
            console.log('   (Properties that make images visible in working browser)');
            
            // Get the first visible image for reference
            let sampleImage = null;
            for (const cell of analysis.firstColumnImages) {
                const visibleImg = cell.images.find(img => img.isVisible);
                if (visibleImg) {
                    sampleImage = visibleImg;
                    break;
                }
            }

            if (sampleImage) {
                console.log(`\n   Sample working image (${sampleImage.src.substring(sampleImage.src.lastIndexOf('/') + 1)}):`);
                Object.entries(sampleImage.styles).forEach(([prop, value]) => {
                    if (value && value !== 'auto' && value !== 'none' && value !== 'normal' && value !== 'static') {
                        console.log(`     ${prop}: ${value}`);
                    }
                });

                if (sampleImage.parentElement.styles) {
                    console.log(`\n   Parent element styles:`);
                    Object.entries(sampleImage.parentElement.styles).forEach(([prop, value]) => {
                        if (value && value !== 'auto' && value !== 'none' && value !== 'normal' && value !== 'static') {
                            console.log(`     ${prop}: ${value}`);
                        }
                    });
                }
            }
        }

        console.log('\n🎯 Key Findings:');
        if (visibleImages === 0) {
            console.log('   🚨 CRITICAL: No visible images found in Products table first column!');
            console.log('   🔧 This suggests the issue exists even in desktop browser');
        } else if (visibleImages < totalImages * 0.8) {
            console.log(`   ⚠️  PARTIAL: Only ${Math.round((visibleImages/totalImages)*100)}% of images are visible`);
            console.log('   🔧 Some images are hidden by CSS properties');
        } else {
            console.log('   ✅ GOOD: Most images are visible in desktop browser');
            console.log('   🔧 Issue is likely WebView-specific rendering differences');
        }

        console.log('\n✅ Analysis complete!');
        console.log('💾 Check the JSON file and screenshot for detailed technical data.');
        console.log('='.repeat(70));
    }
}

// Check if Puppeteer is available
async function checkPuppeteer() {
    try {
        require.resolve('puppeteer');
        return true;
    } catch {
        console.log('📦 Puppeteer not found. Installing...');
        const { execSync } = require('child_process');
        try {
            execSync('npm install puppeteer --no-save', { stdio: 'inherit' });
            return true;
        } catch (error) {
            console.error('❌ Failed to install Puppeteer:', error.message);
            return false;
        }
    }
}

// Main execution
if (require.main === module) {
    (async () => {
        if (await checkPuppeteer()) {
            const analyzer = new CoinsTableImageAnalyzer();
            try {
                await analyzer.run();
            } catch (error) {
                console.error('❌ Analysis failed:', error.message);
                process.exit(1);
            }
        } else {
            console.error('❌ Could not install required dependencies');
            process.exit(1);
        }
    })();
}

module.exports = CoinsTableImageAnalyzer;