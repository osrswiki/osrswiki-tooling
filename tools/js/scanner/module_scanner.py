#!/usr/bin/env python3
"""
Enhanced Module Scanner with Accumulative Tracking

Enhanced version of the old page_modules_extractor.py that:
- Uses Playwright to extract RLPAGEMODULES from pages
- Accumulates results across multiple runs (doesn't overwrite)
- Tracks first seen/last seen dates and pages found on
- Supports both mobile and desktop wiki formats
"""

import asyncio
import json
import logging
from pathlib import Path
from typing import Dict, List, Any, Optional, Set
from playwright.async_api import async_playwright

logger = logging.getLogger(__name__)

class ModuleScanner:
    """
    Enhanced module scanner with accumulative discovery tracking.
    """
    
    def __init__(self, base_url: str = "https://oldschool.runescape.wiki"):
        self.base_url = base_url
        self.discovered_modules = {}
        
    async def scan_single_page(self, page_name: str, use_mobile: bool = True, 
                               scan_id: str = None) -> Dict[str, Any]:
        """
        Extract modules from a single wiki page.
        
        Args:
            page_name: Wiki page name (e.g., "Exchange:Abyssal_whip")
            use_mobile: Whether to use mobile format
            scan_id: Optional scan identifier for tracking
            
        Returns:
            Dict with extracted modules and metadata
        """
        # Construct URL
        page_url = f"{self.base_url}/w/{page_name}"
        if use_mobile:
            page_url += "?useformat=mobile"
            
        logger.info(f"Scanning page: {page_url}")
        
        async with async_playwright() as p:
            browser = await p.chromium.launch(headless=True)
            page = await browser.new_page()
            
            try:
                # Navigate to the page and wait for MediaWiki to load
                await page.goto(page_url, wait_until="networkidle", timeout=30000)
                
                # Wait a bit for dynamic loading
                await page.wait_for_timeout(2000)
                
                # Extract page modules and configuration directly from the page
                page_data = await page.evaluate("""
                    () => {
                        const result = {
                            modules: null,
                            config: null,
                            state: null,
                            page_info: {
                                title: null,
                                skin: null,
                                mobile_mode: null,
                                url: window.location.href
                            },
                            extraction_method: 'browser_execution',
                            success: false,
                            error: null
                        };
                        
                        try {
                            // Get page info
                            if (typeof mw !== 'undefined' && mw.config) {
                                result.page_info.title = mw.config.get('wgPageName');
                                result.page_info.skin = mw.config.get('skin');
                                result.page_info.mobile_mode = mw.config.get('wgMFMode');
                            }
                            
                            // Get RLPAGEMODULES
                            if (typeof RLPAGEMODULES !== 'undefined') {
                                result.modules = RLPAGEMODULES;
                                result.success = true;
                            } else {
                                result.error = 'RLPAGEMODULES not found';
                            }
                            
                            // Get RLCONF
                            if (typeof RLCONF !== 'undefined') {
                                result.config = RLCONF;
                            }
                            
                            // Get RLSTATE 
                            if (typeof RLSTATE !== 'undefined') {
                                result.state = RLSTATE;
                            }
                            
                        } catch (e) {
                            result.error = e.message;
                        }
                        
                        return result;
                    }
                """)
                
                if not page_data['success']:
                    logger.warning(f"Failed to extract modules from {page_name}: {page_data.get('error', 'Unknown error')}")
                    return {
                        "page_name": page_name,
                        "page_url": page_url,
                        "mobile_page": use_mobile,
                        "scan_id": scan_id,
                        "success": False,
                        "error": page_data.get('error', 'Unknown error'),
                        "modules": []
                    }
                
                modules = page_data.get('modules', [])
                logger.info(f"Extracted {len(modules)} modules from {page_name}")
                
                return {
                    "page_name": page_name,
                    "page_url": page_url,
                    "mobile_page": use_mobile,
                    "scan_id": scan_id,
                    "success": True,
                    "modules": modules,
                    "page_modules": page_data.get('modules'),
                    "page_config": page_data.get('config'),
                    "page_state": page_data.get('state'),
                    "page_info": page_data.get('page_info'),
                    "extraction_method": page_data.get('extraction_method')
                }
                
            except Exception as e:
                logger.error(f"Error scanning {page_name}: {str(e)}")
                return {
                    "page_name": page_name,
                    "page_url": page_url,
                    "mobile_page": use_mobile,
                    "scan_id": scan_id,
                    "success": False,
                    "error": str(e),
                    "modules": []
                }
            finally:
                await browser.close()
    
    async def scan_multiple_pages(self, page_names: List[str], use_mobile: bool = True,
                                  scan_id: str = None) -> List[Dict[str, Any]]:
        """
        Scan multiple pages for modules.
        
        Args:
            page_names: List of wiki page names to scan
            use_mobile: Whether to use mobile format
            scan_id: Optional scan identifier for tracking
            
        Returns:
            List of scan results
        """
        results = []
        
        logger.info(f"Starting scan of {len(page_names)} pages (scan_id: {scan_id})")
        
        for i, page_name in enumerate(page_names):
            logger.info(f"Scanning page {i+1}/{len(page_names)}: {page_name}")
            
            try:
                result = await self.scan_single_page(page_name, use_mobile, scan_id)
                results.append(result)
                
                # Small delay between requests to be nice to the server
                await asyncio.sleep(1)
                
            except Exception as e:
                logger.error(f"Failed to scan {page_name}: {str(e)}")
                results.append({
                    "page_name": page_name,
                    "success": False,
                    "error": str(e),
                    "modules": []
                })
        
        successful_scans = sum(1 for r in results if r.get('success', False))
        logger.info(f"Scan complete: {successful_scans}/{len(page_names)} pages successful")
        
        return results
    
    def extract_unique_modules(self, scan_results: List[Dict[str, Any]]) -> Dict[str, Set[str]]:
        """
        Extract unique modules and the pages they were found on.
        
        Args:
            scan_results: List of scan results from scan_multiple_pages
            
        Returns:
            Dict mapping module names to set of pages they were found on
        """
        module_to_pages = {}
        
        for result in scan_results:
            if not result.get('success', False):
                continue
                
            page_name = result.get('page_name', 'unknown')
            modules = result.get('modules', [])
            
            for module in modules:
                if module not in module_to_pages:
                    module_to_pages[module] = set()
                module_to_pages[module].add(page_name)
        
        return module_to_pages
    
    def get_sample_pages(self) -> List[str]:
        """
        Get a sample list of pages for testing/regular scanning.
        
        Returns:
            List of wiki page names representing different content types
        """
        return [
            "Exchange:Abyssal_whip",  # Item exchange page (GECharts)
            "Attack",  # Skill page (general modules)
            "Barrows",  # Guide page (multiple gadgets)
            "Giant_Mole",  # Monster page
            "Dragon_scimitar",  # Item page
            "Wintertodt",  # Activity page
            "Calculator:Smithing",  # Calculator page
            "Combat",  # Combat guide
            "Grand_Exchange",  # Main GE page
            "Ironman_Mode"  # Game mode page
        ]
    
    async def run_sample_scan(self, scan_id: str = None) -> Dict[str, Any]:
        """
        Run a scan on sample pages for testing.
        
        Args:
            scan_id: Optional scan identifier
            
        Returns:
            Summary of scan results
        """
        if scan_id is None:
            from datetime import datetime
            scan_id = f"sample_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
        
        sample_pages = self.get_sample_pages()
        results = await self.scan_multiple_pages(sample_pages, scan_id=scan_id)
        
        module_to_pages = self.extract_unique_modules(results)
        
        return {
            "scan_id": scan_id,
            "pages_scanned": len(sample_pages),
            "successful_scans": sum(1 for r in results if r.get('success', False)),
            "unique_modules_found": len(module_to_pages),
            "modules": dict(module_to_pages),  # Convert sets to lists for JSON
            "detailed_results": results
        }