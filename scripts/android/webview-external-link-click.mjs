#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";

const DEFAULT_PACKAGE = "com.omiyawaki.osrswiki";
const DEFAULT_TIMEOUT_MS = 15_000;
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "../..");
const storageHelper = path.join(repoRoot, "scripts/shared/local-artifact-root.sh");

function localArtifactPath(category) {
  const laneId = process.env.OSRS_LANE_ID || "webview-external-link";
  return execFileSync(
    storageHelper,
    ["prepare", "active", laneId, `runs/${timestamp()}-${category}`],
    { encoding: "utf8", env: process.env },
  ).trim();
}

function validateLocalArtifactPath(candidate) {
  return execFileSync(
    storageHelper,
    ["validate-path", path.resolve(candidate)],
    { encoding: "utf8", env: process.env },
  ).trim();
}

export function normalizeNeedle(value) {
  return String(value ?? "")
    .replace(/\s*\.\s*/g, ".")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

export function pickActivationPoint(candidates, viewport, options = {}) {
  const minSizePx = options.minSizePx ?? 1;
  const viewportWidth = Number(viewport?.viewportWidth ?? 0);
  const viewportHeight = Number(viewport?.viewportHeight ?? 0);

  for (const candidate of candidates ?? []) {
    for (const rect of candidate.rects ?? []) {
      const width = Number(rect.width ?? rect.right - rect.left);
      const height = Number(rect.height ?? rect.bottom - rect.top);
      if (width < minSizePx || height < minSizePx) {
        continue;
      }

      const x = (Number(rect.left) + Number(rect.right)) / 2;
      const y = (Number(rect.top) + Number(rect.bottom)) / 2;
      if (x < 0 || y < 0 || x > viewportWidth || y > viewportHeight) {
        continue;
      }
      if (rect.hitMatchesAnchor === false) {
        continue;
      }

      return {
        href: candidate.href,
        text: candidate.text,
        x,
        y,
        rect,
      };
    }
  }

  throw new Error("No visible clickable WebView rect matched the requested external link.");
}

function parseArgs(argv) {
  const options = {
    androidSerial: process.env.ANDROID_SERIAL ?? "",
    appPackage: DEFAULT_PACKAGE,
    hrefContains: "",
    textContains: "",
    expectedUrlContains: "",
    pageTitleContains: "",
    outputDir: process.env.QA_EVIDENCE_DIR || "",
    timeoutMs: DEFAULT_TIMEOUT_MS,
    click: true,
    scrollIfNeeded: true,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--serial":
        options.androidSerial = requireValue(argv, ++index, arg);
        break;
      case "--package":
        options.appPackage = requireValue(argv, ++index, arg);
        break;
      case "--href-contains":
        options.hrefContains = requireValue(argv, ++index, arg);
        break;
      case "--text-contains":
        options.textContains = requireValue(argv, ++index, arg);
        break;
      case "--expected-url-contains":
        options.expectedUrlContains = requireValue(argv, ++index, arg);
        break;
      case "--page-title-contains":
        options.pageTitleContains = requireValue(argv, ++index, arg);
        break;
      case "--timeout":
        options.timeoutMs = Number(requireValue(argv, ++index, arg)) * 1000;
        break;
      case "--output-dir":
        options.outputDir = requireValue(argv, ++index, arg);
        break;
      case "--probe-only":
        options.click = false;
        break;
      case "--no-scroll":
        options.scrollIfNeeded = false;
        break;
      case "-h":
      case "--help":
        usage();
        process.exit(0);
        break;
      default:
        throw new Error(`Unknown option: ${arg}`);
    }
  }

  if (!options.hrefContains && !options.textContains) {
    throw new Error("Provide --href-contains or --text-contains.");
  }
  if (!options.expectedUrlContains) {
    options.expectedUrlContains = options.hrefContains || options.textContains;
  }
  options.outputDir = validateLocalArtifactPath(
    options.outputDir || localArtifactPath("webview-external-link"),
  );
  return options;
}

function requireValue(argv, index, flag) {
  if (index >= argv.length || argv[index].startsWith("--")) {
    throw new Error(`${flag} requires a value.`);
  }
  return argv[index];
}

function usage() {
  console.log(`Usage: scripts/android/webview-external-link-click.mjs [options]

Activates an in-article Android WebView link through the WebView DevTools
endpoint. The helper queries DOM geometry and hit-testing inside the WebView,
then dispatches a DevTools mouse click at the verified content coordinate.

Options:
  --href-contains TEXT         Required unless --text-contains is provided.
  --text-contains TEXT         Match visible link text or aria label.
  --expected-url-contains TEXT Expected URL evidence after click.
  --page-title-contains TEXT   Prefer a matching WebView DevTools page.
  --serial SERIAL             Defaults to ANDROID_SERIAL.
  --package PACKAGE           Defaults to ${DEFAULT_PACKAGE}.
  --timeout SEC               Defaults to ${DEFAULT_TIMEOUT_MS / 1000}.
  --output-dir DIR            Evidence directory.
  --probe-only                Query and verify the link without clicking.
  --no-scroll                 Do not scroll a matching offscreen link into view.
  -h, --help                  Show this help.
`);
}

