#!/usr/bin/env python3
"""Drive every catalogued calculator in a live Android WebView.

Unit tests and wiki ?action=render cannot prove the gadget form replaced the
placeholder. This probe opens each catalog title in the installed app, waits
for OOUI widgets, and records whether Submit/Lookup is on-screen.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import subprocess
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SNAPSHOT = ROOT / "shared" / "manifests" / "osrs-wiki-calculators.json"
PROBE_JS = r"""
(() => {
  const text = (document.body && document.body.innerText) || '';
  const waiting = /Please wait for the form to load/i.test(text);
  const btn = [...document.querySelectorAll('button, .oo-ui-buttonElement-button')].find((el) =>
    /submit|lookup|calculate/i.test((el.innerText || el.value || ''))
  );
  const result = document.querySelector('[id$="Result"]');
  const br = btn ? btn.getBoundingClientRect() : null;
  return {
    title: document.title,
    waiting,
    ooui: document.querySelectorAll('.oo-ui-widget').length,
    hasConfig: !!document.querySelector('pre.jcConfig'),
    btnText: btn ? String(btn.innerText || btn.value || '').slice(0, 40) : '',
    btnX: br ? Math.round(br.left) : null,
    btnVisible: !!(br && br.width > 8 && br.left >= 0 && br.left < (window.innerWidth - 4)),
    resultText: result ? String(result.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 180) : '',
    vw: window.innerWidth
  };
})()
"""


def adb(serial: str, *args: str) -> str:
    cmd = ["adb", "-s", serial, *args]
    return subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT).strip()


def load_catalog() -> list[dict]:
    payload = json.loads(SNAPSHOT.read_text())
    return list(payload.get("calculators") or [])


def page_url(title: str) -> str:
    path = title.replace(" ", "_")
    return "osrswiki://page/" + urllib.parse.quote(path, safe=":")


async def eval_js(wsurl: str, expression: str):
    import websockets

    async with websockets.connect(wsurl, max_size=8_000_000) as ws:
        await ws.send(json.dumps({
            "id": 1,
            "method": "Runtime.evaluate",
            "params": {"expression": expression, "returnByValue": True},
        }))
        while True:
            msg = json.loads(await ws.recv())
            if msg.get("id") == 1:
                if "error" in msg:
                    raise RuntimeError(msg["error"])
                return msg.get("result", {}).get("result", {}).get("value")


def cdp_pages() -> list[dict]:
    with urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=5) as response:
        return json.loads(response.read().decode("utf-8"))


def attach_cdp(serial: str) -> None:
    pid = adb(serial, "shell", "pidof", "com.omiyawaki.osrswiki").split()[0]
    subprocess.check_call(
        ["adb", "-s", serial, "forward", "tcp:9222", f"localabstract:webview_devtools_remote_{pid}"],
        stdout=subprocess.DEVNULL,
    )


def wiki_path(title: str) -> str:
    return urllib.parse.quote(title.replace(" ", "_"), safe=":")


def is_live_page(page: dict) -> bool:
    url = str(page.get("url") or "")
    title = str(page.get("title") or "").strip()
    if not url:
        return False
    # Injected wiki documents often stay on about:blank while title is set.
    if url.startswith("about:"):
        return bool(title) and title not in {"", "about:blank"}
    return True


def page_matches_title(page: dict, title: str) -> bool:
    url = str(page.get("url") or "").lower()
    page_title = str(page.get("title") or "").lower()
    path = wiki_path(title).lower()
    tokens = {
        title.lower(),
        title.split(":", 1)[-1].rstrip("/").lower(),
        title.replace(" ", "_").lower(),
        title.replace("'", "’").lower(),
    }
    return path in url or any(token and token in page_title for token in tokens)


def choose_target(pages: list[dict], title: str) -> dict | None:
    live = [page for page in pages if is_live_page(page)]
    matches = [page for page in live if page_matches_title(page, title)]
    if matches:
        return matches[-1]
    wiki_pages = [
        page for page in live
        if "oldschool.runescape.wiki" in str(page.get("url") or "")
        and "Special:" not in str(page.get("title") or "")
    ]
    if len(wiki_pages) == 1:
        return wiki_pages[0]
    return None


def pop_to_single_page(serial: str) -> None:
    """Stacked CDP pages were harness noise. One article WebView at a time."""
    try:
        attach_cdp(serial)
        live = [page for page in cdp_pages() if is_live_page(page)]
    except Exception:
        return
    for _ in range(min(6, max(0, len(live) - 1))):
        adb(serial, "shell", "input", "keyevent", "4")
        time.sleep(0.25)


def screenshot_device(serial: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    raw = subprocess.check_output(["adb", "-s", serial, "exec-out", "screencap", "-p"])
    dest.write_bytes(raw)


def click_submit(wsurl: str) -> None:
    asyncio.run(eval_js(wsurl, """
