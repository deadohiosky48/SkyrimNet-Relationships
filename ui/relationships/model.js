/* model.js - pure functions over a snapshot: keys, progress, filter, sort.

   Nothing here touches the DOM, so the tests can reason about it and the
   roster can re-run it on every keystroke without cost. */

(function (UI) {
  "use strict";

  var L = UI.labels;

  // A bond is a pair. The key names both parties, so a second bond for the
  // same subject (NPC-to-NPC, design 3.3) can never collide with the first.
  function bondKey(b) {
    return b.subject.formId + ">" + b.object.formId;
  }

  // How far through their current tier, and - in developer mode only - why they
  // are not moving if they are being held. Thresholds come from the snapshot,
  // never from here.
  //
  // A hold is private state (mode.js): it exists because of a spark or a verdict
  // the player has not been told about. So in player mode a held bond reads
  // like any other, "1 to next" at 1,999, which is also what the points say.
  function progress(b, ladder) {
    var reveal = UI.mode.developer;
    var th = ladder.thresholds;
    var t = b.depth.tier;
    var p = b.depth.points;
    var top = th.length - 1;
    var out = { pct: 1, held: false, note: "" };
    // BELOW STRANGER (2.2, WP-N) the bar fills from the right, by how deep
    // into the tier they are, and the note is the climb back to the next.
    if (t < 0) {
      var below = ladder.below || [-500, -1000, -1500];
      var floorPts = typeof ladder.floor === "number" ? ladder.floor : -2000;
      var ceil = below[-t - 1];
      var bottom = -t < below.length ? below[-t] + 1 : floorPts;
      out.below = true;
      out.pct = Math.max(0, Math.min(1, (ceil - p) / Math.max(1, ceil - bottom)));
      out.toNext = ceil + 1 - p;
      out.note = UI.t("progress.toClimb", "{0} to climb", L.number(out.toNext));
      return out;
    }
    if (t >= top) {
      out.note = UI.t("progress.top", "Top of the ladder");
      return out;
    }
    var floor = th[t], next = th[t + 1];
    out.pct = Math.max(0, Math.min(1, (p - floor) / (next - floor)));
    out.toNext = next - p;
    // Held one short of the Lover line: HoldShortOfLover withholds (and banks)
    // what would carry an unjudged or unanswered bond across. Said in words,
    // because a full bar that never fills otherwise reads as a bug.
    var loverLine = th[4];
    var atLine = p >= loverLine - 1 || b.depth.banked > 0;
    if (!reveal) {
      out.note = UI.t("progress.toNext", "{0} to next", L.number(out.toNext));
    } else if (atLine && b.state === "unexamined") {
      out.held = true;
      out.note = UI.t("progress.heldJudged", "Held until judged");
    } else if (atLine && b.state === "interested" && b.stance === "unanswered") {
      out.held = true;
      out.note = b.askPending ? UI.t("progress.heldOwed", "Held: question owed") : UI.t("progress.heldUnanswered", "Held: question unanswered");
    } else {
      out.note = UI.t("progress.toNext", "{0} to next", L.number(out.toNext));
    }
    return out;
  }

  function matches(b, f) {
    if (f.following === "yes" && !b.following) return false;
    if (f.following === "no" && b.following) return false;
    if (f.track !== "all" && b.track !== f.track) return false;
    if (f.state !== "all" && b.state !== f.state) return false;
    if (f.commitment !== "all" && b.commitment !== f.commitment) return false;
    if (f.standing === "good" && b.depth.tier < 1) return false;
    if (f.standing === "none" && b.depth.tier !== 0) return false;
    if (f.standing === "ill" && b.depth.tier >= 0) return false;
    if (f.text) {
      if (b.subject.name.toLowerCase().indexOf(f.text) < 0) return false;
    }
    return true;
  }

  function byName(a, b) {
    var x = a.subject.name.toLowerCase(), y = b.subject.name.toLowerCase();
    if (x < y) return -1;
    if (x > y) return 1;
    return a.subject.formId - b.subject.formId;
  }

  var SORTS = {
    "depth-desc": function (a, b) { return (b.depth.points - a.depth.points) || byName(a, b); },
    "depth-asc": function (a, b) { return (a.depth.points - b.depth.points) || byName(a, b); },
    "name-asc": byName,
    "name-desc": function (a, b) { return byName(b, a); }
  };

  function view(bonds, f, sort) {
    var norm = {
      following: f.following || "all",
      track: f.track || "all",
      state: f.state || "all",
      commitment: f.commitment || "all",
      standing: f.standing || "all",
      text: (f.text || "").trim().toLowerCase()
    };
    var out = [];
    for (var i = 0; i < bonds.length; i++) if (matches(bonds[i], norm)) out.push(bonds[i]);
    out.sort(SORTS[sort] || SORTS["depth-desc"]);
    return out;
  }

  function counts(bonds) {
    var c = { total: bonds.length, following: 0, platonic: 0, romantic: 0, states: {} };
    L.STATE_ORDER.forEach(function (s) { c.states[s] = 0; });
    bonds.forEach(function (b) {
      if (b.following) c.following++;
      c[b.track]++;
      c.states[b.state]++;
    });
    return c;
  }

  UI.model = { bondKey: bondKey, progress: progress, view: view, counts: counts, SORTS: SORTS };
})(window.SNRomUI = window.SNRomUI || {});
