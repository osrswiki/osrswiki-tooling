#!/usr/bin/env python3
"""
Initialize Masterlists from Existing Data

Creates initial masterlists from historical discovery data:
- Uses legacy discovery files for discovered modules (if available)
- Uses WikiModuleRegistry.kt for implemented modules
- Creates initial unimplemented modules list
"""

import json
import logging
import re
import sys
from datetime import datetime
from pathlib import Path

# Add the tools directory to Python path
tools_dir = Path(__file__).parent.parent
sys.path.insert(0, str(tools_dir))

from core.masterlist_manager import MasterlistManager

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class MasterlistInitializer:
    """Initialize masterlists from existing data sources"""
    
    def __init__(self):
        self.manager = MasterlistManager()
        self.tools_js_dir = tools_dir / "js"
        self.android_dir = tools_dir.parent / "platforms" / "android"
    
    def initialize_from_existing_data(self):
        """Initialize all masterlists from existing data"""
        logger.info("Initializing masterlists from existing data")
        
        # 1. Initialize discovered modules from logs_real_wiki_analysis.json
        self._initialize_discovered_modules()
        
        # 2. Initialize implemented modules from WikiModuleRegistry.kt
        self._initialize_implemented_modules()
        
        # 3. Update unimplemented priorities
        self.manager.update_unimplemented_priorities()
        
        # 4. Validate and save
        self.manager.validate_no_cross_duplicates()
        self.manager.save_all_masterlists()
        
        # 5. Print summary
        self._print_initialization_summary()
    
    def _initialize_discovered_modules(self):
        """Initialize discovered modules from existing JSON files"""
        logger.info("Initializing discovered modules from existing data")
        
        # Try different source files
        source_files = [
            "logs_real_wiki_analysis.json",
            "logs_loading_plan_v2.json",
            "startup_registry_v3.json"
        ]
        
        modules_found = set()
        
        for filename in source_files:
            file_path = self.tools_js_dir / filename
            if not file_path.exists():
                logger.warning(f"Source file not found: {file_path}")
                continue
            
            logger.info(f"Processing {filename}")
            
            try:
                with open(file_path, 'r') as f:
                    data = json.load(f)
                
                # Extract modules based on file structure
                if filename == "logs_real_wiki_analysis.json":
                    page_modules = data.get('page_modules', [])
                    for module in page_modules:
                        modules_found.add(module)
                        context = {
                            'page': 'unknown_historical',
                            'type': self._classify_module_type(module),
                            'dependencies': []
                        }
                        self.manager.add_discovered_module(module, context)
                
                elif filename == "logs_loading_plan_v2.json":
                    all_modules = data.get('all_required_modules', [])
                    for module in all_modules:
                        if module not in modules_found:
                            modules_found.add(module)
                            context = {
                                'page': 'loading_plan_analysis',
                                'type': self._classify_module_type(module),
                                'dependencies': []
                            }
                            self.manager.add_discovered_module(module, context)
                
                elif filename.startswith("startup_registry"):
                    registry = data.get('registry', {})
                    for module_name in registry.keys():
                        if module_name not in modules_found:
                            modules_found.add(module_name)
                            context = {
                                'page': 'startup_registry',
                                'type': self._classify_module_type(module_name),
                                'dependencies': registry[module_name].get('dependencies', [])
                            }
                            self.manager.add_discovered_module(module_name, context)
                
            except Exception as e:
                logger.error(f"Error processing {filename}: {e}")
        
        logger.info(f"Initialized {len(modules_found)} discovered modules")
    
    def _initialize_implemented_modules(self):
        """Initialize implemented modules from WikiModuleRegistry.kt and app assets"""
        logger.info("Initializing implemented modules from WikiModuleRegistry.kt")
        
        registry_file = (self.android_dir / "app" / "src" / "main" / "java" / 
                        "com" / "omiyawaki" / "osrswiki" / "page" / "WikiModuleRegistry.kt")
        
        if not registry_file.exists():
            logger.warning(f"WikiModuleRegistry.kt not found at {registry_file}")
            return
        
        try:
            with open(registry_file, 'r') as f:
                content = f.read()
            
            # Parse the modules map
            self._parse_kotlin_modules(content)
            
            # Add app-specific implementations
            self._add_app_specific_implementations()
            
        except Exception as e:
            logger.error(f"Error parsing WikiModuleRegistry.kt: {e}")
    
    def _parse_kotlin_modules(self, content: str):
        """Parse module definitions from Kotlin code"""
        # Look for module definitions in the format:
        # "ext.gadget.GECharts" to ModuleConfig(...)
        
        pattern = r'"([^"]+)"\s+to\s+ModuleConfig\s*\('
        matches = re.findall(pattern, content)
        
        for wiki_module_name in matches:
            # Create implementation name from wiki name
            impl_name = self._wiki_name_to_impl_name(wiki_module_name)
            
            # Find corresponding app files
            app_files = self._find_app_files_for_module(wiki_module_name)
            
            try:
                self.manager.add_implemented_module(
                    impl_name=impl_name,
                    wiki_names=[wiki_module_name],
                    app_files=app_files,
                    implementation_type="curated",
                    functionality=self._get_module_functionality(wiki_module_name)
                )
                logger.info(f"Added implemented module: {impl_name} -> {wiki_module_name}")
            except ValueError as e:
                logger.warning(f"Could not add {impl_name}: {e}")
    
    def _add_app_specific_implementations(self):
        """Add implementations that don't directly map to wiki modules"""
        app_specific = [
            {
                "impl_name": "ge_charts_highcharts",
                "wiki_names": ["ext.gadget.GECharts", "ext.gadget.GECharts-core"],
                "app_files": ["web/ge_charts_init.js", "web/highcharts-stock.js"],
                "functionality": "Grand Exchange price charts with Highcharts"
            },
            {
                "impl_name": "switch_infobox",
                "wiki_names": ["ext.gadget.switch-infobox"],
                "app_files": ["web/switch_infobox.js", "web/infobox_switcher_bootstrap.js"],
                "functionality": "Switchable infobox functionality"
            },
            {
                "impl_name": "collapsible_content",
                "wiki_names": ["jquery.makeCollapsible"],
                "app_files": ["web/collapsible_content.js"],
                "functionality": "Collapsible content sections"
            }
        ]
        
        for impl in app_specific:
            try:
                self.manager.add_implemented_module(**impl)
                logger.info(f"Added app-specific implementation: {impl['impl_name']}")
            except ValueError as e:
                logger.warning(f"Could not add {impl['impl_name']}: {e}")
    
    def _wiki_name_to_impl_name(self, wiki_name: str) -> str:
        """Convert wiki module name to implementation name"""
        # Remove prefixes and convert to snake_case
        name = wiki_name.replace('ext.gadget.', '').replace('ext.', '').replace('mediawiki.', '')
        # Convert PascalCase to snake_case
        name = re.sub('([a-z0-9])([A-Z])', r'\1_\2', name).lower()
        return name
    
    def _find_app_files_for_module(self, wiki_module_name: str) -> list:
        """Find app files related to a wiki module"""
        # Simple mapping based on module name
        module_to_files = {
            'ext.gadget.GECharts': ['web/ge_charts_init.js'],
            'ext.gadget.switch-infobox': ['web/switch_infobox.js'],
            'jquery.makeCollapsible': ['web/collapsible_content.js'],
            'ext.cite.ux-enhancements': ['web/mediawiki/page_modules.js']
        }
        
        return module_to_files.get(wiki_module_name, [])
    
    def _get_module_functionality(self, wiki_module_name: str) -> str:
        """Get functionality description for a module"""
        descriptions = {
            'ext.gadget.GECharts': 'Grand Exchange price charts',
            'ext.gadget.GECharts-core': 'Core functionality for GE charts',
            'ext.gadget.switch-infobox': 'Switchable infobox tabs',
            'ext.cite.ux-enhancements': 'Citation user experience enhancements',
            'jquery.makeCollapsible': 'Collapsible content functionality',
            'ext.Tabber': 'Tabbed interface for content sections'
        }
        
        return descriptions.get(wiki_module_name, f'Functionality for {wiki_module_name}')
    
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
    
    def _print_initialization_summary(self):
        """Print summary of initialization"""
        stats = self.manager.get_stats()
        
        print("\n" + "="*60)
        print("MASTERLIST INITIALIZATION COMPLETE")
        print("="*60)
        print(f"Discovered modules: {stats['discovered']}")
        print(f"Implemented modules: {stats['implemented']}")
        print(f"Unimplemented modules: {stats['unimplemented']}")
        print()
        
        # Show sample discovered modules
        print("Sample discovered modules:")
        discovered_modules = list(self.manager.discovered['modules'].keys())[:10]
        for module in discovered_modules:
            print(f"  - {module}")
        
        print()
        
        # Show implemented modules
        print("Implemented modules:")
        for impl_name, impl_data in self.manager.implemented['modules'].items():
            wiki_names = impl_data.get('wiki_names', [])
            print(f"  - {impl_name}: {', '.join(wiki_names)}")
        
        print("\n" + "="*60)

def main():
    """Main entry point"""
    initializer = MasterlistInitializer()
    initializer.initialize_from_existing_data()

if __name__ == "__main__":
    main()