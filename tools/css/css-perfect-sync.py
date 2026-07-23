#!/usr/bin/env python3
"""
CSS Perfect Sync System - Dynamic Reference-Based Perfect Parity
Automatically achieves perfect CSS parity with any reference CSS size.
"""

import json
import re
import subprocess
from datetime import datetime
from typing import Dict, List, Tuple, Optional, Set
from dataclasses import dataclass, field
from pathlib import Path
import hashlib


@dataclass
class CSSRule:
    """Represents a single CSS rule."""
    selector: str
    properties: Dict[str, str]
    source_file: Optional[str] = None
    line_number: Optional[int] = None
    
    def get_hash(self) -> str:
        """Generate unique hash for this rule."""
        content = f"{self.selector}:{json.dumps(self.properties, sort_keys=True)}"
        return hashlib.md5(content.encode()).hexdigest()


@dataclass
class ReferenceProfile:
    """Profile of reference CSS characteristics."""
    total_rules: int
    rules: List[CSSRule]
    rule_patterns: Dict[str, int] = field(default_factory=dict)
    selector_types: Dict[str, int] = field(default_factory=dict)
    admin_rules: Set[str] = field(default_factory=set)
    user_rules: Set[str] = field(default_factory=set)
    last_updated: datetime = field(default_factory=datetime.now)
    
    def get_hash(self) -> str:
        """Generate hash for reference version tracking."""
        rule_hashes = [rule.get_hash() for rule in self.rules]
        content = f"{self.total_rules}:{':'.join(sorted(rule_hashes))}"
        return hashlib.md5(content.encode()).hexdigest()


@dataclass
class CoverageAnalysis:
    """Analysis of current CSS coverage against reference."""
    target_rules: int
    local_rules: int
    coverage_percent: float
    missing_rules: List[CSSRule]
    extra_rules: List[CSSRule]
    matched_rules: List[Tuple[CSSRule, CSSRule]]  # (reference, local)
    is_perfect: bool = False
    
    @property
    def summary(self) -> str:
        return (f"Coverage: {self.coverage_percent:.1f}% "
                f"({self.local_rules}/{self.target_rules} rules, "
                f"{len(self.missing_rules)} missing, {len(self.extra_rules)} extra)")


@dataclass
class SyncPlan:
    """Plan for achieving perfect CSS synchronization."""
    reference_profile: ReferenceProfile
    missing_rules: List[CSSRule]
    extra_rules: List[CSSRule]
    rules_to_generate: List[CSSRule]
    rules_to_remove: List[CSSRule]
    estimated_final_count: int
    
    @property
    def summary(self) -> str:
        return (f"Sync Plan: Generate {len(self.rules_to_generate)} rules, "
                f"Remove {len(self.rules_to_remove)} rules, "
                f"Target: {self.estimated_final_count} rules")


