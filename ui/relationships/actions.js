/* actions.js - what the dashboard can ask the game to do.

   Every entry is one `op` the page sends through snrom.request("action", ...),
   and `calls` names the SNRom_Bridge function the native side's table maps it
   to. The native side must look `op` up in a fixed table of its own; this list
   is what that table has to cover (bridge.js, the contract).

   These are the repairs and the re-read that exist today, as the README's
   Troubleshooting section documents them, plus the one new operation 2.0 needs.

   NOT HERE, ON PURPOSE: AcceptRomance, DeclineRomance, ReopenRomance,
   AskTheQuestion and EndRomance. Each one changes the consent gate or the
   stance, and a dashboard button for any of them would let the player answer
   a question nobody asked. That is a stop-and-ask change (brief 2.7), not a
   UI detail, so the page offers none of them. */

(function (UI) {
  "use strict";

  var FIELD = { intimacy: 0, ardor: 1, exclusivity: 2 };

  var ACTIONS = [
    {
      op: "ReseedActor",
      scope: "bond",
      calls: "SNRom_Bridge.ReseedActor(Actor)",
      label: "Re-read their standing",
      help: "Reads their record again and tops their standing up to what it now supports. It can raise them, never lower them.",
      // No follow requirement from 1.9 (WP4): the points are the mod's own,
      // and a re-read of someone not following used to change nothing
      // (Erdi, 2026-09-29). Ours land wherever
      // they are, so it works for anyone, like the re-author.
      needs: "Nothing: works wherever they are.",
      needsNearby: false,
      needsFollowing: false,
      confirm: null
    },
    {
      op: "ReauthorCharacter",
      scope: "bond",
      calls: "SNRom_Bridge.ReauthorCharacter(Actor)",
      label: "Re-author their character",
      help: "Writes who they are again from the record: orientation, intimacy, ardor, exclusivity, Why and Limit. What they call you is kept.",
      // Reads by character, not by what is in front of the player; only the
      // crosshair hotkey needs them present (design 12, decided 2026-09-29).
      needs: "Nothing: works wherever they are.",
      needsNearby: false,
      confirm: "This throws away the character on file, including everything that has drifted over your time together. The old one is written to the log, but there is no undo."
    },
    {
      op: "SetCharacterField",
      scope: "bond",
      calls: "SNRom_Bridge.SetCharacterField(Actor, Int field, Int value)",
      label: "Correct one trait",
      help: "Writes one trait directly, with no LLM involved. For a single wrong field when the rest are right.",
      needs: "Nothing: works wherever they are.",
      needsNearby: false,
      confirm: null,
      form: "traitField"
    },
    {
      op: "UnenrollActor",
      scope: "bond",
      calls: "SNRom_Bridge.UnenrollActor(Actor)",
      label: "Remove from roster",
      help: "For someone enrolled by mistake. They come off the roster and nothing assesses them from then on.",
      needs: "Nothing: works wherever they are.",
      needsNearby: false,
      confirm: "They come off the roster and stop being assessed. This is not a reset: what is already stored about them stays."
    },
    {
      op: "EnrollActor",
      scope: "crosshair",
      calls: "SNRom_Bridge.EnrollByHand(Actor)",
      label: "Enroll",
      help: "Starts a bond with the person you were looking at when you opened this, following you or not. Their character is written and their record read over the next few minutes.",
      needs: "They were under your crosshair when the dashboard opened.",
      needsNearby: false,
      confirm: null
    },
    {
      op: "StartFreshStore",
      scope: "playthrough",
      calls: "SNRom_Bridge.StartFreshStore()",
      label: "Give this playthrough its own store",
      help: "For a new game that inherited another playthrough's characters. Nothing is deleted; the other store stays on disk.",
      needs: null,
      needsNearby: false,
      confirm: "Everyone in this playthrough starts reading from a new, empty store. The store you leave is untouched, and 'Return to the main store' undoes this."
    },
    {
      op: "AdoptLegacyStore",
      scope: "playthrough",
      calls: "SNRom_Bridge.AdoptLegacyStore()",
      label: "Return to the main store",
      help: "Reattaches this playthrough to the original store and claims it. Undoes the action above.",
      needs: null,
      needsNearby: false,
      confirm: "This playthrough claims the main store. If another playthrough owns it, that one will get a store of its own the next time it loads."
    },

    // Developer tools. They exist and dispatch the same way, but each bypasses a
    // gate that is the design (their own doc comments say so), so they appear
    // only in developer mode - the same switch that shows hidden state
    // (mode.js). The native table maps them either way.
    {
      op: "RequestSparkNow",
      scope: "bond",
      calls: "SNRom_Bridge.RequestSparkNow(Actor)",
      label: "Ask the spark assessor now",
      help: "Judges them out of turn instead of waiting for the tenure gate. It does not set a spark; the assessor still decides.",
      needs: "They must be near you, with no spark verdict yet.",
      needsNearby: true,
      confirm: null,
      developer: true
    },
    {
      op: "UnsparkActor",
      scope: "bond",
      calls: "SNRom_Bridge.UnsparkActor(Actor)",
      label: "Return to the platonic ladder",
      help: "Clears a spark that should not have happened, keeping every point.",
      needs: null,
      needsNearby: false,
      confirm: "Their spark is cleared and the spark tenure gate starts again from now.",
      developer: true
    },
    {
      op: "ForceDriftReview",
      scope: "bond",
      calls: "SNRom_Bridge.ForceDriftReview(Actor, Int field)",
      label: "Force a drift review",
      help: "Reviews one trait now, bypassing both drift gates. A quiet history should come back NO.",
      needs: null,
      needsNearby: false,
      confirm: null,
      developer: true
    },
    {
      // The dashboard draws following, commitment and foreclosure from display
      // copies of three Papyrus functions (native/src/Display.cpp), on
      // probation. This runs the real ones for every bond and logs each
      // disagreement. Only ever when asked.
      op: "CheckDisplay",
      scope: "playthrough",
      calls: "SNRom_Bridge.CheckDashboardDisplay()",
      label: "Check the display against the rules",
      help: "Runs the real IsFollowing, CommitmentState and RomanceApplicability for every bond and compares what the dashboard shows. Slow on purpose: about a minute with 120 bonds. Disagreements go to SkyrimNetRelationships.log.",
      needs: null,
      needsNearby: false,
      confirm: "This takes about a minute with 120 bonds, and the game's scripts are busy until it is done.",
      developer: true
    }

  ];

  // A player's actions for a scope. Developer tools are never among them:
  // they have their own labelled place (developerTools, below), so a player
  // reading "Repairs" or "Playthrough repairs" meets only what is meant for
  // them, and a developer can find the tools without hunting.
  function available(scope) {
    return ACTIONS.filter(function (a) { return a.scope === scope && !a.developer; });
  }

  // The developer tools for a scope: none unless the developer view is on
  // (mode.js). The DLL and Papyrus refuse them without it all the same.
  function developerTools(scope) {
    if (!UI.mode.developer) return [];
    return ACTIONS.filter(function (a) { return a.scope === scope && a.developer; });
  }

  function byOp(op) {
    for (var i = 0; i < ACTIONS.length; i++) if (ACTIONS[i].op === op) return ACTIONS[i];
    return null;
  }

  UI.actions = { ACTIONS: ACTIONS, FIELD: FIELD, available: available, developerTools: developerTools, byOp: byOp };
})(window.SNRomUI = window.SNRomUI || {});