(() => {
  const btn = [...document.querySelectorAll('button, .oo-ui-buttonElement-button')].find((el) =>
    /submit|lookup|calculate/i.test((el.innerText || el.value || ''))
  );
  if (btn) btn.click();
  return !!btn;
})()
"""))


def probe_title(serial: str, title: str, timeout: float, screenshot_dir: Path | None) -> dict:
    adb(serial, "shell", "am", "force-stop", "com.omiyawaki.osrswiki")
    time.sleep(0.45)
    adb(
        serial,
        "shell",
        "am",
        "start",
        "-a",
        "android.intent.action.VIEW",
        "-d",
        page_url(title),
        "-n",
        "com.omiyawaki.osrswiki/.MainActivity",
    )
    deadline = time.time() + timeout
    last = {"title": title, "waiting": True, "ooui": 0, "error": "timeout"}
    while time.time() < deadline:
        time.sleep(0.45)
        try:
            attach_cdp(serial)
            pages = cdp_pages()
        except Exception as exc:
            last = {"title": title, "waiting": True, "ooui": 0, "error": str(exc)}
            continue
        target = choose_target(pages, title)
        if not target or not target.get("webSocketDebuggerUrl"):
            continue
        wsurl = target["webSocketDebuggerUrl"]
        try:
            value = asyncio.run(eval_js(wsurl, PROBE_JS))
        except Exception as exc:
            last = {"title": title, "waiting": True, "ooui": 0, "error": str(exc)}
            continue
        if not isinstance(value, dict):
            continue
        last = value
        last["catalogTitle"] = title
        last["pageUrl"] = target.get("url")
        ooui = int(value.get("ooui") or 0)
        ready = (not value.get("waiting")) and (
            ooui > 0 or bool(value.get("resultText")) or bool(value.get("btnVisible"))
        )
        if ready:
            try:
                click_submit(wsurl)
                time.sleep(0.6)
                refreshed = asyncio.run(eval_js(wsurl, PROBE_JS))
                if isinstance(refreshed, dict):
                    last.update(refreshed)
            except Exception as exc:
                last["submitError"] = str(exc)
            last["ok"] = not last.get("waiting")
            if screenshot_dir is not None:
                safe = "".join(ch if ch.isalnum() or ch in "-_." else "_" for ch in title)
                shot = screenshot_dir / f"{safe}.png"
                screenshot_device(serial, shot)
                last["screenshot"] = str(shot)
            return last
    last["catalogTitle"] = title
    last["ok"] = False
    if screenshot_dir is not None:
        safe = "".join(ch if ch.isalnum() or ch in "-_." else "_" for ch in title)
        shot = screenshot_dir / f"{safe}-fail.png"
        try:
            screenshot_device(serial, shot)
            last["screenshot"] = str(shot)
        except Exception:
            pass
    return last


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial", default=os.environ.get("ANDROID_SERIAL", ""))
    parser.add_argument("--timeout", type=float, default=8.0)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--only", action="append", default=[])
    parser.add_argument("--out", default="")
    parser.add_argument("--screenshot-dir", default="")
    args = parser.parse_args()
    if not args.serial:
        raise SystemExit("ANDROID_SERIAL or --serial is required")
    catalog = load_catalog()
    if args.only:
        wanted = {
            item.strip()
            for block in args.only
            for item in block.split(",")
            if item.strip()
        }
        catalog = [entry for entry in catalog if entry["title"] in wanted]
    if args.limit:
        catalog = catalog[: args.limit]
    screenshot_dir = Path(args.screenshot_dir) if args.screenshot_dir else None
    rows = []
    for index, entry in enumerate(catalog, start=1):
        title = entry["title"]
        row = probe_title(args.serial, title, args.timeout, screenshot_dir)
        rows.append(row)
        pop_to_single_page(args.serial)
        status = "OK" if row.get("ok") else "FAIL"
        print(f"[{index}/{len(catalog)}] {status} {title} ooui={row.get('ooui')} waiting={row.get('waiting')} btn={row.get('btnVisible')}", flush=True)
    failed = [row for row in rows if not row.get("ok")]
    report = {
        "count": len(rows),
        "passed": len(rows) - len(failed),
        "failed": [row.get("catalogTitle") for row in failed],
        "rows": rows,
    }
    out = Path(args.out) if args.out else Path("calculator-live-catalog.json")
    out.write_text(json.dumps(report, indent=2))
    print(f"passed={report['passed']}/{report['count']} wrote {out}", flush=True)
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
