// Writes the mock snapshots in ui/relationships/mock/ that the mock host loads.
//
//   node ui/tests/gen-mocks.mjs
//
// Every name and line here is invented. Never paste a real save's roster in:
// these files ship in the repository, and a save carries other people's
// characters and the player's own history.
//
// Deterministic (seeded), so regenerating changes nothing unless this file did.
// The invariants every bond obeys are the ones snapshot.schema.json states, and
// the run.mjs test re-checks them against the schema, so a generator bug fails
// the tests rather than shipping a mock the game could never produce.

import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OUT = join(dirname(fileURLToPath(import.meta.url)), "..", "relationships", "mock");
const THRESHOLDS = [0, 500, 1000, 1500, 2000, 2500];
const NOW = 214.37;
const PLAYER = { formId: 20, name: "Tamsin Vey", isPlayer: true };

// mulberry32: small, seedable, and the same on every machine.
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const R = rng(0x5e11a);
const pick = (xs) => xs[Math.floor(R() * xs.length)];
const between = (lo, hi) => lo + Math.floor(R() * (hi - lo + 1));
const round2 = (x) => Math.round(x * 100) / 100;

function tierOf(points) {
  let t = 0;
  for (let i = 0; i < THRESHOLDS.length; i++) if (points >= THRESHOLDS[i]) t = i;
  return t;
}

// Signed 32-bit, as Papyrus's GetFormID returns it.
const signed = (u) => (u > 0x7fffffff ? u - 0x100000000 : u);

const FIRST = [
  "Asvild", "Brenna", "Corvane", "Dagrun", "Eluned", "Faelis", "Gerdis", "Halvard",
  "Idrien", "Jorunn", "Kestrel", "Liesl", "Maelis", "Nesta", "Orwen", "Perrin",
  "Quilla", "Ragnith", "Sabeth", "Torvald", "Ullis", "Veyla", "Wystan", "Ysolde",
  "Aldric", "Berrin", "Calla", "Dunstan", "Eddra", "Fenwick", "Gisla", "Hesketh",
  "Ingrith", "Jessamy", "Kjeld", "Lorn", "Marit", "Nerys", "Osric", "Petra",
  "Rook", "Sigrun", "Tovah", "Undry", "Varric", "Wenna", "Yrsa", "Zell",
];
const LAST = [
  "Ashkettle", "Ironbrook", "Frost-Veil", "Marrowind", "Coldwater", "Stonewhistle",
  "Harrowgate", "Emberlee", "Duskmere", "Saltmarch", "Thornbury", "Greywick",
  "Brightwater", "Oakhallow", "Rimeholt", "Silverbirch", "Hollowell", "Brackenridge",
  "Kettleburn", "Mossfell", "Tallow", "Redfern", "Wyndgate", "Cinderholt",
];
const ELSEWHERE = [
  "Dravyn Selothi", "Nerasa Indalen", "Ri'zhala", "Keeps-The-Tides", "Tulvyn Oran",
  "Jo'rassi", "Sings-Under-Rain", "Aurelian Vesk", "Livia Carrenus", "Teldri Morvayn",
];

const WHY = [
  "{n} measures people by what they do when it costs them, and has little patience for charm.",
  "{n} trusts slowly and keeps score quietly; warmth has to be earned twice before it counts.",
  "{n} was raised to be useful rather than loved, and still finds the second harder to accept.",
  "{n} laughs easily and forgives quickly, but remembers exactly who was there when it mattered.",
  "{n} treats loyalty as a debt paid in deeds, never in words.",
  "{n} has buried enough friends to be careful about making new ones.",
  "{n} is drawn to steadiness, and wary of anyone who needs an audience.",
  "{n} wants to be needed more than admired, and notices the difference at once.",
  "{n} reads kindness to strangers as the truest measure of a person.",
  "{n} prizes plain speech and distrusts anyone who talks around a thing.",
  "{n} keeps a small circle and guards it fiercely.",
  "{n} is restless under routine and comes alive on the road.",
];
const LIMIT = [
  "{n} will not stand beside anyone who harms a child.",
  "{n} will not follow someone who kills for coin.",
  "{n} will not share a secret that was given in trust.",
  "{n} will not be lied to twice.",
  "{n} will not bow to a Thalmor justiciar, whatever it costs.",
  "{n} will not leave a companion behind in a fight.",
  "{n} will not take part in cruelty for sport.",
  "{n} will not be kept as someone's second choice.",
];
// 0330 renders this after "You address <player> as:", so it reads as a phrase.
const ADDRESS_PLAIN = ["By name, always.", "'Friend', and means it.", "'Boss', dryly.", "'Traveler', still.",
  "'My Thane' in company; your name alone.", "Your surname, like a soldier."];
