/* mode.js - what the player may see, and the one switch that shows the rest.

   PLAYER MODE IS THE DEFAULT (the author, 2026-09-29, design open question 18).
   The dashboard shows what the player could know: depth, points, track, traits,
   and the states that have been SPOKEN between them - courting, declined,
   ended, foreclosed. It hides what the character has not said: an unspoken
   spark (Interested), the gate nobody has judged yet (Unexamined), the
   assessor's quiet verdict (Platonic), the spark date, a question they owe,
   and points held or banked while it waits. A menu must not tell the player
   what the mod exists to let them discover in play; 1.8.0 made the spark a
   private thought for the same reason.

   The snapshot still carries every field (snapshot.schema.json); this only
   decides what is drawn.

   ONE SWITCH for everything hidden - those fields, and the developer tools in
   actions.js - with three ways to throw it (design 7.6):
     - in game, the SkyrimNet setting dashboardDeveloperView, which arrives in
       every snapshot as settings.developer (WP3: SkyrimNetRelationships.dll);
     - in a browser, ?developer=1, for one page load; the game's hosts never
       add a query string;
     - DEVELOPER below, which stays false in anything shipped.
   Any one of them turns it on. The setting can turn it back off; it never
   overrides the other two. */

(function (UI) {
  "use strict";

  var DEVELOPER = false;

  var SPOKEN = ["foreclosed", "courting", "declined", "ended"];

  var local = DEVELOPER || /(^|[?&])developer=1(&|$)/.test(location.search || "");

  // The state to draw for a bond, or null to draw none. A sparked, unanswered
  // bond is already on the platonic track (the schema says so), so hiding its
  // state chip is all it takes for it to read as any other friendship.
  function shownState(b) {
    if (UI.mode.developer) return b.state;
    return SPOKEN.indexOf(b.state) >= 0 ? b.state : null;
  }

  // The states a filter or legend may offer, in the labels' order.
  function shownStates(order) {
    return UI.mode.developer ? order.slice() : order.filter(function (s) { return SPOKEN.indexOf(s) >= 0; });
  }

  // Takes the game's setting from a snapshot. True when the view changed, so
  // the page can rebuild what depends on it (the state filter, the badge).
  function apply(snapshot) {
    var fromGame = !!(snapshot && snapshot.settings && snapshot.settings.developer === true);
    var next = local || fromGame;
    var changed = next !== UI.mode.developer;
    UI.mode.developer = next;
    return changed;
  }

  UI.mode = { developer: local, shownState: shownState, shownStates: shownStates, apply: apply };
})(window.SNRomUI = window.SNRomUI || {});
