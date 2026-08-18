#!/usr/bin/env python3
"""Measure chrome and table geometry from a PNG using ImageMagick.

This is the e2e yardstick for tab/article chrome. It reads the pixels
the user sees rather than guessing from source strings.

Usage:
  scripts/measure-screenshot.py IMAGE.png [--kind article|tab|auto]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def load_rgb(path: Path) -> tuple[int, int, list[tuple[int, int, int]]]:
    ident = subprocess.check_output(
        ["identify", "-format", "%w %h", str(path)], text=True
    ).strip()
    width, height = (int(part) for part in ident.split())
    raw = subprocess.check_output(["magick", str(path), "-depth", "8", "rgb:-"])
    expected = width * height * 3
    if len(raw) < expected:
        raise SystemExit(f"{path}: short RGB dump ({len(raw)} < {expected})")
    pixels = [(raw[i], raw[i + 1], raw[i + 2]) for i in range(0, expected, 3)]
    return width, height, pixels


def lum(rgb: tuple[int, int, int]) -> float:
    r, g, b = rgb
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def row_mean(pixels, width: int, y: int, x0: int, x1: int) -> float:
    total = 0.0
    count = 0
    row = y * width
    for x in range(max(0, x0), min(width, x1)):
        total += lum(pixels[row + x])
        count += 1
    return total / max(count, 1)


def row_var(pixels, width: int, y: int, x0: int, x1: int) -> float:
    values = [lum(pixels[y * width + x]) for x in range(max(0, x0), min(width, x1))]
    if not values:
        return 0.0
    mean = sum(values) / len(values)
    return sum((value - mean) ** 2 for value in values) / len(values)


def detect_island_bottom(pixels, width: int, height: int) -> int:
    """Dynamic Island is a near-black pill in the top-center."""
    last = 0
    for y in range(0, min(220, height)):
        center = row_mean(pixels, width, y, int(width * 0.36), int(width * 0.64))
        if center < 25:
            last = y
    return last


def first_text_row(pixels, width: int, start: int, end: int) -> int | None:
    """Text rows have high horizontal luminance variance."""
    x0, x1 = int(width * 0.08), int(width * 0.72)
    for y in range(start, min(end, len(pixels) // width)):
        if row_var(pixels, width, y, x0, x1) > 180:
            return y
    return None


def glass_run(
    means: list[float],
    start: int,
    end: int,
    threshold: float,
    min_h: int,
    max_h: int,
    reverse: bool = False,
) -> tuple[int, int] | None:
    if reverse:
        y = end
        while y > start:
            if means[y] >= threshold:
                run = 1
                while y - run > start and means[y - run] >= threshold:
                    run += 1
                if min_h <= run <= max_h:
                    return y - run + 1, y
                y -= run
            else:
                y -= 1
        return None
    y = start
    while y < end:
        if means[y] >= threshold:
            run = 1
            while y + run < end and means[y + run] >= threshold:
                run += 1
            if min_h <= run <= max_h:
                return y, y + run - 1
            y += run
        else:
            y += 1
    return None


def measure_article(path: Path) -> dict:
    width, height, pixels = load_rgb(path)
    scale = 3 if width >= 1100 else 2
    island = detect_island_bottom(pixels, width, height)
    strip_x0, strip_x1 = int(width * 0.04), int(width * 0.20)
    means = [row_mean(pixels, width, y, strip_x0, strip_x1) for y in range(height)]
    bg = sorted(means[0:80])[len(means[0:80]) // 2]
    # Prefer a slightly lighter-than-canvas run (liquid glass).
    threshold = bg + 10
    top = glass_run(means, max(island + 4, 80), int(height * 0.45), threshold, 36, 220)
    if top is None:
        # Light theme: glass can match parchment; use variance of the back button.
        vars_ = [row_var(pixels, width, y, strip_x0, strip_x1) for y in range(height)]
        y = max(island + 4, 80)
        while y < int(height * 0.45):
            if vars_[y] > 80:
                run = 1
                while y + run < height and vars_[y + run] > 40:
                    run += 1
                if 36 <= run <= 220:
                    top = (y, y + run - 1)
                    break
                y += run
            else:
                y += 1
    if top is None:
        return {
            "kind": "article",
            "path": str(path),
            "width": width,
            "height": height,
            "error": "top chrome not found",
            "island_bottom_px": island,
        }
    top_y, top_bottom = top
    content_y = first_text_row(pixels, width, top_bottom + 2, top_bottom + 280)
    bottom = glass_run(
        means, int(height * 0.55), height - 4, threshold, 36, 280, reverse=True
    )
    result = {
        "kind": "article",
        "path": str(path),
        "width": width,
        "height": height,
        "scale": scale,
        "island_bottom_px": island,
        "island_bottom_pt": round(island / scale, 1),
        "top_chrome_top_px": top_y,
        "top_chrome_top_pt": round(top_y / scale, 1),
        "top_chrome_bottom_px": top_bottom,
        "top_chrome_height_px": top_bottom - top_y + 1,
        "gap_island_to_top_chrome_px": top_y - island,
        "gap_island_to_top_chrome_pt": round((top_y - island) / scale, 1),
        "first_content_below_chrome_px": content_y,
        "gap_chrome_to_content_px": None if content_y is None else content_y - top_bottom,
        "gap_chrome_to_content_pt": None
        if content_y is None
        else round((content_y - top_bottom) / scale, 1),
        "bottom_chrome_top_px": None if bottom is None else bottom[0],
        "bottom_chrome_bottom_px": None if bottom is None else bottom[1],
        "bottom_chrome_height_px": None if bottom is None else bottom[1] - bottom[0] + 1,
        "gap_bottom_chrome_to_screen_px": None if bottom is None else height - 1 - bottom[1],
        "gap_bottom_chrome_to_screen_pt": None
        if bottom is None
        else round((height - 1 - bottom[1]) / scale, 1),
    }
    return result


def measure_tab(path: Path) -> dict:
    width, height, pixels = load_rgb(path)
    scale = 3 if width >= 1100 else 2
    island = detect_island_bottom(pixels, width, height)
    strip_x0, strip_x1 = int(width * 0.07), int(width * 0.62)
    means = [row_mean(pixels, width, y, strip_x0, strip_x1) for y in range(height)]
    # Search glass on parchment is often only a few lum above the canvas.
    # Detect the first high-variance row after the island (icons + text).
    search_top = None
    search_bottom = None
    for y in range(max(island + 2, 40), int(height * 0.35)):
        variance = row_var(pixels, width, y, strip_x0, strip_x1)
        if variance > 90:
            run = 1
            while y + run < height and row_var(pixels, width, y + run, strip_x0, strip_x1) > 35:
                run += 1
            if 40 <= run <= 200:
                search_top = y
                search_bottom = y + run - 1
                break
    if search_top is None:
        return {
            "kind": "tab",
            "path": str(path),
            "width": width,
            "height": height,
            "error": "search bar not found",
            "island_bottom_px": island,
        }
    content_y = first_text_row(pixels, width, search_bottom + 4, search_bottom + 280)
    island_gap = search_top - island
    content_gap = None if content_y is None else content_y - search_bottom
    return {
        "kind": "tab",
        "path": str(path),
        "width": width,
        "height": height,
        "scale": scale,
        "island_bottom_px": island,
        "island_bottom_pt": round(island / scale, 1),
        "search_top_px": search_top,
        "search_top_pt": round(search_top / scale, 1),
        "search_bottom_px": search_bottom,
        "search_height_px": search_bottom - search_top + 1,
        "search_height_pt": round((search_bottom - search_top + 1) / scale, 1),
        "gap_island_to_search_px": island_gap,
        "gap_island_to_search_pt": round(island_gap / scale, 1),
        "first_content_px": content_y,
        "first_content_pt": None if content_y is None else round(content_y / scale, 1),
        "gap_search_to_content_px": content_gap,
        "gap_search_to_content_pt": None if content_gap is None else round(content_gap / scale, 1),
        "symmetry_delta_px": None if content_gap is None else abs(content_gap - island_gap),
        "symmetry_delta_pt": None
        if content_gap is None
        else round(abs(content_gap - island_gap) / scale, 1),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("--kind", choices=("article", "tab", "auto"), default="auto")
    args = parser.parse_args()
    kind = args.kind
    if kind == "auto":
        kind = "tab" if "tab" in args.image.name or "home" in args.image.name else "article"
    measured = measure_article(args.image) if kind == "article" else measure_tab(args.image)
    json.dump(measured, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
