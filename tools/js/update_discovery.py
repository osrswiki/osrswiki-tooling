#!/usr/bin/env python3
"""
Main Discovery Orchestrator

Coordinates the entire JS module discovery process:
1. Loads existing masterlists
2. Runs module discovery on sample/specified pages
3. Updates masterlists with deduplication
4. Updates priorities for unimplemented modules
5. Validates data integrity
6. Saves updated masterlists
7. Generates summary report
"""

import asyncio
import logging
import sys
from datetime import datetime
from pathlib import Path
from typing import List, Optional

# Add the tools directory to Python path
tools_dir = Path(__file__).parent.parent
sys.path.insert(0, str(tools_dir))

from core.masterlist_manager import MasterlistManager
from scanner.module_scanner import ModuleScanner

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(Path(__file__).parent / 'discovery.log')
    ]
)

logger = logging.getLogger(__name__)

class DiscoveryOrchestrator:
    """
    Main orchestrator for JS module discovery and tracking.
    """
    
    def __init__(self, masterlists_dir: str = None):
        self.manager = MasterlistManager(masterlists_dir)
        self.scanner = ModuleScanner()
    
    async def run_discovery(self, pages: List[str] = None, scan_id: str = None) -> dict:
        """
        Run the complete discovery process.
        
        Args:
            pages: List of pages to scan (uses sample if None)
            scan_id: Scan identifier (auto-generated if None)
            
        Returns:
            Summary of discovery results
        """
        if scan_id is None:
            scan_id = f"discovery_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
        
        logger.info(f"Starting discovery process (scan_id: {scan_id})")
        
        # 1. Get initial stats
        initial_stats = self.manager.get_stats()
        logger.info(f"Initial state: {initial_stats}")
        
        # 2. Run module discovery
        if pages is None:
            logger.info("Using sample pages for discovery")
            scan_results = await self.scanner.run_sample_scan(scan_id)
        else:
            logger.info(f"Scanning {len(pages)} specified pages")
            results = await self.scanner.scan_multiple_pages(pages, scan_id=scan_id)
            scan_results = {
                "scan_id": scan_id,
                "pages_scanned": len(pages),
                "successful_scans": sum(1 for r in results if r.get('success', False)),
                "modules": self.scanner.extract_unique_modules(results),
                "detailed_results": results
            }
        
        # 3. Update discovered modules masterlist
        modules_found = scan_results.get('modules', {})
        logger.info(f"Processing {len(modules_found)} unique modules")
        
        for module_name, pages_found_on in modules_found.items():
            # For each page the module was found on
            for page in pages_found_on:
                context = {
                    'page': page,
                    'scan_id': scan_id,
                    'type': self._classify_module_type(module_name),
                    'dependencies': []  # TODO: Extract dependencies
                }
                self.manager.add_discovered_module(module_name, context)
        
        # 4. Update unimplemented priorities
        logger.info("Updating unimplemented module priorities")
        self.manager.update_unimplemented_priorities()
        
        # 5. Validate data integrity
        logger.info("Validating data integrity")
        try:
            self.manager.validate_no_cross_duplicates()
            logger.info("Validation passed")
        except ValueError as e:
            logger.warning(f"Validation warning: {e}")
        
        # 6. Save updated masterlists
        logger.info("Saving updated masterlists")
        self.manager.save_all_masterlists()
        
        # 7. Get final stats
        final_stats = self.manager.get_stats()
        logger.info(f"Final state: {final_stats}")
        
        # 8. Generate summary
        summary = {
            "scan_id": scan_id,
            "timestamp": datetime.now().isoformat(),
            "pages_scanned": scan_results.get('pages_scanned', 0),
            "successful_scans": scan_results.get('successful_scans', 0),
            "modules_processed": len(modules_found),
            "new_modules_discovered": final_stats['discovered'] - initial_stats['discovered'],
            "initial_stats": initial_stats,
            "final_stats": final_stats,
            "top_unimplemented": self._get_top_unimplemented(5)
        }
        
        logger.info("Discovery process complete")
        logger.info(f"Summary: {summary}")
        
        return summary
    
    def _classify_module_type(self, module_name: str) -> str:
        """Classify module type based on name"""
        if module_name.startswith('ext.gadget.'):
            return 'gadget'
        elif module_name.startswith('ext.'):
            return 'extension'
        elif module_name.startswith('mediawiki.'):
            return 'mediawiki'
        elif module_name.startswith('jquery.'):
            return 'jquery'
        elif module_name.startswith('skins.'):
            return 'skin'
        else:
            return 'other'
    
    def _get_top_unimplemented(self, limit: int = 5) -> List[dict]:
        """Get top unimplemented modules by priority score"""
        unimplemented = self.manager.unimplemented['modules']
        
        # Sort by priority score
        sorted_modules = sorted(
            unimplemented.items(),
            key=lambda x: x[1].get('priority_score', 0),
            reverse=True
        )
        
        return [
            {
                "module_name": name,
                "priority_score": data.get('priority_score', 0),
                "frequency_seen": data.get('frequency_seen', 0),
                "pages_count": data.get('pages_count', 0),
                "complexity": data.get('complexity', 'unknown')
            }
            for name, data in sorted_modules[:limit]
        ]
    
    def print_summary_report(self) -> None:
        """Print a formatted summary report"""
        stats = self.manager.get_stats()
        
        print("\n" + "="*60)
        print("JS MODULE DISCOVERY SUMMARY")
        print("="*60)
        print(f"Discovered modules: {stats['discovered']}")
        print(f"Implemented modules: {stats['implemented']}")
        print(f"Unimplemented modules: {stats['unimplemented']}")
        print(f"Total scans run: {stats['total_scans']}")
        print(f"Last scan: {stats['last_scan']}")
        
        # Show top unimplemented
        print(f"\nTOP UNIMPLEMENTED MODULES:")
        print("-" * 40)
        top_unimplemented = self._get_top_unimplemented(10)
        
        for i, module in enumerate(top_unimplemented, 1):
            print(f"{i:2d}. {module['module_name']}")
            print(f"    Priority: {module['priority_score']}, "
                  f"Frequency: {module['frequency_seen']}, "
                  f"Pages: {module['pages_count']}, "
                  f"Complexity: {module['complexity']}")
        
        print("\n" + "="*60)

async def main():
    """Main entry point"""
    import argparse
    
    parser = argparse.ArgumentParser(description="JS Module Discovery Orchestrator")
    parser.add_argument('--pages', nargs='+', help='Specific pages to scan')
    parser.add_argument('--scan-id', help='Scan identifier')
    parser.add_argument('--summary-only', action='store_true', help='Only show summary report')
    parser.add_argument('--masterlists-dir', help='Directory for masterlists')
    
    args = parser.parse_args()
    
    orchestrator = DiscoveryOrchestrator(args.masterlists_dir)
    
    if args.summary_only:
        orchestrator.print_summary_report()
        return
    
    # Run discovery
    summary = await orchestrator.run_discovery(args.pages, args.scan_id)
    
    # Print summary
    orchestrator.print_summary_report()
    
    return summary

if __name__ == "__main__":
    asyncio.run(main())