class DynamicReferenceAnalyzer:
    """Analyzes reference CSS dynamically to create flexible targets."""
    
    def __init__(self, config: Dict):
        self.config = config
        self.cache_file = Path("tools/css/output/reference_profile_cache.json")
        
    def fetch_and_analyze_reference(self, reference_urls: List[str]) -> ReferenceProfile:
        """Fetch reference CSS from multiple sources and create dynamic profile."""
        print(f"📡 Fetching reference CSS from {len(reference_urls)} sources")
        
        # Check cache first
        cached_profile = self._load_cached_profile()
        if cached_profile and self._is_cache_valid(cached_profile):
            print(f"📋 Using cached reference profile: {cached_profile.total_rules} rules")
            return cached_profile
        
        # Fetch fresh reference from all URLs
        combined_css_content = ""
        for i, url in enumerate(reference_urls):
            print(f"📡 Fetching source {i+1}/{len(reference_urls)}: {url[:80]}...")
            try:
                result = subprocess.run([
                    'curl', '-s', '--max-time', '30', url
                ], capture_output=True, text=True, check=True)
                css_content = result.stdout
                if css_content.strip():
                    combined_css_content += f"\n/* Source {i+1}: {url} */\n{css_content}\n"
                else:
                    print(f"⚠️ Empty response from source {i+1}, continuing with other sources")
            except subprocess.CalledProcessError as e:
                print(f"⚠️ Failed to fetch source {i+1}: {e} (continuing with other sources)")
                continue
        
        if not combined_css_content.strip():
            print(f"❌ No CSS content retrieved from any source")
            if cached_profile:
                print("📋 Falling back to cached profile")
                return cached_profile
            raise Exception("No CSS content retrieved from any source")
        
        # Analyze combined reference CSS
        print("🔍 Analyzing combined reference CSS structure...")
        profile = self._analyze_css_content(combined_css_content)
        
        # Cache the profile
        self._cache_profile(profile)
        
        print(f"✅ Reference analysis complete: {profile.total_rules} rules discovered")
        return profile
    
    def _analyze_css_content(self, css_content: str) -> ReferenceProfile:
        """Analyze CSS content to create reference profile."""
        rules = self._parse_css_rules(css_content)
        
        profile = ReferenceProfile(
            total_rules=len(rules),
            rules=rules
        )
        
        # Analyze rule patterns
        profile.rule_patterns = self._analyze_rule_patterns(rules)
        profile.selector_types = self._analyze_selector_types(rules)
        profile.admin_rules, profile.user_rules = self._classify_rules(rules)
        
        return profile
    
    def _parse_css_rules(self, css_content: str) -> List[CSSRule]:
        """Parse CSS content into structured rules."""
        rules = []
        
        # Remove comments and normalize whitespace
        css_content = re.sub(r'/\*.*?\*/', '', css_content, flags=re.DOTALL)
        css_content = re.sub(r'\s+', ' ', css_content)
        
        # Extract rules using regex
        rule_pattern = r'([^{}]+)\s*\{([^{}]*)\}'
        matches = re.finditer(rule_pattern, css_content)
        
        for match in matches:
            selector = match.group(1).strip()
            properties_block = match.group(2).strip()
            
            if not selector or not properties_block:
                continue
            
            # Parse properties
            properties = {}
            prop_pattern = r'([^:;]+)\s*:\s*([^;]+)'
            prop_matches = re.finditer(prop_pattern, properties_block)
            
            for prop_match in prop_matches:
                prop_name = prop_match.group(1).strip()
                prop_value = prop_match.group(2).strip()
                if prop_name and prop_value:
                    properties[prop_name] = prop_value
            
            if properties:
                rules.append(CSSRule(
                    selector=selector,
                    properties=properties
                ))
        
        return rules
    
    def _analyze_rule_patterns(self, rules: List[CSSRule]) -> Dict[str, int]:
        """Analyze common patterns in CSS rules."""
        patterns = {
            'class_selectors': 0,
            'id_selectors': 0,
            'element_selectors': 0,
            'pseudo_selectors': 0,
            'combined_selectors': 0,
            'media_queries': 0
        }
        
        for rule in rules:
            selector = rule.selector
            
            if selector.startswith('.'):
                patterns['class_selectors'] += 1
            elif selector.startswith('#'):
                patterns['id_selectors'] += 1
            elif ':' in selector:
                patterns['pseudo_selectors'] += 1
            elif ',' in selector:
                patterns['combined_selectors'] += 1
            elif '@media' in selector:
                patterns['media_queries'] += 1
            else:
                patterns['element_selectors'] += 1
        
        return patterns
    
    def _analyze_selector_types(self, rules: List[CSSRule]) -> Dict[str, int]:
        """Categorize selectors by type."""
        types = {
            'simple': 0,
            'complex': 0,
            'combined': 0,
            'pseudo': 0
        }
        
        for rule in rules:
            selector = rule.selector
            
            if ',' in selector:
                types['combined'] += 1
            elif ':' in selector:
                types['pseudo'] += 1
            elif ' ' in selector or '>' in selector or '+' in selector:
                types['complex'] += 1
            else:
                types['simple'] += 1
        
        return types
    
    def _classify_rules(self, rules: List[CSSRule]) -> Tuple[Set[str], Set[str]]:
        """Classify rules as admin-only vs user-facing."""
        admin_patterns = [
            'mw-abusefilter', 'mw-allmessages', 'mw-special', 'mw-preferences',
            'oo-ui-window', 'oo-ui-dialog', 've-ui', 'mw-rcfilters',
            'mw-echo', 'mw-notification', 'mediawiki-', 'wikibase-'
        ]
        
        admin_rules = set()
        user_rules = set()
        
        for rule in rules:
            selector = rule.selector.lower()
            is_admin = any(pattern in selector for pattern in admin_patterns)
            
            if is_admin:
                admin_rules.add(rule.selector)
            else:
                user_rules.add(rule.selector)
        
        return admin_rules, user_rules
    
    def _load_cached_profile(self) -> Optional[ReferenceProfile]:
        """Load cached reference profile if available."""
        if not self.cache_file.exists():
            return None
        
        try:
            with open(self.cache_file, 'r') as f:
                data = json.load(f)
            
            # Reconstruct profile from cached data
            rules = [
                CSSRule(
                    selector=rule_data['selector'],
                    properties=rule_data['properties']
                )
                for rule_data in data['rules']
            ]
            
            return ReferenceProfile(
                total_rules=data['total_rules'],
                rules=rules,
                rule_patterns=data['rule_patterns'],
                selector_types=data['selector_types'],
                admin_rules=set(data['admin_rules']),
                user_rules=set(data['user_rules']),
                last_updated=datetime.fromisoformat(data['last_updated'])
            )
        except Exception as e:
            print(f"⚠️  Failed to load cached profile: {e}")
            return None
    
    def _cache_profile(self, profile: ReferenceProfile) -> None:
        """Cache reference profile for future use."""
        try:
            self.cache_file.parent.mkdir(parents=True, exist_ok=True)
            
            data = {
                'total_rules': profile.total_rules,
                'rules': [
                    {
                        'selector': rule.selector,
                        'properties': rule.properties
                    }
                    for rule in profile.rules
                ],
                'rule_patterns': profile.rule_patterns,
                'selector_types': profile.selector_types,
                'admin_rules': list(profile.admin_rules),
                'user_rules': list(profile.user_rules),
                'last_updated': profile.last_updated.isoformat()
            }
            
            with open(self.cache_file, 'w') as f:
                json.dump(data, f, indent=2)
            
            print(f"💾 Cached reference profile: {self.cache_file}")
        except Exception as e:
            print(f"⚠️  Failed to cache profile: {e}")
    
    def _is_cache_valid(self, profile: ReferenceProfile) -> bool:
        """Check if cached profile is still valid."""
        cache_duration = self.config.get('reference_source', {}).get('cache_duration', '1h')
        
        # Parse cache duration
        if cache_duration.endswith('h'):
            max_age_hours = int(cache_duration[:-1])
        elif cache_duration.endswith('m'):
            max_age_hours = int(cache_duration[:-1]) / 60
        else:
            max_age_hours = 1  # Default 1 hour
        
        age = datetime.now() - profile.last_updated
        return age.total_seconds() < (max_age_hours * 3600)


