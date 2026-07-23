# JS Module Discovery & Tracking System

Enhanced JavaScript module discovery and tracking system for the OSRS Wiki project. This system provides accumulative discovery, smart deduplication, and implementation tracking capabilities.

## Overview

The system maintains three core masterlists with guaranteed deduplication:

1. **`discovered_modules.json`** - Accumulative tracking of all modules ever discovered
2. **`implemented_modules.json`** - Mapping of wiki modules to app implementations  
3. **`unimplemented_modules.json`** - Prioritized TODO list of modules to implement

## Key Features

✅ **Accumulative Discovery** - Never loses module discoveries across scans  
✅ **Smart Deduplication** - Prevents duplicates at all levels  
✅ **Implementation Tracking** - Maps wiki modules to curated app implementations  
✅ **Priority Scoring** - Automatically prioritizes unimplemented modules  
✅ **Functional Overlap Detection** - Identifies similar modules with different names  
✅ **Progress Reporting** - Clear visibility into implementation coverage  

## Directory Structure

```
tools/js/
├── core/
│   ├── masterlist_manager.py     # Core deduplication & persistence
│   └── module_comparator.py      # Module comparison utilities
├── scanner/
│   ├── module_scanner.py         # Playwright-based module extraction
│   └── gadget_extractor.py       # Gadget discovery
├── analyzer/
│   ├── overlap_detector.py       # Functional similarity detection
│   ├── dependency_analyzer.py    # Module dependency mapping
│   └── priority_scorer.py        # Implementation priority scoring
├── masterlists/
│   ├── discovered_modules.json   # Accumulative discovery data
│   ├── implemented_modules.json  # App implementation mapping
│   └── unimplemented_modules.json # Prioritized TODO list
├── update_discovery.py           # Main orchestrator
├── initialize_masterlists.py     # Bootstrap from existing data
├── generate_report.py            # Comprehensive reporting
└── README.md                     # This file
```

## Quick Start

### 1. Initialize Masterlists

First, bootstrap the system from existing data:

```bash
cd tools/js
python3 initialize_masterlists.py
```

This creates initial masterlists from:
- Historical discovery data (if available)
- `WikiModuleRegistry.kt` (implemented modules)
- Existing app assets

### 2. Run Discovery

Scan wiki pages for new modules:

```bash
# Scan sample pages
python3 update_discovery.py

# Scan specific pages
python3 update_discovery.py --pages "Exchange:Abyssal_whip" "Attack" "Calculator:Smithing"

# View summary only
python3 update_discovery.py --summary-only
```

### 3. Generate Reports

Create comprehensive implementation reports:

```bash
# Generate full text report
python3 generate_report.py

# Save to file
python3 generate_report.py --output implementation_report.txt

# Export JSON data
python3 generate_report.py --json report_data.json
```

## Masterlist Formats

### Discovered Modules (`discovered_modules.json`)

Tracks all modules ever discovered with accumulative data:

```json
{
  "metadata": {
    "last_scan": "2025-08-15T10:00:00Z",
    "total_scans": 42,
    "total_unique_modules": 156
  },
  "modules": {
    "ext.gadget.GECharts": {
      "first_seen": "2025-01-15",
      "last_seen": "2025-08-15",
      "scan_count": 42,
      "pages_found_on": ["Exchange:Abyssal_whip", "Exchange:Dragon_claws"],
      "dependencies": ["jquery", "mediawiki.api"],
      "type": "gadget",
      "size_bytes": 15234
    }
  }
}
```

### Implemented Modules (`implemented_modules.json`)

Maps wiki modules to app implementations:

```json
{
  "modules": {
    "ge_charts": {
      "wiki_names": ["ext.gadget.GECharts", "ext.gadget.GECharts-core"],
      "app_files": ["web/ge_charts_init.js", "web/highcharts-stock.js"],
      "implementation_type": "custom_curated",
      "implemented_date": "2025-01-20",
      "functionality": "Grand Exchange price charts with interactive graphs"
    }
  }
}
```

### Unimplemented Modules (`unimplemented_modules.json`)

Prioritized TODO list for implementation:

