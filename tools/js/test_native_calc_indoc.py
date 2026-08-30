#!/usr/bin/env python3
"""In-document calc chrome: jcConfig parse, invoke, slot HTML, config eligibility."""

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
        self.assertRegex(
            result["html"],
            r'id="osrs-indoc-field-playername"[^>]*enterkeyhint="go"',
        )
        self.assertRegex(
            result["html"],
            r'id="osrs-indoc-field-attack"[^>]*enterkeyhint="done"',
        )
        self.assertNotRegex(
            result["html"],
            r'id="osrs-indoc-field-playername"[^>]*enterkeyhint="done"',
        )

    def test_page_eligibility_is_kit_and_every_config_not_title(self) -> None:
        self.assertTrue(
            eval_js("api.isPageEligible(" + json.dumps(AGILITY) + ', "Calculator:Agility")')
        )
        self.assertTrue(
            eval_js("api.isPageEligible(" + json.dumps(COMBAT) + ', "Calculator:Combat level")')
        )
        cooking = AGILITY.replace("Agility", "Cooking")
        self.assertTrue(
            eval_js("api.isEligible(api.parse(" + json.dumps(cooking) + ', "Calculator:Cooking"))')
        )
        self.assertTrue(eval_js("api.isPageEligible(" + json.dumps(cooking) + ', "Calculator:Cooking")'))
        self.assertEqual(eval_js("api.countJcConfigs(" + json.dumps(AGILITY) + ")"), 1)
        coords = (ROOT / "tools" / "js" / "fixtures" / "native_calc" / "coordinates.html").read_text(
            encoding="utf-8"
        )
        self.assertEqual(eval_js("api.countJcConfigs(" + json.dumps(coords) + ")"), 2)
        self.assertTrue(
            eval_js("api.isPageEligible(" + json.dumps(coords) + ', "Calculator:Coordinates")')
        )
        mixed = coords.replace("int | 0-180", "voiceofseren |")
        self.assertFalse(
            eval_js("api.isPageEligible(" + json.dumps(mixed) + ', "Calculator:Coordinates")')
        )
        self.assertFalse(eval_js("api.isPageEligible('<p>no calculator</p>', 'Calculator:None')"))
        self.assertFalse(eval_js("Object.prototype.hasOwnProperty.call(api, 'isAllowlisted')"))
        self.assertFalse(eval_js("Object.prototype.hasOwnProperty.call(api, 'titles')"))

    def test_autosubmit_tokens_normalize_to_on_or_off(self) -> None:
        mapping = eval_js(
            """({
              off: api.normalizeAutosubmit('off'),
              disabled: api.normalizeAutosubmit('disabled'),
              enabled: api.normalizeAutosubmit('enabled'),
              on: api.normalizeAutosubmit('on'),
              trueToken: api.normalizeAutosubmit('true'),
              empty: api.normalizeAutosubmit(''),
            })"""
        )
        self.assertEqual(mapping["off"], "off")
        self.assertEqual(mapping["disabled"], "off")
        self.assertEqual(mapping["enabled"], "on")
        self.assertEqual(mapping["on"], "on")
        self.assertEqual(mapping["trueToken"], "on")
        self.assertEqual(mapping["empty"], "off")
        agility = eval_js("api.parse(" + json.dumps(AGILITY) + ', "Calculator:Agility")')
        self.assertEqual(agility["ui"]["autosubmit"], "on")

    def test_should_autosubmit_honors_page_flag_and_field_type(self) -> None:
        result = eval_js(
            """(() => {
              const on = api.parse(""" + json.dumps(AGILITY) + """, "Calculator:Agility");
              const offHtml = """ + json.dumps(AGILITY.replace("autosubmit = enabled", "autosubmit = disabled")) + """;
              const off = api.parse(offHtml, "Calculator:Agility");
              const missing = api.parse(
                """ + json.dumps(AGILITY.replace("autosubmit = enabled\n", "")) + """,
                "Calculator:Agility"
              );
              return {
                onBoot: api.shouldAutosubmit(on),
                onInt: api.shouldAutosubmit(on, "int"),
                onHs: api.shouldAutosubmit(on, "hs"),
                offBoot: api.shouldAutosubmit(off),
                offInt: api.shouldAutosubmit(off, "int"),
                missingBoot: api.shouldAutosubmit(missing),
                missingAutosubmit: missing.ui.autosubmit,
              };
            })()"""
        )
        self.assertTrue(result["onBoot"])
        self.assertTrue(result["onInt"])
        self.assertFalse(result["onHs"])
        self.assertFalse(result["offBoot"])
        self.assertFalse(result["offInt"])
        self.assertEqual(result["missingAutosubmit"], "off")
        self.assertFalse(result["missingBoot"])

    def test_parse_result_classifies_parser_and_lua_errors(self) -> None:
        expr = '<strong class="error">Expression error: Unexpected &lt; operator</strong>'
        lua = '<p class="scribunto-error">Lua error in Module:Skill_calc at line 1</p>'
        ok = '<table class="wikitable"><tr><td>12.4</td></tr></table>'
        self.assertTrue(eval_js("api.parseResultIsError(" + json.dumps(expr) + ")"))
        self.assertTrue(eval_js("api.parseResultIsError(" + json.dumps(lua) + ")"))
        self.assertTrue(eval_js("api.parseResultIsError('')"))
        self.assertFalse(eval_js("api.parseResultIsError(" + json.dumps(ok) + ")"))
        self.assertFalse(
            eval_js("api.parseResultIsError('<p>Your combat level is 3, balanced.</p>')")
        )

    def test_runtime_gates_automatic_submit_and_extracts_expression_error(self) -> None:
        runtime = RUNTIME.read_text(encoding="utf-8")
        boot = runtime.split("form.addEventListener('input'", 1)[1].split(
            "window.osrsBootIndocCalc", 1
        )[0]
        self.assertIn("api.shouldAutosubmit(definition)", boot)
        self.assertNotIn("bind();\n        submit();", runtime)
        self.assertIn("if (api.shouldAutosubmit(definition)) submit();", runtime)
        self.assertIn("if (api.shouldAutosubmit(definition, type)) submit();", runtime)
        lookup = runtime.split("function lookupHiscores() {", 1)[1].split(
            "function fieldTypeFor(name)", 1
        )[0]
        self.assertIn("submit();", lookup)
        self.assertIn("/Expression error[^<]*/i", runtime)
        self.assertIn("/Lua error[^<]*/i", runtime)
        err_path = runtime.split("if (api.parseResultIsError(html)) {", 1)[1].split(
            "window.osrsNativeCalcSetResult(definition.ui.resultId, html)", 1
        )[0]
        self.assertIn("osrsNativeCalcSetResult(definition.ui.resultId, '')", err_path)
        form_submit = runtime.split("form.addEventListener('submit'", 1)[1].split(
            "form.addEventListener('keydown'", 1
        )[0]
        self.assertIn("submit();", form_submit)
        initialize = runtime.split("function initialize() {", 1)[1].split(
            "if (document.readyState", 1
        )[0]
        self.assertNotIn("osrsWrapCollapsible", initialize)
        prepare = runtime.split("function prepareCalculatorLayout(", 1)[1].split(
            "function osrsReassertCalculatorThemeSheets(", 1
        )[0]
        self.assertIn("osrsWrapGadgetCalculatorLayout(existing)", prepare)
        self.assertIn("osrsWrapGadgetCalculatorLayout(layout)", prepare)
        self.assertIn("kind: 'calculator'", prepare)
        self.assertIn("elementToWrap: layout", prepare)
        self.assertIn("captionText: 'Calculator'", prepare)
        self.assertNotIn("osrsWrapNativeCalcCalculatorBox", prepare)

    def test_calculator_collapsible_overflow_owner_is_not_a_scrollport(self) -> None:
        fixes = (ROOT / "shared" / "css" / "fixes.css").read_text(encoding="utf-8")
        owner = (
            ".collapsible-container.collapsible-calculator:not(.collapsed) > "
            ".collapsible-content,"
        )
        self.assertEqual(fixes.count(owner), 1)
        owner_block = fixes.split(owner, 1)[1].split("ul.gallery,", 1)[0]
        self.assertIn("overflow-x: visible !important", owner_block)
        self.assertNotIn("overflow-x: auto", owner_block)
        self.assertNotIn("html.osrs-native-calc-slot-active", owner_block)
        self.assertIn(
            ".collapsible-container.collapsible-calculator .osrs-local-scroll-surface > table",
            fixes,
        )
        runtime = RUNTIME.read_text(encoding="utf-8")
        install = runtime.split("window.osrsInstallNativeCalcSlot = function", 1)[1].split(
            "window.osrsNativeCalcSetSlotHeight", 1
        )[0]
        self.assertNotIn(
            "html.osrs-native-calc-slot-active .collapsible-calculator:not(.collapsed) > .collapsible-content > .osrs-disclosure-body",
            install,
        )
        self.assertIn("#osrs-native-calc-slot", install)
        self.assertIn("[data-osrs-native-calc-slot]", install)

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
        self.assertIn("#osrs-native-calc-slot input", install)
        self.assertIn(".jcTable input,", install)
        css = (ROOT / "shared" / "css" / "gadget_calc.css").read_text(encoding="utf-8")
        self.assertIn(".osrs-indoc-calc-form", css)
        self.assertIn("html.osrs-indoc-calc", css)
        self.assertIn("overflow: visible !important", css)
        core = (ROOT / "shared" / "js" / "mediawiki" / "gadget_calc_core.js").read_text(encoding="utf-8")
        self.assertIn("osrsIndocPageShouldSkipGadgetBoot", core)
        self.assertIn("osrsIndocNativeSlotTakingOver", core)
        self.assertIn("isPageEligible", core)
        skip_boot = core.split("function osrsIndocPageShouldSkipGadgetBoot()", 1)[1].split(
            "function osrsBootCalcCore()", 1
        )[0]
        self.assertNotIn("Calculator:Agility", skip_boot)
        self.assertNotIn("Calculator:Combat level", skip_boot)
        skip_init = core.split("function osrsIndocPageShouldSkipGadget()", 1)[1].split(
            "function init()", 1
        )[0]
        self.assertNotIn("Calculator:Agility", skip_init)
        self.assertIn("resolvePageTitle", runtime)

    def test_hs_enterkeyhint_is_go_and_enter_looks_up(self) -> None:
        runtime = RUNTIME.read_text(encoding="utf-8")
        indoc = INDOC.read_text(encoding="utf-8")
        self.assertIn("isIndocEnterKey", runtime)
        self.assertIn("fieldTypeFor(target.name) === 'hs'", runtime)
        self.assertIn("dismissIndocKeyboard", runtime)
        self.assertIn("lookupHiscores();", runtime)
        self.assertIn("input.type === 'hs' ? 'go' : 'done'", indoc)

    def test_lookup_error_html_has_icon_and_strong_error(self) -> None:
        result = eval_js(
            'api.lookupErrorHtml(api.missingPlayerMessage("osamosis"))'
        )
        self.assertIn('class="osrs-indoc-calc-error"', result)
        self.assertIn("osrs-indoc-calc-error-icon", result)
        self.assertIn("<svg", result)
        self.assertIn("osrs-indoc-calc-error-stop", result)
        self.assertIn('<strong class="error">', result)
        self.assertIn("The player &quot;osamosis&quot; does not exist", result)
        self.assertNotIn("oo-ui-", result)

    def test_lookup_start_and_success_clear_missing_player_output(self) -> None:
        runtime = RUNTIME.read_text(encoding="utf-8")
        lookup = runtime.split("function lookupHiscores() {", 1)[1].split(
            "function fieldTypeFor(name)", 1
        )[0]
        self.assertGreaterEqual(lookup.count("clearLookupOutput()"), 2)
        self.assertLess(
            lookup.find("clearLookupOutput()"),
            lookup.find("osrsIndocRequest("),
            "lookup must clear result/status/banner before the hiscores request",
        )
        self.assertIn("showLookupError(player)", lookup)
        self.assertIn("osrsNativeCalcSetResult(definition.ui.resultId, '')", runtime)
        self.assertIn("osrsClearCalculatorPublishEcho()", runtime)
        css = (ROOT / "shared" / "css" / "gadget_calc.css").read_text(encoding="utf-8")
        self.assertIn(".osrs-indoc-calc-error-icon", css)
        self.assertIn(".osrs-indoc-calc-error-stop", css)
        self.assertIn("html.theme-osrs-dark .osrs-indoc-calc-error", css)

    def test_publisher_cannot_rehydrate_stale_status_player_name(self) -> None:
        runtime = RUNTIME.read_text(encoding="utf-8")
        publish = runtime.split("function osrsPublishCalculatorResult() {", 1)[1].split(
            "function osrsRevealCalculatorNode", 1
        )[0]
        self.assertNotIn("innerText", publish)
        self.assertNotIn("document.body", publish)
        self.assertNotIn('match(/The player', publish)
        self.assertIn("osrsCalculatorResultSourceNode()", publish)
        self.assertIn("osrsClearCalculatorPublishEcho()", publish)
        source = runtime.split("function osrsCalculatorResultSourceNode() {", 1)[1].split(
            "function osrsPublishCalculatorResult()", 1
        )[0]
        self.assertIn("osrs-calculator-status", source)
        self.assertIn("continue", source)
        fail = runtime.split("function showLookupError(player) {", 1)[1].split(
            "function lookupHiscores()", 1
        )[0]
        self.assertIn("api.lookupErrorHtml(err)", fail)
        self.assertIn("osrsNativeCalcSetResult", fail)


    def test_kit_carrier_unlocks_single_config_leftovers(self) -> None:
        fixtures = ROOT / "tools" / "js" / "fixtures" / "native_calc"
        barrows = (fixtures / "barrows.html").read_text(encoding="utf-8")
        rumours = (fixtures / "hunter_rumours.html").read_text(encoding="utf-8")
        quests = (fixtures / "recursive_quest.html").read_text(encoding="utf-8")
        wrench = (fixtures / "holy_wrench.html").read_text(encoding="utf-8")
        drain = (fixtures / "prayer_drain.html").read_text(encoding="utf-8")
        herbs = (fixtures / "farming_herbs.html").read_text(encoding="utf-8")
        coords = (fixtures / "coordinates.html").read_text(encoding="utf-8")
        result = eval_js(
            """(() => {
              const barrows = api.parse(""" + json.dumps(barrows) + """, "Calculator:Barrows");
              const rumours = api.parse(""" + json.dumps(rumours) + """, "Calculator:Hunter/Rumours");
              const quests = api.parse(""" + json.dumps(quests) + """, "Calculator:Recursive Quest Requirements");
              const wrench = api.parse(""" + json.dumps(wrench) + """, "Calculator:Prayer/Holy wrench");
              const offInvoke = api.invokeWikitext(barrows);
              const onInvoke = api.invokeWikitext(barrows, {toggleUnitKill: "true"});
              const rumoursHtml = api.renderFormHtml(rumours);
              const questHtml = api.renderFormHtml(quests);
              const toggle = barrows.inputs.find((i) => i.name === "toggleUnitKill");
              return {
                barrowsEligible: api.isPageEligible(""" + json.dumps(barrows) + """, "Calculator:Barrows"),
                rumoursEligible: api.isPageEligible(""" + json.dumps(rumours) + """, "Calculator:Hunter/Rumours"),
                questsEligible: api.isPageEligible(""" + json.dumps(quests) + """, "Calculator:Recursive Quest Requirements"),
                wrenchEligible: api.isPageEligible(""" + json.dumps(wrench) + """, "Calculator:Prayer/Holy wrench"),
                drainEligible: api.isPageEligible(""" + json.dumps(drain) + """, "Calculator:Prayer/Prayer drain"),
                herbsEligible: api.isPageEligible(""" + json.dumps(herbs) + """, "Calculator:Farming/Herbs"),
                coordsCount: api.countJcConfigs(""" + json.dumps(coords) + """),
                coordsEligible: api.isPageEligible(""" + json.dumps(coords) + """, "Calculator:Coordinates"),
                toggleKeys: Object.keys(toggle.toggles),
                offHasBloodworm: offInvoke.indexOf("|bloodworm=") >= 0,
                offHasGroup: offInvoke.indexOf("|unitKill=") >= 0,
                onHasBloodworm: onInvoke.indexOf("|bloodworm=") >= 0,
                onHasGroup: onInvoke.indexOf("|unitKill=") >= 0,
                rumoursHelp: rumoursHtml.indexOf("Karamja and Varlamore") >= 0,
                rumoursTbg: rumoursHtml.indexOf('data-osrs-indoc-chip="togglebuttongroup"') >= 0,
                questCombo: questHtml.indexOf('data-osrs-indoc-type="combobox"') >= 0,
                questOptions: (quests.inputs.find((i) => i.type === "combobox") || {}).options.length,
                wrenchAhrim: false,
              };
            })()"""
        )
        self.assertTrue(result["barrowsEligible"])
        self.assertTrue(result["rumoursEligible"])
        self.assertTrue(result["questsEligible"])
        self.assertTrue(result["wrenchEligible"])
        self.assertTrue(result["drainEligible"])
        self.assertTrue(result["herbsEligible"])
        self.assertEqual(result["coordsCount"], 2)
        self.assertTrue(result["coordsEligible"])
        self.assertEqual(result["toggleKeys"], ["true"])
        self.assertFalse(result["offHasBloodworm"])
        self.assertFalse(result["offHasGroup"])
        self.assertTrue(result["onHasBloodworm"])
        self.assertFalse(result["onHasGroup"])
        self.assertTrue(result["rumoursHelp"])
        self.assertTrue(result["rumoursTbg"])
        self.assertTrue(result["questCombo"])
        self.assertGreater(result["questOptions"], 50)

    def test_div_config_survives_collapsed_paragraph_whitespace(self) -> None:
        html = """
        <div class="jcConfig" style="display: none;">
        <p>template = Calculator:Prayer/Holy wrench/Template form = HWForm result = HWResult param = playername|Username||hs|PrayerLevel,6,1 param = PrayerLevel|Prayer level|99|int|1-99| param = PrayerPotions|Prayer potions (4)|5|int|0-50| autosubmit = enabled</p>
        </div>
        """
        result = eval_js(
            """(() => {
              const html = """ + json.dumps(html) + """;
              const def = api.parse(html, "Calculator:Prayer/Holy wrench");
              return {
                eligible: api.isPageEligible(html, "Calculator:Prayer/Holy wrench"),
                types: def.inputs.map((i) => i.type),
                names: def.inputs.map((i) => i.name),
                template: def.invoke.template
              };
            })()"""
        )
        self.assertTrue(result["eligible"])
        self.assertEqual(result["template"], "Calculator:Prayer/Holy wrench/Template")
        self.assertEqual(result["names"], ["playername", "PrayerLevel", "PrayerPotions"])
        self.assertEqual(result["types"], ["hs", "int", "int"])

    def test_render_form_html_prefixes_instance_ids(self) -> None:
        coords = (ROOT / "tools" / "js" / "fixtures" / "native_calc" / "coordinates.html").read_text(
            encoding="utf-8"
        )
        result = eval_js(
            """(() => {
              const sources = api.eachConfigSource(""" + json.dumps(coords) + """);
              const first = api.parse(sources[0], "Calculator:Coordinates");
              const second = api.parse(sources[1], "Calculator:Coordinates");
              const html0 = api.renderFormHtml(first);
              const html1 = api.renderFormHtml(second, {}, 1);
              return {
                names: [first.ui.name, second.ui.name],
                formIds: [first.ui.formId, second.ui.formId],
                resultIds: [first.ui.resultId, second.ui.resultId],
                html0: html0,
                html1: html1,
              };
            })()"""
        )
        self.assertEqual(result["names"], ["Planar to Geographic", "Geographic to Planar"])
        self.assertEqual(result["formIds"], ["FormPtoG", "FormGtoP"])
        self.assertEqual(result["resultIds"], ["ResultPtoG", "ResultGtoP"])
        self.assertIn('id="osrs-indoc-calc-form"', result["html0"])
        self.assertIn("osrs-indoc-field-x", result["html0"])
        self.assertIn('id="osrs-indoc-calc-banner"', result["html0"])
        self.assertIn('id="osrs-indoc-calc-status"', result["html0"])
        self.assertIn('id="osrs-indoc-calc-form-1"', result["html1"])
        self.assertIn("osrs-indoc-field-1-ndeg", result["html1"])
        self.assertIn('id="osrs-indoc-calc-banner-1"', result["html1"])
        self.assertIn('id="osrs-indoc-calc-status-1"', result["html1"])
        self.assertNotIn('id="osrs-indoc-calc-form"', result["html1"])
        self.assertIn("Submit", result["html0"])
        self.assertIn("Submit", result["html1"])

    def test_runtime_boots_one_slot_per_config_and_routes_results(self) -> None:
        runtime = RUNTIME.read_text(encoding="utf-8")
        boot = runtime.split("window.osrsBootIndocCalc = function", 1)[1].split(
            "function osrsInstallCalculatorKeyboardGuards", 1
        )[0]
        self.assertNotIn("if (nodes.length !== 1)", boot)
        self.assertIn("querySelectorAll(osrsJcConfigSelector())", boot)
        self.assertIn("renderFormHtml(definition, values", boot)
        self.assertIn("data-osrs-native-calc-slot", runtime)
        self.assertIn("osrs-native-calc-slot-", runtime)
        self.assertIn("[data-osrs-native-calc-slot]", runtime)
        set_result = runtime.split("window.osrsNativeCalcSetResult = function", 1)[1].split(
            "window.osrsUninstallNativeCalcSlot", 1
        )[0]
        self.assertIn("data-osrs-native-calc-slot", set_result)
        self.assertIn("osrs-calculator-result", set_result)
        self.assertIn("multi && !resultId", set_result)
        self.assertIn("!multi", set_result)
        collapse = runtime.split("window.osrsNativeCalcSetCollapsed = function", 1)[1].split(
            "window.osrsNativeCalcIsCollapsed = function", 1
        )[0]
        self.assertNotIn("document.querySelector('.collapsible-calculator')", collapse)
        is_collapsed = runtime.split("window.osrsNativeCalcIsCollapsed = function", 1)[1].split(
            "return container;", 1
        )[0]
        self.assertNotIn("document.querySelector('.collapsible-calculator')", is_collapsed)
        bind = runtime.split("function bind() {", 1)[1].split("form.addEventListener('submit'", 1)[0]
        self.assertIn(".osrs-indoc-calc-form", bind)

    def test_unknown_types_still_wrap_gadget(self) -> None:
        html = """
        <pre class="jcConfig">
        template = Calculator:Agility/Template
        param = voice|Voice of Seren|Amlodd|article|
        param = skill|Skill|Agility|hidden
        </pre>
        """
        self.assertFalse(eval_js("api.isPageEligible(" + json.dumps(html) + ', "Calculator:Agility")'))
        self.assertFalse(eval_js("api.isEligible(api.parse(" + json.dumps(html) + ', "Calculator:Agility"))'))


if __name__ == "__main__":
    unittest.main()
