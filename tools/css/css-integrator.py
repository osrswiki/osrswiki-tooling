#!/usr/bin/env python3
"""
CSS Integration Tool
Automatically integrates generated CSS into appropriate modular CSS files.
"""

import os
import re
import subprocess
import sys
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Tuple


class CSSIntegrator:
    """Integrates generated CSS into modular CSS files."""
    
    def __init__(self, styles_dir: str = "app/src/main/assets/styles"):
        self.styles_dir = Path(styles_dir)
        self.modules_dir = self.styles_dir / "modules"
        self.generated_css_file = "tools/css/output/generated_missing_css.css"
        
        # Module categories for automatic integration (matching css-generator.py)
        self.module_categories = {
            "tables": ["wikitable", "table-", "droptable"],
            "forms": ["input", "button", "form", "fieldset", "textarea", "cdx-"],
            "messagebox": ["messagebox", "errorbox", "warningbox", "successbox"],
            "media": ["thumb", "img", "gallery", "filehistory", "mw-mmv"],
            "navigation": ["navbox", "nav-", "menu", "tabbernav"],
            "layout": ["container", "content", "mw-body", "tile"],
            "gaming": ["quest", "skill", "combat", "item-", "infobox-room"],
            "mediawiki": ["mw-", "smw-", "diff-", "echo-"],
            "interactive": [":hover", ":focus", ":active", "ooui-"],
            "typography": ["h1", "h2", "h3", "h4", "h5", "h6", "font-", "text-"]
        }
        
        # Default module for unmatched selectors
        self.default_module = "other"
    
    def log(self, message: str):
        """Log a message with timestamp."""
        timestamp = datetime.now().strftime("%H:%M:%S")
        print(f"[{timestamp}] {message}")
    
    def determine_module(self, selector: str) -> str:
        """Determine which module a selector belongs to."""
        selector_lower = selector.lower()
        
        # Check each module's patterns
        for module, patterns in self.module_categories.items():
            for pattern in patterns:
                if pattern.lower() in selector_lower:
                    return module
        
        return self.default_module
    
    def parse_css_file(self, css_file: str) -> Dict[str, List[str]]:
        """Parse CSS file and group rules by target module."""
        if not os.path.exists(css_file):
            self.log(f"❌ Generated CSS file not found: {css_file}")
            return {}
        
        modules_css = {}
        current_rule = []
        current_selector = ""
        
        with open(css_file, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        
        for line in lines:
            line = line.rstrip()
            
            # Skip comments and empty lines
            if line.startswith('/*') or line.startswith(' *') or not line.strip():
                continue
            
            # Start of CSS rule
            if line and not line.startswith('    ') and '{' in line:
                # Process previous rule if exists
                if current_rule and current_selector:
                    module = self.determine_module(current_selector)
                    if module not in modules_css:
                        modules_css[module] = []
                    modules_css[module].extend(current_rule)
                    modules_css[module].append("")  # Add spacing
                
                # Start new rule
                current_selector = line.split('{')[0].strip()
                current_rule = [line]
            
            # Continuation of CSS rule
            elif current_rule:
                current_rule.append(line)
                
                # End of CSS rule
                if line == '}':
                    # Process completed rule
                    if current_selector:
                        module = self.determine_module(current_selector)
                        if module not in modules_css:
                            modules_css[module] = []
                        modules_css[module].extend(current_rule)
                        modules_css[module].append("")  # Add spacing
                    
                    # Reset for next rule
                    current_rule = []
                    current_selector = ""
        
        return modules_css
    
    def append_to_module(self, module: str, css_lines: List[str]) -> bool:
        """Append CSS lines to a module file."""
        module_file = self.modules_dir / f"{module}.css"
        
        if not module_file.exists():
            self.log(f"⚠️  Module file doesn't exist, creating: {module_file}")
            module_file.touch()
        
        try:
            # Add header comment
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            header = [
                f"",
                f"/* Auto-integrated CSS - {timestamp} */",
                ""
            ]
            
            # Write to module file
            with open(module_file, 'a', encoding='utf-8') as f:
                f.write('\n'.join(header + css_lines))
            
            self.log(f"✅ Added {len([l for l in css_lines if l.strip()])} lines to {module}.css")
            return True
            
        except Exception as e:
            self.log(f"❌ Error writing to {module_file}: {e}")
            return False
    
    def integrate_css(self, generated_css_file: str = None) -> bool:
        """Integrate generated CSS into modular files."""
        css_file = generated_css_file or self.generated_css_file
        
        self.log(f"🔄 Parsing generated CSS: {css_file}")
        modules_css = self.parse_css_file(css_file)
        
        if not modules_css:
            self.log("❌ No CSS rules found to integrate")
            return False
        
        # Integrate CSS into each module
        success_count = 0
        for module, css_lines in modules_css.items():
            if self.append_to_module(module, css_lines):
                success_count += 1
        
        self.log(f"✅ Successfully integrated CSS into {success_count} modules")
        return success_count > 0
    
    def rebuild_main_css(self) -> bool:
        """Rebuild the main CSS file from modules."""
        try:
            self.log("🔧 Rebuilding main CSS file...")
            result = subprocess.run([
                "python3", "tools/css/css-build.py"
            ], capture_output=True, text=True, cwd=".")
            
            if result.returncode == 0:
                self.log("✅ CSS build completed successfully")
                return True
            else:
                self.log(f"❌ CSS build failed: {result.stderr}")
                return False
                
        except Exception as e:
            self.log(f"❌ Error running CSS build: {e}")
            return False
    
    def run_integration_workflow(self, generated_css_file: str = None, rebuild: bool = True) -> bool:
        """Run the complete integration workflow."""
        self.log("=== Starting CSS Integration Workflow ===")
        
        # Step 1: Integrate CSS into modules
        if not self.integrate_css(generated_css_file):
            self.log("❌ CSS integration failed")
            return False
        
        # Step 2: Rebuild main CSS (optional)
        if rebuild:
            if not self.rebuild_main_css():
                self.log("❌ CSS rebuild failed")
                return False
        
        self.log("=== CSS Integration Complete ===")
        self.log("📄 Check the updated module files in app/src/main/assets/styles/modules/")
        
        if rebuild:
            self.log("📄 Main CSS file updated: app/src/main/assets/styles/wiki-integration.css")
            self.log("🚀 Ready to build the app: ./gradlew assembleDebug")
        else:
            self.log("⚠️  Remember to rebuild CSS: python3 tools/css/css-build.py")
        
        return True
    
    def preview_integration(self, generated_css_file: str = None) -> str:
        """Preview what would be integrated without making changes."""
        css_file = generated_css_file or self.generated_css_file
        modules_css = self.parse_css_file(css_file)
        
        if not modules_css:
            return "❌ No CSS rules found to integrate"
        
        preview = ["=== CSS Integration Preview ===\n"]
        
        for module, css_lines in modules_css.items():
            rule_count = len([l for l in css_lines if l.strip() and not l.startswith('/*')])
            preview.append(f"{module.upper()}: {rule_count} CSS rules")
        
        total_rules = sum(len([l for l in css_lines if l.strip() and not l.startswith('/*')]) 
                         for css_lines in modules_css.values())
        preview.append(f"\nTotal CSS rules to integrate: {total_rules}")
        
        return "\n".join(preview)


def main():
    """Main entry point."""
    import argparse
    
    parser = argparse.ArgumentParser(description="Integrate generated CSS into modules")
    parser.add_argument("--preview", action="store_true", 
                       help="Preview integration without making changes")
    parser.add_argument("--no-rebuild", action="store_true",
                       help="Skip rebuilding main CSS file")
    parser.add_argument("--generated-css", 
                       help="Path to generated CSS file")
    
    args = parser.parse_args()
    
    integrator = CSSIntegrator()
    
    if args.preview:
        print("🔍 CSS Integration Preview:")
        print(integrator.preview_integration(args.generated_css))
        return
    
    if not os.path.exists(integrator.generated_css_file) and not args.generated_css:
        print(f"❌ Generated CSS file not found: {integrator.generated_css_file}")
        print("Run 'python3 tools/css/css-generator.py' first to generate CSS.")
        sys.exit(1)
    
    print("🚀 Starting CSS integration...")
    
    if integrator.run_integration_workflow(
        generated_css_file=args.generated_css,
        rebuild=not args.no_rebuild
    ):
        print("\n✅ CSS integration complete!")
    else:
        print("\n❌ CSS integration failed!")
        sys.exit(1)


if __name__ == '__main__':
    main()