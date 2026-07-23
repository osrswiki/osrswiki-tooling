#!/usr/bin/env python3
"""
CSS Extractor
Extracts CSS from monolithic files and organizes them into functional modules.
"""

import re
import os
import json
from typing import Dict, List, Tuple, Set
from pathlib import Path
import argparse
from collections import defaultdict

class CSSExtractor:
    """Extract and categorize CSS selectors into functional modules."""
    
    def __init__(self):
        self.categories = {
            "base": {
                "patterns": ["@media", ":root", "body", "html", "*", "::placeholder"],
                "description": "Base styles, resets, and global rules"
            },
            "typography": {
                "patterns": ["h1", "h2", "h3", "h4", "h5", "h6", "font-", "text-", ".mw-heading"],
                "description": "Heading and text styling"
            },
            "tables": {
                "patterns": [".wikitable", ".table-", ".droptable", "table", "td", "th", "tr"],
                "description": "Table styling including wikitables and drop tables"
            },
            "forms": {
                "patterns": ["input", "button", "form", "fieldset", "textarea", ".cdx-", "select"],
                "description": "Form controls and input elements"
            },
            "messagebox": {
                "patterns": [".messagebox", ".errorbox", ".warningbox", ".successbox", ".mw-message"],
                "description": "Message boxes and notifications"
            },
            "media": {
                "patterns": [".thumb", "img", ".gallery", ".filehistory", ".mw-mmv", ".extimage"],
                "description": "Images, galleries, and media handling"
            },
            "navigation": {
                "patterns": [".navbox", ".nav-", "menu", ".tabbernav", ".mw-rcfilters"],
                "description": "Navigation elements and menus"
            },
            "layout": {
                "patterns": [".container", ".content", ".mw-body", ".main", ".tile", ".column"],
                "description": "Page layout and structure"
            },
            "gaming": {
                "patterns": [".quest", ".skill", ".combat", ".item-", ".droptable", ".infobox-room"],
                "description": "OSRS gaming-specific UI elements"
            },
            "mediawiki": {
                "patterns": [".mw-", ".smw-", ".diff-", ".echo-", "mw-content"],
                "description": "MediaWiki and Semantic MediaWiki components"
            },
            "interactive": {
                "patterns": [":hover", ":focus", ":active", ":checked", ".ooui-", "transition"],
                "description": "Interactive states and OOUI components"
            }
        }
        
    def normalize_selector(self, selector: str) -> str:
        """Normalize a CSS selector."""
        return ' '.join(selector.strip().split())
    
    def categorize_selector(self, selector: str) -> str:
        """Categorize a selector based on patterns."""
        selector_lower = selector.lower()
        
        # Check each category's patterns
        for category, info in self.categories.items():
            for pattern in info["patterns"]:
                if pattern.lower() in selector_lower:
                    return category
                    
        # Default category for uncategorized selectors
        return "other"
    
    def parse_css_file(self, file_path: Path) -> List[Tuple[str, str, List[str]]]:
        """Parse CSS file and extract rules with their categories.
        
        Returns: List of (selector, category, css_lines)
        """
        rules = []
        
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                content = f.read()
        except Exception as e:
            print(f"Error reading {file_path}: {e}")
            return rules
            
        # Remove comments but preserve structure
        content = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group(0).count('\n'), content, flags=re.DOTALL)
        
        # Split into lines for processing
        lines = content.split('\n')
        current_rule = []
        current_selector = ""
        brace_count = 0
        
        for line in lines:
            line = line.rstrip()
            
            # Track braces
            open_braces = line.count('{')
            close_braces = line.count('}')
            
            if brace_count == 0 and open_braces > 0:
                # Start of new rule
                selector_line = line.split('{')[0].strip()
                if current_selector:
                    current_selector += " " + selector_line
                else:
                    current_selector = selector_line
                    
                current_rule = [line]
                brace_count = open_braces - close_braces
                
                if brace_count == 0:
                    # Single-line rule
                    if current_selector.strip():
                        category = self.categorize_selector(current_selector)
                        rules.append((self.normalize_selector(current_selector), category, current_rule.copy()))
                    current_selector = ""
                    current_rule = []
                    
            elif brace_count == 0 and not line.strip():
                # Empty line outside of rules
                continue
                
            elif brace_count == 0:
                # Continuing selector (multi-line)
                if current_selector:
                    current_selector += " " + line.strip()
                else:
                    current_selector = line.strip()
                    
            else:
                # Inside a rule
                current_rule.append(line)
                brace_count += open_braces - close_braces
                
                if brace_count <= 0:
                    # End of rule
                    if current_selector.strip():
                        category = self.categorize_selector(current_selector)
                        rules.append((self.normalize_selector(current_selector), category, current_rule.copy()))
                    current_selector = ""
                    current_rule = []
                    brace_count = 0
        
        return rules
    
    def extract_to_modules(self, input_file: str, output_dir: str):
        """Extract CSS from input file into modular files."""
        input_path = Path(input_file)
        output_path = Path(output_dir)
        
        if not input_path.exists():
            print(f"Input file not found: {input_file}")
            return
            
        # Create output directory
        output_path.mkdir(parents=True, exist_ok=True)
        
        print(f"Extracting CSS from: {input_file}")
        rules = self.parse_css_file(input_path)
        
        # Group rules by category
        categorized_rules = defaultdict(list)
        for selector, category, css_lines in rules:
            categorized_rules[category].append((selector, css_lines))
            
        # Generate module files
        stats = {}
        for category, rules_list in categorized_rules.items():
            if category == "other":
                continue  # Handle "other" separately
                
            module_file = output_path / f"{category}.css"
            stats[category] = len(rules_list)
            
            with open(module_file, 'w') as f:
                f.write(f"/*\n * {category.upper()} MODULE\n")
                f.write(f" * {self.categories.get(category, {}).get('description', 'CSS rules')}\n")
                f.write(f" * Generated from: {input_file}\n")
                f.write(f" * Rules: {len(rules_list)}\n */\n\n")
                
                for selector, css_lines in rules_list:
                    f.write('\n'.join(css_lines))
                    f.write('\n\n')
            
            print(f"Created: {module_file} ({len(rules_list)} rules)")
        
        # Handle "other" category
        if "other" in categorized_rules:
            other_file = output_path / "other.css"
            other_rules = categorized_rules["other"]
            stats["other"] = len(other_rules)
            
            with open(other_file, 'w') as f:
                f.write("/*\n * OTHER MODULE\n")
                f.write(" * Uncategorized CSS rules that didn't match specific patterns\n")
                f.write(f" * Generated from: {input_file}\n")
                f.write(f" * Rules: {len(other_rules)}\n */\n\n")
                
                for selector, css_lines in other_rules:
                    f.write('\n'.join(css_lines))
                    f.write('\n\n')
            
            print(f"Created: {other_file} ({len(other_rules)} rules)")
        
        # Generate extraction report
        report = {
            "extraction_date": __import__('datetime').datetime.now().isoformat(),
            "input_file": str(input_file),
            "output_directory": str(output_dir),
            "total_rules_extracted": sum(stats.values()),
            "modules_created": len(stats),
            "module_stats": stats,
            "categories": {k: v["description"] for k, v in self.categories.items()}
        }
        
        report_file = output_path / "extraction_report.json"
        with open(report_file, 'w') as f:
            json.dump(report, f, indent=2)
            
        print(f"\n=== EXTRACTION SUMMARY ===")
        print(f"Total rules extracted: {sum(stats.values())}")
        print(f"Modules created: {len(stats)}")
        print(f"Report saved: {report_file}")
        
        # Show module distribution
        print("\nModule distribution:")
        for category, count in sorted(stats.items(), key=lambda x: x[1], reverse=True):
            percentage = round(count / sum(stats.values()) * 100, 1)
            print(f"  {category}: {count} rules ({percentage}%)")
    
    def create_build_order(self, modules_dir: str) -> List[str]:
        """Create a recommended build order for CSS modules."""
        # Recommended load order (most specific to least specific)
        recommended_order = [
            "base.css",        # Base styles first
            "typography.css",  # Typography foundation
            "layout.css",      # Layout structure
            "tables.css",      # Table styling
            "forms.css",       # Form controls
            "media.css",       # Media elements
            "navigation.css",  # Navigation
            "messagebox.css",  # Message boxes
            "gaming.css",      # Game-specific
            "mediawiki.css",   # MediaWiki components
            "interactive.css", # Interactive states
            "other.css"        # Uncategorized last
        ]
        
        modules_path = Path(modules_dir)
        existing_modules = []
        
        for module in recommended_order:
            module_file = modules_path / module
            if module_file.exists():
                existing_modules.append(module)
                
        return existing_modules

def main():
    parser = argparse.ArgumentParser(description="Extract CSS into functional modules")
    parser.add_argument("input_file", help="Input CSS file to extract from")
    parser.add_argument("--output-dir", default="app/src/main/assets/styles/modules",
                       help="Output directory for extracted modules")
    parser.add_argument("--list-categories", action="store_true",
                       help="List available categories and patterns")
    
    args = parser.parse_args()
    
    extractor = CSSExtractor()
    
    if args.list_categories:
        print("=== AVAILABLE CATEGORIES ===")
        for category, info in extractor.categories.items():
            print(f"\n{category.upper()}:")
            print(f"  Description: {info['description']}")
            print(f"  Patterns: {', '.join(info['patterns'])}")
        return
    
    # Extract CSS into modules
    extractor.extract_to_modules(args.input_file, args.output_dir)
    
    # Create build order
    build_order = extractor.create_build_order(args.output_dir)
    if build_order:
        print(f"\nRecommended CSS load order:")
        for i, module in enumerate(build_order, 1):
            print(f"  {i}. {module}")

if __name__ == "__main__":
    main()