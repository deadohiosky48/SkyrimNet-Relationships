// Headless tests for the dashboard page, against every mock, at 1920x1080 and
// 1280x720. Writes screenshots to ui/tests/screenshots/.
//
//   cd ui/tests && npm install && npm test        (or: node run.mjs)
//
// Uses the browser in $CHROME_PATH when that file exists, and otherwise
// whatever Chromium Playwright finds on its own. Never downloads one.
//
// What "pass" means here: the page renders every mock, every action reaches the
// mock host with the right envelope and comes back, every snapshot the page is
// handed validates against snapshot.schema.json, nothing asks the network for
// anything, and the console stays free of errors. What it cannot mean: that
// Meridian or PrismaUI render it the same way. That is the local check.

import { createServer } from "node:http";
import { readFileSync, existsSync, mkdirSync, readdirSync } from "node:fs";
import { join, dirname, extname, normalize, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createRequire } from "node:module";
import { execSync } from "node:child_process";
import { validate } from "./validate.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const PAGE = join(HERE, "..", "relationships");
const SHOTS = join(HERE, "screenshots");
const VIEWPORTS = [{ width: 1920, height: 1080 }, { width: 1280, height: 720 }];
const schema = JSON.parse(readFileSync(join(PAGE, "snapshot.schema.json"), "utf8"));
const index = JSON.parse(readFileSync(join(PAGE, "mock", "index.json"), "utf8"));
const mockData = Object.fromEntries(index.mocks.map((m) => [m.id, JSON.parse(readFileSync(join(PAGE, "mock", m.id + ".json"), "utf8"))]));

// ------------------------------------------------------------------ plumbing

function loadPlaywright() {
  const req = createRequire(import.meta.url);
  try { return req("playwright"); } catch (e) { /* fall through to a global install */ }
  const globalRoot = execSync("npm root -g", { encoding: "utf8" }).trim();
  return createRequire(join(globalRoot, "noop.js"))("playwright");
}

const results = [];
let failures = 0;
async function test(name, fn) {
  try {
    await fn();
    results.push(`PASS  ${name}`);
  } catch (e) {
    failures++;
    results.push(`FAIL  ${name}\n      ${String(e && e.message ? e.message : e).split("\n").join("\n      ")}`);
  }
}
function assert(cond, msg) { if (!cond) throw new Error(msg); }

const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json", ".png": "image/png" };
function serve() {
  return new Promise((resolve) => {
    const server = createServer((req, res) => {
      const path = decodeURIComponent(new URL(req.url, "http://x").pathname);
      const file = normalize(join(PAGE, path === "/" ? "index.html" : path));
      if (!file.startsWith(PAGE + sep) || !existsSync(file)) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { "Content-Type": TYPES[extname(file)] || "application/octet-stream" });
      res.end(readFileSync(file));
    });
    server.listen(0, "127.0.0.1", () => resolve({ base: `http://127.0.0.1:${server.address().port}/`, server }));
  });
}

// Every page gets the same guards: console errors, page errors and any request
// that leaves the page's own origin are recorded and fail the test.
async function openPage(browser, base, viewport, url, init) {
  const context = await browser.newContext({ viewport, deviceScaleFactor: 1 });
  const page = await context.newPage();
  page.setDefaultTimeout(10000);
  const problems = [];
  page.on("console", (m) => { if (m.type() === "error") problems.push(`console.error: ${m.text()}`); });
  page.on("pageerror", (e) => problems.push(`pageerror: ${e.message}`));
  await context.route("**/*", (route) => {
    const u = route.request().url();
    if (u.startsWith(base) || u.startsWith("file:")) return route.continue();
    problems.push(`network request left the page: ${u}`);
    return route.abort();
  });
  if (init) await page.addInitScript(init);
  await page.goto(url);
  return { page, context, problems };
}

async function ready(page) {
  await page.waitForFunction(() => {
    const s = document.getElementById("summary");
    return s && s.textContent.indexOf("Waiting") < 0;
  });
  // Every snapshot the page is handed from here on is kept for the schema check.
  await page.evaluate(() => { window.__snaps = []; window.snrom.on("snapshot", (s) => window.__snaps.push(s)); });
}

async function finish(t, label) {
  const snaps = await t.page.evaluate(() => window.__snaps || []).catch(() => []);
  snaps.forEach((s, i) => {
    const errs = validate(schema, s);
    if (errs.length) t.problems.push(`${label}: snapshot ${i} fails the schema: ${errs.slice(0, 3).join("; ")}`);
  });
  await t.context.close();
  assert(!t.problems.length, t.problems.join("\n"));
}

const mockUrl = (base, id, extra = "") => `${base}index.html?mock=${id}&devbar=0${extra}`;
const DEV = "&developer=1";

// Words that name what a character has not said (mode.js). None may appear
// anywhere on the page in player mode.
const HIDDEN_WORDS = ["Interested", "Unexamined", "Held:", "Held until", "held back", "Sparked", "Not judged", "Judged:", "Your answer", "Owed"];
const SPOKEN = ["foreclosed", "courting", "declined", "ended"];
const shot = (page, name) => page.screenshot({ path: join(SHOTS, name) });
const vpName = (vp) => `${vp.width}x${vp.height}`;

async function waitToast(page, text) {
  await page.waitForFunction((t) => Array.prototype.some.call(document.querySelectorAll(".toast"), (e) => e.textContent.indexOf(t) >= 0), text);
}
async function clearToasts(page) { await page.evaluate(() => { document.getElementById("toasts").innerHTML = ""; }); }
async function lastLog(page) { return page.evaluate(() => window.__snromMock.log[window.__snromMock.log.length - 1]); }
async function openByName(page, name) {
  await page.fill("#f-text", name);
  await page.click(`.row:has-text("${name}")`);
  await page.waitForFunction((n) => { const h = document.querySelector(".detail h2"); return h && h.textContent === n; }, name);
  await page.fill("#f-text", "");
}
const rowCount = (page) => page.evaluate(() => document.querySelectorAll(".row:not([hidden])").length);
const countText = (page) => page.textContent("#count");

// ------------------------------------------------------------------ tests

