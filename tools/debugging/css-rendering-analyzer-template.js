#!/usr/bin/env node

/**
 * CSS Rendering Analyzer Template
 * 
 * Generic template for investigating CSS rendering discrepancies between
 * desktop browsers and mobile WebViews. Customize the target URL and
 * analysis selectors for your specific investigation.
 * 
 * Based on successful methodology used to fix table image rendering issues.
 */

const puppeteer = require('puppeteer');
const fs = require('fs');
const path = require('path');

class CSSRenderingAnalyzer {
    constructor(config = {}) {
        // CUSTOMIZE THESE SETTINGS FOR YOUR INVESTIGATION
        this.config = {
            // Target page to analyze
            targetUrl: config.targetUrl || 'https://oldschool.runescape.wiki/w/Coins',
            
            // CSS selectors to focus analysis on
            containerSelector: config.containerSelector || 'table.wikitable',
            contentSelector: config.contentSelector || 'td, th',
            imageSelector: config.imageSelector || 'img',
            
            // Analysis depth (number of elements to analyze per container)
            analysisDepth: config.analysisDepth || 30,
            
            // Output configuration
            outputDir: config.outputDir || path.join(__dirname, 'analysis-output'),
            timestampFormat: config.timestampFormat || 'YYYY-MM-DD-HH-mm-ss',
            
            // Browser configuration
            viewport: config.viewport || {
                width: 375,
                height: 812,
                deviceScaleFactor: 3,
                isMobile: true,
                hasTouch: true
            },
            userAgent: config.userAgent || 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'
        };
        
        this.ensureOutputDir();
    }

    ensureOutputDir() {
        if (!fs.existsSync(this.config.outputDir)) {
            fs.mkdirSync(this.config.outputDir, { recursive: true });
        }
    }

    async checkDependencies() {
        try {
            require.resolve('puppeteer');
            return true;
        } catch {
            console.log('📦 Installing puppeteer...');
            try {
                const { execSync } = require('child_process');
                execSync('npm install puppeteer --no-save', { stdio: 'inherit' });
                return true;
            } catch (error) {
                console.error('❌ Failed to install puppeteer:', error.message);
                return false;
            }
        }
    }

