#!/usr/bin/env python3
"""
CSS Gap Analyzer - Detailed analysis of missing selectors
Helps categorize and review which selectors should be included vs skipped
"""

import json
import re
from collections import defaultdict, Counter
from typing import Dict, List, Tuple


class CSSGapAnalyzer:
    """Analyze CSS gaps in detail to guide automation improvements."""
    
    def __init__(self, analysis_file: str = "tools/css/output/css_gap_analysis.json"):
        self.analysis_file = analysis_file
        
        # Current skip patterns from css-generator.py
        self.skip_patterns = [
            r'a\[href="/w/User:[^"]+"\]',  # All user-specific links
            r'#mw-(page-base|head-base)',  # MediaWiki admin base elements
            r'\.mw-echo-ui-',    # Echo notifications UI
            r'#ca-(nstab|talk|edit|history)', # Content action tabs
            r'#p-(personal|lang|views|actions)', # Portlets
            r'\.vector-menu',    # Vector skin menus
            r'\.citizen-drawer', # Citizen skin drawer
            r'@media.*print',    # Print media queries
            r'@media.*screen.*max-width.*(480|600)px', # Very small mobile queries
            r'\.minerva-header', # Minerva mobile skin header
            r'#mw-history-compare', # History comparison (admin feature)
        ]
    
    def should_skip_selector(self, selector: str) -> Tuple[bool, str]:
        """Check if selector should be skipped and return reason."""
        for pattern in self.skip_patterns:
            if re.search(pattern, selector):
                return True, f"matches pattern: {pattern}"
        return False, ""
    
    def categorize_selector(self, selector: str) -> str:
        """Categorize selector by its likely purpose."""
        selector_lower = selector.lower()
        
        # User/Bot related
        if 'user:' in selector_lower or 'bot' in selector_lower:
            return "user/bot"
        
        # Admin interface
        if any(x in selector_lower for x in ['#mw-', '#ca-', '#p-', '.mw-echo', '.vector-', '.citizen-']):
            return "admin-interface"
        
        # Content styling
        if any(x in selector_lower for x in ['wikitable', 'messagebox', 'infobox', '.content']):
            return "content-styling"
        
        # Gaming specific
        if any(x in selector_lower for x in ['skill', 'quest', 'combat', 'item-', 'coins']):
            return "gaming"
        
        # Layout/UI
        if any(x in selector_lower for x in ['tile', 'container', 'header', 'footer', 'nav']):
            return "layout"
        
        # Interactive
        if any(x in selector_lower for x in [':hover', ':focus', ':active', 'button', 'input']):
            return "interactive"
        
        # Media/images
        if any(x in selector_lower for x in ['img', 'image', 'gallery', 'thumb']):
            return "media"
        
        # Typography
        if any(x in selector_lower for x in ['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'font']):
            return "typography"
        
        # Charts/graphs
        if any(x in selector_lower for x in ['chart', 'highcharts', 'graph']):
            return "charts"
        
        return "uncategorized"
    
    def analyze_missing_selectors(self) -> Dict:
        """Analyze all missing selectors in detail."""
        with open(self.analysis_file, 'r') as f:
            data = json.load(f)
        
        results = {
            "summary": {
                "total_missing": 0,
                "total_skipped": 0,
                "total_should_include": 0,
            },
            "by_category": defaultdict(lambda: {
                "total": 0,
                "skipped": 0,
                "should_include": 0,
                "examples": []
            }),
            "by_purpose": defaultdict(lambda: {
                "total": 0,
                "skipped": 0,
                "should_include": 0,
                "examples": []
            }),
            "recommendations": []
        }
        
        # Analyze missing selectors
        for category, selectors in data.get('missing_selectors', {}).items():
            for selector, properties in selectors.items():
                results["summary"]["total_missing"] += 1
                results["by_category"][category]["total"] += 1
                
                # Check if should be skipped
                should_skip, skip_reason = self.should_skip_selector(selector)
                
                # Categorize by purpose
                purpose = self.categorize_selector(selector)
                results["by_purpose"][purpose]["total"] += 1
                
                if should_skip:
                    results["summary"]["total_skipped"] += 1
                    results["by_category"][category]["skipped"] += 1
                    results["by_purpose"][purpose]["skipped"] += 1
                else:
                    results["summary"]["total_should_include"] += 1
                    results["by_category"][category]["should_include"] += 1
                    results["by_purpose"][purpose]["should_include"] += 1
                    
                    # Add examples for selectors that should be included
                    if len(results["by_category"][category]["examples"]) < 3:
                        results["by_category"][category]["examples"].append({
                            "selector": selector,
                            "properties": list(properties.get("properties", {}).keys()),
                            "purpose": purpose
                        })
                    
                    if len(results["by_purpose"][purpose]["examples"]) < 3:
                        results["by_purpose"][purpose]["examples"].append({
                            "selector": selector,
                            "properties": list(properties.get("properties", {}).keys()),
                            "category": category
                        })
        
        # Analyze incomplete selectors
        for category, selectors in data.get('incomplete_selectors', {}).items():
            for selector, properties in selectors.items():
                should_skip, skip_reason = self.should_skip_selector(selector)
                purpose = self.categorize_selector(selector)
                
                if not should_skip:
                    results["summary"]["total_should_include"] += 1
                    results["by_category"][category]["should_include"] += 1
                    results["by_purpose"][purpose]["should_include"] += 1
        
        # Generate recommendations
        results["recommendations"] = self._generate_recommendations(results)
        
        return results
    
    def _generate_recommendations(self, results: Dict) -> List[str]:
        """Generate recommendations based on analysis."""
        recommendations = []
        
        # Check for high-value categories that aren't being processed
        high_value_purposes = ["content-styling", "gaming", "layout", "interactive", "typography"]
        
        for purpose in high_value_purposes:
            data = results["by_purpose"][purpose]
            if data["should_include"] > 5:
                recommendations.append(
                    f"HIGH PRIORITY: {data['should_include']} {purpose} selectors should be included but aren't being processed"
                )
        
        # Check for categories that could be entirely skipped
        for purpose, data in results["by_purpose"].items():
            skip_ratio = data["skipped"] / data["total"] if data["total"] > 0 else 0
            if skip_ratio > 0.8 and data["total"] > 10:
                recommendations.append(
                    f"SKIP CANDIDATE: {purpose} category is {skip_ratio:.0%} skipped ({data['skipped']}/{data['total']}), consider adding to skip patterns"
                )
        
        # Check for automation failures
        if results["summary"]["total_should_include"] > 50:
            recommendations.append(
                f"AUTOMATION ISSUE: {results['summary']['total_should_include']} selectors should be included but automation failed"
            )
        
        return recommendations
    
    def print_analysis(self):
        """Print detailed analysis report."""
        results = self.analyze_missing_selectors()
        
        print("=== CSS GAP ANALYSIS REPORT ===\\n")
        
        # Summary
        summary = results["summary"]
        print(f"SUMMARY:")
        print(f"  Total Missing: {summary['total_missing']}")
        print(f"  Correctly Skipped: {summary['total_skipped']}")
        print(f"  Should Include: {summary['total_should_include']}")
        print(f"  Skip Rate: {summary['total_skipped']/summary['total_missing']*100:.1f}%")
        
        # By purpose analysis
        print(f"\\nBY PURPOSE:")
        for purpose, data in sorted(results["by_purpose"].items(), 
                                   key=lambda x: x[1]["should_include"], reverse=True):
            if data["total"] > 0:
                print(f"  {purpose.upper()}: {data['should_include']}/{data['total']} should include")
                for example in data["examples"]:
                    props = ", ".join(example["properties"][:3])
                    print(f"    - {example['selector']} ({props})")
        
        # By category analysis  
        print(f"\\nBY CATEGORY:")
        for category, data in sorted(results["by_category"].items(),
                                   key=lambda x: x[1]["should_include"], reverse=True):
            if data["should_include"] > 0:
                print(f"  {category.upper()}: {data['should_include']}/{data['total']} should include")
        
        # Recommendations
        print(f"\\nRECOMMENDATIONS:")
        for i, rec in enumerate(results["recommendations"], 1):
            print(f"  {i}. {rec}")
        
        return results


def main():
    """Main entry point."""
    import argparse
    
    parser = argparse.ArgumentParser(description="Analyze CSS gaps in detail")
    parser.add_argument("--analysis-file", 
                       default="tools/css/output/css_gap_analysis.json",
                       help="Path to CSS gap analysis file")
    parser.add_argument("--json-output", help="Save results as JSON file")
    
    args = parser.parse_args()
    
    analyzer = CSSGapAnalyzer(args.analysis_file)
    results = analyzer.print_analysis()
    
    if args.json_output:
        # Convert defaultdict to regular dict for JSON serialization
        json_results = json.loads(json.dumps(results, default=dict))
        with open(args.json_output, 'w') as f:
            json.dump(json_results, f, indent=2)
        print(f"\\nDetailed results saved to: {args.json_output}")


if __name__ == '__main__':
    main()