class AdaptiveCoverageAnalyzer:
    """Analyzes coverage against dynamic reference."""
    
    def __init__(self, config: Dict):
        self.config = config
    
    def analyze_coverage(self, reference_profile: ReferenceProfile, local_css_path: str) -> CoverageAnalysis:
        """Analyze current CSS coverage against reference."""
        print(f"📊 Analyzing coverage against {reference_profile.total_rules} reference rules...")
        
        # Load local CSS
        local_rules = self._load_local_css(local_css_path)
        
        # Create rule mapping
        mapping = self._create_rule_mapping(reference_profile.rules, local_rules)
        
        # Calculate coverage metrics
        coverage_percent = (len(mapping['matched']) / reference_profile.total_rules) * 100
        
        analysis = CoverageAnalysis(
            target_rules=reference_profile.total_rules,
            local_rules=len(local_rules),
            coverage_percent=coverage_percent,
            missing_rules=mapping['missing'],
            extra_rules=mapping['extra'],
            matched_rules=mapping['matched'],
            is_perfect=(coverage_percent == 100.0 and len(mapping['extra']) == 0)
        )
        
        print(f"📈 {analysis.summary}")
        return analysis
    
    def _load_local_css(self, css_path: str) -> List[CSSRule]:
        """Load and parse local CSS file."""
        try:
            with open(css_path, 'r') as f:
                content = f.read()
            
            analyzer = DynamicReferenceAnalyzer({})
            return analyzer._parse_css_rules(content)
        except Exception as e:
            print(f"❌ Failed to load local CSS: {e}")
            return []
    
    def _create_rule_mapping(self, reference_rules: List[CSSRule], local_rules: List[CSSRule]) -> Dict:
        """Create mapping between reference and local rules."""
        mapping = {
            'matched': [],     # (reference_rule, local_rule) pairs
            'missing': [],     # reference rules without local match
            'extra': []        # local rules without reference match
        }
        
        # Create lookup for efficient matching
        local_by_selector = {rule.selector: rule for rule in local_rules}
        matched_local_selectors = set()
        
        # Find matches and missing rules
        for ref_rule in reference_rules:
            if ref_rule.selector in local_by_selector:
                local_rule = local_by_selector[ref_rule.selector]
                mapping['matched'].append((ref_rule, local_rule))
                matched_local_selectors.add(ref_rule.selector)
            else:
                mapping['missing'].append(ref_rule)
        
        # Find extra rules
        for local_rule in local_rules:
            if local_rule.selector not in matched_local_selectors:
                mapping['extra'].append(local_rule)
        
        return mapping


