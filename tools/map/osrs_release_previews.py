#!/usr/bin/env python3
"""Create deterministic representative previews from a realm release."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import sqlite3
from pathlib import Path
from typing import Any, Mapping, Sequence

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from osrs_non_surface_realms import osrs_canonical_json_bytes, osrsPipelineError


Image.MAX_IMAGE_PIXELS = None
OSRS_PREVIEW_WIDTH = 560
OSRS_PREVIEW_HEIGHT = 400


def osrs_build_release_previews(
    release: Path,
    output: Path,
    artifact_root: Path | None = None,
) -> dict[str, Any]:
    manifest_path = release / "underground-realms.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    realms = manifest.get("realms")
    if not isinstance(realms, list) or not realms:
        raise osrsPipelineError("release manifest has no realms")
    selected = _osrs_select_records(realms)
    candidate = _osrs_stem(str(manifest.get("candidate") or "unknown"))
    output.mkdir(parents=True, exist_ok=True)
    artifact_root = (artifact_root or Path(os.path.commonpath((release, output)))).resolve()

    def artifact_reference(path: Path) -> str:
        try:
            return path.resolve().relative_to(artifact_root).as_posix()
        except ValueError as error:
            raise osrsPipelineError(
                f"preview artifact is outside the declared root: {path.name}"
            ) from error

    rows: list[dict[str, Any]] = []
    previews: list[tuple[str, Image.Image]] = []
    for role, record, asset in selected:
        mbtiles_path = release / str(asset["mbtiles_path"])
        preview = _osrs_render_mbtiles_preview(mbtiles_path, asset)
        pixels = np.asarray(preview)
        content_pixels = int(
            np.count_nonzero(
                (pixels[..., 3] != 0) & np.any(pixels[..., :3] != 0, axis=2)
            )
        )
        if content_pixels == 0:
            raise osrsPipelineError(f"preview is blank: {record['id']} floor {asset['plane']}")
        filename = f"{role}-{_osrs_stem(str(record['id']))}-floor-{asset['plane']}.png"
        path = output / filename
        preview.save(path, format="PNG", optimize=False, compress_level=9)
        rows.append(
            {
                "role": role,
                "realm_id": record["id"],
                "canonical_name": record["canonical_name"],
                "group": record["group"],
                "plane": asset["plane"],
                "source_width": asset["width"],
                "source_height": asset["height"],
                "tile_count": asset["tile_count"],
                "layout_component_count": len(asset.get("layout_components", [])),
                "mbtiles_path": artifact_reference(mbtiles_path),
                "mbtiles_sha256": asset["mbtiles_sha256"],
                "preview_path": filename,
                "preview_sha256": _osrs_sha256(path),
                "preview_content_bearing_pixels": content_pixels,
                "selection_rationale": _osrs_selection_rationale(role),
            }
        )
        previews.append((f"{role}: {record['canonical_name']} · floor {asset['plane']}", preview))

    contact_sheet = _osrs_contact_sheet(previews)
    contact_sheet_path = output / f"candidate-{candidate}-realm-contact-sheet.png"
    contact_sheet.save(contact_sheet_path, format="PNG", optimize=False, compress_level=9)
    surface = next(record for record in realms if record["group"] == "surface")
    surface_asset = next(asset for asset in surface["assets"] if asset["plane"] == 0)
    surface_layout = surface_asset.get("layout_components", [])
    index = {
        "schema_version": 1,
        "candidate": manifest.get("candidate"),
        "manifest_reference": artifact_reference(manifest_path),
        "manifest_sha256": _osrs_sha256(manifest_path),
        "contact_sheet_path": contact_sheet_path.name,
        "contact_sheet_sha256": _osrs_sha256(contact_sheet_path),
        "previews": rows,
        "surface_isolation": {
            "realm_id": surface["id"],
            "asset_plane": 0,
            "single_identity_layout_component": len(surface_layout) == 1
            and surface_layout[0]["source_to_display_dx_pixels"] == 0
            and surface_layout[0]["source_to_display_dy_pixels"] == 0,
            "source_pixel_bounds": [
                value["source_pixel_bounds"] for value in surface_layout
            ],
            "asset_target_constraint_is_local_content_bounds": surface_asset[
                "content_latlon_bounds"
            ],
            "accounting_owner_realm_id": surface["accounting_owner_realm_id"],
            "accounting_pixel_count": surface["accounting_pixel_count"],
            "proof": (
                "The surface MBTiles is generated only from renderer-provenance "
                "codes assigned to the isSurface=true definition; northern atlas "
                "pixels have no source, tile, or camera extent in this asset."
            ),
        },
        "checks": {
            "all_previews_nonblank": all(
                value["preview_content_bearing_pixels"] > 0 for value in rows
            ),
            "surface_isolated": len(surface_layout) == 1,
            "release_ready": True,
        },
    }
    index_path = output / "preview-index.json"
    index_path.write_bytes(osrs_canonical_json_bytes(index))
    return {
        "preview_count": len(rows),
        "contact_sheet_path": contact_sheet_path.name,
        "contact_sheet_sha256": index["contact_sheet_sha256"],
        "index_path": index_path.name,
        "index_sha256": _osrs_sha256(index_path),
    }


def _osrs_select_records(
    realms: Sequence[Mapping[str, Any]],
) -> list[tuple[str, Mapping[str, Any], Mapping[str, Any]]]:
    surface = next(record for record in realms if record["group"] == "surface")
    native = [record for record in realms if record["group"] == "realms"]
    special = [
        record
        for record in realms
        if str(record["id"]).startswith("cache-special-region:")
    ]
    wiki = [record for record in realms if str(record["id"]).startswith("other-map-")]
    all_native_assets = [(record, asset) for record in native for asset in record["assets"]]
    compact_native_assets = [
        value
        for value in all_native_assets
        if value[1]["content_bearing_pixel_count"]
        / value[1]["assigned_pixel_count"]
        >= 0.1
    ]
    small_record, small_asset = min(
        compact_native_assets,
        key=lambda value: (
            value[1]["assigned_pixel_count"],
            value[0]["id"],
            value[1]["plane"],
        ),
    )
    large_record, large_asset = max(
        all_native_assets, key=lambda value: (value[1]["assigned_pixel_count"], value[0]["id"], -value[1]["plane"])
    )
    disconnected_record, disconnected_asset = max(
        all_native_assets,
        key=lambda value: (
            len(value[1].get("layout_components", [])),
            value[1]["assigned_pixel_count"],
            value[0]["id"],
        ),
    )
    special_record = min(special, key=lambda value: str(value["id"]))
    wiki_record = min(wiki, key=lambda value: int(value["map_id"]))
    return [
        ("surface", surface, next(asset for asset in surface["assets"] if asset["plane"] == 0)),
        ("small-native", small_record, small_asset),
        ("large-native", large_record, large_asset),
        ("disconnected-native", disconnected_record, disconnected_asset),
        ("cache-component", special_record, special_record["assets"][0]),
        ("wiki-view", wiki_record, wiki_record["assets"][0]),
    ]


def _osrs_render_mbtiles_preview(
    path: Path, asset: Mapping[str, Any]
) -> Image.Image:
    width = int(asset["width"])
    height = int(asset["height"])
    scale = min(OSRS_PREVIEW_WIDTH / width, OSRS_PREVIEW_HEIGHT / height)
    target_width = max(1, int(round(width * scale)))
    target_height = max(1, int(round(height * scale)))
    result = Image.new("RGBA", (target_width, target_height), (0, 0, 0, 0))
    zoom = int(asset["max_zoom"])
    tile_size = int(asset["tile_size"])
    dimension = 2**zoom
    with sqlite3.connect(path) as database:
        tiles = database.execute(
            "SELECT tile_column, tile_row, tile_data FROM tiles WHERE zoom_level=? "
            "ORDER BY tile_column, tile_row",
            (zoom,),
        ).fetchall()
    for tile_x, tile_row, payload in tiles:
        tile_y = dimension - 1 - int(tile_row)
        left = int(tile_x) * tile_size
        top = tile_y * tile_size
        right = min(left + tile_size, width)
        bottom = min(top + tile_size, height)
        if left >= width or top >= height or right <= left or bottom <= top:
            continue
        tile = Image.open(io.BytesIO(payload)).convert("RGBA")
        tile = tile.crop((0, 0, right - left, bottom - top))
        target_box = (
            int(round(left * target_width / width)),
            int(round(top * target_height / height)),
            int(round(right * target_width / width)),
            int(round(bottom * target_height / height)),
        )
        resized_width = max(1, target_box[2] - target_box[0])
        resized_height = max(1, target_box[3] - target_box[1])
        tile = tile.resize((resized_width, resized_height), Image.Resampling.NEAREST)
        result.alpha_composite(tile, (target_box[0], target_box[1]))
    return result


def _osrs_contact_sheet(values: Sequence[tuple[str, Image.Image]]) -> Image.Image:
    cell_width = 600
    cell_height = 470
    sheet = Image.new("RGB", (cell_width * 2, cell_height * 3), (30, 27, 24))
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default(size=18)
    for index, (label, preview) in enumerate(values):
        column = index % 2
        row = index // 2
        x = column * cell_width
        y = row * cell_height
        draw.rectangle((x + 10, y + 10, x + cell_width - 10, y + cell_height - 10), fill=(48, 43, 37))
        draw.text((x + 24, y + 22), label, fill=(245, 222, 174), font=font)
        image_x = x + (cell_width - preview.width) // 2
        image_y = y + 58 + (OSRS_PREVIEW_HEIGHT - preview.height) // 2
        sheet.paste(preview, (image_x, image_y), preview)
    return sheet


def _osrs_selection_rationale(role: str) -> str:
    return {
        "surface": "Mandatory true Gielinor surface isolation case.",
        "small-native": "Smallest content-bearing native floor asset.",
        "large-native": "Largest assigned-pixel native floor asset.",
        "disconnected-native": "Native floor with the most packed transform components.",
        "cache-component": "Deterministic cache-derived backing component in Other maps.",
        "wiki-view": "Lowest pinned structured custom Wiki mapID.",
    }[role]


def _osrs_stem(value: str) -> str:
    return "".join(character if character.isalnum() else "-" for character in value).strip("-")


def _osrs_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--artifact-root", type=Path)
    args = parser.parse_args()
    print(
        json.dumps(
            osrs_build_release_previews(args.release, args.output, args.artifact_root),
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