async function main() {
  mkdirSync(SHOTS, { recursive: true });
  const { chromium } = loadPlaywright();
  const exe = process.env.CHROME_PATH && existsSync(process.env.CHROME_PATH) ? process.env.CHROME_PATH : undefined;
  console.log(exe ? "browser: $CHROME_PATH" : "browser: $CHROME_PATH missing; using Playwright's own resolution");
  const browser = await chromium.launch({ executablePath: exe });
  const { base, server } = await serve();

  await test("schema: every mock validates, and index.json lists exactly the mock files", async () => {
    const files = readdirSync(join(PAGE, "mock")).filter((f) => f.endsWith(".json") && f !== "index.json").map((f) => f.replace(/\.json$/, "")).sort();
    assert(JSON.stringify(files) === JSON.stringify(index.mocks.map((m) => m.id).sort()), `index.json lists ${index.mocks.map((m) => m.id)} but the folder has ${files}`);
    for (const [id, snap] of Object.entries(mockData)) {
      const errs = validate(schema, snap);
      assert(!errs.length, `${id}: ${errs.slice(0, 5).join("; ")}`);
    }
  });

  await test("mocks: the shapes the brief asks for", async () => {
    const dev = mockData["dev-save"].bonds;
    const following = dev.filter((b) => b.following).length;
    assert(dev.length >= 110 && dev.length <= 130, `dev-save has ${dev.length} bonds, want about 120`);
    assert(following >= 12 && following <= 18, `dev-save has ${following} following, want about 15`);
    const states = new Set(mockData.states.bonds.map((b) => b.state));
    assert(states.size === 7, `states mock covers ${[...states]}`);
    assert(mockData.empty.bonds.length === 0, "empty mock is not empty");
    const reading = mockData.reading;
    assert(reading.roster.status === "reading" && reading.bonds.length === 0 && reading.playthrough.store === null &&
      reading.crosshairTarget.enrolled === null, "reading does not look like the DLL's first snapshot after a load");
    const statuses = new Set(Object.values(mockData).map((m) => m.roster.status));
    assert(["reading", "current", "not ready", "no answer"].every((x) => statuses.has(x)), `mocks cover roster statuses ${[...statuses]}`);
    assert(mockData.refreshing.roster.status === "reading" && mockData.refreshing.bonds.length > 0, "no mock reads with a roster already shown");
    assert(mockData["declined-at-depth"].bonds.some((b) => b.state === "declined" && b.depth.tier >= 4), "no declined companion at Lover depth");
    assert(mockData["foreclosed-child"].bonds.some((b) => b.state === "foreclosed" && (b.foreclosure === "kin" || b.foreclosure === "minor")), "no foreclosed child");
    for (const m of Object.values(mockData)) for (const b of m.bonds) assert(!b.object.isPlayer || b.object.formId === m.player.formId, "a bond's object is not the player");
  });

  for (const vp of VIEWPORTS) {
    for (const m of index.mocks) {
      await test(`render ${m.id} at ${vpName(vp)}`, async () => {
        const t = await openPage(browser, base, vp, mockUrl(base, m.id));
        await ready(t.page);
        const bonds = mockData[m.id].bonds;
        const count = await countText(t.page);
        assert(count.indexOf(String(bonds.length)) === 0, `count reads "${count}", want ${bonds.length}`);
        const current = mockData[m.id].roster.status === "current";
        if (!bonds.length && current) assert(await t.page.isVisible("text=Nobody on your roster yet"), "empty roster message not shown");
        // An empty roster that is not current must never read as nobody.
        if (!current) assert(!(await t.page.isVisible("text=Nobody on your roster yet")), "a roster that is not current reads as empty");
        // Virtualized: never more rows in the DOM than fit, plus overscan.
        const rowH = await t.page.evaluate(() => parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--row-h")));
        const vh = await t.page.evaluate(() => document.getElementById("roster-list").clientHeight);
        const bound = Math.ceil(vh / rowH) + 2 * 6 + 1;
        const rendered = await rowCount(t.page);
        assert(rendered <= bound && rendered <= bonds.length, `${rendered} rows in the DOM, bound ${bound}`);
        const leaked = await t.page.evaluate((words) => words.filter((w) => document.body.innerText.indexOf(w) >= 0), HIDDEN_WORDS);
        assert(!leaked.length, `player mode shows hidden state: ${leaked.join(", ")}`);
        await shot(t.page, `${m.id}-${vpName(vp)}.png`);
        await finish(t, m.id);
      });
    }
  }

  await test("two tracks: a platonic bond never reads Lover or Spouse, in any mock", async () => {
    const t = await openPage(browser, base, VIEWPORTS[0], mockUrl(base, "states"));
    await ready(t.page);
    const bad = await t.page.evaluate((mocks) => {
      const L = window.SNRomUI.labels, out = [];
      Object.keys(mocks).forEach((id) => mocks[id].bonds.forEach((b) => {
        const n = L.tierName(b.track, b.depth.tier);
        if (b.track !== "romantic" && (n === "Lover" || n === "Spouse")) out.push(id + ": " + b.subject.name + " reads " + n);
      }));
      return out;
    }, mockData);
    assert(!bad.length, bad.join("; "));
    await finish(t, "two-tracks");
  });

  await test("reading: the first open after a load renders honestly - reading, no store, no guessed enrollment", async () => {
    for (const vp of VIEWPORTS) {
      const t = await openPage(browser, base, vp, mockUrl(base, "reading"));
      await ready(t.page);
      assert((await t.page.textContent("#store")) === "Store: not reported yet", `store line: ${await t.page.textContent("#store")}`);
      const target = mockData.reading.crosshairTarget;
      assert((await t.page.textContent("#crosshair-text")) === `You were looking at ${target.name}.`, "crosshair line guesses enrollment");
      assert(await t.page.isHidden("#crosshair-btn"), "an Enroll or Show button is offered while enrollment is unknown");
      assert((await t.page.textContent("#summary")).indexOf("Reading your roster from the game") === 0, `summary: ${await t.page.textContent("#summary")}`);
      assert(await t.page.isVisible("text=Reading the roster"), "the empty roster does not say it is reading");
      await shot(t.page, `reading-${vpName(vp)}.png`);
      await finish(t, "reading");
    }
  });

  await test("roster status: reading with a roster stays usable; no answer and not ready say so", async () => {
    // Reading, with the last refresh's roster: a quiet line, and everything works.
    let t = await openPage(browser, base, VIEWPORTS[1], mockUrl(base, "refreshing"));
    await ready(t.page);
    assert(await t.page.isVisible("#roster-status"), "no status line while refreshing");
    assert((await t.page.textContent("#roster-status")).indexOf("Refreshing from the game") === 0, "status line while refreshing");
    assert(!(await t.page.getAttribute("#roster-status", "class")).includes("is-warn"), "refreshing is not a warning");
    await openByName(t.page, "Ansel Vireo");
    await t.page.selectOption("#f-track", "romantic");
    assert((await rowCount(t.page)) === 1, "filters do not work while reading");
    await finish(t, "refreshing");

    // No answer: the same roster, with a warning that it may be out of date.
    t = await openPage(browser, base, VIEWPORTS[1], mockUrl(base, "no-answer"));
    await ready(t.page);
    assert((await t.page.getAttribute("#roster-status", "class")).includes("is-warn"), "no answer is not shown as a warning");
    assert((await t.page.textContent("#roster-status")).indexOf("haven't answered yet") > 0, "no-answer line");
    assert((await rowCount(t.page)) === mockData["no-answer"].bonds.length, "the roster is hidden while there is no answer");
    await shot(t.page, `no-answer-${vpName(VIEWPORTS[1])}.png`);
    await finish(t, "no-answer");

    // Not ready: Papyrus's own words, instead of an empty roster.
    t = await openPage(browser, base, VIEWPORTS[1], mockUrl(base, "not-ready"));
    await ready(t.page);
    const why = mockData["not-ready"].roster.message;
    assert(await t.page.isVisible("text=Relationships isn't ready"), "not-ready heading");
    assert((await t.page.textContent("#roster")).indexOf(why) >= 0, "not-ready does not show Papyrus's reason");
    await shot(t.page, `not-ready-${vpName(VIEWPORTS[1])}.png`);
    await finish(t, "not-ready");

    // A reason is the game's words, set as HTML: it must not become markup.
    t = await openPage(browser, base, VIEWPORTS[1], mockUrl(base, "not-ready"));
    await ready(t.page);
    await t.page.evaluate(() => {
      const s = JSON.parse(JSON.stringify(window.__snromMock.peek()));
      s.roster = { status: "not ready", message: "<b id=\"inj\">x</b>" };
      window.__snromMock.load(s);
    });
    await t.page.waitForFunction(() => document.getElementById("roster").textContent.indexOf("<b id") >= 0);
    assert(!(await t.page.$("#inj")), "roster.message became markup");
    await finish(t, "not-ready-escaped");
  });

  await test("settings.developer: the game's setting turns the developer view on and off", async () => {
    const t = await openPage(browser, base, VIEWPORTS[0], mockUrl(base, "states"));
    await ready(t.page);
    const view = () => t.page.evaluate(() => ({
      badge: !!document.getElementById("dev-badge"),
      options: document.querySelectorAll("#f-state option").length,
      sabeth: (function () {
        const row = Array.prototype.find.call(document.querySelectorAll(".row"), (r) => r.querySelector(".name").textContent === "Sabeth Rimeholt");
        const c = row.querySelector(".c-state .chip");
        return c.hidden ? null : c.textContent;
      })(),
      tools: !!document.querySelector('button[data-op="RequestSparkNow"]'),
    }));
    let v = await view();
    assert(!v.badge && v.options === 5 && v.sabeth === null, `player mode before the setting: ${JSON.stringify(v)}`);
    // The setting arrives in a snapshot, as the DLL sends it.
    const on = JSON.parse(JSON.stringify(mockData.states));
    on.settings.developer = true;
    await t.page.evaluate((s) => window.__snromMock.load(s), on);
    await t.page.waitForFunction(() => !!document.getElementById("dev-badge"));
    await t.page.selectOption("#f-state", "interested");
    await openByName(t.page, "Sabeth Rimeholt");
    v = await view();
    assert(v.badge && v.options === 8 && v.sabeth === "Interested" && v.tools, `developer setting on: ${JSON.stringify(v)}`);
    assert(await t.page.isVisible("#devtools-btn"), "the Developer tools button did not follow the setting on");
    // And back off: the filter on a now-hidden state falls back to Any.
    await t.page.evaluate((s) => window.__snromMock.load(s), mockData.states);
    await t.page.waitForFunction(() => !document.getElementById("dev-badge"));
    v = await view();
    assert(!v.badge && v.options === 5 && v.sabeth === null && !v.tools, `developer setting off again: ${JSON.stringify(v)}`);
    assert(!(await t.page.isVisible("#devtools-btn")), "the Developer tools button did not follow the setting off");
    assert(await t.page.evaluate(() => document.getElementById("f-state").value) === "all", "a hidden state is still selected");
    await finish(t, "settings-developer");
  });

  await test("settings.developer: false from the game never overrides ?developer=1", async () => {
    const t = await openPage(browser, base, VIEWPORTS[1], mockUrl(base, "states", DEV));
    await ready(t.page);
    assert(mockData.states.settings.developer === false, "mock changed: states should carry developer false");
    assert(await t.page.isVisible("#dev-badge"), "?developer=1 lost to settings.developer false");
    await finish(t, "settings-local");
  });

  // ---------------------------------------------------------- display settings
  // Where everything sits, for the display tests: the panel, the roster, the
  // detail, the header's and a row's columns, what style.css was handed, and
  // any text an ellipsis cut short in a row.
  const layoutOf = (page) => page.evaluate(() => {
    const box = (e) => { const r = e.getBoundingClientRect(); return { left: r.left, right: r.right, width: r.width }; };
    const root = document.documentElement, cs = getComputedStyle(root);
    const panelEl = document.getElementById("panel"), detailEl = document.getElementById("detail");
    const row = document.querySelector(".row:not([hidden])");
    const cut = [];
    document.querySelectorAll(".row:not([hidden]) .chip:not([hidden]), .row:not([hidden]) .name, .row:not([hidden]) .name-sub, .row:not([hidden]) .tier, .row:not([hidden]) .pts")
      .forEach((e) => { if (e.textContent && e.scrollWidth > e.clientWidth + 1) cut.push(`${e.className}: ${e.textContent} (${e.scrollWidth} > ${e.clientWidth})`); });
    const pcs = getComputedStyle(panelEl);
    return {
      vw: root.clientWidth, vh: window.innerHeight, narrow: root.classList.contains("is-narrow"),
      fontPx: parseFloat(cs.fontSize), t: parseFloat(cs.getPropertyValue("--t")), rowH: parseFloat(cs.getPropertyValue("--row-h")),
      rowBox: row ? row.getBoundingClientRect().height : 0,
      nameFont: row ? parseFloat(getComputedStyle(row.querySelector(".name")).fontSize) : 0,
      natural: parseFloat(cs.getPropertyValue("--roster-w")),
      nameW: getComputedStyle(document.getElementById("roster")).getPropertyValue("--w-name"),
      min: parseFloat(cs.getPropertyValue("--detail-min")), max: parseFloat(cs.getPropertyValue("--detail-max")),
      room: root.clientWidth - parseFloat(pcs.left) - parseFloat(pcs.right),
      panel: box(panelEl), roster: box(document.getElementById("roster")),
      detail: detailEl.hidden ? null : box(detailEl),
      head: Array.from(document.querySelectorAll(".roster-head > div")).map(box),
      cells: row ? Array.from(row.children).map(box) : [],
      cut,
    };
  });
  const near = (a, b, tol = 1) => Math.abs(a - b) <= tol;
  // What display.js makes of a scale: Auto is the view's height over 1080,
  // kept between 75% and 200%.
  const expectedPx = (scale, vh) => 16 * (scale === "auto" ? Math.max(0.75, Math.min(2, vh / 1080)) : scale / 100);

  // The layout rules, checked wherever the page is drawn.
  function checkLayout(L, label) {
    const where = `${label}: ${JSON.stringify({ narrow: L.narrow, natural: L.natural, min: L.min, max: L.max, room: L.room, panel: L.panel, roster: L.roster, detail: L.detail })}`;
    assert(!L.cut.length, `${label}: text cut short in a row: ${L.cut.slice(0, 4).join("; ")}`);
    // Columns size to their content, and the header and the rows share them.
    L.head.forEach((h, i) => {
      assert(L.cells[i] && near(h.left, L.cells[i].left, 0.5) && near(h.width, L.cells[i].width, 0.5),
        `${label}: header column ${i} and the row's disagree: ${JSON.stringify(h)} vs ${JSON.stringify(L.cells[i])}`);
    });
    assert(L.head[L.head.length - 1].right <= L.roster.right + 0.5, `${label}: the last column spills out of the roster: ${where}`);
    assert(near(L.rowBox, L.rowH, 0.5), `${label}: a row is ${L.rowBox}px, --row-h says ${L.rowH}`);
    if (L.narrow) {
      // The roster has the panel; the detail, if open, slides over it.
      assert(L.room < L.natural + L.min, `${label}: narrow, though the roster and the detail's minimum fit: ${where}`);
      assert(near(L.roster.width, L.panel.width - 2), `${label}: narrow, but the roster does not fill the panel: ${where}`);
      // Its columns keep to their content: the name never grows into the room
      // the detail slides over.
      assert(L.cells[0].width <= parseFloat(L.nameW) + 0.5, `${label}: narrow, and the name column stretched: ${L.cells[0].width} > ${L.nameW}`);
      return;
    }
    // Wide: the list does not stretch; the detail takes the rest up to its
    // maximum; past that, even margins with the panel centred.
    assert(near(L.roster.width, L.natural), `${label}: the roster stretched past its columns: ${where}`);
    assert(L.detail, `${label}: wide, but no detail beside the roster`);
    assert(L.detail.width >= L.min - 1 && L.detail.width <= L.max + 1, `${label}: the detail is outside its range: ${where}`);
    if (L.detail.width < L.max - 1) {
      assert(near(L.panel.width, L.room), `${label}: the detail is under its maximum but the panel has margins to spare: ${where}`);
    } else {
      assert(near(L.panel.width, L.natural + L.max + 2), `${label}: the panel grew past the roster and the detail's maximum: ${where}`);
      assert(near(L.panel.left, L.vw - L.panel.right), `${label}: the margins are not even: ${where}`);
    }
  }

  await test("settings.scale and settings.textSize: an open dashboard follows a saved change at once", async () => {
    const vp = { width: 2560, height: 1440 };
    const t = await openPage(browser, base, vp, mockUrl(base, "states"));
    await ready(t.page);
    let L = await layoutOf(t.page);
    assert(near(L.fontPx, expectedPx("auto", 1440), 0.01) && L.t === 1, `Auto at 1440 lines should be 133%: ${L.fontPx}px, --t ${L.t}`);
    checkLayout(L, "2560x1440 auto");
    const rowsBefore = await rowCount(t.page);
    // Saved in the game's panel: the DLL's watcher sends a snapshot carrying it.
    await t.page.evaluate(() => window.__snromMock.settings({ scale: 100 }));
    await t.page.waitForFunction(() => parseFloat(getComputedStyle(document.documentElement).fontSize) === 16);
    L = await layoutOf(t.page);
    assert(near(L.rowH, 74, 0.5), `100%: rows should be 74px (the record and its last change), are ${L.rowH}`);
    checkLayout(L, "2560x1440 100%");
    await t.page.evaluate(() => window.__snromMock.settings({ textSize: "larger" }));
    await t.page.waitForFunction(() => document.documentElement.style.getPropertyValue("--t") === "1.3");
    L = await layoutOf(t.page);
    assert(near(L.fontPx, 16, 0.01) && near(L.nameFont, 16 * 1.3, 0.05), `Larger text on 100%: root ${L.fontPx}px, a name ${L.nameFont}px`);
    assert(near(L.rowH, Math.round(3.5 * 16 * 1.3), 0.5), `Larger text: the rows grow with it, ${L.rowH}px`);
    checkLayout(L, "2560x1440 100% larger");
    await shot(t.page, "display-live-100-larger-2560x1440.png");
    await t.page.evaluate(() => window.__snromMock.settings({ scale: "auto", textSize: "normal" }));
    await t.page.waitForFunction(() => document.documentElement.style.getPropertyValue("--t") === "1");
    L = await layoutOf(t.page);
    assert(near(L.fontPx, expectedPx("auto", 1440), 0.01), `back to Auto: ${L.fontPx}px`);
    assert(await rowCount(t.page) === rowsBefore, "the roster lost rows across the changes");
    // A value this page does not know is a newer DLL: the setting stays put.
    const kept = await t.page.evaluate(() => {
      window.SNRomUI.display.apply({ settings: { scale: "huge", textSize: "enormous" } });
      return [window.SNRomUI.display.scale(), window.SNRomUI.display.textSize()];
    });
    assert(kept[0] === "auto" && kept[1] === "normal", `an unknown setting was taken: ${kept}`);
    await finish(t, "display-live");
  });

  await test("settings.scale: Auto follows the view's height, within 75% to 200%; a fixed scale ignores it", async () => {
    for (const [vp, scale] of [[{ width: 1280, height: 720 }, "auto"], [{ width: 1920, height: 1080 }, "auto"],
      [{ width: 3840, height: 2160 }, "auto"], [{ width: 5120, height: 2880 }, "auto"], [{ width: 2560, height: 1440 }, 90]]) {
      const t = await openPage(browser, base, vp, mockUrl(base, "states", `&scale=${scale}`));
      await ready(t.page);
      const L = await layoutOf(t.page);
      assert(near(L.fontPx, expectedPx(scale, vp.height), 0.01), `${vpName(vp)} at ${scale}: ${L.fontPx}px, expected ${expectedPx(scale, vp.height)}`);
      checkLayout(L, `${vpName(vp)} at ${scale}`);
      await finish(t, `display-auto-${vpName(vp)}`);
    }
  });

  // THE WIDE-SCREEN EVIDENCE: the dev save with a bond open, at each size the
  // author named, at Auto and at 150%.
  const WIDE = [{ width: 1920, height: 1080 }, { width: 2560, height: 1440 }, { width: 3440, height: 1440 }, { width: 5120, height: 1440 }];
  for (const scale of ["auto", 150]) {
    await test(`wide screens at ${scale === "auto" ? "Auto" : scale + "%"}: the list keeps its width, the detail takes the rest, then even margins`, async () => {
      for (const vp of WIDE) {
        const t = await openPage(browser, base, vp, mockUrl(base, "dev-save", `&scale=${scale}`));
        await ready(t.page);
        await t.page.click(".row[data-index='0']");
        await t.page.waitForFunction(() => { const h = document.querySelector(".detail h2"); return h && h.textContent; });
        const L = await layoutOf(t.page);
        assert(near(L.fontPx, expectedPx(scale, vp.height), 0.01), `${vpName(vp)}: ${L.fontPx}px`);
        checkLayout(L, `${vpName(vp)} at ${scale}`);
        await shot(t.page, `wide-${vpName(vp)}-${scale}.png`);
        await finish(t, `wide-${vpName(vp)}-${scale}`);
      }
    });
  }

  await test("settings.textSize: Large and Larger grow the text and its columns, never cutting a label short", async () => {
    for (const [vp, text] of [[VIEWPORTS[0], "large"], [VIEWPORTS[0], "larger"], [VIEWPORTS[1], "larger"]]) {
      for (const mock of ["states", "dev-save"]) {
        const t = await openPage(browser, base, vp, mockUrl(base, mock, `&text=${text}${DEV}`));
        await ready(t.page);
        const L = await layoutOf(t.page);
        assert(L.t === (text === "large" ? 1.15 : 1.3), `${text}: --t is ${L.t}`);
        checkLayout(L, `${mock} ${vpName(vp)} ${text}`);
        if (mock === "dev-save" && vp === VIEWPORTS[0] && text === "larger") await shot(t.page, `text-larger-${vpName(vp)}.png`);
        await finish(t, `text-${mock}-${text}`);
      }
    }
  });

  await test("declined at depth: the turned-down companion at 2240 does not read Lover", async () => {
    for (const vp of VIEWPORTS) {
      const t = await openPage(browser, base, vp, mockUrl(base, "declined-at-depth"));
      await ready(t.page);
      const tier = await t.page.textContent('.row:has-text("Marit Hollowell") .tier');
      assert(tier !== "Lover" && tier !== "Spouse", `Marit reads "${tier}"`);
      const lover = await t.page.textContent('.row:has-text("Gisla Emberlee") .tier');
      assert(lover === "Lover", `the courting companion at 2140 should read Lover, reads "${lover}"`);
      await openByName(t.page, "Marit Hollowell");
      const detailTier = await t.page.textContent(".detail .depth-big .tier");
      assert(detailTier !== "Lover", `detail reads "${detailTier}"`);
      assert(await t.page.isVisible(".detail .chip.s-declined"), "the spoken Declined state is not shown");
      await shot(t.page, `detail-declined-at-depth-${vpName(vp)}.png`);
      await finish(t, "declined-at-depth");
    }
  });

  await test("labels: Ally and Best Friend on the platonic ladder; Courting reads Devoted at Spouse depth", async () => {
    const t = await openPage(browser, base, VIEWPORTS[0], mockUrl(base, "foreclosed-child"));
    await ready(t.page);
    const rowOf = (name) => t.page.evaluate((n) => {
      const row = Array.prototype.find.call(document.querySelectorAll(".row"), (r) => r.querySelector(".name").textContent === n);
      const st = row.querySelector(".c-state .chip");
      return { tier: row.querySelector(".tier").textContent, state: st.hidden ? null : st.textContent };
    }, name);
    const lissa = await rowOf("Lissa Ashkettle");   // platonic, 2640: tier 5
    assert(lissa.tier === "Best Friend", `platonic tier 5 reads ${lissa.tier}`);
    const aldric = await rowOf("Aldric Ashkettle"); // courting, 2780: Spouse depth
    assert(aldric.tier === "Spouse" && aldric.state === "Devoted", `courting at Spouse depth: ${JSON.stringify(aldric)}`);
    await openByName(t.page, "Aldric Ashkettle");
    const blurb = await t.page.textContent(".detail .blurb");
    assert(blurb.indexOf("as deep as a bond goes") >= 0, `Devoted blurb: ${blurb}`);
    const options = await t.page.evaluate(() => Array.prototype.map.call(document.querySelectorAll("#f-state option"), (o) => o.textContent));
    assert(options.indexOf("Courting / Devoted") >= 0 && options.indexOf("Devoted") < 0 && options.indexOf("Courting") < 0,
      `one filter entry for both labels: ${options.join(", ")}`);
    await finish(t, "labels-devoted");

    const d = await openPage(browser, base, VIEWPORTS[0], mockUrl(base, "declined-at-depth"));
    await ready(d.page);
    const tiers = await d.page.evaluate(() => Array.prototype.map.call(document.querySelectorAll(".row"), (r) => r.querySelector(".name").textContent + "=" + r.querySelector(".tier").textContent));
    assert(tiers.indexOf("Marit Hollowell=Ally") >= 0, `platonic tier 4 reads Ally: ${tiers.join(", ")}`);
    assert(tiers.indexOf("Gisla Emberlee=Lover") >= 0, `courting below Spouse depth keeps the romantic name: ${tiers.join(", ")}`);
    const gisla = await d.page.evaluate(() => {
      const row = Array.prototype.find.call(document.querySelectorAll(".row"), (r) => r.querySelector(".name").textContent === "Gisla Emberlee");
      return row.querySelector(".c-state .chip").textContent;
    });
    assert(gisla === "Courting", `courting below Spouse depth reads ${gisla}`);
    await finish(d, "labels-ally");
  });

  await test("foreclosed child: deep platonic depth, no romantic chips, never Spouse", async () => {
    const t = await openPage(browser, base, VIEWPORTS[0], mockUrl(base, "foreclosed-child"));
    await ready(t.page);
    const row = '.row:has-text("Lissa Ashkettle")';
    const tier = await t.page.textContent(`${row} .tier`);
    assert(tier !== "Spouse" && tier !== "Lover", `the child reads "${tier}"`);
    for (const c of [".c-int", ".c-exc", ".c-ori"]) {
      const v = await t.page.textContent(`${row} ${c} .chip`);
      assert(v === "—", `${c} shows "${v}" for a foreclosed child`);
    }
    await openByName(t.page, "Lissa Ashkettle");
    const text = await t.page.textContent(".detail");
    assert(text.indexOf("Your own child") >= 0, "foreclosure reason missing");
    assert(text.indexOf("Your answer") < 0 && text.indexOf("Spark") < 0, "stance or spark shown for a foreclosed child");
    const traits = await t.page.textContent(".detail .traits");
    assert(!/Intimacy|Exclusivity|Drawn to/.test(traits), `romantic traits shown for a foreclosed child: ${traits}`);
    await shot(t.page, `detail-foreclosed-child-${vpName(VIEWPORTS[0])}.png`);
    await finish(t, "foreclosed-child");
  });

  await test("roster: filters by following, track and state; sorts by depth and name", async () => {
    const t = await openPage(browser, base, VIEWPORTS[1], mockUrl(base, "dev-save"));
    await ready(t.page);
    const bonds = mockData["dev-save"].bonds;
    const n = (f) => bonds.filter(f).length;
    await t.page.selectOption("#f-following", "yes");
    assert((await countText(t.page)).startsWith(`${n((b) => b.following)} of ${bonds.length}`), `following filter: ${await countText(t.page)}`);
    await t.page.selectOption("#f-following", "all");
    for (const tr of ["platonic", "romantic"]) {
      await t.page.selectOption("#f-track", tr);
      assert((await countText(t.page)).startsWith(`${n((b) => b.track === tr)} of`), `track ${tr}: ${await countText(t.page)}`);
    }
    await t.page.selectOption("#f-track", "romantic");
    await shot(t.page, `dev-save-romantic-${vpName(VIEWPORTS[1])}.png`);
    await t.page.selectOption("#f-track", "all");
    const options = await t.page.evaluate(() => Array.prototype.map.call(document.querySelectorAll("#f-state option"), (o) => o.value));
    assert(JSON.stringify(options) === JSON.stringify(["all"].concat(SPOKEN)), `player mode offers states ${options}`);
    for (const s of SPOKEN) {
      await t.page.selectOption("#f-state", s);
      const c = await countText(t.page);
      assert(c.startsWith(`${n((b) => b.state === s)} of`), `state ${s}: ${c}`);
    }
    await t.page.selectOption("#f-state", "all");
    await t.page.fill("#f-text", "zzzz");
    assert(await t.page.isVisible("text=Nobody matches"), "no-match message missing");
    await t.page.fill("#f-text", "");
    const first = () => t.page.textContent('.row[data-index="0"] .name');
    const maxPts = Math.max(...bonds.map((b) => b.depth.points));
    await t.page.selectOption("#f-sort", "depth-desc");
    const deepest = bonds.filter((b) => b.depth.points === maxPts).map((b) => b.subject.name).sort()[0];
    assert(await first() === deepest, `deepest first: got ${await first()}, want ${deepest}`);
    await t.page.selectOption("#f-sort", "name-asc");
    const names = bonds.map((b) => b.subject.name.toLowerCase()).sort();
    assert((await first()).toLowerCase() === names[0], `A to Z: got ${await first()}`);
    await t.page.selectOption("#f-sort", "name-desc");
    assert((await first()).toLowerCase() === names[names.length - 1], `Z to A: got ${await first()}`);
    await finish(t, "filters");
  });

  await test("roster: 2,000 bonds stay virtualized, and scrolling costs little", async () => {
    const t = await openPage(browser, base, VIEWPORTS[1], mockUrl(base, "dev-save"));
    await ready(t.page);
    const stats = await t.page.evaluate(async (dev) => {
      const big = JSON.parse(JSON.stringify(dev));
      const src = big.bonds;
      big.bonds = [];
      for (let i = 0; i < 2000; i++) {
        const b = JSON.parse(JSON.stringify(src[i % src.length]));
        b.subject.formId = 0x00200000 + i;
        b.subject.name = b.subject.name + " " + i;
        big.bonds.push(b);
      }
      window.__snromMock.load(big);
      await new Promise((r) => setTimeout(r, 300));
      const vp = document.getElementById("roster-list");
      const frame = () => new Promise((r) => requestAnimationFrame(() => r()));
      // A fling from top to bottom, one scroll step per animation frame. What
      // matters is how long each frame's work takes, so time the synchronous
      // part: the scroll handler's render runs in the next frame, measured by
      // its own callback.
      const times = [];
      const span = vp.scrollHeight - vp.clientHeight;
      await frame();
      const flingStart = performance.now();
      for (let k = 1; k <= 120; k++) {
        vp.scrollTop = (k / 120) * span;
        vp.dispatchEvent(new Event("scroll"));
        const t0 = performance.now();
        await frame();
        times.push(performance.now() - t0);
      }
      const flingMs = performance.now() - flingStart;
      const t1 = performance.now();
      const sel = document.getElementById("f-following");
      sel.value = "yes"; sel.dispatchEvent(new Event("change"));
      const filterMs = performance.now() - t1;
      sel.value = "all"; sel.dispatchEvent(new Event("change"));
      vp.scrollTop = vp.scrollHeight;
      vp.dispatchEvent(new Event("scroll"));
      await frame(); await frame();
      const rows = document.querySelectorAll(".row:not([hidden])").length;
      const lastIndex = Math.max.apply(null, Array.prototype.map.call(document.querySelectorAll(".row:not([hidden])"), (r) => Number(r.getAttribute("data-index"))));
      times.sort((a, b) => a - b);
      return { rows, lastIndex, fps: 120 / (flingMs / 1000), p95: times[113], filterMs };
    }, mockData["dev-save"]);
    console.log(`      2,000 bonds: ${stats.rows} rows in the DOM; a 120-step fling ran at ${stats.fps.toFixed(0)} frames/s (p95 frame ${stats.p95.toFixed(1)} ms); filter ${stats.filterMs.toFixed(1)} ms`);
    assert(stats.rows < 40, `${stats.rows} rows rendered for 2,000 bonds`);
    assert(stats.lastIndex === 1999, `bottom of the list renders index ${stats.lastIndex}`);
    assert(stats.filterMs < 200, `filtering 2,000 bonds took ${stats.filterMs} ms`);
    await finish(t, "stress");
  });

  await test("keyboard: arrows move, Enter opens, Escape backs out one layer at a time, then closes", async () => {
    for (const vp of VIEWPORTS) {
      const t = await openPage(browser, base, vp, mockUrl(base, "states"));
      await ready(t.page);
      await t.page.focus("#roster-list");
      await t.page.keyboard.press("ArrowDown");
      await t.page.keyboard.press("ArrowDown");
      const want = await t.page.textContent('.row[data-index="2"] .name');
      await t.page.keyboard.press("Enter");
      assert(await t.page.textContent(".detail h2") === want, `Enter opened the wrong bond (want ${want})`);
      assert(await t.page.evaluate(() => document.activeElement.id) === "detail-close", "focus did not move into the detail");
      await t.page.keyboard.press("Escape");
      assert(await t.page.evaluate(() => document.activeElement.id) === "roster-list", "Escape did not return focus to the roster");
      assert(await t.page.evaluate(() => window.__snromMock.closes.length) === 0, "Escape closed the dashboard while the detail was open");
      await t.page.keyboard.press("Escape");
      const closes = await t.page.evaluate(() => window.__snromMock.closes.slice());
      assert(closes.length === 1 && closes[0] === "escape", `close calls: ${JSON.stringify(closes)}`);
      await t.page.click("#close-btn");
      assert((await t.page.evaluate(() => window.__snromMock.closes.slice()))[1] === "button", "close button did not call the close function");
      // Focus is visible on every control a keyboard reaches: on the list, as
      // the active row's marker; on a control, as its outline.
      await t.page.focus("#roster-list");
      const marker = await t.page.evaluate(() => getComputedStyle(document.querySelector(".row.is-active")).boxShadow);
      assert(marker && marker !== "none", "the focused list shows no active row");
      await t.page.focus("#f-state");
      const outline = await t.page.evaluate(() => getComputedStyle(document.activeElement).outlineStyle);
      assert(outline !== "none", "focused select has no outline");
      await finish(t, "keyboard");
    }
  });

  await test("player mode (default): only spoken states; no spark, owed question, hold or bank", async () => {
    for (const vp of VIEWPORTS) {
      const t = await openPage(browser, base, vp, mockUrl(base, "states"));
      await ready(t.page);
      const chip = (name) => t.page.evaluate((n) => {
        const row = Array.prototype.find.call(document.querySelectorAll(".row"), (r) => r.querySelector(".name").textContent === n);
        const c = row.querySelector(".c-state .chip");
        return c.hidden ? null : c.textContent;
      }, name);
      // Unspoken: an unanswered spark, the unjudged gate, the quiet verdict.
      for (const name of ["Sabeth Rimeholt", "Eddra Kettleburn", "Halvard Oakhallow"]) {
        assert(await chip(name) === null, `${name} shows a state chip in player mode: ${await chip(name)}`);
      }
      // Spoken: said aloud, answered, over, or never a question.
      const spoken = { "Ysolde Brightwater": "Courting", "Kjeld Frost-Veil": "Declined", "Liesl Saltmarch": "Ended", "Corvane Greywick": "Foreclosed" };
      for (const [name, want] of Object.entries(spoken)) assert(await chip(name) === want, `${name} reads ${await chip(name)}, want ${want}`);
      // The sparked, unanswered bond reads as any other friendship.
      const row = '.row:has-text("Sabeth Rimeholt")';
      assert(await t.page.textContent(`${row} .c-track .chip`) === "Platonic", "sparked, unanswered bond is not on the platonic track");
      assert((await t.page.textContent(`${row} .pts`)) === "1,999 \u00b7 1 to next", `row reads "${await t.page.textContent(`${row} .pts`)}"`);
      assert(!(await t.page.$(`${row} .fill.is-held`)), "hold pattern drawn in player mode");
      assert(!(await t.page.$("#dev-badge")), "developer badge in player mode");
      if (vp.width >= 1600) assert(await t.page.isVisible("text=Nothing said between you either way"), "legend lacks the unspoken group");
      const sabeth = mockData.states.bonds.find((b) => b.subject.name === "Sabeth Rimeholt");
      await openByName(t.page, "Sabeth Rimeholt");
      const text = await t.page.textContent(".detail");
      for (const want of [sabeth.prose.why, sabeth.prose.limit, sabeth.prose.address, "1,999 points", "Joined", "Following you"]) {
        assert(text.indexOf(want) >= 0, `detail lacks "${want}"`);
      }
      const leaked = HIDDEN_WORDS.concat(["215", "State"]).filter((w) => text.indexOf(w) >= 0);
      assert(!leaked.length, `detail shows hidden state: ${leaked.join(", ")}`);
      for (const op of ["RequestSparkNow", "UnsparkActor", "ForceDriftReview"]) {
        assert(await t.page.$(`button[data-op="${op}"]`) === null, `${op} shown in player mode`);
      }
      assert(!(await t.page.isVisible("#devtools-btn")), "the Developer tools button shows in player mode");
      assert(text.indexOf("Developer tools") < 0, "the detail has a Developer tools section in player mode");
      // prose.address reads "Calls you", with its hint; the word Address is gone.
      const labels = await t.page.evaluate(() => Array.prototype.map.call(document.querySelectorAll(".detail .prose .k"), (e) => e.textContent));
      assert(JSON.stringify(labels) === JSON.stringify(["Why", "Limit", "Calls you"]), `prose labels: ${labels}`);
      assert(text.indexOf("saved so they don't forget it, and changed only when a conversation changes it") >= 0, "Calls you has no hint");
      if (vp.width >= 1600) {
        await t.page.evaluate(() => document.querySelector(".detail .prose:last-of-type").scrollIntoView({ block: "center" }));
        await clearToasts(t.page);
        await shot(t.page, `detail-calls-you-${vpName(vp)}.png`);
        await t.page.evaluate(() => { document.querySelector(".detail-scroll").scrollTop = 0; });
      }
      await clearToasts(t.page);
      await shot(t.page, `detail-states-${vpName(vp)}.png`);
      await finish(t, "player-mode");
    }
  });

  await test("developer mode (?developer=1): every state, the spark, the owed question, held and banked, and the tools", async () => {
    for (const vp of VIEWPORTS) {
      const t = await openPage(browser, base, vp, mockUrl(base, "states", DEV));
      await ready(t.page);
      assert(await t.page.isVisible("#dev-badge"), "developer mode does not say so on screen");
      const options = await t.page.evaluate(() => Array.prototype.map.call(document.querySelectorAll("#f-state option"), (o) => o.value));
      assert(options.length === 8, `developer mode offers ${options}`);
      const row = '.row:has-text("Sabeth Rimeholt")';
      assert(await t.page.textContent(`${row} .c-state .chip`) === "Interested", "developer mode hides Interested");
      assert((await t.page.textContent(`${row} .pts`)).indexOf("Held: question owed") >= 0, "developer mode hides the hold");
      if (vp.width >= 1600) await shot(t.page, `developer-states-${vpName(vp)}.png`);
      const sabeth = mockData.states.bonds.find((b) => b.subject.name === "Sabeth Rimeholt");
      await openByName(t.page, "Sabeth Rimeholt");
      const text = await t.page.textContent(".detail");
      for (const want of [sabeth.prose.why, "215 more points are held back", "Held: question owed", "Not answered",
        "Owed.", "Sparked on day", "Interested"]) {
        assert(text.indexOf(want) >= 0, `developer detail lacks "${want}"`);
      }
      // The developer tools ride the same switch, in their own labelled
      // section, never among the repairs, and work from their buttons.
      const sections = await t.page.evaluate(() => Array.prototype.map.call(document.querySelectorAll(".detail .sec"), (s) => ({
        title: s.querySelector("h3").textContent,
        ops: Array.prototype.map.call(s.querySelectorAll("button[data-op]"), (b) => b.getAttribute("data-op")),
      })));
      const repairs = sections.find((s) => s.title === "Repairs"), tools = sections.find((s) => s.title === "Developer tools");
      assert(repairs && tools, `detail sections: ${sections.map((s) => s.title)}`);
      assert(JSON.stringify(tools.ops) === JSON.stringify(["RequestSparkNow", "UnsparkActor", "ForceDriftReview"]), `developer tools: ${tools.ops}`);
      assert(!repairs.ops.some((op) => tools.ops.indexOf(op) >= 0), `a developer tool among the repairs: ${repairs.ops}`);
      assert(await t.page.isVisible("#devtools-btn"), "no Developer tools button in developer mode");
      if (vp.width >= 1600) {
        await t.page.evaluate(() => { const s = document.querySelector(".detail-scroll"); s.scrollTop = s.scrollHeight; });
        await shot(t.page, `developer-detail-tools-${vpName(vp)}.png`);
      }
      if (vp.width < 1600) await shot(t.page, `developer-detail-states-${vpName(vp)}.png`);
      await openByName(t.page, "Eddra Kettleburn");
      await t.page.click('button[data-op="RequestSparkNow"]');
      await waitToast(t.page, "Asking the spark assessor about Eddra Kettleburn");
      await finish(t, "developer-mode");
    }
  });

  await test("developer mode: filters offer and count every state", async () => {
    const t = await openPage(browser, base, VIEWPORTS[1], mockUrl(base, "dev-save", DEV));
    await ready(t.page);
    const bonds = mockData["dev-save"].bonds;
    for (const s of ["foreclosed", "unexamined", "platonic", "interested", "courting", "declined", "ended"]) {
      await t.page.selectOption("#f-state", s);
      const c = await countText(t.page);
      assert(c.startsWith(`${bonds.filter((b) => b.state === s).length} of`), `state ${s}: ${c}`);
    }
    await finish(t, "developer-filters");
  });

  await test("actions: every exposed repair reaches the mock host and comes back", async () => {
    const t = await openPage(browser, base, VIEWPORTS[1], mockUrl(base, "states"));
    await ready(t.page);
    const id = (name) => mockData.states.bonds.find((b) => b.subject.name === name).subject.formId;

    // Re-read: dispatched, answered, then the late notice.
    await openByName(t.page, "Sabeth Rimeholt");
    await t.page.click('button[data-op="ReseedActor"]');
    await waitToast(t.page, "Re-reading the record for Sabeth Rimeholt");
    let log = await lastLog(t.page);
    assert(log.v === 1 && log.kind === "action" && log.payload.op === "ReseedActor" && log.payload.subject === id("Sabeth Rimeholt"), `envelope ${JSON.stringify(log)}`);
    assert(typeof log.id === "string" && log.id.length > 0, "request has no id");
    await waitToast(t.page, "Seed read for Sabeth Rimeholt");

    // From 1.9 (WP4) the points are Relationships' own, so nothing about
    // where someone is gates a re-read: Halvard, near but not following, and
    // Kjeld, neither, can both be re-read and re-authored.
    await clearToasts(t.page);
    await openByName(t.page, "Halvard Oakhallow");
    const halvard = mockData.states.bonds.find((b) => b.subject.name === "Halvard Oakhallow");
    assert(!halvard.following && halvard.nearby, "mock changed: Halvard should be near and not following");
    assert(await t.page.isEnabled('button[data-op="ReseedActor"]'), "re-read greyed out for someone not following");
    assert(await t.page.isEnabled('button[data-op="ReauthorCharacter"]'), "re-author needs presence it does not use");

    await openByName(t.page, "Kjeld Frost-Veil");
    assert(await t.page.isEnabled('button[data-op="ReseedActor"]') && await t.page.isEnabled('button[data-op="ReauthorCharacter"]'),
      "a bond action greyed out for someone far away");

    // Re-author: confirmation first; Escape cancels without sending anything.
    await openByName(t.page, "Eddra Kettleburn");
    const before = await t.page.evaluate(() => window.__snromMock.log.length);
    await t.page.click('button[data-op="ReauthorCharacter"]');
    assert(await t.page.isVisible("#dialog"), "no confirmation for a destructive action");
    assert(await t.page.evaluate(() => document.activeElement.id) === "dialog-cancel", "Cancel is not the default focus");
    await clearToasts(t.page);
    await shot(t.page, `confirm-reauthor-${vpName(VIEWPORTS[1])}.png`);
    await t.page.keyboard.press("Escape");
    assert(await t.page.isHidden("#dialog"), "Escape did not close the dialog");
    assert(await t.page.isVisible(".detail h2"), "Escape closed the detail along with the dialog");
    assert(await t.page.evaluate(() => window.__snromMock.log.length) === before, "a cancelled action was sent");
    await t.page.click('button[data-op="ReauthorCharacter"]');
    await t.page.click("#dialog-confirm");
    await waitToast(t.page, "Re-authoring Eddra Kettleburn");
    await waitToast(t.page, "Character written for Eddra Kettleburn");
    await t.page.waitForFunction(() => document.querySelector(".detail").textContent.indexOf("Not authored yet") < 0);

    // One trait, directly: ardor to Reserved, then exclusivity to 60.
    await t.page.selectOption("#trait-field", "ardor");
    await t.page.selectOption('.act[data-op="SetCharacterField"] select[aria-label="Ardor"]', "0");
    await t.page.click('button[data-op="SetCharacterField"]');
    await t.page.waitForFunction(() => document.querySelector(".detail").textContent.indexOf("Reserved (0 of 4)") >= 0);
    log = await lastLog(t.page);
    assert(JSON.stringify(log.payload.args) === "[1,0]", `SetCharacterField args ${JSON.stringify(log.payload.args)}`);
    assert(await t.page.evaluate(() => document.getElementById("trait-field").value) === "ardor", "the trait form forgot its field after the snapshot");
    await t.page.selectOption("#trait-field", "exclusivity");
    await t.page.fill('.act[data-op="SetCharacterField"] input', "60");
    await t.page.click('button[data-op="SetCharacterField"]');
    await t.page.waitForFunction(() => document.querySelector(".detail").textContent.indexOf("(60 of 100)") >= 0);
    assert(JSON.stringify((await lastLog(t.page)).payload.args) === "[2,60]", "exclusivity args");

    // Remove from roster: confirmation, then they are gone.
    await openByName(t.page, "Liesl Saltmarch");
    await t.page.click('button[data-op="UnenrollActor"]');
    await t.page.click("#dialog-confirm");
    await waitToast(t.page, "is off the roster");
    await t.page.waitForFunction(() => document.getElementById("count").textContent.indexOf("6") === 0);
    assert(!(await t.page.isVisible('.row:has-text("Liesl Saltmarch")')), "unenrolled bond still listed");

    // Developer tools are listed for the native table but not shown in player
    // mode...
    await openByName(t.page, "Sabeth Rimeholt");
    for (const op of ["RequestSparkNow", "UnsparkActor", "ForceDriftReview"]) {
      assert(await t.page.$(`button[data-op="${op}"]`) === null, `${op} is exposed`);
    }
    // ...and still answer when asked through the bridge.
    const dev = await t.page.evaluate(async (ids) => {
      const r1 = await snrom.request("action", { op: "RequestSparkNow", subject: ids.eddra, args: [] });
      const r2 = await snrom.request("action", { op: "UnsparkActor", subject: ids.sabeth, args: [] });
      const r3 = await snrom.request("action", { op: "ForceDriftReview", subject: ids.sabeth, args: [1] });
      const r4 = await snrom.request("action", { op: "NoSuchThing", subject: ids.sabeth, args: [] });
      return [r1, r2, r3, r4];
    }, { eddra: id("Eddra Kettleburn"), sabeth: id("Sabeth Rimeholt") });
    assert(dev[0].ok && dev[1].ok && dev[2].ok, `developer ops: ${JSON.stringify(dev)}`);
    assert(!dev[3].ok && /Unknown operation/.test(dev[3].message), `unknown op answered ${JSON.stringify(dev[3])}`);

    // Crosshair on someone already enrolled: offer to show them, not to enroll.
    assert(await t.page.textContent("#crosshair-btn") === "Show Sabeth Rimeholt", "crosshair on an enrolled bond offers the wrong thing");
    await t.page.keyboard.press("Escape");
    await t.page.click("#crosshair-btn");
    assert(await t.page.textContent(".detail h2") === "Sabeth Rimeholt", "Show did not open their bond");
    await finish(t, "actions");
  });

  await test("enroll: the crosshair target joins the roster from the dashboard", async () => {
    for (const vp of VIEWPORTS) {
      const t = await openPage(browser, base, vp, mockUrl(base, "dev-save"));
      await ready(t.page);
      const target = mockData["dev-save"].crosshairTarget;
      assert(await t.page.textContent("#crosshair-btn") === `Enroll ${target.name}`, "no Enroll offer");
      await t.page.click("#crosshair-btn");
      await waitToast(t.page, `${target.name} is on your roster`);
      const log = await lastLog(t.page);
      assert(log.payload.op === "EnrollActor" && log.payload.subject === target.formId, `enroll envelope ${JSON.stringify(log)}`);
      await t.page.waitForFunction((n) => document.getElementById("crosshair-btn").textContent === "Show " + n, target.name);
      await t.page.waitForFunction(() => document.getElementById("count").textContent.indexOf("121") === 0);
      await waitToast(t.page, `Disposition authored for ${target.name}`);
      await t.page.click("#crosshair-btn");
      assert(await t.page.textContent(".detail h2") === target.name, "Show did not open the new bond");
      assert((await t.page.textContent(".detail")).indexOf("By you") >= 0, "new bond not marked as enrolled by the player");
      await clearToasts(t.page);
      await shot(t.page, `enrolled-${vpName(vp)}.png`);
      await finish(t, "enroll");
    }
  });

  await test("playthrough repairs: fresh store and back, each confirmed", async () => {
    const t = await openPage(browser, base, VIEWPORTS[0], mockUrl(base, "states"));
    await ready(t.page);
    await t.page.click("#repairs-btn");
    assert(await t.page.isDisabled('#dialog button[data-op="AdoptLegacyStore"]'), "offers to adopt the store it already owns");
    await shot(t.page, `playthrough-repairs-${vpName(VIEWPORTS[0])}.png`);
    await t.page.click('#dialog button[data-op="StartFreshStore"]');
    await t.page.click("#dialog-confirm");
    await waitToast(t.page, "own store");
    await t.page.waitForFunction(() => document.getElementById("store").textContent.indexOf("SNRom_Dispositions_7f3a91c2") >= 0);
    await t.page.click("#repairs-btn");
    await t.page.click('#dialog button[data-op="AdoptLegacyStore"]');
    await t.page.click("#dialog-confirm");
    await t.page.waitForFunction(() => document.getElementById("store").textContent.indexOf("owns the main store") >= 0);
    const ops = await t.page.evaluate(() => window.__snromMock.log.map((e) => e.payload.op).filter(Boolean));
    assert(ops.indexOf("StartFreshStore") >= 0 && ops.indexOf("AdoptLegacyStore") >= 0, `ops sent: ${ops}`);
    await finish(t, "playthrough");
  });

  await test("check the display: under Developer tools, never the repairs; answered at once, counted later", async () => {
    let t = await openPage(browser, base, VIEWPORTS[0], mockUrl(base, "states"));
    await ready(t.page);
    assert(!(await t.page.isVisible("#devtools-btn")), "player mode shows the Developer tools button");
    await t.page.click("#repairs-btn");
    assert(!(await t.page.$('#dialog button[data-op="CheckDisplay"]')), "player mode offers the display check");
    await finish(t, "check-display-player");

    t = await openPage(browser, base, VIEWPORTS[0], mockUrl(base, "states", DEV));
    await ready(t.page);
    // The store repairs stay where players find them, with nothing else.
    await t.page.click("#repairs-btn");
    const repairOps = await t.page.evaluate(() => Array.prototype.map.call(document.querySelectorAll("#dialog button[data-op]"), (b) => b.getAttribute("data-op")));
    assert(JSON.stringify(repairOps) === JSON.stringify(["StartFreshStore", "AdoptLegacyStore"]), `playthrough repairs offer ${repairOps}`);
    await t.page.click("#dialog-cancel");
    await t.page.click("#devtools-btn");
    assert(await t.page.textContent("#dialog-title") === "Developer tools", "the Developer tools dialog is not labelled");
    await shot(t.page, `developer-tools-${vpName(VIEWPORTS[0])}.png`);
    assert((await t.page.textContent("#dialog")).indexOf("about a minute with 120 bonds") >= 0, "the check does not say it is slow");
    await t.page.click('#dialog button[data-op="CheckDisplay"]');
    await t.page.click("#dialog-confirm");
    await waitToast(t.page, "Checking every bond against the rules");
    await waitToast(t.page, "bonds checked, 0 disagreements");
    const ops = await t.page.evaluate(() => window.__snromMock.log.map((e) => e.payload.op).filter(Boolean));
    assert(ops.indexOf("CheckDisplay") >= 0, `ops sent: ${ops}`);
    await finish(t, "check-display");
  });

  // The native path, driven the way the DLL will drive it: listeners that
  // appear only after the page has loaded (Prisma registers after DOM ready),
  // text in both directions, and Meridian's object form for the reply.
  await test("native host: late listeners, string envelopes both ways, one close function", async () => {
    const fileUrl = pathToFileURL(join(PAGE, "index.html")).href;
    const snapText = JSON.stringify({ v: 1, kind: "snapshot", payload: mockData.states });
    const t = await openPage(browser, base, VIEWPORTS[1], fileUrl, `
      window.__native = { requests: [], closes: [] };
      setTimeout(function () {
        window.snromRequest = function (text) {
          window.__native.requests.push(text);
          var m = JSON.parse(text);
          setTimeout(function () {
            if (m.kind === "snapshot") window.snromReceive(${JSON.stringify(snapText)});
            window.snromReceive({ v: 1, kind: "result", re: m.id, payload: { ok: true, message: "native saw " + (m.payload.op || m.kind) } });
            if (m.payload.op) window.snromReceive(JSON.stringify({ v: 1, kind: "notice", payload: { text: "a late answer", level: "info" } }));
          }, 20);
        };
        window.snromClose = function (text) { window.__native.closes.push(text); };
      }, 400);
    `);
    await ready(t.page);
    assert(await t.page.evaluate(() => snrom.host) === "prisma", "file URL did not choose the native host");
    assert(await t.page.evaluate(() => !window.__snromMock), "mock host present under a native host");
    const reqs = await t.page.evaluate(() => window.__native.requests);
    assert(reqs.length >= 1 && typeof reqs[0] === "string", "requests are not text");
    const first = JSON.parse(reqs[0]);
    assert(first.v === 1 && first.kind === "snapshot" && first.id, `first request ${reqs[0]}`);
    await openByName(t.page, "Sabeth Rimeholt");
    await t.page.click('button[data-op="ReseedActor"]');
    await waitToast(t.page, "native saw ReseedActor");
    await waitToast(t.page, "a late answer");
    const act = JSON.parse((await t.page.evaluate(() => window.__native.requests)).slice(-1)[0]);
    assert(act.kind === "action" && act.payload.op === "ReseedActor" && Array.isArray(act.payload.args), `action envelope ${JSON.stringify(act)}`);
    await t.page.keyboard.press("Escape");
    await t.page.keyboard.press("Escape");
    const closes = await t.page.evaluate(() => window.__native.closes);
    assert(closes.length === 1 && JSON.parse(closes[0]).reason === "escape" && JSON.parse(closes[0]).v === 1, `closes ${JSON.stringify(closes)}`);
    await finish(t, "native");
  });

  await test("native host: listeners that never come fail loudly and never show mock data", async () => {
    const fileUrl = pathToFileURL(join(PAGE, "index.html")).href;
    const t = await openPage(browser, base, VIEWPORTS[1], fileUrl);
    await t.page.waitForFunction(() => Array.prototype.some.call(document.querySelectorAll(".toast"), (e) => /No connection|never registered/.test(e.textContent)), null, { timeout: 16000 });
    assert(await t.page.evaluate(() => snrom.host) === "prisma", "chose the wrong host");
    assert(await t.page.evaluate(() => document.querySelectorAll(".row:not([hidden])").length) === 0, "rows shown with no game");
    assert((await t.page.textContent("#summary")).indexOf("Waiting") >= 0, "summary claims data it never got");
    // The two toasts are console-free by design; the failure is the toast.
    await finish(t, "native-missing");
  });

  server.close();
  await browser.close();

  console.log("\n" + results.join("\n"));
  console.log(`\n${results.length - failures} passed, ${failures} failed. Screenshots in ui/tests/screenshots/.`);
  process.exit(failures ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(2); });