class AdaptiveRuleGenerator:
    """Generates missing CSS rules using intelligent property extraction."""
    
    def __init__(self, config: Dict):
        self.config = config
    
    def generate_missing_rules(self, missing_rules: List[CSSRule], reference_profile: ReferenceProfile) -> List[CSSRule]:
        """Generate missing rules with smart property extraction."""
        print(f"🔧 Generating {len(missing_rules)} missing rules...")
        
        generated_rules = []
        
        for rule in missing_rules:
            generated_rule = self._smart_generate_rule(rule, reference_profile)
            if generated_rule:
                generated_rules.append(generated_rule)
        
        print(f"✅ Generated {len(generated_rules)} rules successfully")
        return generated_rules
    
    def _smart_generate_rule(self, missing_rule: CSSRule, reference_profile: ReferenceProfile) -> Optional[CSSRule]:
        """Generate a single rule using context and patterns."""
        # Use the properties from the reference rule directly
        return CSSRule(
            selector=missing_rule.selector,
            properties=missing_rule.properties.copy(),
            source_file="generated"
        )


class IntelligentRulePruner:
    """Removes extra CSS rules while preserving essential functionality."""
    
    def __init__(self, config: Dict):
        self.config = config
        self.preservation_policy = config.get('preservation_rules', {})
    
    def create_pruning_plan(self, extra_rules: List[CSSRule], reference_profile: ReferenceProfile) -> List[CSSRule]:
        """Create plan for removing extra rules while preserving essentials."""
        print(f"🔍 Analyzing {len(extra_rules)} extra rules for removal...")
        
        # For perfect parity, we need to remove ALL extra rules except CSS variables
        rules_to_remove = []
        rules_to_preserve = []
        
        for rule in extra_rules:
            # Only preserve CSS variable rules that are absolutely essential
            if self._is_essential_css_variable_rule(rule):
                rules_to_preserve.append(rule)
            else:
                rules_to_remove.append(rule)
        
        print(f"📋 Pruning plan: Remove {len(rules_to_remove)} rules, Preserve {len(rules_to_preserve)} rules")
        
        # If we're still preserving too many rules for perfect parity, be even more aggressive
        max_preserve = reference_profile.total_rules // 10  # Allow max 10% CSS variables
        if len(rules_to_preserve) > max_preserve:
            print(f"⚠️  Too many preserved rules ({len(rules_to_preserve)} > {max_preserve}), being more aggressive...")
            # Sort by importance and keep only the most critical
            critical_rules = [rule for rule in rules_to_preserve if self._is_critical_theming_rule(rule)]
            rules_to_preserve = critical_rules[:max_preserve]
            # Move the rest to removal
            for rule in extra_rules:
                if rule not in rules_to_preserve:
                    if rule not in rules_to_remove:
                        rules_to_remove.append(rule)
            
            print(f"📋 Revised plan: Remove {len(rules_to_remove)} rules, Preserve {len(rules_to_preserve)} rules")
        
        return rules_to_remove
    
    def _should_preserve_rule(self, rule: CSSRule, reference_profile: ReferenceProfile) -> bool:
        """Determine if a rule should be preserved despite not being in reference."""
        selector = rule.selector.lower()
        
        # Preserve CSS variables if policy allows
        if self.preservation_policy.get('css_variables') == 'preserve_all':
            if self._is_css_variable_rule(rule):
                return True
        
        # Preserve essential theming if policy allows  
        if self.preservation_policy.get('theming_overrides') == 'preserve_essential':
            if self._is_essential_theming_rule(rule):
                return True
        
        # Remove local enhancements if policy requires
        if self.preservation_policy.get('local_enhancements') == 'remove_all':
            return False
        
        return False
    
    def _is_css_variable_rule(self, rule: CSSRule) -> bool:
        """Check if rule defines or uses CSS variables."""
        # Check if rule defines CSS variables
        for prop_name, prop_value in rule.properties.items():
            if prop_name.startswith('--'):
                return True
            if 'var(--' in prop_value:
                return True
        return False
    
    def _is_essential_css_variable_rule(self, rule: CSSRule) -> bool:
        """Check if rule defines essential CSS variables only."""
        # Only preserve rules that DEFINE CSS variables (not just use them)
        for prop_name in rule.properties.keys():
            if prop_name.startswith('--'):
                return True
        return False
    
    def _is_critical_theming_rule(self, rule: CSSRule) -> bool:
        """Check if rule defines critical theme variables."""
        # Only preserve :root rules that define theme variables
        if rule.selector.strip() != ':root':
            return False
        
        # Check if it defines color/theme variables
        critical_vars = ['--color', '--background', '--border', '--text']
        for prop_name in rule.properties.keys():
            if any(var in prop_name for var in critical_vars):
                return True
        return False
    
    def _is_essential_theming_rule(self, rule: CSSRule) -> bool:
        """Check if rule is essential for theming."""
        essential_patterns = [
            'theme', 'color', 'background', 'border', 'shadow'
        ]
        selector = rule.selector.lower()
        
        return any(pattern in selector for pattern in essential_patterns)