const ADDRESS_WARM = ["'My heart', when no one is listening.", "'Love', easily.", "Your name, softly.", "'Dearest', half teasing."];

const usedIds = new Set();
function formId() {
  for (;;) {
    const u = between(0x00010000, 0x000fffff);
    if (!usedIds.has(u)) { usedIds.add(u); return u; }
  }
}
function spawnedId() {
  // A mod-spawned FF-range reference: negative once signed.
  for (;;) {
    const u = 0xff000000 + between(0x100, 0xfff);
    if (!usedIds.has(u)) { usedIds.add(u); return signed(u); }
  }
}

const usedNames = new Set();
function newName() {
  for (;;) {
    const n = R() < 0.1 ? pick(ELSEWHERE) : `${pick(FIRST)} ${pick(LAST)}`;
    if (!usedNames.has(n)) { usedNames.add(n); return n; }
  }
}
const firstWord = (name) => name.split(" ")[0];

function traits(opts = {}) {
  const authored = opts.authored !== undefined ? opts.authored : true;
  if (!authored) {
    // StorageUtil's defaults, not anyone's judgement.
    return { authored: false, intimacy: "romantic", ardor: 2, exclusivity: 50, orientation: "both", orientationBasis: "unknown" };
  }
  const anchors = [0, 25, 50, 75, 100];
  let excl = pick(anchors);
  if (R() < 0.25) excl = Math.max(0, Math.min(100, excl + pick([-20, 20]))); // one drift step
  return {
    authored: true,
    intimacy: opts.intimacy || pick(["casual", "casual", "romantic", "romantic", "romantic", "guarded", "guarded", "never"]),
    ardor: opts.ardor !== undefined ? opts.ardor : between(0, 4),
    exclusivity: opts.exclusivity !== undefined ? opts.exclusivity : excl,
    orientation: opts.orientation || pick(["both", "both", "both", "men", "women", "none"]),
    orientationBasis: opts.orientationBasis || pick(["unknown", "inferred", "inferred", "known"]),
  };
}

function prose(name, warm, authored) {
  if (!authored) return { why: "", limit: "", address: "" };
  const n = firstWord(name);
  return {
    why: pick(WHY).replace("{n}", n),
    limit: pick(LIMIT).replace("{n}", n),
    address: warm ? pick(ADDRESS_WARM) : pick(ADDRESS_PLAIN),
  };
}

// One bond. `s` names the state; everything else is made consistent with it.
function bond(s, o = {}) {
  const name = o.name || newName();
  const id = o.formId !== undefined ? o.formId : (R() < 0.03 ? spawnedId() : formId());
  const joinedAt = o.joinedAt !== undefined ? o.joinedAt : round2(between(4, 205) + R());
  const following = o.following !== undefined ? o.following : false;
  const nearby = o.nearby !== undefined ? o.nearby : (following ? R() < 0.9 : R() < 0.08);
  const sparked = ["interested", "courting", "declined"].includes(s);
  const decided = s !== "unexamined" && s !== "foreclosed" ? true : (s === "foreclosed" ? R() < 0.5 : false);
  const stance = s === "courting" ? "accepted" : s === "declined" ? "declined" : "unanswered";
  let points = o.points;
  if (points === undefined) {
    points = {
      unexamined: () => (R() < 0.7 ? between(0, 600) : between(600, 1999)),
      platonic: () => (R() < 0.75 ? between(80, 1450) : between(1500, 2900)),
      interested: () => between(900, 1999),
      courting: () => between(2000, 2950),
      declined: () => between(1250, 1700),
      ended: () => between(500, 1500),
      foreclosed: () => between(150, 2700),
    }[s]();
  }
  const banked = o.banked !== undefined ? o.banked : 0;
  const commitment = o.commitment || "none";
  const authored = o.authored !== undefined ? o.authored : true;
  const t = traits({ authored, ...(o.traits || {}) });
  const sparkedAt = sparked ? round2(Math.min(NOW - 0.5, joinedAt + between(2, 40) + R())) : null;
  return {
    subject: { formId: id, name, isPlayer: false },
    object: { ...PLAYER },
    following,
    nearby,
    lastFollowingAt: o.lastFollowingAt !== undefined ? o.lastFollowingAt
      : (following ? round2(NOW - R() * 0.05) : (o.enrolledBy === "player" ? null : round2(joinedAt + R() * (NOW - joinedAt)))),
    enrollment: { by: o.enrolledBy || "following", joinedAt: o.joinedAtNull ? null : joinedAt },
    depth: { points, tier: tierOf(points), banked },
    track: s === "courting" || commitment === "engaged" || commitment === "married" ? "romantic" : "platonic",
    state: s,
    foreclosure: s === "foreclosed" ? (o.foreclosure || "minor") : null,
    stance,
    askPending: o.askPending || false,
    spark: {
      sparked,
      decided,
      sparkedAt,
      lastCheckedAt: s === "unexamined" && R() < 0.5 ? null : round2(Math.min(NOW - 0.1, joinedAt + R() * (NOW - joinedAt))),
    },
    commitment,
    seeded: o.seeded !== undefined ? o.seeded : R() < 0.93,
    traits: t,
    prose: prose(name, s === "courting", authored),
    // What moved the bond, newest first: only where a mock gives it, as a
    // literal, so the seeded sequence every name comes from never shifts.
    ...(o.history ? { history: o.history } : {}),
  };
}

