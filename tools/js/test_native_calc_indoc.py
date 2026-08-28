#!/usr/bin/env python3
"""In-document calc chrome: jcConfig parse, invoke, slot HTML, allowlist."""

from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INDOC = ROOT / "shared" / "js" / "osrs_native_calc_indoc.js"
RUNTIME = ROOT / "shared" / "js" / "osrs_calculator_runtime.js"

AGILITY = r"""
<pre class="jcConfig">
template=Calculator:Skill calc/Template
form=AgilityCalc
result=AgilityResults
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

COMBAT = r"""
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


def eval_js(expr: str) -> object:
    script = (
        "const api = require(" + json.dumps(str(INDOC)) + ");\n"
        "const result = (" + expr + ");\n"
        "process.stdout.write(JSON.stringify(result));\n"
    )
    raw = subprocess.check_output(["node", "-e", script], text=True)
    return json.loads(raw)


class NativeCalcIndocTests(unittest.TestCase):
    def test_agility_parse_and_default_invoke(self) -> None:
        result = eval_js(
            """(() => {
              const d = api.parse(""" + json.dumps(AGILITY) + """, "Calculator:Agility");
              return {
                id: d.id,
                form: d.ui.formId,
                result: d.ui.resultId,
                names: d.inputs.map((i) => i.name),
                skill: d.inputs.find((i) => i.name === "skill"),
                eligible: api.isEligible(d),
                invoke: api.invokeWikitext(d),
              };
            })()"""
        )
        self.assertEqual(result["id"], "Calculator:Agility")
        self.assertEqual(result["form"], "AgilityCalc")
        self.assertEqual(result["result"], "AgilityResults")
        self.assertEqual(result["skill"]["type"], "hidden")
        self.assertEqual(result["skill"]["defaultValue"], "Agility")
        self.assertTrue(result["eligible"])
        self.assertIn("|skill=Agility", result["invoke"])
        self.assertNotIn("|XPInput=", result["invoke"])
        self.assertNotIn("|leagueMultiplier=", result["invoke"])

    def test_combat_parse_and_render_aria(self) -> None:
        result = eval_js(
            """(() => {
              const d = api.parse(""" + json.dumps(COMBAT) + """, "Calculator:Combat_level");
              const html = api.renderFormHtml(d);
              return {
                id: d.id,
                eligible: api.isEligible(d),
                invoke: api.invokeWikitext(d),
                html: html,
              };
            })()"""
        )
        self.assertEqual(result["id"], "Calculator:Combat level")
        self.assertTrue(result["eligible"])
        self.assertEqual(
            result["invoke"],
            "{{Calculator:Combat level/Template|attack=1|strength=1|ranged=1|magic=1|defence=1|hitpoints=10|prayer=1}}",
        )
        self.assertIn('id="osrs-indoc-calc-form"', result["html"])
        self.assertIn('aria-label="Combat level calculator"', result["html"])
        self.assertIn('aria-label="Attack"', result["html"])
        self.assertIn('aria-label="Player name"', result["html"])
        self.assertIn("osrs-indoc-field-attack", result["html"])
        self.assertNotIn("oo-ui-", result["html"])

    def test_page_name_not_bare_title_is_allowlisted(self) -> None:
        self.assertFalse(eval_js('api.isAllowlisted("Agility")'))
        self.assertTrue(eval_js('api.isAllowlisted("Calculator:Agility")'))
        self.assertTrue(eval_js('api.isAllowlisted("Calculator:Combat_level")'))

    def test_cooking_is_not_allowlisted(self) -> None:
        result = eval_js(
            'api.isAllowlisted("Calculator:Cooking") || api.isEligible(api.parse('
            + json.dumps(AGILITY.replace("Agility", "Cooking"))
            + ', "Calculator:Cooking"))'
        )
        self.assertFalse(result)

    def test_runtime_boots_indoc_and_skips_gadget(self) -> None:
        runtime = RUNTIME.read_text(encoding="utf-8")
        self.assertIn("osrsBootIndocCalc", runtime)
        self.assertIn("data-osrs-indoc-calc", runtime)
        self.assertIn("opts.indoc", runtime)
        self.assertIn("osrs-indoc-calc", runtime)
        install = runtime.split("window.osrsInstallNativeCalcSlot = function", 1)[1].split(
            "window.osrsNativeCalcSetSlotHeight", 1
        )[0]
        self.assertNotIn(".osrs-calculator-layout input,", install)
        self.assertNotIn(".osrs-calculator-layout button,", install)
        self.assertIn("#osrs-native-calc-slot input,", install)
        self.assertIn(".jcTable input,", install)
        css = (ROOT / "shared" / "css" / "gadget_calc.css").read_text(encoding="utf-8")
        self.assertIn(".osrs-indoc-calc-form", css)
        self.assertIn("html.osrs-indoc-calc", css)
        self.assertIn("overflow: visible !important", css)
        core = (ROOT / "shared" / "js" / "mediawiki" / "gadget_calc_core.js").read_text(encoding="utf-8")
        self.assertIn("osrsIndocPageShouldSkipGadgetBoot", core)
        self.assertIn("names.push(window.RLCONF.wgPageName, window.RLCONF.wgTitle)", core)
        self.assertIn("resolvePageTitle", RUNTIME.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
