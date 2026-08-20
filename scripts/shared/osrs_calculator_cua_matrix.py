#!/usr/bin/env python3
"""Live-user CUA matrix for wiki calculators.

Contract tests cover every catalogued calculator. This matrix is the visible
emulator/simulator pass: drive the running app as a user on Combat, a skill
calculator, a GE/profit calculator, and a hiscores lookup.
"""

from __future__ import annotations

CUA_CALCULATOR_MATRIX = (
    {
        "title": "Calculator:Combat level",
        "why": "Core OOUI form plus parse-backed result; also the previous iOS hijack case.",
        "expect": "Attack/Strength fields, submit or autosubmit, visible combat level result.",
    },
    {
        "title": "Calculator:Cooking",
        "why": "Skill calculator with multiple inputs and template output.",
        "expect": "Form widgets render; submit replaces the result area with parsed HTML.",
    },
    {
        "title": "Calculator:Barrows",
        "why": "GE/profit-style calculator that depends on wiki parse, not a local formula.",
        "expect": "Changing inputs and submitting updates the result table.",
    },
    {
        "title": "Calculator:Combat level",
        "lookup": True,
        "why": "Hiscores lookup uses /cors/m=hiscore_oldschool and must be proxied.",
        "expect": "Player lookup fills combat stats or shows the wiki's missing-player error.",
    },
)
