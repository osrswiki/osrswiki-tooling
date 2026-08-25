#!/usr/bin/env python3
"""Agility spike: jcConfig extract, hidden-param invoke, fallback contract."""

from __future__ import annotations

import unittest

from wiki_calculator_catalog import (
    default_template_call,
    invoke_wikitext,
    native_chrome_eligible,
    parse_calc_definition,
    parse_result_is_error,
)

AGILITY_JCCONFIG = """
<pre class="jcConfig">
template=Calculator:Skill calc/Template
form=AgilityCalc
result=AgilityResults
name =
param = name|Name||hs|XPInput,17,2;lvlInput,17,1
param = currentToggle|Current: Level or Experience|Level|select|Level,Experience|Level=lvlInput;Experience=XPInput
param = lvlInput|Current (per choice above)|1|int|1-126|
param = XPInput|Current (per choice above)|1|int|1-200000000|

param = goalToggle|Goal: Level or Experience?|Level|select|Level,Experience
param = goal|Goal (per choice above)|0|int|0-200000000
param = method|Method|All|select|All,Agility Course,Brimhaven Agility Arena,Rooftop Agility Course,Hallowed Sepulchre,Barbarian Fishing
param = dataCriteria|Hide inaccessible methods|Show All|buttonselect|Show All,Hide,Greyed out
param = leagueGroup|League multiplier?||toggleswitch|false|leagueMultiplier
param = leagueMultiplier|League multiplier value?|5|int|5-32
param = skill|Skill|Agility|hidden
autosubmit = enabled
</pre>
"""

UNKNOWN_TYPE_CONFIG = """
<pre class="jcConfig">
template = Calculator:Agility/Template
param = voice|Voice of Seren|Amlodd|voiceofseren|
param = skill|Skill|Agility|hidden
</pre>
"""


class NativeCalcAgilityTests(unittest.TestCase):
    def test_extract_includes_hidden_skill_and_live_labels(self) -> None:
        definition = parse_calc_definition(AGILITY_JCCONFIG, title="Calculator:Agility")
        self.assertIsNotNone(definition)
        assert definition is not None
        self.assertEqual(definition["id"], "Calculator:Agility")
        self.assertEqual(definition["invoke"]["kind"], "template")
        self.assertEqual(definition["invoke"]["template"], "Calculator:Skill calc/Template")
        self.assertEqual(definition["ui"]["form_id"], "AgilityCalc")
        self.assertEqual(definition["ui"]["result_id"], "AgilityResults")
        self.assertEqual(definition["ui"]["autosubmit"], "enabled")
        names = [item["name"] for item in definition["inputs"]]
        self.assertEqual(
            names,
            [
                "name",
                "currentToggle",
                "lvlInput",
                "XPInput",
                "goalToggle",
                "goal",
                "method",
                "dataCriteria",
                "leagueGroup",
                "leagueMultiplier",
                "skill",
            ],
        )
        skill = next(item for item in definition["inputs"] if item["name"] == "skill")
        self.assertEqual(skill["type"], "hidden")
        self.assertEqual(skill["default"], "Agility")
        current = next(item for item in definition["inputs"] if item["name"] == "currentToggle")
        self.assertEqual(current["label"], "Current: Level or Experience")
        self.assertEqual(current["options"], ["Level", "Experience"])
        self.assertEqual(current["toggles"], {"Level": ["lvlInput"], "Experience": ["XPInput"]})
        method = next(item for item in definition["inputs"] if item["name"] == "method")
        self.assertIn("Hallowed Sepulchre", method["options"])
        data = next(item for item in definition["inputs"] if item["name"] == "dataCriteria")
        self.assertEqual(data["type"], "buttonselect")
        self.assertEqual(data["label"], "Hide inaccessible methods")

    def test_default_invoke_includes_hidden_skill_and_omits_disabled_fields(self) -> None:
        definition = parse_calc_definition(AGILITY_JCCONFIG, title="Calculator:Agility")
        wikitext = invoke_wikitext(definition)
        self.assertTrue(wikitext.startswith("{{Calculator:Skill calc/Template|"))
        self.assertIn("|skill=Agility", wikitext)
        self.assertIn("|currentToggle=Level", wikitext)
        self.assertIn("|lvlInput=1", wikitext)
        self.assertNotIn("|XPInput=", wikitext)
        self.assertIn("|goalToggle=Level", wikitext)
        self.assertIn("|goal=0", wikitext)
        self.assertIn("|method=All", wikitext)
        self.assertIn("|dataCriteria=Show All", wikitext)
        self.assertIn("|leagueGroup=false", wikitext)
        self.assertNotIn("|leagueMultiplier=", wikitext)
        self.assertNotIn("|name=", wikitext)
        self.assertEqual(
            default_template_call(AGILITY_JCCONFIG),
            wikitext,
        )

    def test_experience_toggle_and_league_switch_change_submitted_fields(self) -> None:
        definition = parse_calc_definition(AGILITY_JCCONFIG, title="Calculator:Agility")
        wikitext = invoke_wikitext(
            definition,
            {
                "currentToggle": "Experience",
                "XPInput": "200",
                "goalToggle": "Level",
                "goal": "99",
                "leagueGroup": "true",
                "leagueMultiplier": "8",
            },
        )
        self.assertIn("|currentToggle=Experience", wikitext)
        self.assertIn("|XPInput=200", wikitext)
        self.assertNotIn("|lvlInput=", wikitext)
        self.assertIn("|goal=99", wikitext)
        self.assertIn("|leagueGroup=true", wikitext)
        self.assertIn("|leagueMultiplier=8", wikitext)
        self.assertIn("|skill=Agility", wikitext)

    def test_native_chrome_is_agility_only_and_falls_back_on_unknown_types(self) -> None:
        agility = parse_calc_definition(AGILITY_JCCONFIG, title="Calculator:Agility")
        cooking = parse_calc_definition(
            AGILITY_JCCONFIG.replace("Agility", "Cooking"),
            title="Calculator:Cooking",
        )
        unknown = parse_calc_definition(UNKNOWN_TYPE_CONFIG, title="Calculator:Agility")
        self.assertTrue(native_chrome_eligible(agility))
        self.assertFalse(native_chrome_eligible(cooking))
        self.assertFalse(native_chrome_eligible(unknown))
        self.assertFalse(native_chrome_eligible(None))
        self.assertFalse(native_chrome_eligible(parse_calc_definition("no config here")))

    def test_parse_result_detects_scribunto_error_and_accepts_method_table(self) -> None:
        self.assertTrue(
            parse_result_is_error(
                '<div class="scribunto-error">Lua error in Module:Skill_calc</div>'
            )
        )
        self.assertTrue(parse_result_is_error(""))
        self.assertFalse(
            parse_result_is_error(
                '<table class="wikitable"><tr><td>Plank</td><td>1</td></tr></table>'
            )
        )

    def test_runtime_wraps_slot_in_calculator_collapsible(self) -> None:
        from pathlib import Path

        runtime = Path(__file__).resolve().parents[2] / "shared" / "js" / "osrs_calculator_runtime.js"
        text = runtime.read_text(encoding="utf-8")
        self.assertIn("osrsWrapNativeCalcCalculatorBox", text)
        self.assertIn("collapsible-calculator", text)
        self.assertIn("data-osrs-disclosure-kind", text)
        self.assertIn("osrsNativeCalcSetCollapsed", text)
        self.assertIn("overflow-x:auto", text.replace(" ", ""))


if __name__ == "__main__":
    unittest.main()
