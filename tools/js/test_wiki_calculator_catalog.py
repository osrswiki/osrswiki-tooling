#!/usr/bin/env python3
"""Unit tests for wiki calculator catalog classification."""

from __future__ import annotations

import unittest

from wiki_calculator_catalog import (
    default_template_call,
    exclusion_reason,
    is_user_facing_calculator,
    wiki_url_for_title,
)


class WikiCalculatorCatalogTests(unittest.TestCase):
    def test_user_facing_titles(self) -> None:
        self.assertTrue(is_user_facing_calculator("Calculator:Combat level"))
        self.assertTrue(is_user_facing_calculator("Calculator:Crafting/Glass"))
        self.assertTrue(is_user_facing_calculator("Calculator:Barrows"))

    def test_excludes_templates_docs_and_sandboxes(self) -> None:
        self.assertFalse(is_user_facing_calculator("Calculator:Fletching/Ammo/Template1"))
        self.assertFalse(is_user_facing_calculator("Calculator:Herblore/Potions/Template:Clean"))
        self.assertFalse(is_user_facing_calculator("Calculator:Combat level/doc"))
        self.assertFalse(is_user_facing_calculator("Calculator:Foo/Sandbox"))
        self.assertFalse(is_user_facing_calculator("Calculator:Foo/Module"))
        self.assertEqual(exclusion_reason("Calculator:Combat level/Template"), "template")
        self.assertEqual(exclusion_reason("Calculator:Combat level/doc"), "documentation")
        self.assertEqual(exclusion_reason("Calculator:Foo/Sandbox"), "sandbox")

    def test_wiki_url(self) -> None:
        self.assertEqual(
            wiki_url_for_title("Calculator:Combat level"),
            "https://oldschool.runescape.wiki/w/Calculator:Combat_level",
        )

    def test_default_template_call_skips_hiscores_fields(self) -> None:
        html = """
        <pre class="jcConfig">
        template = Calculator:Combat level/Template
        param = attack|Attack|1|int|1-99
        param = playername|Player name||hs|attack,1,1
        </pre>
        """
        self.assertEqual(
            default_template_call(html),
            "{{Calculator:Combat level/Template|attack=1}}",
        )

    def test_module_calculator_uses_invoke(self) -> None:
        html = """
        <pre class="jcConfig">
        module = Dry calc
        form = dryin
        result = dryout
        param = chance|Chance of drop|1/128|string|
        param = kills|Number of kills|128|int|1-inf
        </pre>
        """
        self.assertEqual(
            default_template_call(html),
            "{{#invoke:Dry calc|main|chance=1/128|kills=128}}",
        )


if __name__ == "__main__":
    unittest.main()
