#!/usr/bin/env python3
"""
Generate Implementation Status Report

Creates comprehensive reports about JS module discovery and implementation status:
- Coverage percentage
- Top priority unimplemented modules  
- Implementation progress over time
- Module usage statistics
- Overlap analysis
"""

import json
import sys
from datetime import datetime
from pathlib import Path

# Add the tools directory to Python path
tools_dir = Path(__file__).parent.parent
sys.path.insert(0, str(tools_dir))

from core.masterlist_manager import MasterlistManager
from analyzer.overlap_detector import OverlapDetector

class ReportGenerator:
    """Generate comprehensive implementation status reports"""
    
    def __init__(self, masterlists_dir: str = None):
        self.manager = MasterlistManager(masterlists_dir)
        self.overlap_detector = OverlapDetector()
    
    def generate_full_report(self, output_file: str = None) -> str:
        """Generate comprehensive status report"""
        
        report_lines = []
        
        # Header
        report_lines.append("=" * 80)
        report_lines.append("JS MODULE DISCOVERY & IMPLEMENTATION STATUS REPORT")
        report_lines.append("=" * 80)
        report_lines.append(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        report_lines.append("")
        
        # Summary statistics
        report_lines.extend(self._generate_summary_section())
        
        # Implementation coverage
        report_lines.extend(self._generate_coverage_section())
        
        # Top unimplemented modules
        report_lines.extend(self._generate_top_unimplemented_section())
        
        # Module type breakdown
        report_lines.extend(self._generate_type_breakdown_section())
        
        # Overlap analysis
        report_lines.extend(self._generate_overlap_section())
        
        # Implementation recommendations
        report_lines.extend(self._generate_recommendations_section())
        
        report_lines.append("=" * 80)
        
        report_text = "\n".join(report_lines)
        
        # Save to file if requested
        if output_file:
            output_path = Path(output_file)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            with open(output_path, 'w') as f:
                f.write(report_text)
            print(f"Report saved to: {output_path}")
        
        return report_text
    
    def _generate_summary_section(self) -> list:
        """Generate summary statistics section"""
        stats = self.manager.get_stats()
        
        # Calculate coverage percentage
        total_modules = stats['discovered']
        implemented_count = stats['implemented']
        coverage_pct = (implemented_count / total_modules * 100) if total_modules > 0 else 0
        
        lines = [
            "SUMMARY STATISTICS",
            "-" * 40,
            f"Total discovered modules: {stats['discovered']}",
            f"Implemented modules: {stats['implemented']}",
            f"Unimplemented modules: {stats['unimplemented']}",
            f"Implementation coverage: {coverage_pct:.1f}%",
            f"Total scans performed: {stats['total_scans']}",
            f"Last scan: {stats['last_scan'] or 'Never'}",
            ""
        ]
        
        return lines
    
    def _generate_coverage_section(self) -> list:
        """Generate implementation coverage details"""
        lines = [
            "IMPLEMENTATION COVERAGE ANALYSIS",
            "-" * 40
        ]
        
        # Get implementation details
        impl_modules = self.manager.implemented['modules']
        
        # Count wiki modules covered by implementations
        covered_wiki_modules = set()
        for impl_data in impl_modules.values():
            covered_wiki_modules.update(impl_data.get('wiki_names', []))
        
        discovered_modules = set(self.manager.discovered['modules'].keys())
        
        # Calculate detailed coverage
        exact_coverage = len(covered_wiki_modules.intersection(discovered_modules))
        total_discovered = len(discovered_modules)
        
        lines.extend([
            f"Exact module coverage: {exact_coverage}/{total_discovered} ({exact_coverage/total_discovered*100:.1f}%)",
            f"Implementation approaches:",
            ""
        ])
        
        # Show implementation types
        impl_types = {}
        for impl_data in impl_modules.values():
            impl_type = impl_data.get('implementation_type', 'unknown')
            impl_types[impl_type] = impl_types.get(impl_type, 0) + 1
        
        for impl_type, count in impl_types.items():
            lines.append(f"  - {impl_type}: {count} implementations")
        
        lines.append("")
        
        return lines
    
    def _generate_top_unimplemented_section(self) -> list:
        """Generate top unimplemented modules section"""
        lines = [
            "TOP PRIORITY UNIMPLEMENTED MODULES",
            "-" * 40
        ]
        
        unimplemented = self.manager.unimplemented['modules']
        
        # Sort by priority score
        sorted_modules = sorted(
            unimplemented.items(),
            key=lambda x: x[1].get('priority_score', 0),
            reverse=True
        )
        
        lines.append(f"Total unimplemented: {len(sorted_modules)}")
        lines.append("")
        lines.append("Top 15 by priority:")
        
        for i, (module_name, data) in enumerate(sorted_modules[:15], 1):
            priority = data.get('priority_score', 0)
            frequency = data.get('frequency_seen', 0)
            pages = data.get('pages_count', 0)
            complexity = data.get('complexity', 'unknown')
            deps_available = data.get('dependencies_available', False)
            
            lines.append(f"{i:2d}. {module_name}")
            lines.append(f"    Priority: {priority}, Frequency: {frequency}, Pages: {pages}")
            lines.append(f"    Complexity: {complexity}, Deps available: {'✓' if deps_available else '✗'}")
        
        lines.append("")
        
        return lines
    
    def _generate_type_breakdown_section(self) -> list:
        """Generate module type breakdown"""
        lines = [
            "MODULE TYPE BREAKDOWN",
            "-" * 40
        ]
        
        # Count by type in discovered modules
        type_counts = {}
        for module_data in self.manager.discovered['modules'].values():
            module_type = module_data.get('type', 'unknown')
            type_counts[module_type] = type_counts.get(module_type, 0) + 1
        
        lines.append("Discovered modules by type:")
        for module_type, count in sorted(type_counts.items(), key=lambda x: x[1], reverse=True):
            percentage = count / sum(type_counts.values()) * 100
            lines.append(f"  - {module_type}: {count} ({percentage:.1f}%)")
        
        lines.append("")
        
        # Most common gadgets
        gadget_modules = {
            name: data for name, data in self.manager.discovered['modules'].items()
            if data.get('type') == 'gadget'
        }
        
        if gadget_modules:
            lines.append("Most frequently seen gadgets:")
            sorted_gadgets = sorted(
                gadget_modules.items(),
                key=lambda x: x[1].get('scan_count', 0),
                reverse=True
            )
            
            for name, data in sorted_gadgets[:10]:
                scan_count = data.get('scan_count', 0)
                pages_count = len(data.get('pages_found_on', set()))
                lines.append(f"  - {name}: seen {scan_count} times on {pages_count} pages")
        
        lines.append("")
        
        return lines
    
    def _generate_overlap_section(self) -> list:
        """Generate overlap analysis section"""
        lines = [
            "OVERLAP ANALYSIS",
            "-" * 40
        ]
        
        # Run overlap detection
        overlap_results = self.overlap_detector.detect_overlaps(
            self.manager.discovered['modules'],
            self.manager.implemented['modules']
        )
        
        # Summarize results
        exact_matches = len(overlap_results.get('exact_matches', []))
        name_similarities = len(overlap_results.get('name_similarity', []))
        functional_similarities = len(overlap_results.get('functional_similarity', []))
        consolidations = len(overlap_results.get('potential_consolidations', []))
        
        lines.extend([
            f"Exact matches (already implemented): {exact_matches}",
            f"Name similarities found: {name_similarities}",
            f"Functional similarities found: {functional_similarities}",
            f"Consolidation opportunities: {consolidations}",
            ""
        ])
        
        # Show some examples
        if functional_similarities > 0:
            lines.append("Functional similarity examples:")
            for sim in overlap_results['functional_similarity'][:5]:
                lines.append(f"  - {sim['discovered_module']} ≈ {sim['implemented_module']}")
                lines.append(f"    Categories: {', '.join(sim['functionality_categories'])}")
        
        if consolidations > 0:
            lines.append("")
            lines.append("Consolidation opportunities:")
            for opp in overlap_results['potential_consolidations'][:3]:
                lines.append(f"  - {opp['category']} category:")
                lines.append(f"    Could extend existing implementation to cover {len(opp['unimplemented_modules'])} more modules")
        
        lines.append("")
        
        return lines
    
    def _generate_recommendations_section(self) -> list:
        """Generate implementation recommendations"""
        lines = [
            "IMPLEMENTATION RECOMMENDATIONS",
            "-" * 40
        ]
        
        # Get top unimplemented with good dependency availability
        unimplemented = self.manager.unimplemented['modules']
        
        # High priority with available dependencies
        ready_to_implement = [
            (name, data) for name, data in unimplemented.items()
            if data.get('dependencies_available', False) and data.get('priority_score', 0) > 0
        ]
        
        ready_to_implement.sort(key=lambda x: x[1].get('priority_score', 0), reverse=True)
        
        if ready_to_implement:
            lines.append("Ready to implement (dependencies available):")
            for name, data in ready_to_implement[:5]:
                priority = data.get('priority_score', 0)
                complexity = data.get('complexity', 'unknown')
                lines.append(f"  1. {name} (priority: {priority}, complexity: {complexity})")
        
        lines.append("")
        
        # Low complexity, high impact
        easy_wins = [
            (name, data) for name, data in unimplemented.items()
            if data.get('complexity') == 'low' and data.get('priority_score', 0) > 10
        ]
        
        easy_wins.sort(key=lambda x: x[1].get('priority_score', 0), reverse=True)
        
        if easy_wins:
            lines.append("Easy wins (low complexity, high impact):")
            for name, data in easy_wins[:5]:
                priority = data.get('priority_score', 0)
                pages = data.get('pages_count', 0)
                lines.append(f"  - {name} (priority: {priority}, {pages} pages)")
        
        lines.append("")
        
        return lines
    
    def export_json_report(self, output_file: str) -> dict:
        """Export structured data as JSON"""
        
        stats = self.manager.get_stats()
        
        # Get top unimplemented
        unimplemented = self.manager.unimplemented['modules']
        top_unimplemented = sorted(
            unimplemented.items(),
            key=lambda x: x[1].get('priority_score', 0),
            reverse=True
        )[:20]
        
        # Run overlap analysis
        overlap_results = self.overlap_detector.detect_overlaps(
            self.manager.discovered['modules'],
            self.manager.implemented['modules']
        )
        
        report_data = {
            "metadata": {
                "generated_at": datetime.now().isoformat(),
                "generator": "js-discovery-report-generator",
                "version": "1.0.0"
            },
            "summary": stats,
            "coverage": {
                "percentage": (stats['implemented'] / stats['discovered'] * 100) if stats['discovered'] > 0 else 0,
                "exact_matches": len(overlap_results.get('exact_matches', []))
            },
            "top_unimplemented": [
                {
                    "module_name": name,
                    **data
                }
                for name, data in top_unimplemented
            ],
            "overlap_analysis": {
                "exact_matches": len(overlap_results.get('exact_matches', [])),
                "name_similarities": len(overlap_results.get('name_similarity', [])),
                "functional_similarities": len(overlap_results.get('functional_similarity', [])),
                "consolidation_opportunities": len(overlap_results.get('potential_consolidations', []))
            },
            "recommendations": {
                "ready_to_implement": [
                    name for name, data in unimplemented.items()
                    if data.get('dependencies_available', False) and data.get('priority_score', 0) > 0
                ][:10],
                "easy_wins": [
                    name for name, data in unimplemented.items() 
                    if data.get('complexity') == 'low' and data.get('priority_score', 0) > 10
                ][:10]
            }
        }
        
        # Save to file
        with open(output_file, 'w') as f:
            json.dump(report_data, f, indent=2, default=str)
        
        return report_data

def main():
    """Main entry point"""
    import argparse
    
    parser = argparse.ArgumentParser(description="Generate JS Module Implementation Report")
    parser.add_argument('--output', '-o', help='Output file path')
    parser.add_argument('--json', help='Export JSON report to file')
    parser.add_argument('--masterlists-dir', help='Directory for masterlists')
    
    args = parser.parse_args()
    
    generator = ReportGenerator(args.masterlists_dir)
    
    # Generate text report
    report = generator.generate_full_report(args.output)
    
    if not args.output:
        print(report)
    
    # Generate JSON report if requested
    if args.json:
        generator.export_json_report(args.json)
        print(f"JSON report saved to: {args.json}")

if __name__ == "__main__":
    main()