function snapshot(bonds, extra = {}) {
  return {
    schemaVersion: 3,
    generatedAt: NOW,
    roster: { status: "current", message: null },
    playthrough: { id: "7f3a91c2", store: "SNRom_Dispositions", storeDecision: "legacy" },
    ladder: { thresholds: THRESHOLDS.slice() },
    player: { ...PLAYER },
    settings: { developer: false, scale: "auto", textSize: "normal" },
    crosshairTarget: null,
    bonds,
    ...extra,
  };
}

function write(file, obj) {
  writeFileSync(join(OUT, file), JSON.stringify(obj, null, 2) + "\n");
}

mkdirSync(OUT, { recursive: true });

// ---------------------------------------------------------------- empty
write("empty.json", snapshot([], {
  playthrough: { id: "c04d2e17", store: "SNRom_Dispositions_c04d2e17", storeDecision: "own" },
}));

// ---------------------------------------------------------------- dev save
// The development save's SHAPE: about 120 enrolled, about 15 following, most of
// them dismissed long ago. Proportions, not people.
{
  const plan = [
    ["foreclosed", 6], ["unexamined", 30], ["platonic", 62], ["interested", 7],
    ["courting", 9], ["declined", 3], ["ended", 3],
  ];
  const bonds = [];
  let followingLeft = 15;
  for (const [s, count] of plan) {
    for (let i = 0; i < count; i++) {
      const o = {};
      if (s === "foreclosed") {
        o.foreclosure = ["kin", "kin", "minor", "minor", "orientation", "orientation"][i];
        if (o.foreclosure === "orientation") o.traits = { orientation: "men", orientationBasis: "known" };
        else o.traits = { intimacy: "never", exclusivity: 0, orientation: "none", orientationBasis: "unknown" };
      }
      if (s === "interested" && i < 2) {
        // Held one short of Lover with the question owed: the consent gate's
        // everyday face.
        o.points = 1999; o.banked = between(40, 400); o.askPending = true;
      }
      if (s === "courting") {
        o.commitment = i < 3 ? "married" : i < 5 ? "engaged" : "none";
        if (i < 3) o.points = between(2500, 2950);
      }
      if (s === "unexamined" && i < 4) { o.authored = false; o.seeded = false; o.joinedAt = round2(NOW - R() * 2); }
      if (s === "platonic" && i < 6) o.enrolledBy = "dialogue";
      if (s === "platonic" && i >= 6 && i < 10) { o.enrolledBy = "unknown"; o.joinedAtNull = true; }
      bonds.push(bond(s, o));
    }
  }
  // Pick the followers across states rather than all from one.
  const order = bonds.map((b, i) => i).sort(() => R() - 0.5);
  for (const i of order) {
    if (followingLeft === 0) break;
    const b = bonds[i];
    if (b.state === "foreclosed" && b.foreclosure !== "orientation") continue;
    if (b.enrollment.by !== "following") continue;
    b.following = true; b.nearby = R() < 0.9; b.lastFollowingAt = round2(NOW - R() * 0.05);
    followingLeft--;
  }
  // No join date exists until phase 2 stores one (design 7.3), and nothing can
  // recover it for anyone enrolled earlier. This save took phase 2 on day
  // PHASE2_DAY, so everyone older reads null. The smaller mocks stand for a
  // playthrough started after it, so their dates stay.
  const PHASE2_DAY = 150;
  for (const b of bonds) {
    if (b.enrollment.joinedAt !== null && b.enrollment.joinedAt < PHASE2_DAY) b.enrollment.joinedAt = null;
  }
  const crosshairTarget = { formId: formId(), name: newName(), enrolled: false };
  write("dev-save.json", snapshot(bonds, { crosshairTarget }));
}

