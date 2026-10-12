/* labels.js - every word the page shows for a number or an enum.

   One place, so a vocabulary decision is a one-line change here and nowhere
   else. The snapshot carries values (snapshot.schema.json); this turns them
   into what a player reads.

   IN THE PLAYER'S LANGUAGE (2.3, WP-L). Every word goes through t(key,
   english): the snapshot's `strings` (the DLL's table for the Language
   setting, native/src/L10n.h) when it has the key, the English written here
   when it does not. The tables below are built by build() and REBUILT IN
   PLACE when the language changes (setStrings), so everything that holds
   them - the roster, the detail, the filters - reads the new words without
   being told. tools/gen-l10n.ps1 collects every t call's key and English in
   the page into l10n/en.json; keep both literals on the call's line. */

(function (UI) {
  "use strict";

  // ------------------------------------------------------------- the words
  var strings = {};

  // The text for a key in the player's language, or the English given here;
  // {0} and {1} filled from the arguments either way.
  function t(key, english, a0, a1) {
    var s = Object.prototype.hasOwnProperty.call(strings, key) && typeof strings[key] === "string"
      ? strings[key] : english;
    if (a0 !== undefined) s = s.split("{0}").join(String(a0));
    if (a1 !== undefined) s = s.split("{1}").join(String(a1));
    return s;
  }

  // The snapshot's table; rebuilds every table below when it changed.
  // Returns true when it did, so the page knows to redraw what it drew once.
  var current = "";
  function setStrings(table) {
    var next = table && typeof table === "object" ? table : {};
    var sig = JSON.stringify(next);
    if (sig === current) return false;
    current = sig;
    strings = next;
    build();
    return true;
  }

  function fill(target, source) {
    if (Array.isArray(target)) { target.length = 0; source.forEach(function (v) { target.push(v); }); return; }
    Object.keys(target).forEach(function (k) { delete target[k]; });
    Object.keys(source).forEach(function (k) { target[k] = source[k]; });
  }

  // Depth names per TRACK (design 7.1: two tracks, visibly). Index is the tier.
  //
  // The romantic ladder's names, kept from 1.x (design 1).
  //
  // Platonic names decided 2026-09-29 (design 12, question 2): Ally, vanilla's
  // own rank above Confidant, and Best Friend. Several characters may each be a
  // Best Friend at once; it names depth, not uniqueness, and nothing here or
  // anywhere may enforce a single one. A platonic bond is named from this list,
  // so it can never read "Lover" or "Spouse".
  var TIER_NAMES = { romantic: [], platonic: [] };

  // BELOW STRANGER (2.2, WP-N): one ladder, whatever the track. Index is
  // -tier - 1. And Stranger after being close reads ESTRANGED: named by
  // history (depth.estranged), never by points.
  var BELOW_NAMES = [];
  var ESTRANGED = { word: "" };

  var TRACKS = { platonic: {}, romantic: {} };

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
  var STATES = {};
  var STATE_ORDER = ["foreclosed", "unexamined", "platonic", "interested", "courting", "declined", "ended"];

  var FORECLOSURE = {};
  var STANCE = {};
  var COMMITMENT = {};
  // The roster's Commitment column (asked for 2026-10-01: a long list of
  // Spouse-depth bonds says nothing about who is actually married). No chip
  // for "none": an empty cell is the ordinary case, as with State.
  var COMMITMENT_CHIP = {};
  var ENROLLED_BY = {};

  // The authoring vocabulary (SNRom_Decorators: IntimacyWordFromTier,
  // ArdorToInt, ExclusivityToInt). Shown as words because the words carry
  // their own meaning and the numbers do not.
  var INTIMACY = {};
  var ARDOR = [];
  var EXCLUSIVITY = [];
  var ORIENTATION = {};
  var ORIENTATION_SHORT = {};

  // WHAT MOVED A BOND: the history the DLL keeps per bond (snapshot
  // bond.history, newest first), by SNRom_Bridge.ApplyDepth's kind. What a
  // player sees follows design 7.6, immersion first:
  //   show  - the reason as recorded; it says nothing unspoken
  //   plain - the label stands in for a reason that would say what nobody has
  //           said aloud (a spark is someone's private feeling)
  //   dev   - the developer view only: the consent gate's own workings
  var CHANGE = {};

  function build() {
    fill(TIER_NAMES.romantic, [t("tier.stranger", "Stranger"), t("tier.acquaintance", "Acquaintance"), t("tier.friend", "Friend"),
      t("tier.confidant", "Confidant"), t("tier.lover", "Lover"), t("tier.spouse", "Spouse")]);
    fill(TIER_NAMES.platonic, [t("tier.stranger", "Stranger"), t("tier.acquaintance", "Acquaintance"), t("tier.friend", "Friend"),
      t("tier.confidant", "Confidant"), t("tier.ally", "Ally"), t("tier.bestFriend", "Best Friend")]);
    fill(BELOW_NAMES, [t("tier.disliked", "Disliked"), t("tier.resentful", "Resentful"), t("tier.enemy", "Enemy")]);
    ESTRANGED.word = t("tier.estranged", "Estranged");

    TRACKS.platonic.label = t("track.platonic", "Platonic");
    TRACKS.romantic.label = t("track.romantic", "Romantic");

    fill(STATES, {
      foreclosed: { label: t("state.foreclosed", "Foreclosed"), blurb: t("state.foreclosed.blurb", "Romance was never a question between you.") },
      unexamined: { label: t("state.unexamined", "Unexamined"), blurb: t("state.unexamined.blurb", "Nobody has judged yet whether anything romantic has crossed. They are held short of Lover until then.") },
      platonic:   { label: t("state.platonic", "Platonic"),     blurb: t("state.platonic.blurb", "Judged: nothing romantic. The bond climbs freely all the way up.") },
      interested: { label: t("state.interested", "Interested"), blurb: t("state.interested.blurb", "Something has crossed on their side, and they have not said it aloud.") },
      courting:   { label: t("state.courting", "Courting"),     blurb: t("state.courting.blurb", "Said aloud and mutual: they asked, and you said yes."),
                    filterLabel: t("state.courting.filter", "Courting / Devoted"),
                    devoted: { label: t("state.devoted", "Devoted"), blurb: t("state.devoted.blurb", "Said aloud and mutual, and as deep as a bond goes. Whether there has been a wedding is the Commitment line's to say.") } },
      declined:   { label: t("state.declined", "Declined"),     blurb: t("state.declined.blurb", "They asked and you said no. It stings for a while and mends as the bond grows; if they climb back to where they asked, they ask again.") },
      ended:      { label: t("state.ended", "Ended"),           blurb: t("state.ended.blurb", "It was romantic once, and it is over. There is history between you.") }
    });

    fill(FORECLOSURE, {
      kin: t("foreclosure.kin", "Your own child"),
      minor: t("foreclosure.minor", "A child"),
      orientation: t("foreclosure.orientation", "Not drawn to you")
    });
    fill(STANCE, {
      unanswered: t("stance.unanswered", "Not answered"),
      accepted: t("stance.accepted", "You said yes"),
      declined: t("stance.declined", "You said no")
    });
    fill(COMMITMENT, {
      none: t("commitment.none", "None recorded"),
      candidate: t("commitment.candidate", "Marriage candidate"),
      engaged: t("commitment.engaged", "Engaged"),
      married: t("commitment.married", "Married")
    });
    fill(COMMITMENT_CHIP, {
      candidate: { label: t("commitment.chip.candidate", "Candidate"), hint: t("commitment.chip.candidate.hint", "Marriage candidate: a proposal would be accepted") },
      engaged: { label: t("commitment.engaged", "Engaged"), hint: t("commitment.chip.engaged.hint", "Engaged to you") },
      married: { label: t("commitment.married", "Married"), hint: t("commitment.chip.married.hint", "Married to you") }
    });
    fill(ENROLLED_BY, {
      following: t("enrolledBy.following", "Automatically, while following you"),
      dialogue: t("enrolledBy.dialogue", "When they began it in conversation"),
      player: t("enrolledBy.player", "By you"),
      unknown: t("enrolledBy.unknown", "Before this was recorded")
    });

    fill(INTIMACY, {
      casual: t("intimacy.casual", "Casual"), romantic: t("intimacy.romantic", "Romantic"),
      guarded: t("intimacy.guarded", "Guarded"), never: t("intimacy.never", "Never")
    });
    fill(ARDOR, [t("ardor.0", "Reserved"), t("ardor.1", "Measured"), t("ardor.2", "Warm"), t("ardor.3", "Open"), t("ardor.4", "Intense")]);
    fill(EXCLUSIVITY, [
      { at: 0, word: t("exclusivity.0", "Untroubled") },
      { at: 25, word: t("exclusivity.25", "Accepting") },
      { at: 50, word: t("exclusivity.50", "Conventional") },
      { at: 75, word: t("exclusivity.75", "Possessive") },
      { at: 100, word: t("exclusivity.100", "Consuming") }
    ]);
    fill(ORIENTATION, {
      men: t("orientation.men", "Men"), women: t("orientation.women", "Women"),
      both: t("orientation.both", "Men and women"), none: t("orientation.none", "No one")
    });
    fill(ORIENTATION_SHORT, {
      men: t("orientation.men", "Men"), women: t("orientation.women", "Women"),
      both: t("orientation.both.short", "Both"), none: t("orientation.none", "No one")
    });

    fill(CHANGE, {
      moment: { label: t("change.moment", "A moment between you"), player: "show" },
      talk: { label: t("change.talk", "A conversation"), player: "show" },
      began: { label: t("change.began", "Something began"), player: "show" },
      seed: { label: t("change.seed", "Read from your history together"), player: "plain" },
      married: { label: t("change.married", "Married"), player: "show" },
      accepted: { label: t("change.accepted", "You said yes"), player: "show" },
      declined: { label: t("change.declined", "You said no"), player: "show" },
      ended: { label: t("change.ended", "It ended"), player: "show" },
      "import": { label: t("change.import", "Brought over"), player: "show" },
      spark: { label: t("change.spark", "Something shifted"), player: "plain" },
      released: { label: t("change.released", "Counted at last"), player: "plain" },
      withheld: { label: t("change.withheld", "Held back short of Lover, until you answer"), player: "dev" },
      ceiling: { label: t("change.ceiling", "Held at the Lover line"), player: "dev" },
      dev: { label: t("change.dev", "Set by a developer tool"), player: "dev" }
    });
  }
  build();

  function tierName(track, tier, estranged) {
    if (tier < 0) return BELOW_NAMES[Math.min(BELOW_NAMES.length, -tier) - 1];
    if (tier === 0 && estranged) return ESTRANGED.word;
    var names = track === "romantic" ? TIER_NAMES.romantic : TIER_NAMES.platonic;
    return names[Math.max(0, Math.min(names.length - 1, tier))];
  }

  // The class a tier's name and bar take: the track's colour, or the colour of
  // the ill will below Stranger.
  function tierClass(b) {
    return b.depth.tier < 0 ? "t-below n" + (-b.depth.tier) : "t-" + b.track;
  }

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

  // Drift moves exclusivity by 20, so most values sit between anchors: name
  // the nearest one and show the number beside it.
  function exclusivityWord(v) {
    var best = EXCLUSIVITY[0];
    EXCLUSIVITY.forEach(function (a) { if (Math.abs(a.at - v) < Math.abs(best.at - v)) best = a; });
    return best.word;
  }

  function orientationChip(traits) {
    if (traits.orientationBasis === "unknown") return { text: t("orientation.unknown", "Unknown"), hint: t("orientation.unknown.hint", "Nobody has established who they are drawn to.") };
    var word = ORIENTATION_SHORT[traits.orientation] || traits.orientation;
    if (traits.orientationBasis === "inferred") return { text: word + "?", hint: t("orientation.inferred.hint", "Inferred, not known: {0}. Only a known orientation can close a door.", ORIENTATION[traits.orientation]) };
    return { text: word, hint: t("orientation.known.hint", "Known: {0}.", ORIENTATION[traits.orientation]) };
  }

  function hexId(formId) {
    var s = (formId >>> 0).toString(16).toUpperCase();
    while (s.length < 8) s = "0" + s;
    return "0x" + s;
  }

  function number(n) {
    return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, t("number.thousands", ","));
  }

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
    if (key === "withheld") return t("change.held", "held {0}", number(e.delta));
    if (key === "import") return number(e.delta);
    return (e.delta >= 0 ? "+" : "−") + number(Math.abs(e.delta));
  }

  function changeClass(e) {
    var key = kindKey(e.kind);
    if (key === "withheld" || key === "ceiling") return "held";
    if (key === "import") return "base";
    return e.delta >= 0 ? "up" : "down";
  }

  function gameDay(time) {
    return t("time.day", "day {0}", Math.floor(time));
  }

  function daysAgo(then, now) {
    var d = Math.floor(now - then);
    if (d <= 0) return t("time.today", "today");
    if (d === 1) return t("time.yesterday", "yesterday");
    return t("time.daysAgo", "{0} days ago", d);
  }

  UI.t = t;
  UI.labels = {
    t: t,
    setStrings: setStrings,
    TIER_NAMES: TIER_NAMES,
    BELOW_NAMES: BELOW_NAMES,
    ESTRANGED: ESTRANGED,
    tierName: tierName,
    tierClass: tierClass,
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
