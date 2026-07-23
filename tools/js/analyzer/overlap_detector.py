#!/usr/bin/env python3
"""
Functional Overlap Detector

Detects functional overlap between discovered wiki modules and implemented app modules.
Helps identify:
- Modules that might be functionally equivalent but have different names
- Implementation gaps
- Consolidation opportunities
"""

import re
from typing import Dict, List, Tuple, Set
from difflib import SequenceMatcher

class OverlapDetector:
    """Detects functional overlap between wiki modules and app implementations"""
    
    def __init__(self):
        # Keywords that indicate similar functionality
        self.functionality_keywords = {
            'charts': ['chart', 'graph', 'plot', 'price', 'ge', 'exchange'],
            'collapsible': ['collaps', 'fold', 'expand', 'toggle', 'hide'],
            'tables': ['table', 'sort', 'filter', 'tablesort'],
            'tooltips': ['tooltip', 'hover', 'popup', 'hint'],
            'navigation': ['nav', 'menu', 'link', 'anchor'],
            'calculator': ['calc', 'calculate', 'compute', 'math'],
            'infobox': ['infobox', 'info', 'box', 'switch', 'tab'],
            'cite': ['cite', 'citation', 'reference', 'ref']
        }
    
    def detect_overlaps(self, discovered_modules: Dict[str, dict], 
                       implemented_modules: Dict[str, dict]) -> Dict[str, List[dict]]:
        """
        Detect overlaps between discovered and implemented modules.
        
        Args:
            discovered_modules: Dict of discovered module data
            implemented_modules: Dict of implemented module data
            
        Returns:
            Dict with overlap analysis results
        """
        results = {
            'exact_matches': [],
            'name_similarity': [],
            'functional_similarity': [],
            'keyword_matches': [],
            'potential_consolidations': []
        }
        
        # Get all wiki names from implemented modules
        implemented_wiki_names = set()
        impl_name_to_wiki_names = {}
        
        for impl_name, impl_data in implemented_modules.items():
            wiki_names = impl_data.get('wiki_names', [])
            implemented_wiki_names.update(wiki_names)
            impl_name_to_wiki_names[impl_name] = wiki_names
        
        # Check each discovered module
        for disc_module, disc_data in discovered_modules.items():
            # 1. Exact matches (already implemented)
            if disc_module in implemented_wiki_names:
                for impl_name, wiki_names in impl_name_to_wiki_names.items():
                    if disc_module in wiki_names:
                        results['exact_matches'].append({
                            'discovered_module': disc_module,
                            'implemented_as': impl_name,
                            'wiki_names': wiki_names
                        })
                        break
                continue
            
            # 2. Name similarity
            name_matches = self._find_name_similarities(disc_module, impl_name_to_wiki_names)
            if name_matches:
                results['name_similarity'].extend(name_matches)
            
            # 3. Functional similarity based on keywords
            functional_matches = self._find_functional_similarities(
                disc_module, disc_data, implemented_modules
            )
            if functional_matches:
                results['functional_similarity'].extend(functional_matches)
            
            # 4. Keyword matches
            keyword_matches = self._find_keyword_matches(disc_module, implemented_modules)
            if keyword_matches:
                results['keyword_matches'].extend(keyword_matches)
        
        # 5. Identify potential consolidations
        results['potential_consolidations'] = self._identify_consolidation_opportunities(
            discovered_modules, implemented_modules
        )
        
        return results
    
    def _find_name_similarities(self, disc_module: str, 
                               impl_name_to_wiki_names: Dict[str, List[str]]) -> List[dict]:
        """Find modules with similar names"""
        similarities = []
        disc_module_clean = self._clean_module_name(disc_module)
        
        for impl_name, wiki_names in impl_name_to_wiki_names.items():
            impl_name_clean = self._clean_module_name(impl_name)
            
            # Check similarity with implementation name
            name_ratio = SequenceMatcher(None, disc_module_clean, impl_name_clean).ratio()
            if name_ratio > 0.6:  # 60% similarity threshold
                similarities.append({
                    'discovered_module': disc_module,
                    'implemented_module': impl_name,
                    'similarity_score': name_ratio,
                    'comparison_type': 'impl_name'
                })
            
            # Check similarity with wiki names
            for wiki_name in wiki_names:
                wiki_name_clean = self._clean_module_name(wiki_name)
                wiki_ratio = SequenceMatcher(None, disc_module_clean, wiki_name_clean).ratio()
                if wiki_ratio > 0.8:  # Higher threshold for wiki names
                    similarities.append({
                        'discovered_module': disc_module,
                        'implemented_module': impl_name,
                        'similar_wiki_name': wiki_name,
                        'similarity_score': wiki_ratio,
                        'comparison_type': 'wiki_name'
                    })
        
        return similarities
    
    def _find_functional_similarities(self, disc_module: str, disc_data: dict,
                                    implemented_modules: Dict[str, dict]) -> List[dict]:
        """Find modules with similar functionality based on keywords"""
        similarities = []
        disc_keywords = self._extract_keywords(disc_module)
        
        for impl_name, impl_data in implemented_modules.items():
            impl_functionality = impl_data.get('functionality', '')
            impl_keywords = self._extract_keywords(impl_name + ' ' + impl_functionality)
            
            # Check for keyword overlap
            common_keywords = disc_keywords.intersection(impl_keywords)
            if common_keywords:
                # Calculate functionality score
                func_categories = self._categorize_by_functionality(disc_keywords, impl_keywords)
                if func_categories:
                    similarities.append({
                        'discovered_module': disc_module,
                        'implemented_module': impl_name,
                        'common_keywords': list(common_keywords),
                        'functionality_categories': func_categories,
                        'confidence': len(common_keywords) / max(len(disc_keywords), 1)
                    })
        
        return similarities
    
    def _find_keyword_matches(self, disc_module: str, 
                             implemented_modules: Dict[str, dict]) -> List[dict]:
        """Find keyword-based matches"""
        matches = []
        
        for category, keywords in self.functionality_keywords.items():
            disc_module_lower = disc_module.lower()
            
            # Check if discovered module contains category keywords
            if any(keyword in disc_module_lower for keyword in keywords):
                # Find implemented modules in same category
                for impl_name, impl_data in implemented_modules.items():
                    impl_text = (impl_name + ' ' + impl_data.get('functionality', '')).lower()
                    
                    if any(keyword in impl_text for keyword in keywords):
                        matches.append({
                            'discovered_module': disc_module,
                            'implemented_module': impl_name,
                            'category': category,
                            'matching_keywords': [k for k in keywords if k in disc_module_lower]
                        })
        
        return matches
    
    def _identify_consolidation_opportunities(self, discovered_modules: Dict[str, dict],
                                            implemented_modules: Dict[str, dict]) -> List[dict]:
        """Identify opportunities to consolidate similar modules"""
        opportunities = []
        
        # Group discovered modules by functionality
        functionality_groups = {}
        
        for module_name in discovered_modules.keys():
            categories = []
            module_lower = module_name.lower()
            
            for category, keywords in self.functionality_keywords.items():
                if any(keyword in module_lower for keyword in keywords):
                    categories.append(category)
            
            for category in categories:
                if category not in functionality_groups:
                    functionality_groups[category] = []
                functionality_groups[category].append(module_name)
        
        # Find groups with multiple modules that could be consolidated
        for category, modules in functionality_groups.items():
            if len(modules) > 1:
                # Check if any are already implemented
                implemented_in_category = []
                unimplemented_in_category = []
                
                for module in modules:
                    is_implemented = any(
                        module in impl_data.get('wiki_names', [])
                        for impl_data in implemented_modules.values()
                    )
                    
                    if is_implemented:
                        implemented_in_category.append(module)
                    else:
                        unimplemented_in_category.append(module)
                
                if implemented_in_category and unimplemented_in_category:
                    opportunities.append({
                        'category': category,
                        'implemented_modules': implemented_in_category,
                        'unimplemented_modules': unimplemented_in_category,
                        'suggestion': f"Consider extending existing {category} implementation to cover unimplemented modules"
                    })
        
        return opportunities
    
    def _clean_module_name(self, name: str) -> str:
        """Clean module name for comparison"""
        # Remove common prefixes
        name = re.sub(r'^(ext\.|ext\.gadget\.|mediawiki\.|jquery\.)', '', name)
        # Convert to lowercase and remove special chars
        name = re.sub(r'[^a-z0-9]', '', name.lower())
        return name
    
    def _extract_keywords(self, text: str) -> Set[str]:
        """Extract meaningful keywords from text"""
        text = text.lower()
        # Split on common separators and remove common words
        words = re.findall(r'[a-z]+', text)
        
        # Remove common words
        stop_words = {'ext', 'gadget', 'mediawiki', 'jquery', 'the', 'a', 'an', 'and', 'or', 'but', 'in', 'on', 'at', 'to', 'for', 'of', 'with', 'by'}
        keywords = {word for word in words if len(word) > 2 and word not in stop_words}
        
        return keywords
    
    def _categorize_by_functionality(self, disc_keywords: Set[str], 
                                   impl_keywords: Set[str]) -> List[str]:
        """Categorize overlap by functionality type"""
        categories = []
        
        for category, keywords in self.functionality_keywords.items():
            category_keywords = set(keywords)
            
            # Check if both modules have keywords in this category
            disc_matches = disc_keywords.intersection(category_keywords)
            impl_matches = impl_keywords.intersection(category_keywords)
            
            if disc_matches and impl_matches:
                categories.append(category)
        
        return categories
    
    def generate_overlap_report(self, overlap_results: Dict[str, List[dict]]) -> str:
        """Generate a formatted overlap report"""
        report = []
        report.append("=" * 60)
        report.append("JS MODULE OVERLAP ANALYSIS REPORT")
        report.append("=" * 60)
        
        # Exact matches
        exact_matches = overlap_results.get('exact_matches', [])
        report.append(f"\n1. EXACT MATCHES ({len(exact_matches)} found)")
        report.append("-" * 40)
        for match in exact_matches:
            report.append(f"   ✓ {match['discovered_module']}")
            report.append(f"     → Implemented as: {match['implemented_as']}")
        
        # Name similarities
        name_sims = overlap_results.get('name_similarity', [])
        report.append(f"\n2. NAME SIMILARITIES ({len(name_sims)} found)")
        report.append("-" * 40)
        for sim in name_sims:
            report.append(f"   ~ {sim['discovered_module']}")
            report.append(f"     → Similar to: {sim['implemented_module']} ({sim['similarity_score']:.2f})")
        
        # Functional similarities
        func_sims = overlap_results.get('functional_similarity', [])
        report.append(f"\n3. FUNCTIONAL SIMILARITIES ({len(func_sims)} found)")
        report.append("-" * 40)
        for sim in func_sims:
            report.append(f"   ? {sim['discovered_module']}")
            report.append(f"     → Possibly similar to: {sim['implemented_module']}")
            report.append(f"     → Categories: {', '.join(sim['functionality_categories'])}")
        
        # Consolidation opportunities
        consolidations = overlap_results.get('potential_consolidations', [])
        report.append(f"\n4. CONSOLIDATION OPPORTUNITIES ({len(consolidations)} found)")
        report.append("-" * 40)
        for opp in consolidations:
            report.append(f"   📦 {opp['category'].upper()} category:")
            report.append(f"      Implemented: {', '.join(opp['implemented_modules'])}")
            report.append(f"      Unimplemented: {', '.join(opp['unimplemented_modules'])}")
            report.append(f"      💡 {opp['suggestion']}")
        
        report.append("\n" + "=" * 60)
        
        return "\n".join(report)