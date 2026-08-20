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


def first_jcconfig(text: str) -> str | None:
    raw = text or ""
    match = _JCCONFIG_RE.search(raw)
    if match:
        return match.group(2)
    loose = _LOOSE_CONFIG_RE.search(raw)
    if loose:
        return loose.group(0)
    return None


def default_template_call(text: str) -> str | None:
    config = first_jcconfig(text)
    if not config:
        return None
    module_match = _MODULE_RE.search(config)
    template_match = _TEMPLATE_RE.search(config)
    if module_match:
        module = module_match.group(1).strip()
        func = "main"
        func_match = _MODULEFUNC_RE.search(config)
        if func_match:
            func = func_match.group(1).strip() or "main"
        if not module:
            return None
        parts = ["{{#invoke:" + module + "|" + func]
    elif template_match:
        template = template_match.group(1).strip()
        if not template:
            return None
        parts = ["{{" + template]
    else:
        return None
    for match in _PARAM_RE.finditer(config):
        name = match.group(1).strip()
        initial = match.group(3).strip()
        kind = match.group(4).strip().lower()
        if not name or kind in {"hidden", "hs", "rsn"}:
            continue
        parts.append(f"|{name}={initial}")
    parts.append("}}")
    return "".join(parts)


def fetch_all_calculator_pages() -> list[dict]:
    pages: list[dict] = []
    continue_token: str | None = None
    while True:
        params = {
            "action": "query",
            "list": "allpages",
            "apnamespace": str(CALCULATOR_NAMESPACE),
            "aplimit": "500",
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
        "source": "api.php?action=query&list=allpages&apnamespace=116",
        "calculator_count": len(calculators),
        "excluded_count": len(excluded),
        "calculators": calculators,
        "excluded": excluded,
    }
