#!/usr/bin/env python3
"""Upload an Android App Bundle to Google Play and assign testing tracks.

The primary track is internal testing. After a successful upload, the same
versionCode can be assigned to Closed testing Alpha without a second AAB.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SCOPES = ["https://www.googleapis.com/auth/androidpublisher"]
FORBIDDEN_TRACKS = frozenset({"production", "beta"})
# Extra assignments are only for Closed testing. Do not invent other tracks.
ALLOWED_ALSO_ASSIGN_TRACKS = frozenset({"alpha"})


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aab", type=Path, help="Path to .aab file (required unless --assign-only)")
    parser.add_argument("--package-name", required=True)
    parser.add_argument("--service-account-json", required=True, type=Path)
    parser.add_argument("--track", default="internal")
    parser.add_argument(
        "--also-assign-track",
        action="append",
        default=[],
        dest="also_assign_tracks",
        help="Assign the same versionCode to an additional track after the primary update. Repeatable. Allowed: alpha.",
    )
    parser.add_argument(
        "--assign-only",
        action="store_true",
        help="Skip AAB upload and only assign an already-uploaded versionCode to the requested tracks.",
    )
    parser.add_argument("--version-code", required=True, type=int)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--evidence-dir", type=Path)
    return parser.parse_args()


def release_name_for(version_code: int) -> str:
    return f"internal-{version_code}"


def release_body(version_code: int) -> dict:
    return {
        "releases": [
            {
                "name": release_name_for(version_code),
                "status": "completed",
                "versionCodes": [version_code],
            }
        ]
    }


def normalize_also_assign_tracks(primary_track: str, extra_tracks: list[str]) -> list[str]:
    normalized: list[str] = []
    seen: set[str] = set()
    for raw in extra_tracks:
        track = raw.strip()
        if not track or track == primary_track or track in seen:
            continue
        if track in FORBIDDEN_TRACKS:
            raise ValueError(
                f"Refusing to assign track {track!r}. Production and beta are out of scope."
            )
        if track not in ALLOWED_ALSO_ASSIGN_TRACKS:
            raise ValueError(
                f"Refusing to assign track {track!r}. Additional assignment is limited to Closed testing (alpha)."
            )
        seen.add(track)
        normalized.append(track)
    return normalized


def assigned_tracks(primary_track: str, extra_tracks: list[str]) -> list[str]:
    tracks = [primary_track]
    for track in extra_tracks:
        if track not in tracks:
            tracks.append(track)
    return tracks


def write_evidence(evidence_dir: Path | None, payload: dict) -> None:
    if evidence_dir is None:
        return
    evidence_dir.mkdir(parents=True, exist_ok=True)
    out = evidence_dir / "android-upload-result.json"
    out.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def build_payload(
    args: argparse.Namespace,
    extra_tracks: list[str],
    dry_run: bool,
    bundle: dict | None = None,
    track: dict | None = None,
    extra_track_responses: dict | None = None,
    commit: dict | None = None,
) -> dict:
    payload = {
        "dry_run": dry_run,
        "assign_only": bool(args.assign_only),
        "aab": str(args.aab) if args.aab is not None else None,
        "package_name": args.package_name,
        "track": args.track,
        "also_assign_tracks": extra_tracks,
        "assigned_tracks": assigned_tracks(args.track, extra_tracks),
        "version_code": args.version_code,
        "release_name": release_name_for(args.version_code),
    }
    if dry_run:
        payload["service_account_json"] = str(args.service_account_json)
    else:
        payload.update(
            {
                "bundle": bundle,
                "track_response": track,
                "also_assign_track_responses": extra_track_responses or {},
                "commit": commit,
            }
        )
    return payload


def update_track(service, edit_id: str, package_name: str, track: str, version_code: int) -> dict:
    return (
        service.edits()
        .tracks()
        .update(
            editId=edit_id,
            packageName=package_name,
            track=track,
            body=release_body(version_code),
        )
        .execute()
    )


def main() -> int:
    args = parse_args()

    if args.track in FORBIDDEN_TRACKS:
        print(
            f"ERROR: Refusing to upload or assign track {args.track!r}. Production and beta are out of scope.",
            file=sys.stderr,
        )
        return 1

    try:
        extra_tracks = normalize_also_assign_tracks(args.track, args.also_assign_tracks)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    if args.assign_only:
        if not assigned_tracks(args.track, extra_tracks):
            print("ERROR: --assign-only requires a track to update.", file=sys.stderr)
            return 1
    else:
        if args.aab is None:
            print("ERROR: --aab is required unless --assign-only is set.", file=sys.stderr)
            return 1
        if not args.aab.is_file():
            print(f"ERROR: AAB not found: {args.aab}", file=sys.stderr)
            return 1

    if not args.service_account_json.is_file():
        print(f"ERROR: Service account JSON not found: {args.service_account_json}", file=sys.stderr)
        return 1

    if args.dry_run:
        payload = build_payload(args, extra_tracks, dry_run=True)
        write_evidence(args.evidence_dir, payload)
        print(json.dumps(payload, indent=2))
        return 0

    try:
        from google.oauth2 import service_account
        from googleapiclient.discovery import build
        from googleapiclient.errors import HttpError
        from googleapiclient.http import MediaFileUpload
    except ImportError as exc:
        print(
            "ERROR: Google API Python dependencies missing. Install google-api-python-client and google-auth, "
            "or set OSRSWIKI_INTERNAL_DEPLOY_PYTHON to a Python environment that has them.",
            file=sys.stderr,
        )
        print(f"Import failure: {exc}", file=sys.stderr)
        return 1

    credentials = service_account.Credentials.from_service_account_file(
        str(args.service_account_json),
        scopes=SCOPES,
    )
    service = build("androidpublisher", "v3", credentials=credentials, cache_discovery=False)

    bundle = None
    extra_track_responses: dict[str, dict] = {}
    try:
        edit = service.edits().insert(body={}, packageName=args.package_name).execute()
        edit_id = edit["id"]

        if not args.assign_only:
            media = MediaFileUpload(str(args.aab), mimetype="application/octet-stream", resumable=True)
            bundle = (
                service.edits()
                .bundles()
                .upload(editId=edit_id, packageName=args.package_name, media_body=media)
                .execute()
            )

        track = update_track(service, edit_id, args.package_name, args.track, args.version_code)
        for extra_track in extra_tracks:
            extra_track_responses[extra_track] = update_track(
                service,
                edit_id,
                args.package_name,
                extra_track,
                args.version_code,
            )

        commit = service.edits().commit(editId=edit_id, packageName=args.package_name).execute()
    except HttpError as exc:
        print(f"ERROR: Google Play API request failed: {exc}", file=sys.stderr)
        return 1

    payload = build_payload(
        args,
        extra_tracks,
        dry_run=False,
        bundle=bundle,
        track=track,
        extra_track_responses=extra_track_responses,
        commit=commit,
    )
    write_evidence(args.evidence_dir, payload)
    print(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
