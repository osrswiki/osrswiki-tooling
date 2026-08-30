#!/usr/bin/env python3
"""Classify OSRS wiki Calculator: namespace pages into hosted tools vs templates."""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

WIKI_ORIGIN = "https://oldschool.runescape.wiki"
CALCULATOR_NAMESPACE = 116
CALCULATOR_NS_PREFIX = "Calculator:"

_TEMPLATE_SUFFIXES = (
    "/template",
    "/doc",
    "/sandbox",
    "/module",
)
_TEMPLATE_INFIXES = (
    "/template/",
    "/doc/",
    "/sandbox/",
    "/module/",
)


def is_calculator_namespace_title(title: str) -> bool:
    return title.startswith(CALCULATOR_NS_PREFIX)


def is_user_facing_calculator(title: str) -> bool:
    if not is_calculator_namespace_title(title):
        return False
    lowered = title.lower()
    if "sandbox" in lowered:
        return False
    rest = title[len(CALCULATOR_NS_PREFIX) :]
    for part in rest.split("/"):
        if part.lower().startswith("template"):
            return False
        if part.lower() in {"doc", "sandbox", "module"}:
            return False
    return True


def exclusion_reason(title: str) -> str | None:
    if not is_calculator_namespace_title(title):
        return "not_calculator_namespace"
    if is_user_facing_calculator(title):
        return None
    lowered = title.lower()
    if "sandbox" in lowered:
        return "sandbox"
    if "/template" in lowered:
        return "template"
    if "/doc" in lowered:
        return "documentation"
    if "/module" in lowered:
        return "module"
    return "implementation"


def wiki_url_for_title(title: str) -> str:
    encoded = quote(title.replace(" ", "_"), safe=":_/")
    return f"{WIKI_ORIGIN}/w/{encoded}"


def catalog_entry(page: dict) -> dict:
    title = page["title"]
    return {
        "title": title,
        "pageid": page.get("pageid"),
        "url": wiki_url_for_title(title),
    }


_JCCONFIG_RE = re.compile(
    r"(?is)<pre[^>]*class=(['\"])[^'\"]*jcConfig[^'\"]*\1[^>]*>(.*?)</pre>"
)
_TEMPLATE_RE = re.compile(
    r"(?i)\btemplate\s*=\s*(.+?)(?=\s+(?:form|result|param|name|autosubmit|module|modulefunc)\b|$)"
)
_MODULE_RE = re.compile(
    r"(?i)\bmodule\s*=\s*(.+?)(?=\s+(?:form|result|param|name|autosubmit|modulefunc|template)\b|$)"
)
_MODULEFUNC_RE = re.compile(
    r"(?i)\bmodulefunc\s*=\s*(\S+)"
)
_PARAM_RE = re.compile(
    r"(?i)\bparam\s*=\s*([^|\n]+)\|([^|\n]*)\|([^|\n]*)\|([^|\n]*)"
)
_LOOSE_CONFIG_RE = re.compile(
    r"(?is)(?:^|\n)\s*(?:template|module)\s*=.+?(?=\n\s*(?:\{\||----|<pre|$))"
)

# Native kit for this spike. Unknown types force WebView fallback.
# Mirrors MediaWiki:Gadget-calc-core.js validParamTypes used on OSRS.
NATIVE_KIT_TYPES = frozenset(
    {
        "string",
        "int",
        "number",
        "select",
        "buttonselect",
        "check",
        "toggleswitch",
        "togglebutton",
        "hs",
        "rsn",
        "hidden",
        "fixed",
        "semihidden",
    }
)
_SKIP_EMPTY_ON_SUBMIT = frozenset({"hs", "rsn"})
_ALWAYS_SUBMIT = frozenset({"hidden", "fixed"})
_CONFIG_KEYS = frozenset(
    {
        "form",
        "param",
        "result",
        "suggestns",
        "template",
        "module",
        "modulefunc",
        "name",
        "autosubmit",
    }
)


def first_jcconfig(text: str) -> str | None:
    raw = text or ""
    match = _JCCONFIG_RE.search(raw)
    if match:
        return match.group(2)
    loose = _LOOSE_CONFIG_RE.search(raw)
    if loose:
        return loose.group(0)
    return None