// ---------------------------------------------------------------- one of each state
// Design 5.2, one row each, plus the 2.0 case of a shopkeeper the player
// enrolled by crosshair without ever travelling together.
{
  const bonds = [
    bond("foreclosed", { name: "Corvane Greywick", foreclosure: "orientation", following: true, nearby: true,
      points: 1320, traits: { orientation: "men", orientationBasis: "known", intimacy: "casual" } }),
    bond("unexamined", { name: "Eddra Kettleburn", following: true, nearby: true, points: 420, authored: false, seeded: false,
      joinedAt: round2(NOW - 0.6) }),
    bond("platonic", { name: "Halvard Oakhallow", enrolledBy: "player", following: false, nearby: true, points: 870,
      lastFollowingAt: null,
      history: [
        { day: 214.2, delta: 20, total: 870, kind: "talk", reason: "He asked my advice about his daughter, and actually listened to it." },
        { day: 210.0, delta: 850, total: 850, kind: "seed", reason: "Prior history together" },
      ] }),
    bond("interested", { name: "Sabeth Rimeholt", following: true, nearby: true, points: 1999, banked: 215, askPending: true,
      traits: { intimacy: "romantic", ardor: 3, exclusivity: 50, orientation: "both", orientationBasis: "inferred" },
      history: [
        { day: 213.8, delta: 40, total: 1999, kind: "withheld", reason: "You defended me in front of the jarl's whole court." },
        { day: 211.5, delta: 30, total: 1999, kind: "talk", reason: "We laughed until the fire burned down to coals." },
        { day: 205.0, delta: 1500, total: 1500, kind: "seed", reason: "Prior history together" },
      ] }),
    bond("courting", { name: "Ysolde Brightwater", following: true, nearby: true, points: 2310, commitment: "engaged",
      traits: { intimacy: "romantic", ardor: 4, exclusivity: 75, orientation: "women", orientationBasis: "known" },
      history: [
        { day: 214.1, delta: 40, total: 2310, kind: "moment", reason: "You stayed with me at the shrine until the fever broke, and never once let go of my hand." },
        { day: 212.6, delta: 35, total: 2270, kind: "talk", reason: "We talked about the house we would build, and you meant every word of it." },
        { day: 209.2, delta: 215, total: 2235, kind: "accepted", reason: "What was held while the question waited" },
        { day: 203.9, delta: 25, total: 2020, kind: "spark", reason: "Her heart caught when he laughed at the river crossing, and she stopped pretending it had not." },
      ] }),
    bond("declined", { name: "Kjeld Frost-Veil", following: false, nearby: false, points: 1250,
      traits: { intimacy: "guarded", ardor: 1, exclusivity: 100, orientation: "both", orientationBasis: "known" },
      history: [
        { day: 207.3, delta: -500, total: 1250, kind: "declined", reason: "Turned down" },
        { day: 200.1, delta: 45, total: 1750, kind: "moment", reason: "You carried me out of the barrow on your back." },
      ] }),
    bond("ended", { name: "Liesl Saltmarch", following: false, nearby: false, points: 1500,
      history: [
        { day: 199.0, delta: -400, total: 1500, kind: "ended", reason: "I can't keep waiting for you to choose me." },
      ] }),
  ];
  write("states.json", snapshot(bonds, {
    crosshairTarget: { formId: bonds[3].subject.formId, name: bonds[3].subject.name, enrolled: true },
  }));
}

// ---------------------------------------------------------------- declined at depth
// The trap: a companion the player turned down, still sparked, at Lover-tier
// depth (an old save carried above the line before 1.8.1 re-asked on climbing
// back, design 5.6). Their depth must never read "Lover".
{
  const bonds = [
    bond("declined", { name: "Marit Hollowell", following: true, nearby: true, points: 2240,
      traits: { intimacy: "romantic", ardor: 3, exclusivity: 50, orientation: "both", orientationBasis: "known" } }),
    bond("declined", { name: "Osric Tallow", following: true, nearby: true, points: 1250,
      traits: { intimacy: "casual", ardor: 2, exclusivity: 25, orientation: "women", orientationBasis: "inferred" } }),
    bond("courting", { name: "Gisla Emberlee", following: true, nearby: true, points: 2140,
      traits: { intimacy: "romantic", ardor: 2, exclusivity: 50, orientation: "both", orientationBasis: "inferred" } }),
  ];
  write("declined-at-depth.json", snapshot(bonds));
}

