import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "../..");
const storageHelper = path.join(repoRoot, "scripts/shared/local-artifact-root.sh");

function localArtifactPath(category) {
  const laneId = process.env.OSRS_LANE_ID || "samsung-rtl-playwright";
  return execFileSync(
    storageHelper,
    ["prepare", "active", laneId, category],
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

async function loadPlaywright() {
  try {
    return await import("playwright");
  } catch (error) {
    const fallback = path.join(
      process.env.HOME,
      ".codex/tmp/samsung-rtl-playwright-harness/node_modules/playwright/index.js",
    );
    if (fs.existsSync(fallback)) {
      return await import(pathToFileURL(fallback).href);
    }
    throw error;
  }
}

const playwright = await loadPlaywright();
const { chromium } = playwright.default || playwright;

const profileDir =
  process.env.SAMSUNG_RTL_PROFILE_DIR ||
  path.join(process.env.HOME, ".codex/state/samsung-rtl-playwright/chrome-profile");
const evidenceDir =
  validateLocalArtifactPath(
    process.env.SAMSUNG_RTL_EVIDENCE_DIR ||
      localArtifactPath("samsung-rtl-playwright"),
  );
const mode = process.argv[2] || "status";
const keepOpen = process.env.KEEP_OPEN === "1" || mode === "login";
const baseApi = "https://developer.samsung.com/remotetestlab/rtl/api/v1/";
const loginWaitMs = Number(process.env.SAMSUNG_RTL_LOGIN_WAIT_MS || 180_000);
const otpPollMs = Number(process.env.SAMSUNG_RTL_OTP_POLL_MS || 5_000);
const samsungRtlPasswordService = process.env.SAMSUNG_RTL_PASSWORD_SERVICE || "samsung-rtl";
const samsungRtlEmail =
  process.env.SAMSUNG_RTL_EMAIL ||
  samsungRtlAccountFromKeychainService(samsungRtlPasswordService);
const useKeychainPassword = process.env.SAMSUNG_RTL_USE_KEYCHAIN_PASSWORD !== "0";
const preferredDeviceId = process.env.SAMSUNG_RTL_DEVICE_ID || "";
const preferredDeviceLocation =
  process.env.SAMSUNG_RTL_DEVICE_LOCATION ||
  process.env.SAMSUNG_RTL_LOCATION_FILTER ||
  "";
const preferredDeviceProduct =
  process.env.SAMSUNG_RTL_DEVICE_PRODUCT ||
  process.env.SAMSUNG_RTL_PRODUCT_FILTER ||
  "";
const forceNewReservation = process.env.SAMSUNG_RTL_FORCE_NEW === "1";
const allowAdditionalReservation = process.env.SAMSUNG_RTL_ALLOW_ADDITIONAL_RESERVATION === "1";
const inspectPanels = process.env.SAMSUNG_RTL_INSPECT_PANELS === "1";
const connectRdb = process.env.SAMSUNG_RTL_RDB_CONNECT === "1";
const holdOpenMs = Number(process.env.SAMSUNG_RTL_HOLD_OPEN_MS || 0);
const messagesDb =
  process.env.SAMSUNG_RTL_MESSAGES_DB ||
  path.join(process.env.HOME, "Library/Messages/chat.db");
const useMessagesOtp = process.env.SAMSUNG_RTL_USE_MESSAGES_OTP !== "0";
const useMessagesLaunchdHelper = process.env.SAMSUNG_RTL_USE_MESSAGES_LAUNCHD_HELPER !== "0";
const messagesHelperDir =
  process.env.SAMSUNG_RTL_MESSAGES_HELPER_DIR ||
  path.join(process.env.HOME, ".cache/samsung-rtl-playwright");
const allowManualLoginWait =
  process.env.SAMSUNG_RTL_ALLOW_MANUAL_LOGIN_WAIT === "1" ||
  mode === "login";
const unattendedLoginGraceMs = Number(process.env.SAMSUNG_RTL_UNATTENDED_LOGIN_GRACE_MS || 30_000);

fs.mkdirSync(profileDir, { recursive: true, mode: 0o700 });
fs.mkdirSync(evidenceDir, { recursive: true });
const downloadDir =
  process.env.SAMSUNG_RTL_DOWNLOAD_DIR ||
  path.resolve(evidenceDir, "../downloads");
fs.mkdirSync(downloadDir, { recursive: true });

let context;
try {
  context = await chromium.launchPersistentContext(profileDir, {
    channel: "chrome",
    headless: false,
    viewport: { width: 1440, height: 1000 },
    acceptDownloads: true,
  });
} catch (error) {
  const message = String(error?.message || error);
  if (
    message.includes("SingletonLock") ||
    message.includes("ProcessSingleton") ||
    message.includes("existing browser session")
  ) {
    console.error(
      "[profile] The Samsung RTL automation Chrome profile is already open. Close that Chrome window or stop the existing samsung-rtl-playwright process, then retry.",
    );
  }
  throw error;
}

context.on("page", page => {
  page.on("dialog", dialog => {
    console.log(`[dialog:${page.url()}] ${dialog.type()} ${dialog.message()}`);
  });
  page.on("console", message => {
    if (message.type() === "error" || message.type() === "warning") {
      console.log(`[console:${message.type()}:${page.url()}] ${message.text().slice(0, 800)}`);
    }
  });
  page.on("pageerror", error => {
    console.log(`[pageerror:${page.url()}] ${String(error.message || error).slice(0, 800)}`);
  });
  page.on("requestfailed", request => {
    const url = request.url();
    if (url.includes("developer.samsung.com/remotetestlab") || url.includes("rtl-front-api")) {
      console.log(`[requestfailed:${page.url()}] ${request.method()} ${url} ${request.failure()?.errorText || ""}`);
    }
  });
  page.on("response", async response => {
    const url = response.url();
    if (response.status() >= 400) {
      let safeUrl = url;
      try {
        const parsed = new URL(url);
        safeUrl = `${parsed.origin}${parsed.pathname}`;
      } catch {
        safeUrl = url.split("?")[0];
      }
      console.log(`[response:${page.url()}] ${response.status()} ${response.request().method()} ${safeUrl}`);
      if (url.includes("-rtl.developer.samsung.com/device/")) {
        const headers = response.request().headers();
        console.log(`[device-host-auth] cookie=${headers.cookie ? "present" : "absent"} authorization=${headers.authorization ? "present" : "absent"} referer=${headers.referer ? "present" : "absent"}`);
        if (headers.authorization) {
          console.log(`[device-host-auth-summary] ${summarizeAuthorization(headers.authorization)}`);
        }
        const body = await response.text().catch(() => "");
        if (body) {
          console.log(`[device-host-body] ${body.slice(0, 1000)}`);
        }
      }
    }
  });
});

function summarizeAuthorization(value) {
  const [scheme, token = ""] = value.split(/\s+/, 2);
  const summary = [`scheme=${scheme || "unknown"}`, `tokenLength=${token.length}`];
  const parts = token.split(".");
  if (/^Bearer$/i.test(scheme) && parts.length >= 2) {
    try {
      const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
      const now = Math.floor(Date.now() / 1000);
      const selected = {
        aud: payload.aud,
        iss: payload.iss,
        iat: payload.iat,
        exp: payload.exp,
        expiresInSeconds: typeof payload.exp === "number" ? payload.exp - now : undefined,
        keys: Object.keys(payload).sort(),
      };
      summary.push(`jwtPayload=${JSON.stringify(selected)}`);
    } catch (error) {
      summary.push(`jwtPayload=unparseable:${String(error.message).split("\n")[0]}`);
    }
  }
  return summary.join(" ");
}

async function getPage() {
  const existing = context.pages().find(page =>
    page.url().includes("developer.samsung.com/remotetestlab"),
  );
  if (existing) return existing;
  const page = await context.newPage();
  await page.goto("https://developer.samsung.com/remotetestlab/reservations", {
    waitUntil: "domcontentloaded",
  });
  return page;
}

async function screenshot(page, name) {
  const file = path.join(evidenceDir, `${new Date().toISOString().replace(/[:.]/g, "-")}-${name}.png`);
  await page.screenshot({ path: file, fullPage: true });
  console.log(`[screenshot] ${file}`);
}

async function status() {
  const page = await getPage();
  await page.waitForLoadState("domcontentloaded");
  await page.waitForTimeout(6000);
  await screenshot(page, "status");
  const text = await page.locator("body").innerText({ timeout: 10_000 }).catch(error => `BODY_READ_ERROR ${error.message}`);
  console.log(`[url] ${page.url()}`);
  console.log(`[title] ${await page.title()}`);
  console.log("[body excerpt]");
  console.log(text.slice(0, 4000));
}

async function dismissDisclaimerAndInspectClient() {
  const pagesBefore = new Set(context.pages());

  const page = await getPage();
  await page.waitForLoadState("domcontentloaded");
  await page.waitForTimeout(8000);
  await screenshot(page, "reservation-before-launch");

  let launched = await clickLaunchControl(page);
  if (!launched) {
    const opened = await openFirstReservationCard(page);
    if (opened) {
      await page.waitForTimeout(2000);
      await screenshot(page, "reservation-card-opened");
    }
  }

  await clearWebClientCookies();
  const popupPromise = context.waitForEvent("page", { timeout: 30_000 }).catch(() => null);
  launched = launched || await clickLaunchControl(page, { visibleTextFallback: true });
  if (!launched) {
    console.log("[launch] Launch button not found after waiting and opening reservation card");
  }

  const popup = launched ? await popupPromise : null;
  if (!popup) {
    await page.waitForTimeout(8000);
  }
  const client = popup || page;
  await client.bringToFront();
  await client.waitForLoadState("domcontentloaded").catch(() => {});
  await logWebClientCookieSummary();
  await waitForWebClientUi(client);
  await screenshot(client, "client-before-disclaimer");

  const okButton = client.getByRole("button", { name: "OK" });
  if ((await okButton.count()) > 0) {
    await okButton.click();
    await client.waitForTimeout(3000);
  } else {
    console.log("[disclaimer] OK button not found");
  }

  await screenshot(client, "client-after-disclaimer");
  console.log(`[client url] ${client.url()}`);
  console.log(`[client title] ${await client.title()}`);
  const body = await client.locator("body").innerText({ timeout: 10_000 }).catch(error => `BODY_READ_ERROR ${error.message}`);
  console.log("[client body excerpt]");
  console.log(body.slice(0, 4000));
}

async function waitForWebClientUi(client) {
  if (!client.url().includes("/remotetestlab/webclient")) return;
  await Promise.race([
    client.getByText(/Remote Debug Bridge|Applications|File Browser|Audio Out|Logs|All ongoing tests have ended/i)
      .first()
      .waitFor({ timeout: 45_000 })
      .catch(() => {}),
    client.waitForTimeout(45_000),
  ]);
}

async function logWebClientCookieSummary() {
  const cookies = await context.cookies([
    "https://developer.samsung.com/remotetestlab/webclient/",
    "https://developer.samsung.com/remotetestlab/reservations",
  ]).catch(() => []);
  const interesting = cookies
    .filter(cookie => /WEB_CLIENT|RTL|SESSION|TOKEN|GATEWAY|DATA|NAME/i.test(cookie.name))
    .map(cookie => ({
      name: cookie.name,
      domain: cookie.domain,
      path: cookie.path,
      valueLength: cookie.value.length,
      expires: cookie.expires,
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
  console.log("[webclient cookies]");
  console.log(JSON.stringify(interesting, null, 2));
}

async function clearWebClientCookies() {
  const cookies = await context.cookies([
    "https://developer.samsung.com/remotetestlab/webclient/",
    "https://developer.samsung.com/remotetestlab/reservations",
  ]).catch(() => []);
  const webClientCookies = cookies.filter(cookie => /^WEB_CLIENT_/i.test(cookie.name));
  if (webClientCookies.length === 0) return;
  await context.clearCookies({
    name: /^WEB_CLIENT_/i,
    domain: /developer\.samsung\.com$/,
  });
  console.log(`[webclient cookies] cleared ${webClientCookies.length} WEB_CLIENT_* cookies before launch`);
}

function launchButtons(page) {
  return page.getByRole("button", {
    name: /^(Start|Open|Launch|Connect|Restart|Resume)$/i,
  });
}

async function clickLaunchControl(page, options = {}) {
  const buttons = launchButtons(page);
  const buttonCount = await buttons.count().catch(() => 0);
  for (let index = 0; index < buttonCount; index += 1) {
    const button = buttons.nth(index);
    const box = await button.boundingBox().catch(() => null);
    if (!box || box.width <= 0 || box.height <= 0) continue;
    await button.click();
    console.log("[launch] Clicked launch control by button role");
    return true;
  }

  if (!options.visibleTextFallback) return false;

  const clicked = await clickFirstVisibleButton(page, [
    "Start",
    "Open",
    "Launch",
    "Restart",
    "Resume",
  ]);
  if (clicked) {
    console.log("[launch] Clicked launch control by visible text");
  }
  return clicked;
}

async function openFirstReservationCard(page) {
  const minutes = page.getByText(/\bminutes?\b/i);
  const count = await minutes.count().catch(() => 0);
  for (let index = 0; index < count; index += 1) {
    const element = minutes.nth(index);
    const box = await element.boundingBox().catch(() => null);
    if (!box || box.width <= 0 || box.height <= 0) continue;
    await element.click().catch(() => {});
    console.log("[launch] Opened the first visible active reservation card");
    return true;
  }

  const headings = page.getByRole("heading");
  const headingCount = await headings.count().catch(() => 0);
  for (let index = 0; index < headingCount; index += 1) {
    const heading = headings.nth(index);
    const text = await heading.innerText().catch(() => "");
    if (!/^Galaxy\s+/i.test(text)) continue;
    const box = await heading.boundingBox().catch(() => null);
    if (!box || box.width <= 0 || box.height <= 0) continue;
    await heading.click().catch(() => {});
    console.log(`[launch] Opened reservation card for ${text}`);
    return true;
  }

  return false;
}

async function apiProbe() {
  const page = await getPage();
  await page.waitForLoadState("domcontentloaded");
  await page.waitForTimeout(6000);
  const base = "https://developer.samsung.com/remotetestlab/rtl/api/v1/";
  const reservationsResponse = await context.request.get(`${base}devices/reservation`, {
    params: { _ts: String(Date.now()) },
  });
  const reservationsText = await reservationsResponse.text();
  console.log(`[api reservation status] ${reservationsResponse.status()} ${reservationsResponse.statusText()}`);
  console.log(reservationsText.slice(0, 5000));

  let reservations;
  try {
    reservations = JSON.parse(reservationsText);
  } catch {
    return;
  }
  const first = Array.isArray(reservations) ? reservations[0] : reservations?.items?.[0];
  if (!first) {
    console.log("[api] no active reservations");
    return;
  }
  console.log("[api first reservation]");
  console.log(JSON.stringify(first, null, 2).slice(0, 5000));

  const reservationId = first.reservationId ?? first.seq ?? first.id;
  const clientType = first.clientType ?? "web";
  if (!reservationId) {
    console.log("[api] no reservation id found; not calling restart");
    return;
  }
  if (!isReusableReservation(first)) {
    console.log(`[api] reservation workStatus=${first.workStatus}; not calling restart because the web client is not reusable`);
    return;
  }
  const restartResponse = await context.request.post(`${base}devices/webclient/restart`, {
    params: { reservationId: String(reservationId), _ts: String(Date.now()) },
  });
  const restartText = await restartResponse.text();
  console.log(`[api restart status] ${restartResponse.status()} ${restartResponse.statusText()} clientType=${clientType} reservationId=${reservationId}`);
  console.log(restartText.slice(0, 5000));
}

function normalizeDevices(payload) {
  if (Array.isArray(payload)) return payload;
  if (Array.isArray(payload?.content)) return payload.content;
  if (Array.isArray(payload?.items)) return payload.items;
  if (Array.isArray(payload?.devices)) return payload.devices;
  return [];
}

function normalizeProducts(payload) {
  if (Array.isArray(payload)) return payload;
  if (Array.isArray(payload?.productList)) return payload.productList;
  if (Array.isArray(payload?.items)) return payload.items;
  return [];
}

function flattenProductDevices(products) {
  return products.flatMap(product => {
    const devices = Array.isArray(product.devices) ? product.devices : [];
    return devices.map(device => ({
      ...device,
      productId: product.productId,
      productName: device.productName || product.productName,
      productBranch: product.productBranch,
      image: device.image || product.image,
    }));
  });
}

function isAvailableDevice(device) {
  return (!device.waiting || device.waiting === "") && device.clientType === "web";
}

function isReusableReservation(reservation) {
  return reservation.clientType === "web" && [1, 3].includes(Number(reservation.workStatus));
}

function includesFilter(value, filter) {
  if (!filter) return true;
  return String(value || "").toLowerCase().includes(filter.toLowerCase());
}

function selectPreferredDevice(devices) {
  const available = devices.filter(device =>
    isAvailableDevice(device) &&
    String(device.osVersionName || "").includes("Android"),
  );

  let filtered = available;
  if (preferredDeviceId) {
    filtered = filtered.filter(device => String(device.deviceId) === String(preferredDeviceId));
  }
  filtered = filtered.filter(device =>
    includesFilter(device.location, preferredDeviceLocation) &&
    includesFilter(device.productName, preferredDeviceProduct),
  );

  if (filtered.length === 0 && (preferredDeviceId || preferredDeviceLocation || preferredDeviceProduct)) {
    console.log("[start] no available web device matched the requested selector; no credits consumed");
    console.log(JSON.stringify({
      preferredDeviceId: preferredDeviceId || null,
      preferredDeviceLocation: preferredDeviceLocation || null,
      preferredDeviceProduct: preferredDeviceProduct || null,
      availableSample: available.slice(0, 12).map(device => ({
        deviceId: device.deviceId,
        deviceName: device.deviceName,
        productName: device.productName,
        osVersionName: device.osVersionName,
        oneUiVer: device.oneUiVer,
        location: device.location,
        clientType: device.clientType,
      })),
    }, null, 2));
    return null;
  }

  return filtered[0] || available[0] || devices.find(isAvailableDevice) || null;
}

function selectReusableReservation(reservations) {
  const reusable = reservations.filter(isReusableReservation);
  if (reusable.length === 0) return null;

  let filtered = reusable;
  if (preferredDeviceId) {
    filtered = filtered.filter(reservation => String(reservation.deviceId) === String(preferredDeviceId));
  }
  filtered = filtered.filter(reservation =>
    includesFilter(reservation.location, preferredDeviceLocation) &&
    includesFilter(reservation.productName, preferredDeviceProduct),
  );

  if (filtered.length === 0 && (preferredDeviceId || preferredDeviceLocation || preferredDeviceProduct)) {
    console.log("[reservation] no active reservation matched the requested selector");
    console.log(JSON.stringify({
      preferredDeviceId: preferredDeviceId || null,
      preferredDeviceLocation: preferredDeviceLocation || null,
      preferredDeviceProduct: preferredDeviceProduct || null,
      activeReservations: reusable.map(reservation => ({
        reservationId: reservation.reservationId ?? reservation.seq ?? reservation.id,
        deviceId: reservation.deviceId,
        deviceName: reservation.deviceName,
        productName: reservation.productName,
        osVersionName: reservation.osVersionName,
        location: reservation.location,
        clientType: reservation.clientType,
        durationHour: reservation.durationHour,
        durationMinute: reservation.durationMinute,
      })),
    }, null, 2));
    return null;
  }

  return filtered[0] || reusable[0];
}

async function getJson(url, params) {
  const response = await context.request.get(url, { params });
  const text = await response.text();
  console.log(`[api get] ${url} ${response.status()} ${response.statusText()}`);
  if (!response.ok()) {
    console.log(text.slice(0, 2000));
    return null;
  }
  try {
    return JSON.parse(text);
  } catch {
    console.log(text.slice(0, 2000));
    return null;
  }
}

async function fetchDevicePages(base, maxPages = 8) {
  const devices = [];
  let totalCount = null;
  for (let pageNum = 1; pageNum <= maxPages; pageNum += 1) {
    const payload = await getJson(`${base}devices`, {
      pageNum: String(pageNum),
      pageSize: "80",
      sortBy: "availability",
      sortOrder: "asc",
      _ts: String(Date.now()),
    });
    const pageDevices = normalizeDevices(payload);
    if (typeof payload?.totalElement === "number") totalCount = payload.totalElement;
    if (typeof payload?.totalCount === "number") totalCount = payload.totalCount;
    devices.push(...pageDevices);
    if (pageDevices.length === 0 || (totalCount !== null && devices.length >= totalCount)) break;
  }
  console.log(`[devices] paged-returned=${devices.length} total=${totalCount ?? "unknown"}`);
  return devices;
}

async function listDevices() {
  const page = await getPage();
  await page.waitForLoadState("domcontentloaded");
  await page.waitForTimeout(3000);
  const base = "https://developer.samsung.com/remotetestlab/rtl/api/v1/";
  const devices = await fetchDevicePages(base);
  let available = devices.filter(isAvailableDevice);
  console.log(`[devices] available-web=${available.length}`);
  if (available.length === 0) {
    console.log("[devices] shortest-wait sample");
    for (const device of devices.slice(0, 8)) {
      console.log(JSON.stringify({
        deviceId: device.deviceId,
        deviceName: device.deviceName,
        productName: device.productName,
        osVersionName: device.osVersionName,
        location: device.location,
        waiting: device.waiting,
        clientType: device.clientType,
        status: device.status,
      }));
    }
  }

  const productsPayload = await getJson(`${base}products`, {
    _ts: String(Date.now()),
  });
  const productDevices = flattenProductDevices(normalizeProducts(productsPayload));
  const productAvailable = productDevices.filter(isAvailableDevice);
  console.log(`[products] flattened-devices=${productDevices.length}`);
  console.log(`[products] available-web=${productAvailable.length}`);
  available = productAvailable.length ? productAvailable : available;
  for (const device of available.slice(0, 12)) {
    console.log(JSON.stringify({
      deviceId: device.deviceId,
      deviceName: device.deviceName,
      productName: device.productName,
      osVersionName: device.osVersionName,
      oneUiVer: device.oneUiVer,
      location: device.location,
      waiting: device.waiting,
      clientType: device.clientType,
    }));
  }
}

async function startSmallWebDevice() {
  const page = await getPage();
  await page.waitForLoadState("domcontentloaded");
  await page.waitForTimeout(3000);
  const base = "https://developer.samsung.com/remotetestlab/rtl/api/v1/";

  const reservationsPayload = await getJson(`${base}devices/reservation`, {
    _ts: String(Date.now()),
  });
  const reservations = Array.isArray(reservationsPayload)
    ? reservationsPayload
    : normalizeDevices(reservationsPayload);
  const reusable = selectReusableReservation(reservations);
  if (reusable && !forceNewReservation) {
    const reservationId = reusable.reservationId ?? reusable.seq ?? reusable.id;
    console.log(`[start] reusing online/free reservationId=${reservationId} product=${reusable.productName} device=${reusable.deviceName}`);
    const restartResponse = await context.request.post(`${base}devices/webclient/restart`, {
      params: { reservationId: String(reservationId), _ts: String(Date.now()) },
    });
    const restartText = await restartResponse.text();
    console.log(`[start restart] ${restartResponse.status()} ${restartResponse.statusText()}`);
    console.log(restartText.slice(0, 2000));
    return await openClientFromApiResponse(restartText);
  }
  if (reusable && forceNewReservation && !allowAdditionalReservation) {
    console.log(
      `[start] active web reservationId=${reusable.reservationId ?? reusable.seq ?? reusable.id} remains for ${reusable.durationHour ?? "?"}h${reusable.durationMinute ?? "?"}m; not starting a second reservation. Set SAMSUNG_RTL_ALLOW_ADDITIONAL_RESERVATION=1 to override after checking credits.`,
    );
    return;
  }

  let devices = await fetchDevicePages(base);
  const productsPayload = await getJson(`${base}products`, {
    _ts: String(Date.now()),
  });
  const productDevices = flattenProductDevices(normalizeProducts(productsPayload));
  if (productDevices.length > devices.length) devices = productDevices;
  const preferred = selectPreferredDevice(devices);
  if (!preferred) {
    console.log("[start] no available web device found in paged inventory; no credits consumed");
    return;
  }
  console.log("[start] about to request the smallest web session:");
  console.log(JSON.stringify({
    deviceId: preferred.deviceId,
    deviceName: preferred.deviceName,
    productName: preferred.productName,
    osVersionName: preferred.osVersionName,
    oneUiVer: preferred.oneUiVer,
    location: preferred.location,
    clientType: preferred.clientType,
    tsg: 2,
    expectedCredits: 2,
    expectedDuration: "30m",
  }, null, 2));

  const startResponse = await context.request.post(`${base}devices/webclient/start`, {
    params: { did: String(preferred.deviceId), tsg: "2", _ts: String(Date.now()) },
  });
  const startText = await startResponse.text();
  console.log(`[start api] ${startResponse.status()} ${startResponse.statusText()}`);
  console.log(startText.slice(0, 3000));
  await openClientFromApiResponse(startText, { inspectPanels });
}

async function reuseActiveWebDevice() {
  const page = await getPage();
  await page.waitForLoadState("domcontentloaded");
  await page.waitForTimeout(3000);
  const base = "https://developer.samsung.com/remotetestlab/rtl/api/v1/";
  const reservationsPayload = await getJson(`${base}devices/reservation`, {
    _ts: String(Date.now()),
  });
  const reservations = Array.isArray(reservationsPayload)
    ? reservationsPayload
    : normalizeDevices(reservationsPayload);
  const reusable = selectReusableReservation(reservations);
  if (!reusable) {
    console.log("[reuse] no online/free web reservation found; no credits consumed");
    return;
  }
  const reservationId = reusable.reservationId ?? reusable.seq ?? reusable.id;
  console.log(`[reuse] reopening reservationId=${reservationId} product=${reusable.productName} device=${reusable.deviceName} remaining=${reusable.durationHour}h${reusable.durationMinute}m`);
  const restartResponse = await context.request.post(`${base}devices/webclient/restart`, {
    params: { reservationId: String(reservationId), _ts: String(Date.now()) },
  });
  const restartText = await restartResponse.text();
  console.log(`[reuse restart] ${restartResponse.status()} ${restartResponse.statusText()}`);
  console.log(restartText.slice(0, 2000));
  await openClientFromApiResponse(restartText, { inspectPanels: true });
}

async function openClientFromApiResponse(text, options = {}) {
  const redirect = text.trim().replace(/^"|"$/g, "").replace(/^redirect:/, "");
  if (!/^https?:\/\//.test(redirect)) {
    console.log("[client] API did not return a redirect URL");
    return;
  }
  const client = await context.newPage();
  await client.goto(redirect, { waitUntil: "domcontentloaded", timeout: 45_000 });
  await client.waitForTimeout(8000);
  await screenshot(client, "rtl-client-opened");
  const okButton = client.getByRole("button", { name: "OK" });
  if ((await okButton.count()) > 0) {
    await okButton.click();
    await client.waitForTimeout(6000);
    await screenshot(client, "rtl-client-after-disclaimer");
  } else {
    console.log("[client] disclaimer OK button not found");
  }
  if (options.inspectPanels) {
    for (const panelName of ["Remote Debug Bridge", "Logs", "Audio Out", "Applications", "File Browser"]) {
      const panel = await firstVisibleTextElement(client, panelName);
      if (!panel) {
        console.log(`[panel] ${panelName}: not found`);
        continue;
      }
      try {
        await panel.click();
        await client.waitForTimeout(3000);
        await screenshot(client, `rtl-panel-${panelName.toLowerCase().replaceAll(" ", "-")}`);
        if (panelName === "Remote Debug Bridge" && connectRdb) {
          await connectRemoteDebugBridge(client);
        }
        const panelText = await client.locator("body").innerText({ timeout: 10_000 }).catch(error => `BODY_READ_ERROR ${error.message}`);
        console.log(`[panel body excerpt: ${panelName}]`);
        console.log(panelText.slice(0, 1500));
      } catch (error) {
        console.log(`[panel] ${panelName}: click failed: ${error.message}`);
      }
    }
  }
  const body = await client.locator("body").innerText({ timeout: 10_000 }).catch(error => `BODY_READ_ERROR ${error.message}`);
  console.log(`[client url] ${client.url()}`);
  console.log(`[client title] ${await client.title()}`);
  console.log("[client body excerpt]");
  console.log(body.slice(0, 4000));
}

async function connectRemoteDebugBridge(client) {
  console.log("[rdb] attempting Remote Debug Bridge Connect flow");
  const firstDownload = client.waitForEvent("download", { timeout: 15_000 }).catch(() => null);
  const clickedConnect = await clickFirstVisibleButton(client, ["Connect"]);
  if (!clickedConnect) {
    console.log("[rdb] Connect button not found");
    return;
  }
  await client.waitForTimeout(3000);
  await screenshot(client, "rtl-rdb-after-connect");

  let download = await firstDownload;
  if (!download) {
    const secondDownload = client.waitForEvent("download", { timeout: 15_000 }).catch(() => null);
    const clickedDownload = await clickFirstVisibleButton(client, ["Download"]);
    if (clickedDownload) {
      await client.waitForTimeout(2000);
      await screenshot(client, "rtl-rdb-after-download-click");
      download = await secondDownload;
    }
  }

  if (!download) {
    const body = await client.locator("body").innerText({ timeout: 5000 }).catch(error => `BODY_READ_ERROR ${error.message}`);
    console.log("[rdb] no download event observed; body excerpt follows");
    console.log(body.slice(0, 2000));
    return;
  }

  const suggested = download.suggestedFilename() || "samsung-rdb.zip";
  const target = path.join(downloadDir, suggested);
  await download.saveAs(target);
  console.log(`[rdb] downloaded ${target}`);
}

async function firstVisibleTextElement(page, text) {
  const matches = await page.getByText(text, { exact: true }).elementHandles();
  for (const match of matches) {
    const box = await match.boundingBox();
    if (box && box.width > 0 && box.height > 0) return match;
  }
  return null;
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function quietJsonGet(url, params = {}) {
  let response;
  try {
    response = await context.request.get(url, { params });
  } catch (error) {
    return {
      ok: false,
      status: 0,
      statusText: "request-failed",
      text: String(error?.message || error).split("\n")[0],
    };
  }
  const text = await response.text();
  if (!response.ok()) {
    return {
      ok: false,
      status: response.status(),
      statusText: response.statusText(),
      text,
    };
  }
  try {
    return {
      ok: true,
      status: response.status(),
      statusText: response.statusText(),
      data: JSON.parse(text),
    };
  } catch {
    return {
      ok: false,
      status: response.status(),
      statusText: response.statusText(),
      text,
    };
  }
}

async function currentUser() {
  const result = await quietJsonGet(`${baseApi}users/me`, {
    _ts: String(Date.now()),
  });
  if (!result.ok) return null;
  return result.data;
}

function userSummary(user) {
  if (!user) return null;
  return {
    point: user.point,
    userType: user.userType,
    isConfirmed2FA: user.isConfirmed2FA,
  };
}

async function printAuthState(prefix) {
  const user = await currentUser();
  console.log(`[${prefix}]`);
  console.log(JSON.stringify(userSummary(user), null, 2));
  return user;
}

async function clickFirstVisibleButton(page, names) {
  for (const name of names) {
    const namePattern = new RegExp(`^\\s*${escapeRegex(name)}\\s*$`, "i");
    for (const role of ["button", "link"]) {
      const byRole = page.getByRole(role, { name: namePattern });
      const roleCount = await byRole.count().catch(() => 0);
      for (let index = 0; index < roleCount; index += 1) {
        const control = byRole.nth(index);
        const box = await control.boundingBox().catch(() => null);
        if (!box || box.width <= 0 || box.height <= 0) continue;
        await control.click().catch(() => {});
        return true;
      }
    }

    const byText = page.getByText(namePattern);
    const textCount = await byText.count().catch(() => 0);
    for (let index = 0; index < textCount; index += 1) {
      const element = byText.nth(index);
      const box = await element.boundingBox().catch(() => null);
      if (!box || box.width <= 0 || box.height <= 0) continue;
      await element.click().catch(() => {});
      return true;
    }
  }
  return false;
}

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function samsungRtlAccountFromKeychainService(service) {
  try {
    const output = execFileSync("/usr/bin/security", [
      "find-generic-password",
      "-s",
      service,
    ], {
      encoding: "utf8",
      timeout: 5000,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const match = output.match(/"acct"<blob>="([^"]+)"/);
    if (match?.[1]) {
      console.log(`[auth] Using Samsung account from macOS Keychain service=${service}.`);
      return match[1];
    }
  } catch {
    // Missing Keychain item is expected until Osamu completes one-time setup.
  }
  return "";
}

async function pageLooksLikeCaptcha(page) {
  const text = await page.locator("body").innerText({ timeout: 1500 }).catch(() => "");
  return /\b(captcha|robot|unusual traffic|security check)\b/i.test(text);
}

async function credentialFieldsNeedHuman(page) {
  const url = page.url();
  if (/account\.samsung\.com/i.test(url)) {
    const bodyText = await page.locator("body").innerText({ timeout: 1500 }).catch(() => "");
    if (!/\b(captcha|robot|unusual traffic|security check)\b/i.test(bodyText)) {
      return true;
    }
  }

  const credentialInputCount = await page
    .locator('input[type="email"], input[type="password"], input[name*="email" i], input[id*="email" i]')
    .count()
    .catch(() => 0);
  const visibleEmailLabelCount = await page
    .getByText(/^\s*Email address\s*$/i)
    .count()
    .catch(() => 0);
  if (credentialInputCount === 0 && visibleEmailLabelCount === 0) return false;
  const submitCount = await page
    .getByRole("button", { name: /sign in|log in|next|continue/i })
    .count()
    .catch(() => 0);
  return submitCount > 0;
}

async function trySubmitSavedCredentials(page) {
  const passwordInputs = await page.locator('input[type="password"]').elementHandles().catch(() => []);
  let hasFilledPassword = false;
  for (const input of passwordInputs) {
    const filled = await input.evaluate(element => element.value.length > 0).catch(() => false);
    if (filled) {
      hasFilledPassword = true;
      break;
    }
  }
  if (!hasFilledPassword) return false;
  return clickFirstVisibleButton(page, ["Sign in", "Sign In", "Log in", "Log In", "Continue", "Next"]);
}

let keychainPasswordUnavailablePrinted = false;
let cachedSamsungRtlPassword = null;
let authSetupHintPrinted = false;
let messagesDbReadableCache;
let messagesLaunchdHelperReadableCache;
let messagesLaunchdHelperErrorCache = "";

function messagesDbReadable() {
  if (!useMessagesOtp || !fs.existsSync(messagesDb)) return false;
  if (messagesDbReadableCache !== undefined) return messagesDbReadableCache;

  try {
    execFileSync("/usr/bin/sqlite3", [
      messagesDb,
      "select count(*) from message limit 1;",
    ], {
      encoding: "utf8",
      timeout: 5000,
      stdio: ["ignore", "pipe", "pipe"],
    });
    messagesDbReadableCache = true;
  } catch {
    messagesDbReadableCache = false;
  }

  return messagesDbReadableCache;
}

function xmlEscape(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function messagesHelperPythonScript() {
  return `#!/usr/bin/env python3
from __future__ import annotations

import re
import sqlite3
import sys
from pathlib import Path


def decode_blob(value: str | None) -> str:
    if not value:
        return ""
    if value.startswith("X'") and value.endswith("'"):
        try:
            return bytes.fromhex(value[2:-1]).decode("utf-8", "ignore")
        except ValueError:
            return ""
    return value


def samsung_codes(content: str) -> list[str]:
    if not re.search(r"samsung|samsung account|verification|verify|one[- ]time|otp|code", content, flags=re.I):
        return []
    return re.findall(r"(?<![0-9])([0-9]{6,8})(?![0-9])", content)


def main() -> int:
    db_path = sys.argv[1]
    mode = sys.argv[2]
    since = float(sys.argv[3])
    out_path = Path(sys.argv[4])
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        try:
            if mode == "probe":
                con.execute("select count(*) from message").fetchone()
                out_path.write_text("OK\\n", encoding="utf-8")
                return 0
            rows = con.execute(
                """
                select coalesce(nullif(text,''), quote(attributedBody))
                from message
                left join handle on message.handle_id = handle.ROWID
                where message.date / 1000000000 + 978307200 >= ?
                order by message.date desc
                limit 50
                """,
                (since,),
            ).fetchall()
        finally:
            con.close()
        codes: list[str] = []
        for row in rows:
            for code in samsung_codes(decode_blob(row[0])):
                if code not in codes:
                    codes.append(code)
        out_path.write_text("\\n".join(codes) + ("\\n" if codes else ""), encoding="utf-8")
        return 0
    except Exception as exc:
        out_path.write_text(f"ERROR\\t{type(exc).__name__}\\t{exc}\\n", encoding="utf-8")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
`;
}

function cleanupMessagesHelperFiles(paths) {
  for (const candidate of paths) {
    try {
      fs.rmSync(candidate, { force: true });
    } catch {
      // Best-effort cleanup for short-lived launchd helper files.
    }
  }
}

function messagesLaunchdHelper(modeName, sinceEpochSeconds) {
  if (!useMessagesOtp || !useMessagesLaunchdHelper || !fs.existsSync(messagesDb)) {
    return { ok: false, error: "Messages OTP launchd helper is disabled or chat.db is missing.", codes: [] };
  }

  fs.mkdirSync(messagesHelperDir, { recursive: true, mode: 0o700 });
  const unique = `${process.pid}.${Date.now()}.${Math.random().toString(16).slice(2)}`;
  const label = `com.omiyawaki.samsung-rtl.messages-helper.${unique}`;
  const scriptPath = path.join(messagesHelperDir, "messages-helper.py");
  const plistPath = path.join(messagesHelperDir, `${label}.plist`);
  const outPath = path.join(messagesHelperDir, `${label}.out`);
  const stdoutPath = path.join(messagesHelperDir, `${label}.stdout`);
  const stderrPath = path.join(messagesHelperDir, `${label}.stderr`);

  fs.writeFileSync(scriptPath, messagesHelperPythonScript(), { encoding: "utf8", mode: 0o700 });
  const args = [
    "/usr/bin/python3",
    scriptPath,
    messagesDb,
    modeName,
    String(Math.trunc(sinceEpochSeconds)),
    outPath,
  ];
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${xmlEscape(label)}</string>
  <key>ProgramArguments</key>
  <array>
${args.map(arg => `    <string>${xmlEscape(arg)}</string>`).join("\n")}
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${xmlEscape(stdoutPath)}</string>
  <key>StandardErrorPath</key>
  <string>${xmlEscape(stderrPath)}</string>
</dict>
</plist>
`;
  fs.writeFileSync(plistPath, plist, { encoding: "utf8", mode: 0o600 });

  const domain = `gui/${process.getuid ? process.getuid() : execFileSync("/usr/bin/id", ["-u"], { encoding: "utf8" }).trim()}`;
  try {
    try {
      execFileSync("/bin/launchctl", ["bootout", domain, plistPath], {
        stdio: ["ignore", "ignore", "ignore"],
        timeout: 5000,
      });
    } catch {
      // The helper is normally not loaded before bootstrap.
    }
    execFileSync("/bin/launchctl", ["bootstrap", domain, plistPath], {
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 5000,
    });
    try {
      execFileSync("/bin/launchctl", ["kickstart", "-k", `${domain}/${label}`], {
        stdio: ["ignore", "ignore", "ignore"],
        timeout: 5000,
      });
    } catch {
      // RunAtLoad is enough on systems where kickstart races with completion.
    }

    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline) {
      if (fs.existsSync(outPath)) {
        const content = fs.readFileSync(outPath, "utf8");
        if (content.startsWith("ERROR\t")) {
          return { ok: false, error: content.trim(), codes: [] };
        }
        const codes = content
          .split("\n")
          .map(line => line.trim())
          .filter(line => /^[0-9]{6,8}$/.test(line));
        return { ok: true, error: "", codes };
      }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 200);
    }
    return { ok: false, error: "launchd helper timed out", codes: [] };
  } catch (error) {
    const stderr = String(error.stderr || "").trim();
    return {
      ok: false,
      error: stderr || String(error.message).split("\n")[0],
      codes: [],
    };
  } finally {
    try {
      execFileSync("/bin/launchctl", ["bootout", domain, plistPath], {
        stdio: ["ignore", "ignore", "ignore"],
        timeout: 5000,
      });
    } catch {
      // Ignore cleanup failures; the label is unique and short-lived.
    }
    cleanupMessagesHelperFiles([plistPath, outPath, stdoutPath, stderrPath]);
  }
}

function messagesLaunchdHelperReadable() {
  if (messagesLaunchdHelperReadableCache !== undefined) return messagesLaunchdHelperReadableCache;
  const result = messagesLaunchdHelper("probe", 0);
  messagesLaunchdHelperReadableCache = result.ok;
  messagesLaunchdHelperErrorCache = result.error || "";
  if (result.ok) {
    console.log("[otp] Messages launchd helper fallback is readable.");
  }
  return messagesLaunchdHelperReadableCache;
}

function messagesOtpReadable() {
  return messagesDbReadable() || messagesLaunchdHelperReadable();
}

function printAuthSetupHint() {
  if (authSetupHintPrinted) return;
  authSetupHintPrinted = true;
  console.log("[auth setup] Closed-loop Samsung auth is missing a configured credential source.");
  if (!samsungRtlEmail) {
    console.log("[auth setup] Add a Keychain item with the Samsung account email, or set SAMSUNG_RTL_EMAIL before running unattended auth.");
  }
  console.log(
    `[auth setup] Store the password with: security add-generic-password -U -s ${samsungRtlPasswordService} -a <samsung-email> -w`,
  );
  if (!messagesOtpReadable()) {
    const helperDetail = messagesLaunchdHelperErrorCache
      ? ` Last launchd helper error: ${messagesLaunchdHelperErrorCache}.`
      : "";
    console.log(`[auth setup] Messages OTP fallback is not readable by direct SQLite or the launchd helper. Grant Full Disk Access to the process launching this harness, or to /usr/bin/python3 for the helper path, if SMS OTP automation is required.${helperDetail}`);
  }
}

function samsungRtlPasswordFromKeychain() {
  if (!useKeychainPassword || !samsungRtlEmail) return null;
  if (cachedSamsungRtlPassword) return cachedSamsungRtlPassword;

  try {
    cachedSamsungRtlPassword = execFileSync("/usr/bin/security", [
      "find-generic-password",
      "-s",
      samsungRtlPasswordService,
      "-a",
      samsungRtlEmail,
      "-w",
    ], {
      encoding: "utf8",
      timeout: 5000,
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
    if (cachedSamsungRtlPassword) {
      console.log(`[auth] Loaded Samsung password from macOS Keychain service=${samsungRtlPasswordService}.`);
    }
  } catch (error) {
    if (!keychainPasswordUnavailablePrinted) {
      keychainPasswordUnavailablePrinted = true;
      console.log(
        `[auth] Keychain password unavailable for service=${samsungRtlPasswordService}: ${String(error.message).split("\n")[0]}`,
      );
    }
    cachedSamsungRtlPassword = null;
  }

  return cachedSamsungRtlPassword || null;
}

function hasConfiguredPasswordAuth() {
  return Boolean(samsungRtlEmail && samsungRtlPasswordFromKeychain());
}

async function trySamsungKeychainCredentials(page) {
  if (!page.url().includes("account.samsung.com")) return false;
  if (!samsungRtlEmail) return false;

  const bodyText = await page.locator("body").innerText({ timeout: 1500 }).catch(() => "");
  let acted = false;

  if (/Email address/i.test(bodyText) && /\bNext\b/i.test(bodyText)) {
    const emailInput = page
      .locator('input[type="email"], input[name*="email" i], input[id*="email" i], input')
      .first();
    const box = await emailInput.boundingBox().catch(() => null);
    if (box) {
      const current = await emailInput.inputValue().catch(() => "");
      if (current !== samsungRtlEmail) {
        await emailInput.fill(samsungRtlEmail);
      }
      const clicked = await clickFirstVisibleButton(page, ["Next"]);
      if (clicked) {
        console.log("[auth] Submitted Samsung email step from configured account.");
        await page.waitForTimeout(2500);
        acted = true;
      }
    }
  }

  const password = samsungRtlPasswordFromKeychain();
  if (!password) return acted;

  const passwordInput = page.locator('input[type="password"]').first();
  const passwordBox = await passwordInput.boundingBox().catch(() => null);
  if (passwordBox) {
    const currentLength = await passwordInput.evaluate(element => element.value.length).catch(() => 0);
    if (currentLength === 0) {
      await passwordInput.fill(password);
    }
    const clicked = await clickFirstVisibleButton(page, ["Sign in", "Sign In", "Log in", "Log In", "Continue", "Next"]);
    if (clicked) {
      console.log("[auth] Submitted Samsung password step from macOS Keychain.");
      await page.waitForTimeout(4000);
      acted = true;
    }
  }

  return acted;
}

async function trySamsungSavedCredentialKeyboard(page) {
  if (!page.url().includes("account.samsung.com")) return false;

  const bodyText = await page.locator("body").innerText({ timeout: 1500 }).catch(() => "");
  if (/Email address/i.test(bodyText) && /\bNext\b/i.test(bodyText)) {
    const emailInput = page
      .locator('input[type="email"], input[name*="email" i], input[id*="email" i], input')
      .first();
    const box = await emailInput.boundingBox().catch(() => null);
    if (box) {
      const before = await emailInput.inputValue().catch(() => "");
      if (!before) {
        await emailInput.click();
        await page.keyboard.press("ArrowDown").catch(() => {});
        await page.keyboard.press("Enter").catch(() => {});
        await page.waitForTimeout(800);
      }
      const after = await emailInput.inputValue().catch(() => "");
      if (after) {
        const clicked = await clickFirstVisibleButton(page, ["Next"]);
        if (clicked) {
          console.log("[auth] Advanced Samsung email step using browser-saved credential UI.");
          await page.waitForTimeout(2500);
          return true;
        }
      }
    }
  }

  if (/Password/i.test(bodyText) && /Sign in/i.test(bodyText)) {
    const passwordInput = page.locator('input[type="password"]').first();
    const box = await passwordInput.boundingBox().catch(() => null);
    if (box) {
      const beforeLength = await passwordInput.evaluate(element => element.value.length).catch(() => 0);
      if (beforeLength === 0) {
        await passwordInput.click();
        await page.keyboard.press("ArrowDown").catch(() => {});
        await page.keyboard.press("Enter").catch(() => {});
        await page.waitForTimeout(800);
      }
      const afterLength = await passwordInput.evaluate(element => element.value.length).catch(() => 0);
      if (afterLength > 0) {
        const clicked = await clickFirstVisibleButton(page, ["Sign in", "Sign In"]);
        if (clicked) {
          console.log("[auth] Submitted Samsung password step using browser-saved credential UI.");
          await page.waitForTimeout(4000);
          return true;
        }
      }
    }
  }

  return false;
}

function decodeMessageText(raw) {
  const trimmed = raw.trim();
  const quotedHex = trimmed.match(/^X'([0-9A-Fa-f]+)'$/);
  let text = trimmed;
  if (quotedHex) {
    text = Buffer.from(quotedHex[1], "hex").toString("utf8");
  }
  return text.replace(/\0/g, " ").replace(/[^\t\n\r -~]+/g, " ");
}

let messagesAccessWarningPrinted = false;
let messagesLaunchdWarningPrinted = false;

function recentSamsungOtpFromLaunchdHelper(sinceEpochSeconds) {
  const result = messagesLaunchdHelper("recent", sinceEpochSeconds);
  if (!result.ok) {
    if (!messagesLaunchdWarningPrinted) {
      messagesLaunchdWarningPrinted = true;
      console.log(
        `[otp] Messages launchd helper fallback is unavailable: ${result.error || "unknown error"}.`,
      );
    }
    return null;
  }

  if (result.codes.length > 0) {
    console.log("[otp] Found a recent Samsung-looking OTP through the Messages launchd helper; submitting it without logging the code.");
    return result.codes[0];
  }

  return null;
}

function recentSamsungOtpFromMessages(sinceEpochSeconds) {
  if (!useMessagesOtp || !fs.existsSync(messagesDb)) return null;

  const sql = `
SELECT COALESCE(NULLIF(text, ''), quote(attributedBody))
FROM message
LEFT JOIN handle ON message.handle_id = handle.ROWID
WHERE ((message.date / 1000000000) + 978307200) >= ${Math.trunc(sinceEpochSeconds)}
ORDER BY message.date DESC
LIMIT 30;
`;

  let output;
  try {
    output = execFileSync("/usr/bin/sqlite3", [messagesDb, sql], {
      encoding: "utf8",
      timeout: 5000,
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (error) {
    if (!messagesAccessWarningPrinted) {
      messagesAccessWarningPrinted = true;
      const stderr = String(error.stderr || "").trim();
      const detail = stderr || String(error.message).split("\n")[0];
      const hint = /authorization denied|operation not permitted|not authorized/i.test(detail)
        ? " Grant Full Disk Access to the process launching this harness, or run it from a Terminal that has Full Disk Access."
        : "";
      console.log(
        `[otp] Direct Messages database read is unavailable: ${detail}.${hint} Trying launchd helper fallback.`,
      );
    }
    return recentSamsungOtpFromLaunchdHelper(sinceEpochSeconds);
  }

  for (const line of output.split("\n")) {
    const text = decodeMessageText(line);
    if (!/(samsung|samsung account|verification|verify|one[- ]time|otp|code)/i.test(text)) {
      continue;
    }
    const match = text.match(/(?:^|[^0-9])([0-9]{6,8})(?:[^0-9]|$)/);
    if (match) {
      console.log("[otp] Found a recent Samsung-looking OTP in Messages; submitting it without logging the code.");
      return match[1];
    }
  }

  return recentSamsungOtpFromLaunchdHelper(sinceEpochSeconds);
}

async function trySubmitOtpCode(page, code) {
  const singleFieldSelectors = [
    'input[autocomplete="one-time-code"]',
    'input[name*="otp" i]',
    'input[id*="otp" i]',
    'input[name*="code" i]',
    'input[id*="code" i]',
    'input[type="tel"]',
    'input[inputmode="numeric"]',
  ];

  for (const selector of singleFieldSelectors) {
    const fields = await page.locator(selector).elementHandles().catch(() => []);
    for (const field of fields) {
      const box = await field.boundingBox().catch(() => null);
      if (!box || box.width <= 0 || box.height <= 0) continue;
      const disabled = await field.evaluate(element => element.disabled || element.readOnly).catch(() => true);
      if (disabled) continue;
      await field.fill(code).catch(() => {});
      await clickFirstVisibleButton(page, ["Verify", "Submit", "Next", "Continue", "Sign in", "Sign In"]);
      return true;
    }
  }

  const allInputs = await page.locator("input").elementHandles().catch(() => []);
  const visibleNumericInputs = [];
  for (const input of allInputs) {
    const box = await input.boundingBox().catch(() => null);
    if (!box || box.width <= 0 || box.height <= 0) continue;
    const type = await input.evaluate(element => element.getAttribute("type") || "").catch(() => "");
    const maxLength = await input.evaluate(element => element.maxLength).catch(() => -1);
    if (type === "password" || maxLength > 1) continue;
    visibleNumericInputs.push(input);
  }

  if (visibleNumericInputs.length >= code.length) {
    for (let index = 0; index < code.length; index += 1) {
      await visibleNumericInputs[index].fill(code[index]).catch(() => {});
    }
    await clickFirstVisibleButton(page, ["Verify", "Submit", "Next", "Continue", "Sign in", "Sign In"]);
    return true;
  }

  return false;
}

async function tryOtpFallback(startedAtEpochSeconds) {
  const code = recentSamsungOtpFromMessages(startedAtEpochSeconds);
  if (!code) return false;

  for (const page of context.pages()) {
    if (!/samsung|account|developer/i.test(page.url())) continue;
    const submitted = await trySubmitOtpCode(page, code).catch(() => false);
    if (submitted) return true;
  }
  return false;
}

async function authenticateWithClosedLoop() {
  const existingUser = await printAuthState("auth before");
  if (existingUser) return true;

  const startedAtEpochSeconds = Math.floor(Date.now() / 1000) - 5;
  const page = await context.newPage();
  await page.goto("https://developer.samsung.com/remote-test-lab", {
    waitUntil: "domcontentloaded",
  });
  await page.waitForTimeout(4000);
  await page.bringToFront().catch(() => {});
  await page.waitForLoadState("domcontentloaded").catch(() => {});
  await screenshot(page, "auth-start").catch(() => {});

  if (await pageLooksLikeCaptcha(page)) {
    console.log("[auth] CAPTCHA or security challenge detected. Stopping before automated login.");
    return false;
  }

  const clickedLogin = await clickFirstVisibleButton(page, ["Sign in", "Sign In", "Log in", "Log In"]).catch(() => false);
  if (!clickedLogin) {
    await clickFirstVisibleButton(page, ["START TESTING", "Start Testing", "Start testing"]).catch(() => {});
  }
  console.log(
    "[auth] Waiting for Samsung authentication. If Chrome does not autofill, enter the Samsung credentials in the open Chrome window and save them to this automation profile if prompted.",
  );

  const deadline = Date.now() + loginWaitMs;
  let lastOtpPoll = 0;
  let lastPrompt = 0;
  let credentialFormFirstSeenAt = 0;

  while (Date.now() < deadline) {
    const user = await currentUser();
    if (user) {
      console.log("[auth] Samsung RTL authentication is active.");
      console.log(JSON.stringify(userSummary(user), null, 2));
      return true;
    }

    for (const candidate of context.pages()) {
      if (await pageLooksLikeCaptcha(candidate).catch(() => false)) {
        console.log("[auth] CAPTCHA or security challenge detected. Stopping before automated login.");
        return false;
      }
      await trySamsungKeychainCredentials(candidate).catch(() => false);
      await trySamsungSavedCredentialKeyboard(candidate).catch(() => false);
      await trySubmitSavedCredentials(candidate).catch(() => false);
    }

    if (Date.now() - lastOtpPoll >= otpPollMs) {
      lastOtpPoll = Date.now();
      const submitted = await tryOtpFallback(startedAtEpochSeconds);
      if (submitted) {
        await sleep(3000);
        continue;
      }
    }

    if (Date.now() - lastPrompt >= 30_000) {
      lastPrompt = Date.now();
      const loginPages = await Promise.all(
        context.pages().map(async candidate => ({
          url: candidate.url(),
          needsHuman: await credentialFieldsNeedHuman(candidate).catch(() => false),
        })),
      );
      if (loginPages.some(candidate => candidate.needsHuman)) {
        console.log("[auth] Still waiting on the Samsung login form in the open Chrome window.");
        if (!credentialFormFirstSeenAt) credentialFormFirstSeenAt = Date.now();
      } else {
        console.log("[auth] Still waiting for Samsung RTL cookies to become valid.");
      }
    }

    const credentialPages = await Promise.all(
      context.pages().map(async candidate => ({
        needsHuman: await credentialFieldsNeedHuman(candidate).catch(() => false),
      })),
    );
    if (credentialPages.some(candidate => candidate.needsHuman)) {
      if (!credentialFormFirstSeenAt) credentialFormFirstSeenAt = Date.now();
      const canUseConfiguredPassword = hasConfiguredPasswordAuth();
      if (!allowManualLoginWait && !canUseConfiguredPassword && Date.now() - credentialFormFirstSeenAt >= unattendedLoginGraceMs) {
        printAuthSetupHint();
        console.log("[auth] Stopping unattended auth before manual credential entry; no credit claim attempted.");
        return false;
      }
    }

    await sleep(3000);
  }

  console.log("[auth] Timed out waiting for Samsung authentication; no credit claim attempted.");
  return false;
}

async function ensureAuthenticatedForMode(label) {
  const user = await currentUser();
  if (user) return true;
  console.log(`[auth] Samsung session is not active before ${label}; refreshing auth first.`);
  return authenticateWithClosedLoop();
}

async function openDirectWebClient() {
  await openClientFromApiResponse("https://developer.samsung.com/remotetestlab/webclient/");
}

async function credits() {
  const page = await getPage();
  await page.waitForLoadState("domcontentloaded");
  await page.waitForTimeout(3000);
  const base = "https://developer.samsung.com/remotetestlab/rtl/api/v1/";
  const user = await getJson(`${base}users/me`, {
    _ts: String(Date.now()),
  });
  console.log("[credits user]");
  console.log(JSON.stringify({
    point: user?.point,
    userType: user?.userType,
    isConfirmed2FA: user?.isConfirmed2FA,
  }, null, 2));
}

async function claimCredits() {
  const page = await getPage();
  await page.waitForLoadState("domcontentloaded");
  await page.waitForTimeout(3000);
  const base = "https://developer.samsung.com/remotetestlab/rtl/api/v1/";
  const before = await getJson(`${base}users/me`, {
    _ts: String(Date.now()),
  });
  const response = await context.request.post(`${base}users/getFreeCredit`, {
    params: { _ts: String(Date.now()) },
  });
  const text = await response.text();
  console.log(`[claim credits] ${response.status()} ${response.statusText()}`);
  console.log(text.slice(0, 2000));
  const after = await getJson(`${base}users/me`, {
    _ts: String(Date.now()),
  });
  console.log("[claim credits summary]");
  console.log(JSON.stringify({
    beforePoint: before?.point,
    afterPoint: after?.point,
  }, null, 2));
}

async function claimCreditsAuto() {
  const authenticated = await authenticateWithClosedLoop();
  if (!authenticated) return;
  await claimCredits();
}

try {
  if (mode === "status") {
    await status();
  } else if (mode === "login") {
    await status();
    console.log("[login] Browser will remain open. Sign in to Samsung there, then close the browser or stop this process.");
    await new Promise(() => {});
  } else if (mode === "client") {
    if (await ensureAuthenticatedForMode("client")) {
      await dismissDisclaimerAndInspectClient();
    }
  } else if (mode === "api") {
    if (await ensureAuthenticatedForMode("api")) {
      await apiProbe();
    }
  } else if (mode === "devices") {
    if (await ensureAuthenticatedForMode("devices")) {
      await listDevices();
    }
  } else if (mode === "start-small") {
    if (await ensureAuthenticatedForMode("start-small")) {
      await startSmallWebDevice();
    }
  } else if (mode === "reuse") {
    if (await ensureAuthenticatedForMode("reuse")) {
      await reuseActiveWebDevice();
    }
  } else if (mode === "webclient") {
    if (await ensureAuthenticatedForMode("webclient")) {
      await openDirectWebClient();
    }
  } else if (mode === "credits") {
    await credits();
  } else if (mode === "claim-credits") {
    await claimCredits();
  } else if (mode === "claim-credits-auto") {
    await claimCreditsAuto();
  } else {
    throw new Error(`Unknown mode: ${mode}`);
  }
} finally {
  if (keepOpen) {
    console.log("[done] leaving browser open for inspection; close it manually or Ctrl-C if run interactively");
    await new Promise(() => {});
  } else {
    if (holdOpenMs > 0) {
      console.log(`[done] holding browser open for ${holdOpenMs} ms before close`);
      await sleep(holdOpenMs);
    }
    await context.close();
    console.log("[done] browser closed");
  }
}
