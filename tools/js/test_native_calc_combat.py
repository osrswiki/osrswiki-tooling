#!/usr/bin/env python3
"""Combat level canary: reuse Agility native kit, dedicated template, no hidden skill."""

from __future__ import annotations

import unittest

from wiki_calculator_catalog import (
    chrome_title,
    intro_copy,
    invoke_wikitext,
    native_chrome_eligible,
    parse_calc_definition,
    parse_result_is_error,
)

COMBAT_JCCONFIG = """
<pre class="jcConfig">
 template = Calculator:Combat level/Template
 form = combatCalcForm
 result = combatCalcResult
 param  = playername|Player name||hs|attack,1,1;strength,3,1;ranged,5,1;magic,7,1;defence,2,1;hitpoints,4,1;prayer,6,1
 param = attack|Attack|1|int|1-99
 param = strength|Strength|1|int|1-99
 param = ranged|Ranged|1|int|1-99
 param = magic|Magic|1|int|1-99
 param = defence|Defence|1|int|1-99
 param = hitpoints|Hitpoints|10|int|9-99
 param = prayer|Prayer|1|int|1-99
 autosubmit = enabled
</pre>
"""


class NativeCalcCombatTests(unittest.TestCase):
    def test_extract_combat_labels_and_hiscores_map(self) -> None:
        definition = parse_calc_definition(COMBAT_JCCONFIG, title="Calculator:Combat level")
        self.assertIsNotNone(definition)
        assert definition is not None
        self.assertEqual(definition["id"], "Calculator:Combat level")
        self.assertEqual(definition["invoke"]["kind"], "template")
        self.assertEqual(definition["invoke"]["template"], "Calculator:Combat level/Template")
        self.assertEqual(definition["ui"]["form_id"], "combatCalcForm")
        self.assertEqual(definition["ui"]["result_id"], "combatCalcResult")
        self.assertEqual(chrome_title(definition["id"]), "Combat level calculator")
        names = [item["name"] for item in definition["inputs"]]
        self.assertEqual(
            names,
            [
                "playername",
                "attack",
                "strength",
                "ranged",
                "magic",
                "defence",
                "hitpoints",
                "prayer",
            ],
        )
        self.assertFalse(any(item["type"] == "hidden" for item in definition["inputs"]))
        hs = next(item for item in definition["inputs"] if item["name"] == "playername")
        self.assertEqual(hs["type"], "hs")
        self.assertEqual(hs["label"], "Player name")
        self.assertIn("attack,1,1", hs["range"])
        attack = next(item for item in definition["inputs"] if item["name"] == "attack")
        self.assertEqual(attack["label"], "Attack")
        self.assertEqual(attack["int_range"], {"min": "1", "max": "99"})
        hp = next(item for item in definition["inputs"] if item["name"] == "hitpoints")
        self.assertEqual(hp["default"], "10")
        self.assertEqual(hp["int_range"], {"min": "9", "max": "99"})

    def test_default_invoke_skips_empty_hiscores_and_does_not_invent_agility_skill(self) -> None:
        definition = parse_calc_definition(COMBAT_JCCONFIG, title="Calculator:Combat level")
        wikitext = invoke_wikitext(definition)
        self.assertEqual(
            wikitext,
            "{{Calculator:Combat level/Template|attack=1|strength=1|ranged=1|magic=1|defence=1|hitpoints=10|prayer=1}}",
        )
        self.assertNotIn("|skill=", wikitext)
        self.assertNotIn("|playername=", wikitext)

    def test_combat_and_cooking_share_the_kit_predicate(self) -> None:
        combat = parse_calc_definition(COMBAT_JCCONFIG, title="Calculator:Combat level")
        cooking = parse_calc_definition(COMBAT_JCCONFIG, title="Calculator:Cooking")
        self.assertTrue(native_chrome_eligible(combat))
        self.assertTrue(native_chrome_eligible(cooking))

    def test_combat_intro_copy_is_not_agility_methods_text(self) -> None:
        copy = intro_copy(COMBAT_JCCONFIG, title="Calculator:Combat level")
        self.assertIn("combat", copy.lower())
        self.assertNotIn("Agility", copy)
        self.assertNotIn("methods", copy.lower())
        self.assertIn("wiki", copy.lower())

    def test_combat_result_html_is_not_a_scribunto_error(self) -> None:
        self.assertFalse(
            parse_result_is_error(
                "<p>Your combat level is 3, balanced.</p>"
            )
        )


if __name__ == "__main__":
    unittest.main()