function timestamp() {
  return new Date().toISOString().replace(/[:.]/g, "-");
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

function adb(serial, args, options = {}) {
  return execFileSync("adb", ["-s", serial, ...args], {
    encoding: options.encoding ?? "utf8",
    stdio: options.stdio ?? ["ignore", "pipe", "pipe"],
  });
}

function captureCommand(outputDir, name, command, args) {
  const file = path.join(outputDir, `${name}.txt`);
  let text = `$ ${[command, ...args].map(shellQuote).join(" ")}\n`;
  try {
    text += execFileSync(command, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  } catch (error) {
    text += error.stdout?.toString() ?? "";
    text += error.stderr?.toString() ?? "";
    text += `\n(exit ${error.status ?? "unknown"})\n`;
  }
  fs.writeFileSync(file, text, "utf8");
  return file;
}

function ensureDevice(serial) {
  if (!serial) {
    throw new Error("ANDROID_SERIAL is not set. Pass --serial or export ANDROID_SERIAL.");
  }
  const state = adb(serial, ["get-state"]).trim();
  if (state !== "device") {
    throw new Error(`Device ${serial} is not ready: ${state}`);
  }
}

function findWebViewSocket(serial, appPackage, outputDir) {
  const appPid = adb(serial, ["shell", "pidof", "-s", appPackage]).trim();
  fs.writeFileSync(path.join(outputDir, "app-pid.txt"), `${appPid}\n`, "utf8");

  const procNetUnix = adb(serial, ["shell", "cat", "/proc/net/unix"]);
  fs.writeFileSync(path.join(outputDir, "proc-net-unix.txt"), procNetUnix, "utf8");
  const sockets = [...new Set(procNetUnix.match(/webview_devtools_remote_\d+/g) ?? [])];
  if (sockets.length === 0) {
    throw new Error("No Android WebView DevTools sockets found. Confirm this is a debug build with WebView debugging enabled.");
  }

  return sockets.find((socket) => socket.endsWith(`_${appPid}`)) ?? sockets.at(-1);
}

function forwardDevTools(serial, socketName, outputDir) {
  const assignedPort = execFileSync("adb", ["-s", serial, "forward", "tcp:0", `localabstract:${socketName}`], {
    encoding: "utf8",
  }).trim();
  fs.writeFileSync(path.join(outputDir, "devtools-forward.txt"), `tcp:${assignedPort} localabstract:${socketName}\n`, "utf8");
  return Number(assignedPort);
}

function removeForward(serial, port) {
  if (Number.isFinite(port)) {
    execFileSync("adb", ["-s", serial, "forward", "--remove", `tcp:${port}`], { stdio: "ignore" });
  }
}

async function fetchJson(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} from ${url}`);
  }
  return response.json();
}

function chooseDevToolsPage(pages, pageTitleContains = "") {
  const pageNeedle = normalizeNeedle(pageTitleContains);
  const candidates = pages.filter((page) => page.webSocketDebuggerUrl && page.type !== "other");
  if (pageNeedle) {
    const match = candidates.find((page) => normalizeNeedle(`${page.title} ${page.url}`).includes(pageNeedle));
    if (match) {
      return match;
    }
  }
  const article = candidates.find((page) => normalizeNeedle(`${page.title} ${page.url}`).includes("old school runescape"));
  return article ?? candidates[0];
}

class CdpClient {
  constructor(webSocketUrl) {
    this.webSocketUrl = webSocketUrl;
    this.nextId = 1;
    this.pending = new Map();
  }

  async connect() {
    this.socket = new WebSocket(this.webSocketUrl);
    this.socket.addEventListener("message", (event) => this.onMessage(event));
    await new Promise((resolve, reject) => {
      this.socket.addEventListener("open", resolve, { once: true });
      this.socket.addEventListener("error", reject, { once: true });
    });
  }

  onMessage(event) {
    const message = JSON.parse(event.data);
    if (!message.id || !this.pending.has(message.id)) {
      return;
    }
    const { resolve, reject } = this.pending.get(message.id);
    this.pending.delete(message.id);
    if (message.error) {
      reject(new Error(`${message.error.message}: ${message.error.data ?? ""}`));
    } else {
      resolve(message.result);
    }
  }

  send(method, params = {}) {
    const id = this.nextId++;
    const payload = JSON.stringify({ id, method, params });
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.socket.send(payload);
    });
  }

  close() {
    this.socket?.close();
  }
}

function buildProbeExpression(options) {
  const hrefContains = normalizeNeedle(options.hrefContains);
  const textContains = normalizeNeedle(options.textContains);
  return `
(() => {
  const normalize = (value) => String(value || '')
    .replace(/\\s*\\.\\s*/g, '.')
    .replace(/\\s+/g, ' ')
    .trim()
    .toLowerCase();
  const hrefNeedle = ${JSON.stringify(hrefContains)};
  const textNeedle = ${JSON.stringify(textContains)};
  const anchors = Array.from(document.querySelectorAll('a[href]'));
  const candidates = anchors.map((anchor, index) => {
    const href = anchor.href || anchor.getAttribute('href') || '';
    const text = anchor.innerText || anchor.textContent || '';
    const label = anchor.getAttribute('aria-label') || anchor.getAttribute('title') || '';
    const normalizedHref = normalize(href);
    const normalizedText = normalize([text, label].filter(Boolean).join(' '));
    if (hrefNeedle && !normalizedHref.includes(hrefNeedle)) {
      return null;
    }
    if (textNeedle && !normalizedText.includes(textNeedle)) {
      return null;
    }
    const rects = Array.from(anchor.getClientRects()).map((rect) => {
      const left = rect.left;
      const top = rect.top;
      const right = rect.right;
      const bottom = rect.bottom;
      const x = (left + right) / 2;
      const y = (top + bottom) / 2;
      const hit = document.elementFromPoint(x, y);
      const hitAnchor = hit && (hit === anchor || anchor.contains(hit) || (hit.closest && hit.closest('a') === anchor));
      return {
        left,
        top,
        right,
        bottom,
        width: rect.width,
        height: rect.height,
        hitMatchesAnchor: Boolean(hitAnchor),
      };
    });
    return { index, href, text: text || label, normalizedHref, normalizedText, rects };
  }).filter(Boolean);
  return {
    url: location.href,
    title: document.title,
    viewportWidth: window.innerWidth,
    viewportHeight: window.innerHeight,
    devicePixelRatio: window.devicePixelRatio,
    scrollX: window.scrollX,
    scrollY: window.scrollY,
    candidates,
  };
})()
`;
}

function buildScrollExpression(options) {
  const hrefContains = normalizeNeedle(options.hrefContains);
  const textContains = normalizeNeedle(options.textContains);
  return `
(() => {
  const normalize = (value) => String(value || '')
    .replace(/\\s*\\.\\s*/g, '.')
    .replace(/\\s+/g, ' ')
    .trim()
    .toLowerCase();
  const hrefNeedle = ${JSON.stringify(hrefContains)};
  const textNeedle = ${JSON.stringify(textContains)};
  const anchor = Array.from(document.querySelectorAll('a[href]')).find((item) => {
    const href = normalize(item.href || item.getAttribute('href') || '');
    const text = normalize([item.innerText || item.textContent || '', item.getAttribute('aria-label') || '', item.getAttribute('title') || ''].join(' '));
    return (!hrefNeedle || href.includes(hrefNeedle)) && (!textNeedle || text.includes(textNeedle));
  });
  if (!anchor) {
    return false;
  }
  anchor.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
  return true;
})()
`;
}

async function evaluateJson(cdp, expression) {
  const result = await cdp.send("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true,
  });
  if (result.exceptionDetails) {
    throw new Error(`Runtime.evaluate failed: ${JSON.stringify(result.exceptionDetails)}`);
  }
  return result.result.value;
}

async function probeActivationPoint(cdp, options, outputDir) {
  let probe = await evaluateJson(cdp, buildProbeExpression(options));
  fs.writeFileSync(path.join(outputDir, "webview-link-probe-before.json"), JSON.stringify(probe, null, 2), "utf8");

  try {
    return { probe, point: pickActivationPoint(probe.candidates, probe) };
  } catch (error) {
    if (!options.scrollIfNeeded) {
      throw error;
    }
  }

  const didScroll = await evaluateJson(cdp, buildScrollExpression(options));
  fs.writeFileSync(path.join(outputDir, "webview-link-scroll.json"), JSON.stringify({ didScroll }, null, 2), "utf8");
  if (didScroll) {
    await delay(500);
  }

  probe = await evaluateJson(cdp, buildProbeExpression(options));
  fs.writeFileSync(path.join(outputDir, "webview-link-probe-after-scroll.json"), JSON.stringify(probe, null, 2), "utf8");
  return { probe, point: pickActivationPoint(probe.candidates, probe) };
}

async function dispatchClick(cdp, point) {
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: point.x, y: point.y });
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mousePressed",
    x: point.x,
    y: point.y,
    button: "left",
    clickCount: 1,
  });
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mouseReleased",
    x: point.x,
    y: point.y,
    button: "left",
    clickCount: 1,
  });
}

function dumpUi(serial, outputDir, name) {
  const remote = `/sdcard/${name}.xml`;
  try {
    adb(serial, ["shell", "uiautomator", "dump", remote]);
    const xml = adb(serial, ["exec-out", "cat", remote]);
    fs.writeFileSync(path.join(outputDir, `${name}.xml`), xml, "utf8");
  } catch {
    // Evidence best-effort only; command captures below still carry window state.
  }
}

function captureAfterClick(options) {
  const { androidSerial: serial, outputDir } = options;
  captureCommand(outputDir, "window-after-click", "adb", ["-s", serial, "shell", "dumpsys", "window", "displays"]);
  captureCommand(outputDir, "activity-top-after-click", "adb", ["-s", serial, "shell", "dumpsys", "activity", "top"]);
  captureCommand(outputDir, "activity-activities-after-click", "adb", ["-s", serial, "shell", "dumpsys", "activity", "activities"]);
  dumpUi(serial, outputDir, "ui-after-click");
  try {
    const png = adb(serial, ["exec-out", "screencap", "-p"], { encoding: "buffer" });
    fs.writeFileSync(path.join(outputDir, "screen-after-click.png"), png);
  } catch {
    // Best effort.
  }
}

function readIfExists(file) {
  return fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
}

function assertNoAppearanceMistap(options) {
  const combined = [
    "window-after-click.txt",
    "activity-top-after-click.txt",
    "activity-activities-after-click.txt",
    "ui-after-click.xml",
  ].map((name) => readIfExists(path.join(options.outputDir, name))).join("\n");

  if (combined.includes("AppearanceSettingsActivity")) {
    throw new Error("Click opened AppearanceSettingsActivity, indicating a native bottom-bar mistap.");
  }

  const expected = normalizeNeedle(options.expectedUrlContains);
  if (expected && !normalizeNeedle(combined).includes(expected)) {
    throw new Error(`Post-click evidence did not include expected URL fragment: ${options.expectedUrlContains}`);
  }
}

async function run(options) {
  fs.mkdirSync(options.outputDir, { recursive: true });
  const logPath = path.join(options.outputDir, "webview-external-link-click.log");
  const log = (message) => {
    fs.appendFileSync(logPath, `${message}\n`, "utf8");
    console.log(message);
  };

  ensureDevice(options.androidSerial);
  log("Android WebView external link click helper");
  log(`Evidence: ${options.outputDir}`);
  log(`Device: ${options.androidSerial}`);
  log(`Target href/text: ${options.hrefContains || options.textContains}`);

  captureCommand(options.outputDir, "adb-devices", "adb", ["devices", "-l"]);
  const socketName = findWebViewSocket(options.androidSerial, options.appPackage, options.outputDir);
  log(`WebView DevTools socket: ${socketName}`);

  let port;
  let cdp;
  try {
    port = forwardDevTools(options.androidSerial, socketName, options.outputDir);
    const pages = await fetchJson(`http://127.0.0.1:${port}/json/list`);
    fs.writeFileSync(path.join(options.outputDir, "devtools-pages.json"), JSON.stringify(pages, null, 2), "utf8");
    const page = chooseDevToolsPage(pages, options.pageTitleContains);
    if (!page) {
      throw new Error("No debuggable WebView page found.");
    }
    fs.writeFileSync(path.join(options.outputDir, "selected-devtools-page.json"), JSON.stringify(page, null, 2), "utf8");
    log(`Selected WebView page: ${page.title || "(untitled)"} ${page.url || ""}`);

    cdp = new CdpClient(page.webSocketDebuggerUrl);
    await cdp.connect();
    await cdp.send("Runtime.enable");
    await cdp.send("Page.enable");

    const { probe, point } = await probeActivationPoint(cdp, options, options.outputDir);
    fs.writeFileSync(path.join(options.outputDir, "webview-link-activation-point.json"), JSON.stringify(point, null, 2), "utf8");
    log(`Verified WebView link: ${point.href}`);
    log(`Dispatch point in WebView viewport: (${point.x}, ${point.y})`);

    if (!options.click) {
      log("PASS probe-only WebView external link verification");
      return { probe, point };
    }

    await dispatchClick(cdp, point);
    await delay(3_000);
    captureAfterClick(options);
    assertNoAppearanceMistap(options);
    log("PASS WebView external link activation");
    return { probe, point };
  } finally {
    cdp?.close();
    removeForward(options.androidSerial, port);
  }
}

const isCli = process.argv[1] === fileURLToPath(import.meta.url);
if (isCli) {
  run(parseArgs(process.argv.slice(2))).catch((error) => {
    console.error(`FAIL ${error.message}`);
    process.exit(1);
  });
}
