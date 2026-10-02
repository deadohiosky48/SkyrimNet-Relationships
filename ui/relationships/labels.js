/* labels.js - every word the page shows for a number or an enum.

   One place, so a vocabulary decision is a one-line change here and nowhere
   else. The snapshot carries values (snapshot.schema.json); this turns them
   into what a player reads. */

(function (UI) {
  "use strict";

  // Depth names per TRACK (design 7.1: two tracks, visibly). Index is the tier.
  //
  // The romantic ladder's names, kept from 1.x (design 1).
  //
  // Platonic names decided 2026-09-29 (design 12, question 2): Ally, vanilla's
  // own rank above Confidant, and Best Friend. Several characters may each be a
  // Best Friend at once; it names depth, not uniqueness, and nothing here or
  // anywhere may enforce a single one. A platonic bond is named from this list,
  // so it can never read "Lover" or "Spouse".
  var TIER_NAMES = {
    romantic: ["Stranger", "Acquaintance", "Friend", "Confidant", "Lover", "Spouse"],
    platonic: ["Stranger", "Acquaintance", "Friend", "Confidant", "Ally", "Best Friend"]
  };

  function tierName(track, tier) {
    var names = track === "romantic" ? TIER_NAMES.romantic : TIER_NAMES.platonic;
    return names[Math.max(0, Math.min(names.length - 1, tier))];
  }

  var TRACKS = {
    platonic: { label: "Platonic" },
    romantic: { label: "Romantic" }
  };

  // Design 5.2, in words for the player. `blurb` is the detail view's one line;
  // the design table's third column is behavior, which the player sees in play.
  // Player mode draws only the spoken ones (mode.js); the rest are words for
  // developer mode.
  //
  // AN ACCEPTED BOND READS "COURTING" BELOW SPOUSE DEPTH AND "DEVOTED" AT IT
  // (decided 2026-09-29, design 5.6). A label on the courting state, derived
  // from depth, not a new state: the snapshot still says "courting", the chip
  // keeps its colour, and the state filter has one entry for both. Not
  // "Committed", because the Commitment line says "None recorded" unless a
  // marriage is recorded, and the two would contradict each other.
  var DEVOTED_TIER = 5;
  var STATES = {
    foreclosed: { label: "Foreclosed", blurb: "Romance was never a question between you." },
    unexamined: { label: "Unexamined", blurb: "Nobody has judged yet whether anything romantic has crossed. They are held short of Lover until then." },
    platonic:   { label: "Platonic",   blurb: "Judged: nothing romantic. The bond climbs freely all the way up." },
    interested: { label: "Interested", blurb: "Something has crossed on their side, and they have not said it aloud." },
    courting:   { label: "Courting",   blurb: "Said aloud and mutual: they asked, and you said yes.",
                  filterLabel: "Courting / Devoted",
                  devoted: { label: "Devoted", blurb: "Said aloud and mutual, and as deep as a bond goes. Whether there has been a wedding is the Commitment line's to say." } },
    declined:   { label: "Declined",   blurb: "They asked and you said no. It stings for a while and mends as the bond grows; if they climb back to where they asked, they ask again." },
    ended:      { label: "Ended",      blurb: "It was romantic once, and it is over. There is history between you." }
  };
  var STATE_ORDER = ["foreclosed", "unexamined", "platonic", "interested", "courting", "declined", "ended"];

  // What a bond's state chip and blurb read. Only "courting" varies: at Spouse
  // depth it reads Devoted.
  function devoted(state, bond) {
    return state === "courting" && !!bond && bond.depth.tier >= DEVOTED_TIER;
  }
  function stateLabel(state, bond) {
    return devoted(state, bond) ? STATES.courting.devoted.label : STATES[state].label;
  }
  function stateBlurb(state, bond) {
    return devoted(state, bond) ? STATES.courting.devoted.blurb : STATES[state].blurb;
  }
  // The state filter and the summary legend: one entry per state.
  function stateFilterLabel(state) {
    return STATES[state].filterLabel || STATES[state].label;
  }

  var FORECLOSURE = {
    kin: "Your own child",
    minor: "A child",
    orientation: "Not drawn to you"
  };

  var STANCE = {
    unanswered: "Not answered",
    accepted: "You said yes",
    declined: "You said no"
  };

  var COMMITMENT = {
    none: "None recorded",
    candidate: "Marriage candidate",
    engaged: "Engaged",
    married: "Married"
  };
  // The roster's Commitment column (asked for 2026-10-01: a long list of
  // Spouse-depth bonds says nothing about who is actually married). No chip
  // for "none": an empty cell is the ordinary case, as with State.
  var COMMITMENT_CHIP = {
    candidate: { label: "Candidate", hint: "Marriage candidate: a proposal would be accepted" },
    engaged: { label: "Engaged", hint: "Engaged to you" },
    married: { label: "Married", hint: "Married to you" }
  };

  var ENROLLED_BY = {
    following: "Automatically, while following you",
    dialogue: "When they began it in conversation",
    player: "By you",
    unknown: "Before this was recorded"
  };

  // The authoring vocabulary (SNRom_Decorators: IntimacyWordFromTier,
  // ArdorToInt, ExclusivityToInt). Shown as words because the words carry
  // their own meaning and the numbers do not.
  var INTIMACY = { casual: "Casual", romantic: "Romantic", guarded: "Guarded", never: "Never" };
  var ARDOR = ["Reserved", "Measured", "Warm", "Open", "Intense"];
  var EXCLUSIVITY = [
    { at: 0, word: "Untroubled" },
    { at: 25, word: "Accepting" },
    { at: 50, word: "Conventional" },
    { at: 75, word: "Possessive" },
    { at: 100, word: "Consuming" }
  ];

  // Drift moves exclusivity by 20, so most values sit between anchors: name
  // the nearest one and show the number beside it.
  function exclusivityWord(v) {
    var best = EXCLUSIVITY[0];
    EXCLUSIVITY.forEach(function (a) { if (Math.abs(a.at - v) < Math.abs(best.at - v)) best = a; });
    return best.word;
  }

  var ORIENTATION = { men: "Men", women: "Women", both: "Men and women", none: "No one" };
  var ORIENTATION_SHORT = { men: "Men", women: "Women", both: "Both", none: "No one" };

  function orientationChip(traits) {
    if (traits.orientationBasis === "unknown") return { text: "Unknown", hint: "Nobody has established who they are drawn to." };
    var word = ORIENTATION_SHORT[traits.orientation] || traits.orientation;
    if (traits.orientationBasis === "inferred") return { text: word + "?", hint: "Inferred, not known: " + ORIENTATION[traits.orientation] + ". Only a known orientation can close a door." };
    return { text: word, hint: "Known: " + ORIENTATION[traits.orientation] + "." };
  }

  function hexId(formId) {
    var s = (formId >>> 0).toString(16).toUpperCase();
    while (s.length < 8) s = "0" + s;
    return "0x" + s;
  }

  function number(n) {
    return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  }

  // WHAT MOVED A BOND: the history the DLL keeps per bond (snapshot
  // bond.history, newest first), by SNRom_Bridge.ApplyDepth's kind. What a
  // player sees follows design 7.6, immersion first:
  //   show  - the reason as recorded; it says nothing unspoken
  //   plain - the label stands in for a reason that would say what nobody has
  //           said aloud (a spark is someone's private feeling)
  //   dev   - the developer view only: the consent gate's own workings
  var CHANGE = {
    moment: { label: "A moment between you", player: "show" },
    talk: { label: "A conversation", player: "show" },
    began: { label: "Something began", player: "show" },
    seed: { label: "Read from your history together", player: "plain" },
    married: { label: "Married", player: "show" },
    accepted: { label: "You said yes", player: "show" },
    declined: { label: "You said no", player: "show" },
    ended: { label: "It ended", player: "show" },
    "import": { label: "Brought over", player: "show" },
    spark: { label: "Something shifted", player: "plain" },
    released: { label: "Counted at last", player: "plain" },
    withheld: { label: "Held back short of Lover, until you answer", player: "dev" },
    ceiling: { label: "Held at the Lover line", player: "dev" }
  };

  // Lowercased first: Papyrus keeps one copy of each string whatever its case,
  // so "talk" can arrive as "Talk" - seen in play 2026-10-01. The DLL lowers
  // it too (History.cpp); this covers history saved before it did.
  function kindKey(kind) {
    return String(kind || "").toLowerCase();
  }

  function changeKind(kind) {
    var key = kindKey(kind);
    return (Object.prototype.hasOwnProperty.call(CHANGE, key) && CHANGE[key]) || { label: kind, player: "show" };
  }

  // The changes this mode may show, newest first.
  function visibleChanges(history, developer) {
    return (history || []).filter(function (e) { return developer || changeKind(e.kind).player !== "dev"; });
  }

  // The words for one change: its reason, or its label when the reason is
  // the player's to hear only in the developer view (or there is none).
  function changeText(e, developer) {
    var k = changeKind(e.kind);
    if (!developer && k.player === "plain") return k.label;
    return e.reason || k.label;
  }

  // "+40", "−25" (a real minus), or "held 40" for a withheld award.
  function changeAmount(e) {
    var key = kindKey(e.kind);
    if (key === "withheld") return "held " + number(e.delta);
    if (key === "import") return number(e.delta);
    return (e.delta >= 0 ? "+" : "−") + number(Math.abs(e.delta));
  }

  function changeClass(e) {
    var key = kindKey(e.kind);
    if (key === "withheld" || key === "ceiling") return "held";
    if (key === "import") return "base";
    return e.delta >= 0 ? "up" : "down";
  }

  function gameDay(t) {
    return "day " + Math.floor(t);
  }

  function daysAgo(then, now) {
    var d = Math.floor(now - then);
    if (d <= 0) return "today";
    if (d === 1) return "yesterday";
    return d + " days ago";
  }

  UI.labels = {
    TIER_NAMES: TIER_NAMES,
    tierName: tierName,
    TRACKS: TRACKS,
    STATES: STATES,
    STATE_ORDER: STATE_ORDER,
    stateLabel: stateLabel,
    stateBlurb: stateBlurb,
    stateFilterLabel: stateFilterLabel,
    FORECLOSURE: FORECLOSURE,
    STANCE: STANCE,
    COMMITMENT: COMMITMENT,
    COMMITMENT_CHIP: COMMITMENT_CHIP,
    ENROLLED_BY: ENROLLED_BY,
    INTIMACY: INTIMACY,
    ARDOR: ARDOR,
    exclusivityWord: exclusivityWord,
    ORIENTATION: ORIENTATION,
    orientationChip: orientationChip,
    hexId: hexId,
    number: number,
    gameDay: gameDay,
    daysAgo: daysAgo,
    CHANGE: CHANGE,
    changeKind: changeKind,
    visibleChanges: visibleChanges,
    changeText: changeText,
    changeAmount: changeAmount,
    changeClass: changeClass
  };
})(window.SNRomUI = window.SNRomUI || {});
