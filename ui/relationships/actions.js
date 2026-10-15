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

  var t = UI.t;
  var ACTIONS = [];

  // IN THE PLAYER'S LANGUAGE (2.3, WP-L): every word through t (labels.js),
  // and the list rebuilt in place by relabel() when the language changes, so
  // what holds it reads the new words. `calls` stays as written: it names code.
  function build() { fill([
    {
      op: "ReseedActor",
      scope: "bond",
      calls: "SNRom_Bridge.ReseedActor(Actor)",
      label: t("action.reseedActor.label", "Re-read their standing"),
      help: t("action.reseedActor.help", "Reads their record again and tops their standing up to what it now supports. It can raise them, never lower them."),
      // No follow requirement from 1.9 (WP4): the points are the mod's own,
      // and a re-read of someone not following used to change nothing
      // (Erdi, 2026-09-29). Ours land wherever
      // they are, so it works for anyone, like the re-author.
      needs: t("action.reseedActor.needs", "Nothing: works wherever they are."),
      needsNearby: false,
      needsFollowing: false,
      confirm: null
    },
    {
      op: "ReauthorCharacter",
      scope: "bond",
      calls: "SNRom_Bridge.ReauthorCharacter(Actor)",
      label: t("action.reauthorCharacter.label", "Re-author their character"),
      help: t("action.reauthorCharacter.help", "Writes who they are again from the record: orientation, intimacy, ardor, exclusivity, Why and Limit. What they call you is kept."),
      // Reads by character, not by what is in front of the player; only the
      // crosshair hotkey needs them present (design 12, decided 2026-09-29).
      needs: t("action.reauthorCharacter.needs", "Nothing: works wherever they are."),
      needsNearby: false,
      confirm: t("action.reauthorCharacter.confirm", "Their character is written again from the record. How they have changed through play since 2.2 is kept; the old one is written to the log, but there is no undo.")
    },
    {
      op: "SetCharacterField",
      scope: "bond",
      calls: "SNRom_Bridge.SetCharacterField(Actor, Int field, Int value)",
      label: t("action.setCharacterField.label", "Correct one trait"),
      help: t("action.setCharacterField.help", "Writes one trait directly, with no LLM involved. For a single wrong field when the rest are right."),
      needs: t("action.setCharacterField.needs", "Nothing: works wherever they are."),
      needsNearby: false,
      confirm: null,
      form: "traitField"
    },
    {
      op: "SetPlayerHistory",
      scope: "bond",
      calls: "SNRom_Bridge.SetPlayerHistory(Actor, String)",
      label: t("action.setPlayerHistory.label", "Your history with them"),
      help: t("action.setPlayerHistory.help", "For a relationship that began before Relationships was watching. Write it in a sentence or two; their record is read again at once, taking your words as fact, including how long you have known each other. It never makes them your lover or spouse on its own. Save it empty to clear it."),
      needs: t("action.setPlayerHistory.needs", "Nothing: works wherever they are."),
      needsNearby: false,
      confirm: null,
      form: "historyText"
    },
    {
      op: "ClearAddress",
      scope: "bond",
      calls: "SNRom_Bridge.ClearAddress(Actor)",
      label: t("action.clearAddress.label", "Forget what they call you"),
      help: t("action.clearAddress.help", "For a name that came out garbled or wrong. They go back to having no saved name for you, as when they were enrolled, until a conversation sets one again."),
      needs: t("action.clearAddress.needs", "Nothing: works wherever they are."),
      needsNearby: false,
      needsAddress: true,
      confirm: t("action.clearAddress.confirm", "The name they call you is forgotten. There is no undo, but you can tell them in conversation what to call you.")
    },
    {
      op: "UnenrollActor",
      scope: "bond",
      calls: "SNRom_Bridge.UnenrollActor(Actor)",
      label: t("action.unenrollActor.label", "Remove from roster"),
      help: t("action.unenrollActor.help", "For someone enrolled by mistake. They come off the roster and nothing assesses them from then on."),
      needs: t("action.unenrollActor.needs", "Nothing: works wherever they are."),
      needsNearby: false,
      confirm: t("action.unenrollActor.confirm", "They come off the roster and stop being assessed. This is not a reset: what is already stored about them stays.")
    },
    {
      op: "EnrollActor",
      scope: "crosshair",
      calls: "SNRom_Bridge.EnrollByHand(Actor)",
      label: t("action.enrollActor.label", "Enroll"),
      help: t("action.enrollActor.help", "Starts a bond with the person you were looking at when you opened this, following you or not. Their character is written and their record read over the next few minutes."),
      needs: t("action.enrollActor.needs", "They were under your crosshair when the dashboard opened."),
      needsNearby: false,
      confirm: null
    },
    {
      op: "StartFreshStore",
      scope: "playthrough",
      calls: "SNRom_Bridge.StartFreshStore()",
      label: t("action.startFreshStore.label", "Give this playthrough its own store"),
      help: t("action.startFreshStore.help", "For a new game that inherited another playthrough's characters. Nothing is deleted; the other store stays on disk."),
      needs: null,
      needsNearby: false,
      confirm: t("action.startFreshStore.confirm", "Everyone in this playthrough starts reading from a new, empty store. The store you leave is untouched, and 'Return to the main store' undoes this.")
    },
    {
      op: "AdoptLegacyStore",
      scope: "playthrough",
      calls: "SNRom_Bridge.AdoptLegacyStore()",
      label: t("action.adoptLegacyStore.label", "Return to the main store"),
      help: t("action.adoptLegacyStore.help", "Reattaches this playthrough to the original store and claims it. Undoes the action above."),
      needs: null,
      needsNearby: false,
      confirm: t("action.adoptLegacyStore.confirm", "This playthrough claims the main store. If another playthrough owns it, that one will get a store of its own the next time it loads.")
    },
    {
      op: "RestoreOurBioBlocks",
      scope: "playthrough",
      calls: "SNRom_Bridge.RestoreOurBioBlocks()",
      label: t("action.restoreOurBioBlocks.label", "Give everyone our bio blocks again"),
      help: t("action.restoreOurBioBlocks.help", "For a game where Relationships' bio blocks were deleted in SeverActions and then restored: until 2.1.1 everyone who carried one was recorded as having it taken off, so nobody got it back. Restore the blocks on SeverActions' Bio Blocks page (Hidden) first."),
      needs: null,
      needsNearby: false,
      confirm: t("action.restoreOurBioBlocks.confirm", "Every category where a Relationships block was recorded as taken off gets ours again, if it is empty. Blocks you chose yourself stay. A category you emptied on purpose gets ours back too; take it off again in SeverActions if you meant it.")
    },

    // Developer tools. They exist and dispatch the same way, but each bypasses a
    // gate that is the design (their own doc comments say so), so they appear
    // only in developer mode - the same switch that shows hidden state
    // (mode.js). The native table maps them either way.
    {
      op: "RequestSparkNow",
      scope: "bond",
      calls: "SNRom_Bridge.RequestSparkNow(Actor)",
      label: t("action.requestSparkNow.label", "Ask the spark assessor now"),
      help: t("action.requestSparkNow.help", "Judges them out of turn instead of waiting for the tenure gate. It does not set a spark; the assessor still decides."),
      needs: t("action.requestSparkNow.needs", "They must be near you, with no spark verdict yet."),
      needsNearby: true,
      confirm: null,
      developer: true
    },
    {
      op: "UnsparkActor",
      scope: "bond",
      calls: "SNRom_Bridge.UnsparkActor(Actor)",
      label: t("action.unsparkActor.label", "Return to the platonic ladder"),
      help: t("action.unsparkActor.help", "Clears a spark that should not have happened, keeping every point."),
      needs: null,
      needsNearby: false,
      confirm: t("action.unsparkActor.confirm", "Their spark is cleared and the spark tenure gate starts again from now."),
      developer: true
    },
    {
      op: "ForceDriftReview",
      scope: "bond",
      calls: "SNRom_Bridge.ForceDriftReview(Actor, Int field)",
      label: t("action.forceDriftReview.label", "Force a drift review"),
      help: t("action.forceDriftReview.help", "Reviews one trait now, bypassing both drift gates. A quiet history should come back NO."),
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
      label: t("action.checkDisplay.label", "Check the display against the rules"),
      help: t("action.checkDisplay.help", "Runs the real IsFollowing, CommitmentState and RomanceApplicability for every bond and compares what the dashboard shows. Slow on purpose: about a minute with 120 bonds. Disagreements go to SkyrimNetRelationships.log."),
      needs: null,
      needsNearby: false,
      confirm: t("action.checkDisplay.confirm", "This takes about a minute with 120 bonds, and the game's scripts are busy until it is done."),
      developer: true
    }

  ]); }
  function fill(list) { ACTIONS.length = 0; list.forEach(function (a) { ACTIONS.push(a); }); }
  build();

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

  UI.actions = { ACTIONS: ACTIONS, FIELD: FIELD, available: available, developerTools: developerTools, byOp: byOp, relabel: build };
})(window.SNRomUI = window.SNRomUI || {});
