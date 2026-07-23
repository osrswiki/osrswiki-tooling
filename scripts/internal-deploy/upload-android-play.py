#!/usr/bin/env python3
"""Upload an Android App Bundle to Google Play internal testing."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SCOPES = ["https://www.googleapis.com/auth/androidpublisher"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aab", required=True, type=Path, help="Path to .aab file")
    parser.add_argument("--package-name", required=True)
    parser.add_argument("--service-account-json", required=True, type=Path)
    parser.add_argument("--track", default="internal")
    parser.add_argument("--version-code", required=True, type=int)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--evidence-dir", type=Path)
    return parser.parse_args()


def write_evidence(evidence_dir: Path | None, payload: dict) -> None:
    if evidence_dir is None:
        return
    evidence_dir.mkdir(parents=True, exist_ok=True)
    out = evidence_dir / "android-upload-result.json"
    out.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def build_payload(args: argparse.Namespace, dry_run: bool, bundle: dict | None = None, track: dict | None = None, commit: dict | None = None) -> dict:
    payload = {
        "dry_run": dry_run,
        "aab": str(args.aab),
        "package_name": args.package_name,
        "track": args.track,
        "version_code": args.version_code,
        "release_name": f"internal-{args.version_code}",
    }
    if dry_run:
        payload["service_account_json"] = str(args.service_account_json)
    else:
        payload.update({"bundle": bundle, "track_response": track, "commit": commit})
    return payload


def main() -> int:
    args = parse_args()

    if not args.aab.is_file():
        print(f"ERROR: AAB not found: {args.aab}", file=sys.stderr)
        return 1
    if not args.service_account_json.is_file():
        print(f"ERROR: Service account JSON not found: {args.service_account_json}", file=sys.stderr)
        return 1

    if args.dry_run:
        payload = build_payload(args, dry_run=True)
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

    try:
        edit = service.edits().insert(body={}, packageName=args.package_name).execute()
        edit_id = edit["id"]

        media = MediaFileUpload(str(args.aab), mimetype="application/octet-stream", resumable=True)
        bundle = (
            service.edits()
            .bundles()
            .upload(editId=edit_id, packageName=args.package_name, media_body=media)
            .execute()
        )

        track_body = {
            "releases": [
                {
                    "name": f"internal-{args.version_code}",
                    "status": "completed",
                    "versionCodes": [args.version_code],
                }
            ]
        }
        track = (
            service.edits()
            .tracks()
            .update(
                editId=edit_id,
                packageName=args.package_name,
                track=args.track,
                body=track_body,
            )
            .execute()
        )

        commit = service.edits().commit(editId=edit_id, packageName=args.package_name).execute()
    except HttpError as exc:
        print(f"ERROR: Google Play API request failed: {exc}", file=sys.stderr)
        return 1

    payload = build_payload(args, dry_run=False, bundle=bundle, track=track, commit=commit)
    write_evidence(args.evidence_dir, payload)
    print(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