// ---------------------------------------------------------------- foreclosed child
// The player's own child at the deepest platonic depth there is. Must never read
// "Spouse" or "Lover", and carries no romantic chips at all.
{
  const bonds = [
    bond("foreclosed", { name: "Lissa Ashkettle", foreclosure: "kin", following: false, nearby: true, points: 2640,
      enrolledBy: "following", traits: { intimacy: "never", ardor: 4, exclusivity: 0, orientation: "none", orientationBasis: "unknown" } }),
    bond("foreclosed", { name: "Tomsin Greywick", foreclosure: "minor", following: false, nearby: false, points: 1080,
      traits: { intimacy: "never", ardor: 3, exclusivity: 0, orientation: "none", orientationBasis: "unknown" } }),
    bond("courting", { name: "Aldric Ashkettle", following: false, nearby: true, points: 2780, commitment: "married",
      traits: { intimacy: "guarded", ardor: 2, exclusivity: 100, orientation: "women", orientationBasis: "known" } }),
  ];
  write("foreclosed-child.json", snapshot(bonds, {
    crosshairTarget: { formId: formId(), name: "Pim Ashkettle", enrolled: false },
  }));
}

// ---------------------------------------------------------------- roster status
// What the page gets before, and instead of, a current roster (WP2). The DLL
// sends its read model at once and asks Papyrus to refresh it; roster.status
// says how that stands. Mirrors native/src/Model.cpp's Snapshot(); keep the two
// in step.

// The first open after a load: the DLL has nothing yet and Papyrus has not
// answered. No store, no guessed enrollment, and the page says it is reading.
write("reading.json", snapshot([], {
  roster: { status: "reading", message: null },
  playthrough: { id: null, store: null, storeDecision: null },
  crosshairTarget: { formId: formId(), name: "Brenna Stonewhistle", enrolled: null },
}));

// A later open: the roster from the last refresh, with the numbers being read
// again. The page must stay usable while it waits.
{
  const bonds = [
    bond("platonic", { name: "Hrodwen Coldharbor", following: true, nearby: true, points: 940 }),
    bond("courting", { name: "Ansel Vireo", following: true, nearby: true, points: 2210,
      traits: { intimacy: "romantic", ardor: 3, exclusivity: 50, orientation: "both", orientationBasis: "inferred" } }),
    bond("unexamined", { name: "Tova Reedmere", following: false, nearby: false, points: 310 }),
  ];
  write("refreshing.json", snapshot(bonds, { roster: { status: "reading", message: null } }));
  // The same roster when Papyrus has not answered in ten seconds: shown as it
  // was, with a warning that it may be out of date.
  write("no-answer.json", snapshot(bonds, { roster: { status: "no answer", message: null } }));
}

// Papyrus answered that the mod has not started: said instead of an empty
// roster, in Papyrus's own words (SNRom_Bridge.OnDashboardRefresh).
write("not-ready.json", snapshot([], {
  roster: { status: "not ready", message: "Relationships has not started. CS_Romantasy.esp is missing, or its romance faction did not resolve (see snrom.log)." },
  playthrough: { id: null, store: null, storeDecision: null },
}));

write("index.json", {
  "default": "dev-save",
  "mocks": [
    { "id": "empty", "title": "Empty roster" },
    { "id": "dev-save", "title": "Dev save shape (~120 enrolled, ~15 following)" },
    { "id": "states", "title": "One of each state (design 5.2)" },
    { "id": "declined-at-depth", "title": "Declined companion at depth" },
    { "id": "foreclosed-child", "title": "Foreclosed child" },
    { "id": "reading", "title": "First open after a load: reading" },
    { "id": "refreshing", "title": "Reading, with the last roster" },
    { "id": "no-answer", "title": "No answer from Papyrus yet" },
    { "id": "not-ready", "title": "Papyrus says not ready" },
  ],
});

console.log("mocks written to", OUT.replace(/.*[\\/](ui[\\/])/, "$1"));
