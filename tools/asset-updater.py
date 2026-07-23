#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
OSRSWiki Meta Asset Updater

A unified wrapper that orchestrates both map and CSS asset generation tools.
Provides a single entry point for updating all external assets used by the app.

Features:
- Unified interface for map and CSS updates
- Pass-through CLI arguments to underlying tools
- Coordinated progress reporting
- Comprehensive error handling and validation
- Summary reporting of all updates performed
"""

import argparse
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import List, Optional, Tuple


class Colors:
    """ANSI color codes for terminal output"""
    BLUE = '\033[94m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    BOLD = '\033[1m'
    CYAN = '\033[96m'
    END = '\033[0m'


class MetaAssetUpdater:
    """Meta wrapper for coordinating all asset update tools"""
    
    def __init__(self):
        self.script_dir = Path(__file__).parent
        self.map_tool = self.script_dir / "map" / "map-asset-generator.py"
        self.css_tool = self.script_dir / "css" / "css-perfect-sync.py"
        self.js_discovery_tool = self.script_dir / "js" / "update_discovery.py"
        
        # Track execution results
        self.results = {
            'map': {'attempted': False, 'success': False, 'message': ''},
            'css': {'attempted': False, 'success': False, 'message': ''},
            'js-discovery': {'attempted': False, 'success': False, 'message': ''}
        }
        
    def log(self, message: str, color: str = Colors.BLUE):
        """Log a message with timestamp and color"""
        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        print(f"{color}[{timestamp}] {message}{Colors.END}")
        
    def log_success(self, message: str):
        """Log a success message"""
        self.log(f"✅ {message}", Colors.GREEN)
        
    def log_warning(self, message: str):
        """Log a warning message"""
        self.log(f"⚠️  {message}", Colors.YELLOW)
        
    def log_error(self, message: str):
        """Log an error message"""
        self.log(f"❌ {message}", Colors.RED)
        
    def log_info(self, message: str):
        """Log an info message"""
        self.log(f"ℹ️  {message}", Colors.BLUE)
        
    def log_section(self, message: str):
        """Log a section header"""
        self.log(f"\n{'='*60}", Colors.CYAN)
        self.log(f"🔧 {message.upper()}", Colors.CYAN)
        self.log(f"{'='*60}", Colors.CYAN)
        
    def validate_environment(self, update_maps: bool = False, update_css: bool = False, update_js_discovery: bool = False) -> bool:
        """Validate that all required tools and dependencies exist"""
        self.log_info("Validating environment and dependencies...")
        
        # Check that individual tools exist (only for requested updates)
        missing_tools = []
        
        if update_maps and not self.map_tool.exists():
            missing_tools.append(f"Map tool: {self.map_tool}")
        if update_css and not self.css_tool.exists():
            missing_tools.append(f"CSS tool: {self.css_tool}")
        if update_js_discovery and not self.js_discovery_tool.exists():
            missing_tools.append(f"JS Discovery tool: {self.js_discovery_tool}")
            
        if missing_tools:
            self.log_error("Missing required tools:")
            for tool in missing_tools:
                self.log_error(f"  - {tool}")
            return False
            
        # Check that tools are executable (only for requested updates)
        if update_maps and not os.access(self.map_tool, os.X_OK):
            self.log_error(f"Map tool is not executable: {self.map_tool}")
            return False
        if update_css and not os.access(self.css_tool, os.X_OK):
            self.log_error(f"CSS tool is not executable: {self.css_tool}")
            return False
        
        # Check for Pixi (only needed for maps and CSS)
        if update_maps or update_css:
            if shutil.which("pixi") is None:
                self.log_error("Pixi not found on PATH")
                return False
            
        self.log_success("Environment validation passed")
        return True
        
    def get_pixi_command_prefix(self) -> List[str]:
        """Get the command prefix for running tools in the locked Pixi environment."""
        return ["pixi", "run", "--manifest-path", str(self.script_dir)]
        
    def run_tool(self, tool_path: Path, tool_name: str, args: List[str] = None) -> Tuple[bool, str]:
        """Run an individual tool and return success status and message"""
        if args is None:
            args = []
            
        cmd = self.get_pixi_command_prefix() + ["python", str(tool_path)] + args
        self.log_info(f"Executing {tool_name} in the Pixi environment...")
        self.log(f"Command: {' '.join(cmd)}", Colors.BLUE)
        
        try:
            start_time = time.time()
            result = subprocess.run(
                cmd,
                cwd=self.script_dir,
                capture_output=True,
                text=True,
                timeout=1800  # 30 minute timeout
            )
            
            duration = time.time() - start_time
            
            if result.returncode == 0:
                message = f"{tool_name} completed successfully in {duration:.1f}s"
                self.log_success(message)
                
                # Show relevant output if not too verbose
                if result.stdout.strip():
                    lines = result.stdout.strip().split('\n')
                    # Show last few lines of output for context
                    for line in lines[-5:]:
                        if line.strip():
                            self.log(f"  {line}", Colors.BLUE)
                            
                return True, message
            else:
                error_msg = f"{tool_name} failed with exit code {result.returncode}"
                self.log_error(error_msg)
                
                # Show error output
                if result.stderr.strip():
                    self.log_error("Error output:")
                    for line in result.stderr.strip().split('\n')[-10:]:  # Last 10 lines
                        if line.strip():
                            self.log_error(f"  {line}")
                            
                return False, error_msg
                
        except subprocess.TimeoutExpired:
            error_msg = f"{tool_name} timed out after 30 minutes"
            self.log_error(error_msg)
            return False, error_msg
        except Exception as e:
            error_msg = f"{tool_name} failed with exception: {e}"
            self.log_error(error_msg)
            return False, error_msg
            
    def update_map_assets(self, pass_through_args: List[str] = None) -> bool:
        """Update map assets using the map asset generator"""
        self.log_section("Map Asset Update")
        self.results['map']['attempted'] = True
        
        # Filter pass-through args for map tool (remove CSS-specific args)
        map_args = []
        if pass_through_args:
            # Map tool supports: --force, --dry-run, --verify, --check-freshness
            supported_args = ['--force', '--dry-run', '--verify', '--check-freshness']
            map_args = [arg for arg in pass_through_args if arg in supported_args]
            
        success, message = self.run_tool(self.map_tool, "Map Asset Generator", map_args)
        self.results['map']['success'] = success
        self.results['map']['message'] = message
        
        return success
        
    def update_css_assets(self, pass_through_args: List[str] = None) -> bool:
        """Update CSS assets using the CSS perfect sync tool"""
        self.log_section("CSS Asset Update")
        self.results['css']['attempted'] = True
        
        # CSS perfect sync tool doesn't take arguments currently, so we ignore pass-through args
        success, message = self.run_tool(self.css_tool, "CSS Perfect Sync")
        self.results['css']['success'] = success
        self.results['css']['message'] = message
        
        return success
        
    def update_js_discovery(self, pass_through_args: List[str] = None) -> bool:
        """Update JS module discovery using the discovery tool"""
        self.log_section("JS Module Discovery Update")
        self.results['js-discovery']['attempted'] = True
        
        # Use the current Python interpreter for JS discovery.
        args = pass_through_args if pass_through_args else []
        success, message = self.run_js_discovery_tool(args)
        self.results['js-discovery']['success'] = success
        self.results['js-discovery']['message'] = message
        
        return success
        
    def run_js_discovery_tool(self, args: List[str] = None) -> Tuple[bool, str]:
        """Run the JS discovery tool using standard Python"""
        if args is None:
            args = []
            
        cmd = [sys.executable, str(self.js_discovery_tool)] + args
        self.log_info("Executing JS Discovery scan...")
        self.log(f"Command: {' '.join(cmd)}", Colors.BLUE)
        
        try:
            start_time = time.time()
            result = subprocess.run(
                cmd,
                cwd=self.script_dir,
                capture_output=True,
                text=True,
                timeout=600  # 10 minute timeout for JS discovery
            )
            
            execution_time = time.time() - start_time
            
            if result.returncode == 0:
                self.log_success(f"JS Discovery completed successfully in {execution_time:.1f}s")
                return True, f"Discovery scan completed in {execution_time:.1f}s"
            else:
                self.log_error(f"JS Discovery failed with return code {result.returncode}")
                if result.stderr:
                    self.log_error(f"Error output: {result.stderr}")
                return False, f"Discovery failed: {result.stderr or 'Unknown error'}"
                
        except subprocess.TimeoutExpired:
            self.log_error("JS Discovery timed out after 10 minutes")
            return False, "Discovery timed out"
        except Exception as e:
            self.log_error(f"Failed to execute JS Discovery: {str(e)}")
            return False, f"Execution failed: {str(e)}"
        
    def print_summary(self):
        """Print a comprehensive summary of all operations performed"""
        self.log_section("Update Summary")
        
        total_attempted = sum(1 for r in self.results.values() if r['attempted'])
        total_successful = sum(1 for r in self.results.values() if r['success'])
        
        if total_attempted == 0:
            self.log_warning("No update operations were attempted")
            return
            
        self.log_info(f"Operations completed: {total_successful}/{total_attempted}")
        
        # Detailed results
        for tool_name, result in self.results.items():
            if result['attempted']:
                status = "✅ SUCCESS" if result['success'] else "❌ FAILED"
                color = Colors.GREEN if result['success'] else Colors.RED
                self.log(f"{status} - {tool_name.upper()}: {result['message']}", color)
                
        # Overall result
        if total_successful == total_attempted:
            self.log_success(f"🎉 All asset updates completed successfully!")
        elif total_successful > 0:
            self.log_warning(f"⚠️  Partial success: {total_successful}/{total_attempted} updates completed")
        else:
            self.log_error("❌ All asset updates failed")
            
    def run_updates(self, update_maps: bool, update_css: bool, update_js_discovery: bool = False, pass_through_args: List[str] = None) -> bool:
        """Run the specified updates"""
        if not update_maps and not update_css and not update_js_discovery:
            self.log_error("No update types specified. Use --all, --maps, --css, or --js-discovery")
            return False
            
        # Validate environment first
        if not self.validate_environment(update_maps, update_css, update_js_discovery):
            return False
            
        overall_success = True
        
        # Run updates in logical order (maps first, then CSS)
        if update_maps:
            if not self.update_map_assets(pass_through_args):
                overall_success = False
                
        if update_css:
            if not self.update_css_assets(pass_through_args):
                overall_success = False
                
        if update_js_discovery:
            if not self.update_js_discovery(pass_through_args):
                overall_success = False
                
        return overall_success


def main():
    """Main entry point for the meta asset updater"""
    parser = argparse.ArgumentParser(
        description="OSRSWiki Meta Asset Updater - Unified interface for all asset generation tools",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --all                    Update maps, CSS, and JS discovery
  %(prog)s --maps --force           Force update map assets only
  %(prog)s --css                    Update CSS assets only
  %(prog)s --js-discovery           Update JS module discovery only
  %(prog)s --all --dry-run          Preview what would be updated
  %(prog)s --all --verify           Verify all assets exist and are up to date
        """
    )
    
    # Update target selection (mutually exclusive group for clarity)
    target_group = parser.add_mutually_exclusive_group(required=True)
    target_group.add_argument(
        "--all",
        action="store_true",
        help="Update map, CSS, and JS discovery assets"
    )
    target_group.add_argument(
        "--maps",
        action="store_true", 
        help="Update only map assets"
    )
    target_group.add_argument(
        "--css",
        action="store_true",
        help="Update only CSS assets"
    )
    target_group.add_argument(
        "--js-discovery",
        action="store_true",
        help="Update only JS module discovery"
    )
    
    # Pass-through arguments for underlying tools
    parser.add_argument(
        "--force",
        action="store_true",
        help="Force regeneration even if assets are up to date (maps only)"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done without executing (maps only)"
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Only verify that assets exist and are accessible (maps only)"
    )
    parser.add_argument(
        "--check-freshness",
        action="store_true",
        help="Only check if local assets are up to date (maps only)"
    )
    
    args = parser.parse_args()
    
    # Print header
    print(f"{Colors.BOLD}🚀 OSRSWiki Meta Asset Updater{Colors.END}")
    print(f"{Colors.BOLD}{'='*60}{Colors.END}")
    
    # Determine what to update
    update_maps = args.all or args.maps
    update_css = args.all or args.css
    update_js_discovery = args.all or getattr(args, 'js_discovery', False)
    
    # Build pass-through arguments
    pass_through_args = []
    if args.force:
        pass_through_args.append('--force')
    if args.dry_run:
        pass_through_args.append('--dry-run')
    if args.verify:
        pass_through_args.append('--verify')
    if args.check_freshness:
        pass_through_args.append('--check-freshness')
    
    # Create updater and run
    updater = MetaAssetUpdater()
    
    try:
        success = updater.run_updates(update_maps, update_css, update_js_discovery, pass_through_args)
        updater.print_summary()
        
        sys.exit(0 if success else 1)
        
    except KeyboardInterrupt:
        updater.log_warning("Operation cancelled by user")
        updater.print_summary()
        sys.exit(1)
    except Exception as e:
        updater.log_error(f"Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        updater.print_summary()
        sys.exit(1)


if __name__ == "__main__":
    main()
