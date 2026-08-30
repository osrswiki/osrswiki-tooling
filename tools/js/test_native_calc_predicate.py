#!/usr/bin/env python3
"""Predicate-flip contract: kit + exactly one jcConfig, recorded family fixtures."""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from wiki_calculator_catalog import (
    classify_calculator_family,
    count_jcconfigs,
    native_chrome_eligible,
    page_native_chrome_eligible,
    parse_calc_definition,
)

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tools" / "js" / "fixtures" / "native_calc"
CLASSIFICATION = FIXTURES / "family_classification.json"
CATALOG = ROOT / "shared" / "manifests" / "osrs-wiki-calculators.json"


def _html(name: str) -> str:
    return (FIXTURES / name).read_text(encoding="utf-8")


class NativeCalcPredicateTests(unittest.TestCase):
    def test_dry_calc_module_kit_is_eligible(self) -> None:
        html = _html("dry_calc.html")
        definition = parse_calc_definition(html, title="Calculator:Dry calc")
        self.assertEqual(count_jcconfigs(html), 1)
        self.assertEqual(classify_calculator_family(html, definition), "D")
        self.assertTrue(native_chrome_eligible(definition))
        self.assertTrue(page_native_chrome_eligible(html, "Calculator:Dry calc"))
        self.assertEqual(definition["invoke"]["kind"], "module")
        self.assertEqual(definition["invoke"]["module"], "Dry calc")
        self.assertEqual(definition["unknown_types"], [])

    def test_barrows_group_stays_on_gadget(self) -> None:
        html = _html("barrows.html")
        definition = parse_calc_definition(html, title="Calculator:Barrows")
        self.assertEqual(count_jcconfigs(html), 1)
        self.assertEqual(classify_calculator_family(html, definition), "C")
        self.assertIn("group", definition["unknown_types"])
        self.assertFalse(native_chrome_eligible(definition))
        self.assertFalse(page_native_chrome_eligible(html, "Calculator:Barrows"))

    def test_coordinates_two_configs_are_not_eligible(self) -> None:
        html = _html("coordinates.html")
        definition = parse_calc_definition(html, title="Calculator:Coordinates")
        self.assertEqual(count_jcconfigs(html), 2)
        self.assertEqual(classify_calculator_family(html, definition), "multi")
        self.assertTrue(native_chrome_eligible(definition))
        self.assertFalse(page_native_chrome_eligible(html, "Calculator:Coordinates"))

    def test_static_calculator_has_no_native_slot(self) -> None:
        html = _html("static_prayer_bones.html")
        self.assertEqual(count_jcconfigs(html), 0)
        self.assertEqual(classify_calculator_family(html), "E")
        self.assertFalse(page_native_chrome_eligible(html, "Calculator:Prayer/Bones"))
        self.assertIsNone(parse_calc_definition(html, title="Calculator:Prayer/Bones"))

    def test_recorded_family_counts_match_classification_file(self) -> None:
        recorded = json.loads(CLASSIFICATION.read_text(encoding="utf-8"))
        pages = recorded["pages"]
        counts: dict[str, int] = {}
        eligible = 0
        for page in pages:
            family = page["family"]
            counts[family] = counts.get(family, 0) + 1
            if page["eligible"]:
                eligible += 1
            if family in {"A", "B", "D"}:
                self.assertEqual(page["jcconfig_count"], 1, page["title"])
                self.assertFalse(page["unknown_types"], page["title"])
                self.assertTrue(page["eligible"], page["title"])
            else:
                self.assertFalse(page["eligible"], page["title"])
        self.assertEqual(counts, recorded["family_counts"])
        self.assertEqual(eligible, recorded["eligible_count"])
        self.assertEqual(counts["A"], 18)
        self.assertEqual(counts["C"], 9)
        self.assertEqual(counts["multi"], 1)
        self.assertEqual(eligible, counts["A"] + counts["B"] + counts["D"])
        titles = {page["title"]: page for page in pages}
        self.assertEqual(titles["Calculator:Dry calc"]["family"], "D")
        self.assertEqual(titles["Calculator:Barrows"]["family"], "C")
        self.assertEqual(titles["Calculator:Coordinates"]["family"], "multi")
        self.assertEqual(titles["Calculator:Agility"]["family"], "A")
        self.assertEqual(titles["Calculator:Combat level"]["family"], "B")
        self.assertEqual(titles["Calculator:Prayer/Bones"]["family"], "E")

    def test_catalog_drops_redirects_and_keeps_excluding_templates(self) -> None:
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
        self.assertIn("apfilterredir=nonredirects", catalog["source"])
        titles = [entry["title"] for entry in catalog["calculators"]]
        self.assertNotIn("Calculator:Lamp", titles)
        self.assertNotIn("Calculator:Slayer", titles)
        self.assertIn("Calculator:Agility", titles)
        self.assertIn("Calculator:Dry calc", titles)
        excluded_reasons = {entry["reason"] for entry in catalog["excluded"]}
        self.assertTrue({"template", "documentation", "sandbox"} & excluded_reasons)


    def test_shared_js_copies_keep_byte_parity(self) -> None:
        pairs = [
            (
                ROOT / "shared" / "js" / "osrs_native_calc_indoc.js",
                ROOT / "platforms" / "android" / "app" / "src" / "main" / "assets" / "web" / "osrs_native_calc_indoc.js",
            ),
            (
                ROOT / "shared" / "js" / "osrs_native_calc_indoc.js",
                ROOT / "platforms" / "ios" / "osrswiki" / "Assets" / "web" / "osrs_native_calc_indoc.js",
            ),
            (
                ROOT / "shared" / "js" / "osrs_calculator_runtime.js",
                ROOT / "platforms" / "android" / "app" / "src" / "main" / "assets" / "web" / "osrs_calculator_runtime.js",
            ),
            (
                ROOT / "shared" / "js" / "osrs_calculator_runtime.js",
                ROOT / "platforms" / "android" / "app" / "src" / "main" / "assets" / "js" / "osrs_calculator_runtime.js",
            ),
            (
                ROOT / "shared" / "js" / "osrs_calculator_runtime.js",
                ROOT / "platforms" / "ios" / "osrswiki" / "Assets" / "web" / "osrs_calculator_runtime.js",
            ),
            (
                ROOT / "shared" / "js" / "mediawiki" / "gadget_calc_core.js",
                ROOT / "platforms" / "android" / "app" / "src" / "main" / "assets" / "mediawiki" / "gadget_calc_core.js",
            ),
            (
                ROOT / "shared" / "js" / "mediawiki" / "gadget_calc_core.js",
                ROOT / "platforms" / "ios" / "osrswiki" / "Assets" / "js" / "mediawiki" / "gadget_calc_core.js",
            ),
        ]
        for shared, copy in pairs:
            self.assertEqual(shared.read_bytes(), copy.read_bytes(), f"{copy} drifted from {shared}")


if __name__ == "__main__":
    unittest.main()