def _split_config_line(line: str) -> tuple[str, str] | None:
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        return None
    if "=" not in stripped:
        return None
    key, value = stripped.split("=", 1)
    return key.strip().lower(), value.strip()


def _parse_toggles(raw: str, default_key: str) -> dict[str, dict[str, list[str]]]:
    raw = (raw or "").strip()
    if not raw:
        return {}
    toggles: dict[str, dict[str, list[str]]] = {}
    all_keys: list[str] = []
    all_vals: list[str] = []
    for piece in re.split(r"\s*;\s*", raw):
        if not piece:
            continue
        if "=" in piece:
            keys_raw, vals_raw = piece.split("=", 1)
            keys = [item.strip() for item in keys_raw.split(",") if item.strip()]
            vals = [item.strip() for item in vals_raw.split(",") if item.strip()]
        else:
            keys = [default_key]
            vals = [item.strip() for item in piece.split(",") if item.strip()]
        for key in keys:
            toggles[key] = {"on": list(vals), "off": []}
            all_keys.append(key)
        all_vals.extend(vals)
    unique_vals = list(dict.fromkeys(all_vals))
    for key in dict.fromkeys(all_keys):
        on = toggles[key]["on"]
        toggles[key]["off"] = [item for item in unique_vals if item not in on]
    toggles["alltogs"] = {"on": [], "off": unique_vals}
    return toggles


def _options_for_type(kind: str, range_text: str) -> list[str]:
    if kind in {"select", "buttonselect", "check"} and range_text:
        return [item.strip() for item in range_text.split(",") if item.strip()]
    return []


def _int_range(range_text: str) -> dict[str, str]:
    text = (range_text or "").strip()
    if not text or "-" not in text:
        return {}
    left, right = text.split("-", 1)
    return {"min": left.strip(), "max": right.strip()}


def parse_calc_definition(
    text: str,
    title: str | None = None,
    pageid: int | None = None,
    revid: int | None = None,
) -> dict | None:
    config = first_jcconfig(text)
    if not config:
        return None
    ui = {
        "name": "Calculator",
        "form_id": "",
        "result_id": "",
        "autosubmit": "off",
    }
    invoke = {
        "kind": None,
        "template": None,
        "module": None,
        "modulefunc": None,
    }
    inputs: list[dict] = []
    unknown_types: list[str] = []
    for raw_line in config.splitlines():
        parsed = _split_config_line(raw_line)
        if not parsed:
            continue
        key, value = parsed
        if key not in _CONFIG_KEYS:
            continue
        if key == "suggestns":
            continue
        if key != "param":
            if key == "form":
                ui["form_id"] = value
            elif key == "result":
                ui["result_id"] = value
            elif key == "name":
                ui["name"] = value or ui["name"]
            elif key == "autosubmit":
                ui["autosubmit"] = normalize_autosubmit(value)
            elif key == "template":
                invoke["kind"] = "template"
                invoke["template"] = value
            elif key == "module":
                invoke["kind"] = "module"
                invoke["module"] = value
            elif key == "modulefunc":
                invoke["modulefunc"] = value or "main"
            continue
        fields = [item.strip() for item in re.split(r"\s*\|\s*", value)]
        while len(fields) < 6:
            fields.append("")
        name, label, default, kind, range_text, raw_toggles = fields[:6]
        kind = kind.lower()
        if not name:
            continue
        if kind and kind not in NATIVE_KIT_TYPES:
            unknown_types.append(kind)
        toggle_default = default or ("true" if kind in {"toggleswitch", "togglebutton", "check"} else name)
        if kind == "toggleswitch" and not default:
            default = "false"
        inputs.append(
            {
                "name": name,
                "label": label or name,
                "default": default,
                "type": kind,
                "range": range_text,
                "options": _options_for_type(kind, range_text),
                "toggles": {
                    key: value["on"]
                    for key, value in _parse_toggles(raw_toggles, toggle_default).items()
                    if key != "alltogs"
                },
                "toggle_off": {
                    key: value["off"]
                    for key, value in _parse_toggles(raw_toggles, toggle_default).items()
                    if key != "alltogs"
                },
                "int_range": _int_range(range_text) if kind in {"int", "number"} else {},
            }
        )
    if invoke["kind"] == "module" and not invoke["modulefunc"]:
        invoke["modulefunc"] = "main"
    if invoke["kind"] is None:
        return None
    calc_id = title or ui["name"] or "Calculator"
    return {
        "schema_version": 1,
        "id": calc_id,
        "pageid": pageid,
        "revid": revid,
        "wiki_origin": WIKI_ORIGIN,
        "family": "skill-calc-shared-template"
        if (invoke.get("template") or "").startswith("Calculator:Skill calc/")
        else "jcconfig",
        "ui": ui,
        "invoke": invoke,
        "inputs": inputs,
        "unknown_types": unknown_types,
    }


