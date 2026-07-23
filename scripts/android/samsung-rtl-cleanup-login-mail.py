#!/usr/bin/env python3
"""Move Samsung RTL login notification emails from iCloud Inbox to Trash.

This is intentionally narrow: it only targets Samsung account sign-in notices
for the current automation run window.
"""

from __future__ import annotations

import argparse
import email
import imaplib
import subprocess
import sys
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import timezone
from email import policy
from email.utils import parsedate_to_datetime, parseaddr
from typing import Iterable


DEFAULT_ACCOUNT = "omiyawaki@icloud.com"
DEFAULT_KEYCHAIN_SERVICE = "paper_intake.imap"
DEFAULT_IMAP_HOST = "imap.mail.me.com"
DEFAULT_INBOX = "INBOX"
DEFAULT_TRASH = "Deleted Messages"
LOGIN_SENDER = "sa.noreply@samsung-mail.com"
LOGIN_SUBJECT = "New sign-in to your Samsung account"


@dataclass(frozen=True)
class MailCandidate:
    uid: bytes
    date_header: str
    sender: str
    subject: str
    message_id: str


def _quote_folder(name: str) -> str:
    return f'"{name}"'


def _message_epoch(date_header: str) -> float | None:
    try:
        parsed = parsedate_to_datetime(date_header)
    except (TypeError, ValueError, IndexError, OverflowError):
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def is_login_notice(
    candidate: MailCandidate,
    *,
    since_epoch: float,
    now_epoch: float,
    lookback_seconds: int,
    future_tolerance_seconds: int = 900,
) -> bool:
    _, sender_email = parseaddr(candidate.sender)
    if sender_email.lower() != LOGIN_SENDER:
        return False
    if candidate.subject.strip() != LOGIN_SUBJECT:
        return False
    message_epoch = _message_epoch(candidate.date_header)
    if message_epoch is None:
        return False
    lower_bound = since_epoch - lookback_seconds
    upper_bound = now_epoch + future_tolerance_seconds
    return lower_bound <= message_epoch <= upper_bound


def select_login_notices(
    candidates: Iterable[MailCandidate],
    *,
    since_epoch: float,
    now_epoch: float,
    lookback_seconds: int,
    future_tolerance_seconds: int = 900,
) -> list[MailCandidate]:
    return [
        candidate
        for candidate in candidates
        if is_login_notice(
            candidate,
            since_epoch=since_epoch,
            now_epoch=now_epoch,
            lookback_seconds=lookback_seconds,
            future_tolerance_seconds=future_tolerance_seconds,
        )
    ]


def uid_set(candidates: Iterable[MailCandidate]) -> bytes:
    return b",".join(candidate.uid for candidate in candidates)


def _read_keychain_password(account: str, service: str) -> str:
    result = subprocess.run(
        ["security", "find-generic-password", "-s", service, "-a", account, "-w"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"missing iCloud IMAP password in Keychain service {service!r} for configured account"
        )
    password = result.stdout.rstrip("\n")
    if not password:
        raise RuntimeError("iCloud IMAP password read from Keychain was empty")
    return password


@contextmanager
def imap_connection(account: str, service: str, host: str):
    password = _read_keychain_password(account, service)
    conn = imaplib.IMAP4_SSL(host)
    try:
        conn.login(account, password)
        yield conn
    finally:
        try:
            conn.logout()
        except imaplib.IMAP4.error:
            pass


def _fetch_header_bytes(conn: imaplib.IMAP4_SSL, uid: bytes) -> bytes | None:
    typ, data = conn.uid(
        "FETCH",
        uid,
        "(BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)])",
    )
    if typ != "OK":
        return None
    for item in data or []:
        if isinstance(item, tuple) and len(item) >= 2 and isinstance(item[1], bytes):
            return item[1]
    return None


def fetch_login_notice_candidates(
    conn: imaplib.IMAP4_SSL,
    *,
    inbox: str,
) -> list[MailCandidate]:
    typ, _ = conn.select(_quote_folder(inbox))
    if typ != "OK":
        raise RuntimeError(f"failed to select iCloud mailbox {inbox!r}")

    typ, data = conn.uid("SEARCH", None, f'(SUBJECT "{LOGIN_SUBJECT}")')
    if typ != "OK":
        raise RuntimeError("failed to search iCloud Inbox for Samsung login notices")

    candidates: list[MailCandidate] = []
    for uid in data[0].split() if data and data[0] else []:
        header_bytes = _fetch_header_bytes(conn, uid)
        if not header_bytes:
            continue
        msg = email.message_from_bytes(header_bytes, policy=policy.default)
        candidates.append(
            MailCandidate(
                uid=uid,
                date_header=str(msg.get("Date", "")),
                sender=str(msg.get("From", "")),
                subject=str(msg.get("Subject", "")),
                message_id=str(msg.get("Message-Id", "")).strip(),
            )
        )
    return candidates


def move_uid_set_to_trash(conn: imaplib.IMAP4_SSL, uids: bytes, *, trash: str) -> bool:
    if not uids:
        return True
    quoted_trash = _quote_folder(trash)
    try:
        typ, _ = conn.uid("MOVE", uids, quoted_trash)
        if typ == "OK":
            return True
    except imaplib.IMAP4.error:
        pass

    try:
        typ, _ = conn.uid("COPY", uids, quoted_trash)
    except imaplib.IMAP4.error:
        return False
    if typ != "OK":
        return False
    typ, _ = conn.uid("STORE", uids, "+FLAGS", r"(\Deleted)")
    if typ != "OK":
        return False
    typ, _ = conn.expunge()
    return typ == "OK"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true", help="print selected notices without moving mail")
    mode.add_argument("--move-to-trash", action="store_true", help="move selected notices to iCloud Trash")
    parser.add_argument("--since-epoch", type=float, required=True)
    parser.add_argument("--lookback-seconds", type=int, default=300)
    parser.add_argument("--future-tolerance-seconds", type=int, default=900)
    parser.add_argument("--account", default=DEFAULT_ACCOUNT)
    parser.add_argument("--keychain-service", default=DEFAULT_KEYCHAIN_SERVICE)
    parser.add_argument("--imap-host", default=DEFAULT_IMAP_HOST)
    parser.add_argument("--inbox", default=DEFAULT_INBOX)
    parser.add_argument("--trash", default=DEFAULT_TRASH)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    now_epoch = time.time()

    with imap_connection(args.account, args.keychain_service, args.imap_host) as conn:
        candidates = fetch_login_notice_candidates(conn, inbox=args.inbox)
        selected = select_login_notices(
            candidates,
            since_epoch=args.since_epoch,
            now_epoch=now_epoch,
            lookback_seconds=args.lookback_seconds,
            future_tolerance_seconds=args.future_tolerance_seconds,
        )
        print(
            f"[samsung-login-mail] candidates={len(candidates)} selected={len(selected)}"
        )
        for candidate in selected:
            print(
                "[samsung-login-mail] selected "
                f"uid={candidate.uid.decode('ascii', 'replace')} "
                f"date={candidate.date_header} "
                f"message_id={candidate.message_id}"
            )
        if args.dry_run or not selected:
            return 0
        if not move_uid_set_to_trash(conn, uid_set(selected), trash=args.trash):
            print("[samsung-login-mail] failed to move selected notices", file=sys.stderr)
            return 1
        print(f"[samsung-login-mail] moved={len(selected)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
