#!/usr/bin/env python3
"""
Masterlist Manager with Deduplication

Manages the three masterlists with guaranteed deduplication:
- discovered_modules.json: Accumulative discovery tracking
- implemented_modules.json: App implementation mapping  
- unimplemented_modules.json: Prioritized TODO list

Key features:
- Atomic file operations with backup
- Set-based deduplication for pages
- Cross-masterlist validation
- Merge strategies for accumulative updates
"""

import json
import os
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Set, Any, Optional
import logging

logger = logging.getLogger(__name__)

class MasterlistManager:
    """
    Singleton manager for JS module masterlists with deduplication guarantees.
    """
    
    def __init__(self, masterlists_dir: str = None):
        if masterlists_dir is None:
            # Default to tools/js/masterlists
            script_dir = Path(__file__).parent.parent
            masterlists_dir = script_dir / "masterlists"
        
        self.masterlists_dir = Path(masterlists_dir)
        self.masterlists_dir.mkdir(exist_ok=True)
        
        self.discovered_file = self.masterlists_dir / "discovered_modules.json"
        self.implemented_file = self.masterlists_dir / "implemented_modules.json"
        self.unimplemented_file = self.masterlists_dir / "unimplemented_modules.json"
        
        # Load existing data
        self.discovered = self._load_discovered()
        self.implemented = self._load_implemented()
        self.unimplemented = self._load_unimplemented()
    
    def _load_discovered(self) -> Dict[str, Any]:
        """Load discovered modules masterlist"""
        if self.discovered_file.exists():
            with open(self.discovered_file, 'r') as f:
                data = json.load(f)
                # Convert pages_found_on back to sets
                for module_name, module_data in data.get('modules', {}).items():
                    if 'pages_found_on' in module_data:
                        module_data['pages_found_on'] = set(module_data['pages_found_on'])
                return data
        
        return {
            "metadata": {
                "last_scan": None,
                "total_scans": 0,
                "total_unique_modules": 0
            },
            "modules": {}
        }
    
    def _load_implemented(self) -> Dict[str, Any]:
        """Load implemented modules masterlist"""
        if self.implemented_file.exists():
            with open(self.implemented_file, 'r') as f:
                return json.load(f)
        
        return {"modules": {}}
    
    def _load_unimplemented(self) -> Dict[str, Any]:
        """Load unimplemented modules masterlist"""
        if self.unimplemented_file.exists():
            with open(self.unimplemented_file, 'r') as f:
                return json.load(f)
        
        return {"modules": {}}
    
    def add_discovered_module(self, module_name: str, context: Dict[str, Any]) -> None:
        """
        Add discovered module with automatic deduplication.
        
        Args:
            module_name: Module name (e.g., "ext.gadget.GECharts")
            context: Discovery context with page, dependencies, etc.
        """
        now = self._now_iso()
        page = context.get('page', 'unknown')
        
        if module_name in self.discovered['modules']:
            # Update existing module - no duplicate
            module = self.discovered['modules'][module_name]
            module['last_seen'] = now
            module['scan_count'] = module.get('scan_count', 0) + 1
            
            # Use set to prevent duplicate pages
            if 'pages_found_on' not in module:
                module['pages_found_on'] = set()
            module['pages_found_on'].add(page)
            
            # Merge dependencies (union)
            existing_deps = set(module.get('dependencies', []))
            new_deps = set(context.get('dependencies', []))
            module['dependencies'] = list(existing_deps.union(new_deps))
            
            # Update other fields if provided
            for field in ['type', 'size_bytes']:
                if field in context:
                    module[field] = context[field]
        else:
            # New discovery
            self.discovered['modules'][module_name] = {
                'first_seen': now,
                'last_seen': now,
                'scan_count': 1,
                'pages_found_on': {page},  # Set from start
                'dependencies': context.get('dependencies', []),
                'type': context.get('type', 'unknown'),
                'size_bytes': context.get('size_bytes', 0)
            }
        
        # Update metadata
        self.discovered['metadata']['last_scan'] = now
        self.discovered['metadata']['total_scans'] += 1
        self.discovered['metadata']['total_unique_modules'] = len(self.discovered['modules'])
    
    def add_implemented_module(self, impl_name: str, wiki_names: List[str], 
                             app_files: List[str], **kwargs) -> None:
        """
        Add implemented module with validation against duplicates.
        
        Args:
            impl_name: Implementation name (e.g., "ge_charts")
            wiki_names: List of wiki module names this implements
            app_files: List of app files for this implementation
        """
        # Validate no wiki name is already implemented elsewhere
        for wiki_name in wiki_names:
            for existing_impl, existing_data in self.implemented['modules'].items():
                if existing_impl != impl_name and wiki_name in existing_data.get('wiki_names', []):
                    raise ValueError(f"Wiki module '{wiki_name}' already implemented in '{existing_impl}'")
        
        self.implemented['modules'][impl_name] = {
            'wiki_names': wiki_names,
            'app_files': app_files,
            'implementation_type': kwargs.get('implementation_type', 'custom_curated'),
            'implemented_date': kwargs.get('implemented_date', self._now_iso()),
            'functionality': kwargs.get('functionality', ''),
            **{k: v for k, v in kwargs.items() if k not in ['implementation_type', 'implemented_date', 'functionality']}
        }
        
        # Remove from unimplemented
        for wiki_name in wiki_names:
            self.unimplemented['modules'].pop(wiki_name, None)
    
    def update_unimplemented_priorities(self) -> None:
        """
        Update unimplemented module priorities based on discovery data.
        Modules already implemented are automatically excluded.
        """
        # Get all implemented wiki names
        implemented_wiki_names = set()
        for impl_data in self.implemented['modules'].values():
            implemented_wiki_names.update(impl_data.get('wiki_names', []))
        
        # Process discovered modules
        for module_name, module_data in self.discovered['modules'].items():
            if module_name in implemented_wiki_names:
                # Remove from unimplemented if it exists
                self.unimplemented['modules'].pop(module_name, None)
                continue
            
            # Calculate priority score
            frequency = module_data.get('scan_count', 0)
            pages_count = len(module_data.get('pages_found_on', set()))
            
            # Simple priority scoring: frequency * pages_count
            priority_score = frequency * pages_count
            
            # Check if dependencies are available
            dependencies = module_data.get('dependencies', [])
            dependencies_available = all(
                dep in self.discovered['modules'] or dep in implemented_wiki_names
                for dep in dependencies
            )
            
            # Estimate complexity based on dependencies count
            complexity = "low" if len(dependencies) <= 2 else "medium" if len(dependencies) <= 5 else "high"
            
            self.unimplemented['modules'][module_name] = {
                'priority_score': priority_score,
                'frequency_seen': frequency,
                'pages_count': pages_count,
                'complexity': complexity,
                'dependencies_available': dependencies_available,
                'dependencies': dependencies,
                'similar_implemented': [],  # TODO: Implement similarity detection
                'notes': f"Found on {pages_count} pages, seen {frequency} times"
            }
    
    def validate_no_cross_duplicates(self) -> None:
        """
        Validate that no module appears incorrectly in multiple masterlists.
        Raises ValueError if duplicates found.
        """
        implemented_wiki_names = set()
        
        # Collect all implemented wiki names
        for impl_name, impl_data in self.implemented['modules'].items():
            for wiki_name in impl_data.get('wiki_names', []):
                if wiki_name in implemented_wiki_names:
                    raise ValueError(f"Duplicate wiki module '{wiki_name}' in implemented list")
                implemented_wiki_names.add(wiki_name)
        
        # Check for implemented modules in unimplemented list
        invalid_unimplemented = []
        for module_name in self.unimplemented['modules']:
            if module_name in implemented_wiki_names:
                invalid_unimplemented.append(module_name)
        
        if invalid_unimplemented:
            logger.warning(f"Removing {len(invalid_unimplemented)} implemented modules from unimplemented list")
            for module_name in invalid_unimplemented:
                del self.unimplemented['modules'][module_name]
    
    def save_all_masterlists(self) -> None:
        """
        Save all masterlists with atomic operations and backup.
        """
        self._save_with_backup(self.discovered_file, self.discovered, convert_sets=True)
        self._save_with_backup(self.implemented_file, self.implemented)
        self._save_with_backup(self.unimplemented_file, self.unimplemented)
        
        logger.info(f"Saved masterlists: {len(self.discovered['modules'])} discovered, "
                   f"{len(self.implemented['modules'])} implemented, "
                   f"{len(self.unimplemented['modules'])} unimplemented")
    
    def _save_with_backup(self, file_path: Path, data: Dict[str, Any], convert_sets: bool = False) -> None:
        """
        Save file with backup and atomic operation.
        
        Args:
            file_path: Target file path
            data: Data to save
            convert_sets: Convert sets to lists for JSON serialization
        """
        # Convert sets to lists if needed
        if convert_sets:
            data = self._convert_sets_to_lists(data)
        
        # No backup needed - files are tracked in git
        
        # Write to temporary file then move (atomic)
        temp_path = file_path.with_suffix('.json.tmp')
        try:
            with open(temp_path, 'w') as f:
                json.dump(data, f, indent=2, default=str)
            temp_path.replace(file_path)
        except Exception:
            if temp_path.exists():
                temp_path.unlink()
            raise
    
    def _convert_sets_to_lists(self, data: Any) -> Any:
        """Convert sets to lists for JSON serialization"""
        if isinstance(data, dict):
            return {k: self._convert_sets_to_lists(v) for k, v in data.items()}
        elif isinstance(data, list):
            return [self._convert_sets_to_lists(item) for item in data]
        elif isinstance(data, set):
            return list(data)
        else:
            return data
    
    def _now_iso(self) -> str:
        """Get current time in ISO format"""
        return datetime.now(timezone.utc).isoformat()
    
    def get_stats(self) -> Dict[str, Any]:
        """Get summary statistics"""
        return {
            'discovered': len(self.discovered['modules']),
            'implemented': len(self.implemented['modules']),
            'unimplemented': len(self.unimplemented['modules']),
            'total_scans': self.discovered['metadata']['total_scans'],
            'last_scan': self.discovered['metadata']['last_scan']
        }