def native_chrome_eligible(definition: dict | None) -> bool:
    if not definition:
        return False
    invoke = definition.get("invoke") or {}
    if invoke.get("kind") == "template" and not invoke.get("template"):
        return False
    if invoke.get("kind") == "module" and not invoke.get("module"):
        return False
    if invoke.get("kind") not in {"template", "module"}:
        return False
    if definition.get("unknown_types"):
        return False
    inputs = definition.get("inputs") or []
    if not inputs:
        return False
    return all((item.get("type") or "") in NATIVE_KIT_TYPES for item in inputs)


_JCCONFIG_OPEN_RE = re.compile(r'(?i)<pre[^>]*class="[^"]*jcConfig[^"]*"')


def count_jcconfigs(html: str | None) -> int:
    if not html:
        return 0
    return len(_JCCONFIG_OPEN_RE.findall(html))


def page_native_chrome_eligible(html: str | None, title: str | None = None) -> bool:
    if html is None or count_jcconfigs(html) != 1:
        return False
    return native_chrome_eligible(parse_calc_definition(html, title=title))


def normalize_autosubmit(raw: str | None) -> str:
    value = (raw or "off").strip().lower()
    if not value or value in {"off", "disabled", "false"}:
        return "off"
    if value in {"enabled", "on", "true"}:
        return "on"
    return "on"


def classify_calculator_family(html: str | None, definition: dict | None = None) -> str:
    """Recorded-family letters from Fable: A/B/C/D/E, plus multi for >1 jcConfig."""
    count = count_jcconfigs(html)
    if count == 0:
        return "E"
    if count != 1:
        return "multi"
    definition = definition or parse_calc_definition(html or "")
    if not definition:
        return "E"
    if definition.get("unknown_types"):
        return "C"
    invoke = definition.get("invoke") or {}
    if invoke.get("kind") == "module":
        return "D"
    template = invoke.get("template") or ""
    if template.startswith("Calculator:Skill calc/"):
        return "A"
    return "B"


def _visible_input_names(definition: dict, values: dict[str, str]) -> set[str]:
    names = {item["name"] for item in definition.get("inputs") or []}
    visible = set(names)
    for item in definition.get("inputs") or []:
        current = values.get(item["name"], item.get("default") or "")
        toggles = item.get("toggles") or {}
        toggle_off = item.get("toggle_off") or {}
        if not toggles:
            continue
        if current in toggles:
            for name in toggles.get(current) or []:
                visible.add(name)
            for name in toggle_off.get(current) or []:
                visible.discard(name)
        else:
            # Gadget hides alltogs.off when the current value has no explicit mapping
            # (toggleswitch=false → hide leagueMultiplier).
            mapped = set()
            for names_on in toggles.values():
                mapped.update(names_on)
            for name in mapped:
                visible.discard(name)
    return visible