    async run() {
        console.log('🔍 Starting CSS rendering analysis...');
        console.log(`🎯 Target: ${this.config.targetUrl}`);
        console.log(`📱 Viewport: ${this.config.viewport.width}x${this.config.viewport.height}`);

        let browser;
        try {
            // Check and install dependencies
            if (!(await this.checkDependencies())) {
                throw new Error('Failed to install required dependencies');
            }

            // Launch browser with mobile configuration
            browser = await puppeteer.launch({
                headless: "new",
                args: [
                    '--no-sandbox',
                    '--disable-setuid-sandbox',
                    '--disable-web-security',
                    '--disable-features=VizDisplayCompositor'
                ]
            });

            const page = await browser.newPage();

            // Configure mobile environment
            await page.setUserAgent(this.config.userAgent);
            await page.setViewport(this.config.viewport);

            console.log('🌐 Loading page...');
            await page.goto(this.config.targetUrl, {
                waitUntil: 'networkidle2',
                timeout: 30000
            });

            // Wait for dynamic content
            await new Promise(resolve => setTimeout(resolve, 3000));

            console.log('📊 Running CSS analysis...');
            const analysisResult = await page.evaluate((config) => {
                return new Promise((resolve) => {
                    const analysis = {
                        timestamp: new Date().toISOString(),
                        config: {
                            targetUrl: config.targetUrl,
                            containerSelector: config.containerSelector,
                            contentSelector: config.contentSelector,
                            imageSelector: config.imageSelector
                        },
                        environment: {
                            userAgent: navigator.userAgent,
                            viewport: {
                                width: window.innerWidth,
                                height: window.innerHeight,
                                devicePixelRatio: window.devicePixelRatio || 1
                            },
                            documentReadyState: document.readyState,
                            location: window.location.href
                        },
                        mediaQueries: {
                            mobile: window.matchMedia('(max-width: 768px)').matches,
                            tablet: window.matchMedia('(min-width: 768px) and (max-width: 1024px)').matches,
                            desktop: window.matchMedia('(min-width: 1024px)').matches,
                            retina: window.matchMedia('(-webkit-min-device-pixel-ratio: 2)').matches,
                            portrait: window.matchMedia('(orientation: portrait)').matches
                        },
                        cssSupport: {
                            textSizeAdjust: CSS.supports('-webkit-text-size-adjust', '100%'),
                            overflowWrap: CSS.supports('overflow-wrap', 'break-word'),
                            objectFit: CSS.supports('object-fit', 'contain'),
                            flexbox: CSS.supports('display', 'flex'),
                            grid: CSS.supports('display', 'grid')
                        },
                        containers: []
                    };

                    // Find target containers
                    const containers = document.querySelectorAll(config.containerSelector);
                    console.log(`Found ${containers.length} containers matching "${config.containerSelector}"`);

                    containers.forEach((container, containerIndex) => {
                        if (containerIndex < 10) { // Limit analysis to prevent timeout
                            const containerAnalysis = {
                                index: containerIndex,
                                selector: config.containerSelector,
                                tagName: container.tagName.toLowerCase(),
                                className: container.className,
                                id: container.id,
                                dimensions: {},
                                styles: {},
                                content: [],
                                images: []
                            };

                            // Get container dimensions
                            const containerRect = container.getBoundingClientRect();
                            containerAnalysis.dimensions = {
                                width: containerRect.width,
                                height: containerRect.height,
                                scrollWidth: container.scrollWidth,
                                scrollHeight: container.scrollHeight,
                                clientWidth: container.clientWidth,
                                clientHeight: container.clientHeight
                            };

                            // Get container styles
                            const containerStyles = window.getComputedStyle(container);
                            containerAnalysis.styles = {
                                // Layout properties
                                display: containerStyles.display,
                                position: containerStyles.position,
                                overflow: containerStyles.overflow,
                                overflowX: containerStyles.overflowX,
                                overflowY: containerStyles.overflowY,
                                
                                // Box model
                                width: containerStyles.width,
                                height: containerStyles.height,
                                maxWidth: containerStyles.maxWidth,
                                maxHeight: containerStyles.maxHeight,
                                minWidth: containerStyles.minWidth,
                                minHeight: containerStyles.minHeight,
                                padding: containerStyles.padding,
                                margin: containerStyles.margin,
                                border: containerStyles.border,
                                
                                // Table-specific (if applicable)
                                tableLayout: containerStyles.tableLayout,
                                borderCollapse: containerStyles.borderCollapse,
                                
                                // Text properties
                                fontSize: containerStyles.fontSize,
                                fontFamily: containerStyles.fontFamily,
                                lineHeight: containerStyles.lineHeight,
                                textAlign: containerStyles.textAlign,
                                whiteSpace: containerStyles.whiteSpace,
                                wordWrap: containerStyles.wordWrap,
                                overflowWrap: containerStyles.overflowWrap,
                                wordBreak: containerStyles.wordBreak,
                                
                                // WebKit-specific
                                webkitTextSizeAdjust: containerStyles.webkitTextSizeAdjust || 'auto',
                                webkitOverflowScrolling: containerStyles.webkitOverflowScrolling,
                                
                                // Visibility
                                visibility: containerStyles.visibility,
                                opacity: containerStyles.opacity,
                                zIndex: containerStyles.zIndex
                            };

                            // Analyze content elements
                            const contentElements = container.querySelectorAll(config.contentSelector);
                            contentElements.forEach((element, elementIndex) => {
                                if (elementIndex < config.analysisDepth) {
                                    const elementRect = element.getBoundingClientRect();
                                    const elementStyles = window.getComputedStyle(element);

                                    const elementAnalysis = {
                                        index: elementIndex,
                                        tagName: element.tagName.toLowerCase(),
                                        className: element.className,
                                        textContent: element.textContent.trim().substring(0, 200),
                                        textLength: element.textContent.trim().length,
                                        dimensions: {
                                            width: elementRect.width,
                                            height: elementRect.height,
                                            top: elementRect.top,
                                            left: elementRect.left
                                        },
                                        styles: {
                                            // Core layout
                                            display: elementStyles.display,
                                            position: elementStyles.position,
                                            visibility: elementStyles.visibility,
                                            opacity: elementStyles.opacity,
                                            
                                            // Box model
                                            width: elementStyles.width,
                                            height: elementStyles.height,
                                            padding: elementStyles.padding,
                                            margin: elementStyles.margin,
                                            border: elementStyles.border,
                                            
                                            // Background
                                            background: elementStyles.background,
                                            backgroundColor: elementStyles.backgroundColor,
                                            backgroundImage: elementStyles.backgroundImage,
                                            
                                            // Text
                                            textAlign: elementStyles.textAlign,
                                            verticalAlign: elementStyles.verticalAlign,
                                            fontSize: elementStyles.fontSize,
                                            fontWeight: elementStyles.fontWeight,
                                            lineHeight: elementStyles.lineHeight,
                                            
                                            // Overflow and wrapping
                                            overflow: elementStyles.overflow,
                                            whiteSpace: elementStyles.whiteSpace,
                                            wordWrap: elementStyles.wordWrap,
                                            overflowWrap: elementStyles.overflowWrap,
                                            wordBreak: elementStyles.wordBreak,
                                            
                                            // WebKit
                                            webkitTextSizeAdjust: elementStyles.webkitTextSizeAdjust || 'auto'
                                        }
                                    };

                                    containerAnalysis.content.push(elementAnalysis);
                                }
                            });

                            // Analyze images specifically
                            const images = container.querySelectorAll(config.imageSelector);
                            images.forEach((img, imgIndex) => {
                                if (imgIndex < config.analysisDepth) {
                                    const imgRect = img.getBoundingClientRect();
                                    const imgStyles = window.getComputedStyle(img);
                                    const imgParent = img.parentElement;
                                    const parentStyles = imgParent ? window.getComputedStyle(imgParent) : null;

                                    const imageAnalysis = {
                                        index: imgIndex,
                                        src: img.src,
                                        alt: img.alt,
                                        naturalWidth: img.naturalWidth,
                                        naturalHeight: img.naturalHeight,
                                        dimensions: {
                                            width: imgRect.width,
                                            height: imgRect.height,
                                            displayedWidth: img.width,
                                            displayedHeight: img.height
                                        },
                                        styles: {
                                            // Core properties
                                            display: imgStyles.display,
                                            position: imgStyles.position,
                                            visibility: imgStyles.visibility,
                                            opacity: imgStyles.opacity,
                                            
                                            // Sizing
                                            width: imgStyles.width,
                                            height: imgStyles.height,
                                            maxWidth: imgStyles.maxWidth,
                                            maxHeight: imgStyles.maxHeight,
                                            minWidth: imgStyles.minWidth,
                                            minHeight: imgStyles.minHeight,
                                            
                                            // Image-specific
                                            objectFit: imgStyles.objectFit,
                                            objectPosition: imgStyles.objectPosition,
                                            verticalAlign: imgStyles.verticalAlign,
                                            
                                            // Layout
                                            margin: imgStyles.margin,
                                            padding: imgStyles.padding,
                                            border: imgStyles.border,
                                            
                                            // Background
                                            background: imgStyles.background,
                                            backgroundColor: imgStyles.backgroundColor,
                                            
                                            // Box model
                                            boxSizing: imgStyles.boxSizing,
                                            float: imgStyles.float
                                        },
                                        parent: parentStyles ? {
                                            tagName: imgParent.tagName.toLowerCase(),
                                            className: imgParent.className,
                                            styles: {
                                                display: parentStyles.display,
                                                position: parentStyles.position,
                                                visibility: parentStyles.visibility,
                                                opacity: parentStyles.opacity,
                                                overflow: parentStyles.overflow,
                                                textAlign: parentStyles.textAlign,
                                                width: parentStyles.width,
                                                height: parentStyles.height
                                            }
                                        } : null
                                    };

                                    containerAnalysis.images.push(imageAnalysis);
                                }
                            });

                            analysis.containers.push(containerAnalysis);
                        }
                    });

                    resolve(analysis);
                });
            }, this.config);

            // Save results
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
        const filename = `css-rendering-analysis-${timestamp}.json`;
        const filepath = path.join(this.config.outputDir, filename);

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
        console.log('\n' + '='.repeat(80));
        console.log('📊 CSS RENDERING ANALYSIS REPORT');
        console.log('='.repeat(80));

        // Basic info
        console.log(`\n🎯 Analysis Target: ${analysis.config.targetUrl}`);
        console.log(`📱 Container Selector: ${analysis.config.containerSelector}`);
        console.log(`📄 Content Selector: ${analysis.config.contentSelector}`);
        console.log(`🖼️  Image Selector: ${analysis.config.imageSelector}`);

        // Environment
        console.log('\n🌐 Environment:');
        console.log(`   User Agent: ${analysis.environment.userAgent}`);
        console.log(`   Viewport: ${analysis.environment.viewport.width}x${analysis.environment.viewport.height} (DPR: ${analysis.environment.viewport.devicePixelRatio})`);
        console.log(`   Page State: ${analysis.environment.documentReadyState}`);

        // Media queries
        console.log('\n📱 Media Query Matches:');
        Object.entries(analysis.mediaQueries).forEach(([query, matches]) => {
            console.log(`   ${query}: ${matches ? '✅' : '❌'}`);
        });

        // CSS support
        console.log('\n🎨 CSS Feature Support:');
        Object.entries(analysis.cssSupport).forEach(([feature, supported]) => {
            console.log(`   ${feature}: ${supported ? '✅' : '❌'}`);
        });

        // Container analysis
        console.log('\n📦 Container Analysis:');
        console.log(`   Containers found: ${analysis.containers.length}`);

        analysis.containers.forEach((container, index) => {
            console.log(`\n   Container ${index + 1} (${container.tagName}):`);
            console.log(`     - Class: ${container.className || 'none'}`);
            console.log(`     - Dimensions: ${Math.round(container.dimensions.width)}x${Math.round(container.dimensions.height)}px`);
            console.log(`     - Display: ${container.styles.display}`);
            console.log(`     - Position: ${container.styles.position}`);
            console.log(`     - Visibility: ${container.styles.visibility}`);
            console.log(`     - Overflow: ${container.styles.overflow}`);
            if (container.styles.tableLayout) {
                console.log(`     - Table Layout: ${container.styles.tableLayout}`);
                console.log(`     - Border Collapse: ${container.styles.borderCollapse}`);
            }
            console.log(`     - Content Elements: ${container.content.length}`);
            console.log(`     - Images: ${container.images.length}`);

            // Highlight potential issues
            if (container.images.length > 0) {
                const invisibleImages = container.images.filter(img => 
                    img.styles.visibility === 'hidden' || 
                    img.styles.opacity === '0' || 
                    img.dimensions.width === 0 || 
                    img.dimensions.height === 0
                );
                if (invisibleImages.length > 0) {
                    console.log(`     ⚠️  ${invisibleImages.length} potentially invisible images detected`);
                }
            }

            if (container.content.length > 0) {
                const hiddenContent = container.content.filter(content =>
                    content.styles.visibility === 'hidden' || 
                    content.styles.opacity === '0'
                );
                if (hiddenContent.length > 0) {
                    console.log(`     ⚠️  ${hiddenContent.length} potentially hidden content elements detected`);
                }
            }
        });

        // Image analysis summary
        const totalImages = analysis.containers.reduce((sum, container) => sum + container.images.length, 0);
        if (totalImages > 0) {
            console.log('\n🖼️ Image Analysis Summary:');
            console.log(`   Total images analyzed: ${totalImages}`);
            
            let objectFitTypes = {};
            let visibilityIssues = 0;
            let sizeIssues = 0;

            analysis.containers.forEach(container => {
                container.images.forEach(img => {
                    // Object fit analysis
                    const objectFit = img.styles.objectFit || 'initial';
                    objectFitTypes[objectFit] = (objectFitTypes[objectFit] || 0) + 1;
                    
                    // Visibility issues
                    if (img.styles.visibility === 'hidden' || img.styles.opacity === '0') {
                        visibilityIssues++;
                    }
                    
                    // Size issues
                    if (img.dimensions.width === 0 || img.dimensions.height === 0) {
                        sizeIssues++;
                    }
                });
            });

            console.log(`   Object-fit usage:`, Object.entries(objectFitTypes).map(([type, count]) => `${type}: ${count}`).join(', '));
            if (visibilityIssues > 0) {
                console.log(`   ⚠️  Visibility issues: ${visibilityIssues} images`);
            }
            if (sizeIssues > 0) {
                console.log(`   ⚠️  Size issues: ${sizeIssues} images (0x0 dimensions)`);
            }
        }

        console.log('\n📈 Analysis Complete!');
        console.log('💡 Next Steps:');
        console.log('   1. Review JSON output for detailed CSS property data');
        console.log('   2. Compare with mobile WebView behavior');
        console.log('   3. Implement targeted CSS fixes based on differences');
        console.log('   4. Test iteratively and refine as needed');
        console.log('='.repeat(80));
    }
}

// Usage examples and CLI interface
if (require.main === module) {
    // CUSTOMIZE THESE SETTINGS FOR YOUR INVESTIGATION
    const customConfig = {
        // Target page to analyze
        targetUrl: 'https://oldschool.runescape.wiki/w/Coins',
        
        // Focus on specific elements
        containerSelector: 'table.products-list',  // Change to your target containers
        contentSelector: 'td, th',                 // Change to your content elements  
        imageSelector: '.inventory-image img',     // Change to your image elements
        
        // Analysis depth
        analysisDepth: 50,
        
        // Custom viewport (optional)
        // viewport: { width: 414, height: 896, deviceScaleFactor: 2 }, // iPhone 11 Pro Max
    };

    const analyzer = new CSSRenderingAnalyzer(customConfig);
    analyzer.run().catch(error => {
        console.error('❌ Analysis failed:', error.message);
        process.exit(1);
    });
}

module.exports = CSSRenderingAnalyzer;