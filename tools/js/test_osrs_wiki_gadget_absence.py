#!/usr/bin/env python3
"""Wiki gadget JS must not be bundled, generated, or loaded by the apps."""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class OsrsWikiGadgetAbsenceTests(unittest.TestCase):
    def test_gadget_source_and_extractor_are_gone(self) -> None:
        forbidden = [
            ROOT / "shared" / "js" / "mediawiki" / "gadget_calc_core.js",
            ROOT / "shared" / "js" / "mediawiki" / "page_modules.js",
            ROOT / "shared" / "js" / "mediawiki" / "page_bootstrap.js",
            ROOT
            / "platforms"
            / "android"
            / "app"
            / "src"
            / "main"
            / "assets"
            / "mediawiki"
            / "gadget_calc_core.js",
            ROOT
            / "platforms"
            / "android"
            / "app"
            / "src"
            / "main"
            / "assets"
            / "mediawiki"
            / "page_modules.js",
            ROOT
            / "platforms"
            / "ios"
            / "osrswiki"
            / "Assets"
            / "js"
            / "mediawiki"
            / "gadget_calc_core.js",
            ROOT / "tools" / "js" / "extract-gadget-calc-core.py",
            ROOT / "shared" / "css" / "gadget_calc.css",
        ]
        for path in forbidden:
            self.assertFalse(path.exists(), f"{path} still ships wiki gadget source")

    def test_runtime_and_builders_do_not_load_gadgets(self) -> None:
        runtime = (ROOT / "shared" / "js" / "osrs_calculator_runtime.js").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("ext.gadget.", runtime)
        self.assertNotIn("mw.loader.load('ext.gadget.calc-core')", runtime)

        android_builder = (
            ROOT
            / "platforms"
            / "android"
            / "app"
            / "src"
            / "main"
            / "java"
            / "com"
            / "omiyawaki"
            / "osrswiki"
            / "page"
            / "PageHtmlBuilder.kt"
        ).read_text(encoding="utf-8")
        ios_builder = (
            ROOT / "platforms" / "ios" / "osrswiki" / "Services" / "osrsPageHtmlBuilder.swift"
        ).read_text(encoding="utf-8")
        for builder in (android_builder, ios_builder):
            self.assertNotIn("gadget_calc_core.js", builder)
            self.assertNotIn("page_modules.js", builder)
            self.assertNotIn("gadget_calc.css", builder)
            self.assertIn("osrs_article_tooltips.js", builder)

        tooltip = ROOT / "shared" / "js" / "osrs_article_tooltips.js"
        self.assertTrue(tooltip.is_file())
        tooltip_text = tooltip.read_text(encoding="utf-8")
        self.assertNotIn("ext.gadget.", tooltip_text)
        self.assertNotIn("MediaWiki:Gadget", tooltip_text)

        android_registry = (
            ROOT
            / "platforms"
            / "android"
            / "app"
            / "src"
            / "main"
            / "java"
            / "com"
            / "omiyawaki"
            / "osrswiki"
            / "page"
            / "WikiModuleRegistry.kt"
        ).read_text(encoding="utf-8")
        ios_registry = (
            ROOT / "platforms" / "ios" / "osrswiki" / "Services" / "osrsWikiModuleRegistry.swift"
        ).read_text(encoding="utf-8")
        self.assertNotIn("ext.gadget.", android_registry)
        self.assertNotIn("ext.gadget.", ios_registry)


if __name__ == "__main__":
    unittest.main()
