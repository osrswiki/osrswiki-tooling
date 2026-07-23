#!/usr/bin/env python3
"""
Automated CSS Sync Workflow for maintaining parity with oldschool.runescape.wiki
"""

import subprocess
import json
import os
import sys
from datetime import datetime

class CSSSyncWorkflow:
    """Automated workflow for maintaining CSS parity with wiki."""
    
    def __init__(self):
        self.wiki_css_url = "https://oldschool.runescape.wiki/load.php?lang=en&modules=site.styles&only=styles"
        self.wiki_css_file = "wiki_styles.css"
        self.analysis_file = "css_gap_analysis.json"
        self.app_css_dir = "app/src/main/assets/styles"
        self.log_file = "css_sync.log"
        self.auto_generate_enabled = True
    
    def log(self, message: str):
        """Log a message with timestamp."""
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        log_entry = f"[{timestamp}] {message}"
        print(log_entry)
        
        with open(self.log_file, "a", encoding="utf-8") as f:
            f.write(log_entry + "\\n")
    
    def fetch_wiki_css(self) -> bool:
        """Fetch the latest CSS from the wiki."""
        try:
            self.log("Fetching latest CSS from oldschool.runescape.wiki...")
            result = subprocess.run([
                "curl", "-s", self.wiki_css_url, "-o", self.wiki_css_file
            ], capture_output=True, text=True)
            
            if result.returncode == 0:
                self.log(f"Successfully downloaded wiki CSS to {self.wiki_css_file}")
                return True
            else:
                self.log(f"Error downloading wiki CSS: {result.stderr}")
                return False
        except Exception as e:
            self.log(f"Exception while fetching wiki CSS: {e}")
            return False
    
    def run_analysis(self) -> bool:
        """Run CSS gap analysis."""
        try:
            self.log("Running CSS gap analysis...")
            result = subprocess.run([
                "python3", "tools/css/css-rule-analyzer.py"
            ], capture_output=True, text=True)
            
            if result.returncode == 0:
                self.log(f"CSS analysis completed successfully")
                self.log(result.stdout)
                return True
            else:
                self.log(f"CSS analysis failed: {result.stderr}")
                return False
        except Exception as e:
            self.log(f"Exception during CSS analysis: {e}")
            return False
    
    def check_significant_changes(self) -> tuple[bool, dict]:
        """Check if there are significant changes requiring attention."""
        try:
            with open(self.analysis_file, 'r') as f:
                data = json.load(f)
            
            stats = data.get('statistics', {})
            missing_content_high = stats.get('missing_by_category', {}).get('content-high', 0)
            missing_content_medium = stats.get('missing_by_category', {}).get('content-medium', 0)
            incomplete_content = sum(stats.get('incomplete_by_category', {}).values())
            
            # Define thresholds for significant changes
            SIGNIFICANT_THRESHOLDS = {
                'content_high_missing': 10,  # More than 10 high-priority missing styles
                'content_medium_missing': 20,  # More than 20 medium-priority missing styles  
                'incomplete_total': 5  # More than 5 incomplete implementations
            }
            
            significant_changes = {
                'content_high_missing': missing_content_high > SIGNIFICANT_THRESHOLDS['content_high_missing'],
                'content_medium_missing': missing_content_medium > SIGNIFICANT_THRESHOLDS['content_medium_missing'],
                'incomplete_total': incomplete_content > SIGNIFICANT_THRESHOLDS['incomplete_total'],
                'stats': {
                    'content_high_missing': missing_content_high,
                    'content_medium_missing': missing_content_medium,
                    'incomplete_total': incomplete_content
                }
            }
            
            has_significant = any(significant_changes[key] for key in ['content_high_missing', 'content_medium_missing', 'incomplete_total'])
            
            return has_significant, significant_changes
            
        except Exception as e:
            self.log(f"Error checking for significant changes: {e}")
            return False, {}
    
    def auto_generate_css(self) -> bool:
        """Automatically generate and integrate missing CSS."""
        try:
            # Step 1: Generate missing CSS
            self.log("Generating missing CSS...")
            result = subprocess.run([
                "python3", "tools/css/css-generator.py"
            ], capture_output=True, text=True)
            
            if result.returncode != 0:
                self.log(f"CSS generation failed: {result.stderr}")
                return False
            
            self.log("CSS generation completed")
            
            # Step 2: Integrate CSS into modules
            self.log("Integrating CSS into modules...")
            result = subprocess.run([
                "python3", "tools/css/css-integrator.py"
            ], capture_output=True, text=True)
            
            if result.returncode != 0:
                self.log(f"CSS integration failed: {result.stderr}")
                return False
                
            self.log("CSS integration completed")
            return True
            
        except Exception as e:
            self.log(f"Exception during CSS auto-generation: {e}")
            return False
    
    def generate_summary_report(self) -> str:
        """Generate a human-readable summary report."""
        try:
            with open(self.analysis_file, 'r') as f:
                data = json.load(f)
            
            stats = data.get('statistics', {})
            
            report = []
            report.append("=== CSS SYNC ANALYSIS SUMMARY ===")
            report.append(f"Analysis Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
            report.append("")
            report.append("OVERVIEW:")
            report.append(f"  Wiki Total Selectors: {stats.get('wiki_total_selectors', 0)}")
            report.append(f"  App Total Selectors: {stats.get('app_total_selectors', 0)}")
            report.append("")
            
            report.append("MISSING SELECTORS BY CATEGORY:")
            missing_by_cat = stats.get('missing_by_category', {})
            for category, count in missing_by_cat.items():
                report.append(f"  {category}: {count}")
            report.append("")
            
            report.append("INCOMPLETE SELECTORS BY CATEGORY:")
            incomplete_by_cat = stats.get('incomplete_by_category', {})
            for category, count in incomplete_by_cat.items():
                report.append(f"  {category}: {count}")
            report.append("")
            
            # Add priority recommendations
            content_high = missing_by_cat.get('content-high', 0)
            content_medium = missing_by_cat.get('content-medium', 0)
            
            report.append("RECOMMENDATIONS:")
            if content_high > 50:
                report.append("  🔴 HIGH PRIORITY: Many content-high selectors missing - significant styling gaps likely")
            elif content_high > 10:
                report.append("  🟡 MEDIUM PRIORITY: Some content-high selectors missing - minor styling gaps possible")
            else:
                report.append("  🟢 LOW PRIORITY: Few content-high selectors missing - styling mostly up to date")
            
            if content_medium > 30:
                report.append("  🟡 Consider updating content-medium selectors (table styling, etc.)")
            
            report.append("")
            report.append(f"Full analysis saved to: {self.analysis_file}")
            
            return "\\n".join(report)
            
        except Exception as e:
            return f"Error generating summary report: {e}"
    
    def run_full_sync(self) -> bool:
        """Run the complete CSS sync workflow."""
        self.log("=== Starting CSS Sync Workflow ===")
        
        # Step 1: Fetch latest wiki CSS
        if not self.fetch_wiki_css():
            self.log("Failed to fetch wiki CSS - aborting workflow")
            return False
        
        # Step 2: Run analysis
        if not self.run_analysis():
            self.log("Failed to run CSS analysis - aborting workflow")
            return False
        
        # Step 3: Check for significant changes
        has_significant, changes = self.check_significant_changes()
        
        # Step 4: Generate summary report
        summary = self.generate_summary_report()
        self.log("\\n" + summary)
        
        # Step 5: Alert about significant changes
        if has_significant:
            self.log("\\n🚨 SIGNIFICANT CHANGES DETECTED 🚨")
            self.log("The following areas need attention:")
            
            if changes.get('content_high_missing', False):
                self.log(f"  - HIGH PRIORITY: {changes['stats']['content_high_missing']} content-high selectors missing")
            
            if changes.get('content_medium_missing', False):
                self.log(f"  - MEDIUM PRIORITY: {changes['stats']['content_medium_missing']} content-medium selectors missing")
            
            if changes.get('incomplete_total', False):
                self.log(f"  - INCOMPLETE: {changes['stats']['incomplete_total']} incomplete selector implementations")
            
            if self.auto_generate_enabled:
                self.log("\\n🔧 Auto-generating missing CSS...")
                if self.auto_generate_css():
                    self.log("\\n✅ CSS auto-generation complete!")
                    self.log("🚀 Ready to build the app with: ./gradlew assembleDebug")
                else:
                    self.log("\\n❌ CSS auto-generation failed!")
                    self.log("Manual fallback: python3 tools/css/css-generator.py")
                    self.log("Then: python3 tools/css/css-integrator.py")
            else:
                self.log("\\nConsider running: python3 tools/css/css-generator.py")
                self.log("Then: python3 tools/css/css-integrator.py")
                self.log("Then rebuild the app with: ./gradlew assembleDebug")
        else:
            self.log("\\n✅ No significant changes detected - CSS is mostly up to date")
        
        self.log("=== CSS Sync Workflow Complete ===")
        return True
    
    def cleanup(self):
        """Clean up temporary files."""
        temp_files = [self.wiki_css_file]
        for file in temp_files:
            if os.path.exists(file):
                os.remove(file)
                self.log(f"Cleaned up temporary file: {file}")

def main():
    """Main entry point."""
    import argparse
    
    parser = argparse.ArgumentParser(description="CSS Sync Workflow")
    parser.add_argument("--cleanup-only", action="store_true", 
                       help="Only clean up temporary files")
    parser.add_argument("--no-auto-generate", action="store_true",
                       help="Disable automatic CSS generation and integration")
    
    args = parser.parse_args()
    
    workflow = CSSSyncWorkflow()
    
    # Allow disabling auto-generation for manual workflow
    if args.no_auto_generate:
        workflow.auto_generate_enabled = False
    else:
        workflow.auto_generate_enabled = True
    
    try:
        if args.cleanup_only:
            workflow.cleanup()
            return
        
        success = workflow.run_full_sync()
        
        # Always generate a final report file for reference
        report_file = f"css_sync_report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"
        summary = workflow.generate_summary_report()
        with open(report_file, 'w') as f:
            f.write(summary)
        workflow.log(f"Summary report saved to: {report_file}")
        
        if not success:
            sys.exit(1)
            
    except KeyboardInterrupt:
        workflow.log("\\nCSS sync workflow interrupted by user")
        sys.exit(130)
    except Exception as e:
        workflow.log(f"Unexpected error in CSS sync workflow: {e}")
        sys.exit(1)
    finally:
        # Clean up temporary files
        workflow.cleanup()

if __name__ == '__main__':
    main()