```json
{
  "modules": {
    "ext.gadget.calculatorNS": {
      "priority_score": 850,
      "frequency_seen": 150,
      "pages_count": 45,
      "complexity": "medium",
      "dependencies_available": true,
      "dependencies": ["jquery", "mediawiki.util"],
      "similar_implemented": [],
      "notes": "Calculator framework widely used on many pages"
    }
  }
}
```

## Deduplication Guarantees

The system ensures clean, duplicate-free data through:

1. **Primary Key Uniqueness** - Module names are unique keys in each masterlist
2. **Set-Based Page Tracking** - Pages found on are stored as sets (no duplicate pages)
3. **Cross-Masterlist Validation** - Prevents modules from appearing in wrong lists
4. **Fuzzy Matching** - Identifies near-duplicates for manual review
5. **Atomic Operations** - Prevents data corruption during updates

## Priority Scoring

Unimplemented modules are automatically scored based on:

- **Frequency** - How often the module is discovered
- **Page Count** - Number of different pages using the module
- **Complexity** - Estimated implementation difficulty
- **Dependencies** - Whether required dependencies are available

Formula: `priority_score = frequency_seen × pages_count × complexity_multiplier`

## Overlap Detection

The system identifies functional overlap through:

- **Exact Name Matching** - Direct module name matches
- **Similarity Scoring** - Fuzzy string matching for similar names
- **Keyword Analysis** - Functional similarity based on keywords
- **Category Grouping** - Groups modules by functionality type

## Dependencies

Required Python packages:

```bash
# Install required packages
pip install playwright beautifulsoup4

# Install Playwright browsers
playwright install chromium
```

## Integration with Asset Pipeline

Add to `tools/asset-updater.py` for regular discovery:

```python
# In asset-updater.py
def update_js_modules():
    """Update JS module discovery"""
    subprocess.run([
        sys.executable, 
        "js/update_discovery.py"
    ], cwd=tools_dir)
```

## Workflow Examples

### Regular Discovery Scan

```bash
# Weekly discovery scan with specific ID
python3 update_discovery.py --scan-id "weekly_$(date +%Y%m%d)"
```

### Implementation Planning

```bash
# Generate report to identify top priorities
python3 generate_report.py --output weekly_report.txt

# Review overlap analysis for consolidation opportunities
python3 -c "
from analyzer.overlap_detector import OverlapDetector
from core.masterlist_manager import MasterlistManager

manager = MasterlistManager()
detector = OverlapDetector()
results = detector.detect_overlaps(
    manager.discovered['modules'], 
    manager.implemented['modules']
)
print(detector.generate_overlap_report(results))
"
```

### Adding New Implementations

When implementing a new module, update the implemented masterlist:

```python
from core.masterlist_manager import MasterlistManager

manager = MasterlistManager()
manager.add_implemented_module(
    impl_name="calculator_framework",
    wiki_names=["ext.gadget.calculatorNS", "ext.gadget.calc"],
    app_files=["web/calculator_framework.js"],
    functionality="Universal calculator framework for skill calculators"
)
manager.save_all_masterlists()
```

## Monitoring & Maintenance

- **Daily**: Check for scan errors in `discovery.log`
- **Weekly**: Run discovery scan and review reports
- **Monthly**: Review overlap analysis for consolidation opportunities
- **As needed**: Update implemented modules when new features are deployed

## Troubleshooting

### Common Issues

**"Module already implemented" error**: This means a wiki module is already mapped to an implementation. Use overlap detection to identify conflicts.

**Playwright timeout errors**: Increase timeout in `module_scanner.py` or check network connectivity.

**Missing masterlists**: Run `initialize_masterlists.py` to bootstrap from existing data.

### Debug Mode

Enable debug logging:

```bash
export PYTHONPATH="$(pwd)/tools"
python3 -c "
import logging
logging.basicConfig(level=logging.DEBUG)
# ... run your commands
"
```

## Contributing

When adding new features:

1. Maintain deduplication guarantees
2. Add validation checks  
3. Update this README
4. Test with sample data first
5. Ensure backward compatibility with existing masterlists