class PerfectParityBuilder:
    """Builds CSS with perfect reference parity."""
    
    def __init__(self, config: Dict):
        self.config = config
    
    def build_perfect_css(self, reference_profile: ReferenceProfile, current_rules: List[CSSRule], 
                         generated_rules: List[CSSRule], rules_to_remove: List[CSSRule]) -> str:
        """Build CSS with exactly the reference rule count."""
        print(f"🏗️  Building perfect CSS with {reference_profile.total_rules} rules...")
        
        # Create final rule set with deduplication
        final_rules = []
        seen_selectors = set()
        
        # First, add current rules that should be kept (and exist in reference)
        rules_to_remove_selectors = {rule.selector for rule in rules_to_remove}
        reference_selectors = {rule.selector for rule in reference_profile.rules}
        
        for rule in current_rules:
            if (rule.selector not in rules_to_remove_selectors and 
                rule.selector in reference_selectors and
                rule.selector not in seen_selectors):
                final_rules.append(rule)
                seen_selectors.add(rule.selector)
        
        # Then add generated rules for missing selectors
        generated_count = 0
        for rule in generated_rules:
            if rule.selector not in seen_selectors:
                final_rules.append(rule)
                seen_selectors.add(rule.selector)
                generated_count += 1
        
        # Debug: Check if we have all reference selectors
        missing_from_final = reference_selectors - seen_selectors
        if missing_from_final:
            print(f"⚠️  Still missing {len(missing_from_final)} reference selectors after building")
        
        # Build CSS content
        css_content = self._build_css_content(final_rules)
        
        print(f"✅ Built CSS with {len(final_rules)} rules")
        print(f"📊 Rule breakdown:")
        print(f"   • Kept existing: {len(final_rules) - generated_count}")
        print(f"   • Generated new: {generated_count}")
        print(f"   • Reference has: {len(reference_selectors)} unique selectors")
        print(f"   • Final has: {len(seen_selectors)} unique selectors")
        print(f"   • Target: {reference_profile.total_rules}")
        
        return css_content
    
    def _build_css_content(self, rules: List[CSSRule]) -> str:
        """Convert rules back to CSS format."""
        lines = []
        lines.append("/*")
        lines.append(" * Perfect CSS Sync - Generated CSS")
        lines.append(f" * Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        lines.append(f" * Total Rules: {len(rules)}")
        lines.append(" */")
        lines.append("")
        
        for rule in rules:
            lines.append(f"{rule.selector} {{")
            for prop_name, prop_value in rule.properties.items():
                lines.append(f"    {prop_name}: {prop_value};")
            lines.append("}")
            lines.append("")
        
        return '\n'.join(lines)


class DynamicValidator:
    """Validates perfect CSS parity against dynamic reference."""
    
    def __init__(self, config: Dict):
        self.config = config
    
    def validate_perfect_parity(self, reference_profile: ReferenceProfile, css_content: str) -> Dict:
        """Validate that CSS achieves perfect parity with reference."""
        print(f"🔍 Validating perfect parity against {reference_profile.total_rules} reference rules...")
        
        # Parse generated CSS
        analyzer = DynamicReferenceAnalyzer({})
        generated_rules = analyzer._parse_css_rules(css_content)
        
        # Perform validation checks
        validation = {
            'rule_count_match': len(generated_rules) == reference_profile.total_rules,
            'actual_rule_count': len(generated_rules),
            'target_rule_count': reference_profile.total_rules,
            'coverage_perfect': False,
            'no_extra_rules': False,
            'is_perfect': False,
            'errors': []
        }
        
        # Check rule count
        if not validation['rule_count_match']:
            validation['errors'].append(
                f"Rule count mismatch: {validation['actual_rule_count']} != {validation['target_rule_count']}"
            )
        
        # Check coverage (simplified for now)
        reference_selectors = {rule.selector for rule in reference_profile.rules}
        generated_selectors = {rule.selector for rule in generated_rules}
        
        missing_selectors = reference_selectors - generated_selectors
        extra_selectors = generated_selectors - reference_selectors
        
        validation['coverage_perfect'] = len(missing_selectors) == 0
        validation['no_extra_rules'] = len(extra_selectors) == 0
        
        if missing_selectors:
            validation['errors'].append(f"Missing {len(missing_selectors)} reference selectors")
        
        if extra_selectors:
            validation['errors'].append(f"Found {len(extra_selectors)} extra selectors")
        
        # Overall validation
        validation['is_perfect'] = (
            validation['rule_count_match'] and 
            validation['coverage_perfect'] and 
            validation['no_extra_rules']
        )
        
        if validation['is_perfect']:
            print("✅ Perfect parity validation passed!")
        else:
            print(f"❌ Validation failed: {', '.join(validation['errors'])}")
        
        return validation


def load_config(config_path: str = "tools/css/css-perfect-sync.yml") -> Dict:
    """Load configuration with sensible defaults."""
    default_config = {
        'sync_policy': {
            'target_coverage': 100.0,
            'allow_extra_rules': False
        },
        'preservation_rules': {
            'css_variables': 'preserve_all',
            'theming_overrides': 'preserve_essential',
            'local_enhancements': 'remove_all'
        },
        'reference_source': {
            'urls': [
                'https://oldschool.runescape.wiki/load.php?lang=en&modules=site.styles&only=styles',
                'https://oldschool.runescape.wiki/w/MediaWiki:Vector.css?action=raw',
                'https://oldschool.runescape.wiki/w/MediaWiki:Common.css?action=raw',
                'https://oldschool.runescape.wiki/load.php?lang=en-gb&modules=ext.cite.styles%7Cext.embedVideo.styles%7Cext.visualEditor.desktopArticleTarget.noscript%7Cjquery.makeCollapsible.styles%7Cjquery.tablesorter.styles%7Cskins.vector.search.codex.styles%7Cskins.vector.styles.legacy&only=styles&skin=vector',
                'https://oldschool.runescape.wiki/load.php?lang=en-gb&modules=ext.gadget.articlefeedback-styles%2CfalseSubpage%2CheaderTargetHighlight%2CstickyTableHeaders%2Cswitch-infobox-styles&only=styles&skin=vector'
            ],
            'auto_update': True,
            'cache_duration': '1h'
        },
        'validation': {
            'require_exact_match': True,
            'allow_css_variable_substitution': True
        }
    }
    
    # For now, just use defaults - YAML parsing can be added later if needed
    print("📋 Using default configuration")
    return default_config


def main():
    """Main entry point for CSS Perfect Sync."""
    print("🚀 CSS Perfect Sync System - Dynamic Perfect Parity")
    print("=" * 60)
    
    # Load configuration
    config = load_config()
    
    # Initialize all components
    reference_analyzer = DynamicReferenceAnalyzer(config)
    coverage_analyzer = AdaptiveCoverageAnalyzer(config)
    rule_generator = AdaptiveRuleGenerator(config)
    rule_pruner = IntelligentRulePruner(config)
    css_builder = PerfectParityBuilder(config)
    validator = DynamicValidator(config)
    
    try:
        # Step 1: Analyze reference CSS dynamically
        print("\n🔍 Step 1: Analyzing Reference CSS")
        reference_profile = reference_analyzer.fetch_and_analyze_reference(
            config['reference_source']['urls']
        )
        
        # Step 2: Analyze current coverage
        print("\n📊 Step 2: Analyzing Current Coverage")
        local_css_path = "shared/css/wiki-integration.css"
        coverage_analysis = coverage_analyzer.analyze_coverage(reference_profile, local_css_path)
        
        # Report current state
        print("\n📋 Current State Analysis:")
        print(f"   Reference: {reference_profile.total_rules} rules")
        print(f"   Local: {coverage_analysis.local_rules} rules") 
        print(f"   Coverage: {coverage_analysis.coverage_percent:.1f}%")
        print(f"   Missing: {len(coverage_analysis.missing_rules)} rules")
        print(f"   Extra: {len(coverage_analysis.extra_rules)} rules")
        print(f"   Perfect Parity: {'✅ YES' if coverage_analysis.is_perfect else '❌ NO'}")
        
        if coverage_analysis.is_perfect:
            print("\n🎉 Perfect parity already achieved! No changes needed.")
            return 0
        
        # Step 3: Generate missing rules  
        print(f"\n🔧 Step 3: Generating Missing Rules")
        generated_rules = rule_generator.generate_missing_rules(
            coverage_analysis.missing_rules, reference_profile
        )
        
        # Step 4: Create pruning plan
        print(f"\n✂️  Step 4: Creating Pruning Plan") 
        rules_to_remove = rule_pruner.create_pruning_plan(
            coverage_analysis.extra_rules, reference_profile
        )
        
        # Step 5: Build perfect CSS
        print(f"\n🏗️  Step 5: Building Perfect CSS")
        current_rules = coverage_analyzer._load_local_css(local_css_path)
        perfect_css = css_builder.build_perfect_css(
            reference_profile, current_rules, generated_rules, rules_to_remove
        )
        
        # Step 6: Validate perfect parity
        print(f"\n🔍 Step 6: Validating Perfect Parity")
        validation = validator.validate_perfect_parity(reference_profile, perfect_css)
        
        # Step 7: Report results
        print(f"\n📋 Perfect Sync Results:")
        print(f"   Target Rules: {validation['target_rule_count']}")
        print(f"   Generated Rules: {validation['actual_rule_count']}")
        print(f"   Rule Count Match: {'✅' if validation['rule_count_match'] else '❌'}")
        print(f"   Coverage Perfect: {'✅' if validation['coverage_perfect'] else '❌'}")
        print(f"   No Extra Rules: {'✅' if validation['no_extra_rules'] else '❌'}")
        print(f"   Perfect Parity: {'✅' if validation['is_perfect'] else '❌'}")
        
        if validation['errors']:
            print(f"\n⚠️  Validation Issues:")
            for error in validation['errors']:
                print(f"   • {error}")
        
        # Step 8: Save results
        if validation['is_perfect']:
            output_path = "shared/css/wiki-integration-perfect.css"
            with open(output_path, 'w') as f:
                f.write(perfect_css)
            print(f"\n💾 Perfect CSS saved to: {output_path}")
            print(f"🎉 Perfect parity achieved! {reference_profile.total_rules} rules, 100% coverage")
        else:
            draft_path = "tools/css/output/perfect_css_draft.css"
            Path(draft_path).parent.mkdir(parents=True, exist_ok=True)
            with open(draft_path, 'w') as f:
                f.write(perfect_css)
            print(f"\n💾 Draft CSS saved to: {draft_path}")
            print("❌ Perfect parity not achieved - manual review required")
        
        # Save detailed analysis
        output_file = "tools/css/output/perfect_sync_analysis.json"
        analysis_data = {
            'timestamp': datetime.now().isoformat(),
            'reference_profile': {
                'total_rules': reference_profile.total_rules,
                'rule_patterns': reference_profile.rule_patterns,
                'selector_types': reference_profile.selector_types
            },
            'coverage_analysis': {
                'target_rules': coverage_analysis.target_rules,
                'local_rules': coverage_analysis.local_rules,
                'coverage_percent': coverage_analysis.coverage_percent,
                'missing_count': len(coverage_analysis.missing_rules),
                'extra_count': len(coverage_analysis.extra_rules),
                'is_perfect': coverage_analysis.is_perfect
            },
            'sync_results': {
                'generated_rules': len(generated_rules),
                'removed_rules': len(rules_to_remove),
                'final_rule_count': validation['actual_rule_count'],
                'validation_passed': validation['is_perfect'],
                'errors': validation['errors']
            }
        }
        
        Path(output_file).parent.mkdir(parents=True, exist_ok=True)
        with open(output_file, 'w') as f:
            json.dump(analysis_data, f, indent=2)
        
        print(f"\n💾 Detailed analysis saved to: {output_file}")
        
        return 0 if validation['is_perfect'] else 1
        
    except Exception as e:
        print(f"❌ Perfect sync failed: {e}")
        import traceback
        traceback.print_exc()
        return 1


if __name__ == '__main__':
    exit(main())