def invoke_wikitext(definition: dict | None, values: dict[str, str] | None = None) -> str | None:
    if not definition:
        return None
    invoke = definition.get("invoke") or {}
    if invoke.get("kind") == "module":
        module = (invoke.get("module") or "").strip()
        func = (invoke.get("modulefunc") or "main").strip() or "main"
        if not module:
            return None
        parts = ["{{#invoke:" + module + "|" + func]
    elif invoke.get("kind") == "template":
        template = (invoke.get("template") or "").strip()
        if not template:
            return None
        parts = ["{{" + template]
    else:
        return None
    merged: dict[str, str] = {}
    for item in definition.get("inputs") or []:
        merged[item["name"]] = item.get("default") or ""
    if values:
        for key, value in values.items():
            merged[key] = str(value)
    visible = _visible_input_names(definition, merged)
    for item in definition.get("inputs") or []:
        name = item["name"]
        kind = item.get("type") or ""
        if kind == "group":
            continue
        if kind not in _ALWAYS_SUBMIT and name not in visible:
            continue
        value = merged.get(name, "")
        if kind in _SKIP_EMPTY_ON_SUBMIT and not value:
            continue
        if kind == "toggleswitch":
            lowered = value.lower()
            if lowered in {"1", "true", "yes", "on"}:
                value = "true"
            elif lowered in {"0", "false", "no", "off", ""}:
                value = "false"
        parts.append(f"|{name}={value}")
    parts.append("}}")
    return "".join(parts)


def parse_result_is_error(html: str | None) -> bool:
    body = html or ""
    if not body.strip():
        return True
    lowered = body.lower()
    if "scribunto-error" in lowered:
        return True
    if "lua error" in lowered:
        return True
    return False


def chrome_title(calc_id: str) -> str:
    rest = calc_id or ""
    if rest.startswith("Calculator:"):
        rest = rest[len("Calculator:") :]
    rest = rest.strip() or "Calculator"
    if rest.lower().endswith("calculator"):
        return rest
    return f"{rest} calculator"


def intro_copy(wikitext: str, title: str = "") -> str:
    if title == "Calculator:Combat level":
        lead = (
            "Enter your combat stats, or look them up from hiscores. "
            "The wiki returns your combat level. Formulas stay on the wiki, not in the app."
        )
    elif title == "Calculator:Agility":
        lead = (
            "Enter your current Agility level or XP and a goal. "
            "Methods come from the live wiki calculator, not formulas shipped in the app."
        )
    else:
        lead = (
            "Fill the fields below. Results come from the live wiki calculator, "
            "not formulas shipped in the app."
        )
    lines = [lead]
    if "===Assumptions===" in (wikitext or ""):
        rest = wikitext.split("===Assumptions===", 1)[1]
        if "===" in rest:
            rest = rest.split("===", 1)[0]
        bullets = [
            "• " + line[1:].strip()
            for line in rest.splitlines()
            if line.strip().startswith("*")
        ]
        if bullets:
            lines.append("")
            lines.append("Assumptions")
            lines.extend(bullets)
    return "\n".join(lines)


def default_template_call(text: str) -> str | None:
    definition = parse_calc_definition(text)
    return invoke_wikitext(definition)


def fetch_all_calculator_pages() -> list[dict]:
    pages: list[dict] = []
    continue_token: str | None = None
    while True:
        params = {
            "action": "query",
            "list": "allpages",
            "apnamespace": str(CALCULATOR_NAMESPACE),
            "aplimit": "500",
            "apfilterredir": "nonredirects",
            "format": "json",
        }
        if continue_token:
            params["apcontinue"] = continue_token
        url = f"{WIKI_ORIGIN}/api.php?{urlencode(params)}"
        request = Request(url, headers={"User-Agent": "osrswiki-calculator-catalog/1.0"})
        with urlopen(request, timeout=60) as response:
            payload = json.loads(response.read().decode("utf-8"))
        pages.extend(payload.get("query", {}).get("allpages", []))
        continue_token = payload.get("continue", {}).get("apcontinue")
        if not continue_token:
            break
    return pages


def build_catalog(pages: list[dict]) -> dict:
    calculators = []
    excluded = []
    for page in pages:
        title = page.get("title") or ""
        if is_user_facing_calculator(title):
            calculators.append(catalog_entry(page))
        else:
            excluded.append(
                {
                    "title": title,
                    "pageid": page.get("pageid"),
                    "reason": exclusion_reason(title) or "implementation",
                }
            )
    calculators.sort(key=lambda item: item["title"].lower())
    return {
        "schema_version": 1,
        "wiki_origin": WIKI_ORIGIN,
        "namespace": CALCULATOR_NAMESPACE,
        "fetched_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": "api.php?action=query&list=allpages&apnamespace=116&apfilterredir=nonredirects",
        "calculator_count": len(calculators),
        "excluded_count": len(excluded),
        "calculators": calculators,
        "excluded": excluded,
    }
