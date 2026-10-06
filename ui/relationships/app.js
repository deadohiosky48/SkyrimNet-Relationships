/* app.js - wires the page together. Talks to the game only through
   snrom.request and snrom.on (bridge.js). */

(function (UI) {
  "use strict";

  var L = UI.labels;
  var M = UI.model;
  var A = UI.actions;
  var snrom = window.snrom;

  // The snapshot version this page reads (snapshot.schema.json). 2 added
  // roster.status (WP2); 3 added settings.scale and settings.textSize.
  var SCHEMA = 3;

  var $ = function (id) { return document.getElementById(id); };

  var snap = null;
  var openKey = null;
  var busy = {};
  var dialogReturn = null;
  var filters = { text: "", following: "all", track: "all", state: "all", commitment: "all" };
  var sort = "depth-desc";

  var roster = new UI.Roster($("roster"), { onOpen: openBond });
  var detail = new UI.Detail($("detail"), { onAction: runAction, onClose: closeDetail });

  // ---------------------------------------------------------------- layout
  // SIDE BY SIDE when the panel holds the roster at its natural width (its
  // columns sized to their content, roster.js fit) and the detail at its
  // minimum. Then the roster never stretches: the detail takes what is left, up
  // to its maximum, and past that the panel stops growing and sits centred
  // with even margins. Otherwise the roster has the panel and the detail slides
  // over it. Decided here, not by a media query, because it depends on the
  // scale, the text size and the names on the roster.
  //
  // The detail's width, in rem of text (display.js): wide enough for its
  // two-column rows at the minimum, and no wider than a comfortable line of
  // prose at the maximum.
  var DETAIL_MIN_REM = 30;
  var DETAIL_MAX_REM = 44;
  var PANEL_BORDER = 2;  // .panel's border, both sides

  function layout() {
    var D = UI.display;
    var root = document.documentElement;
    var natural = roster.fit(snap ? snap.bonds : [], snap ? snap.ladder : null);
    var min = Math.ceil(D.textPx(DETAIL_MIN_REM));
    var max = Math.ceil(D.textPx(DETAIL_MAX_REM));
    var cs = getComputedStyle($("panel"));
    var room = root.clientWidth - parseFloat(cs.left) - parseFloat(cs.right) - PANEL_BORDER;
    var narrow = room < natural + min;
    if (narrow !== root.classList.contains("is-narrow")) {
      if (narrow) root.classList.add("is-narrow");
      else root.classList.remove("is-narrow");
    }
    root.style.setProperty("--roster-w", natural + "px");
    root.style.setProperty("--detail-min", min + "px");
    root.style.setProperty("--detail-max", max + "px");
    root.style.setProperty("--panel-max", (natural + max + PANEL_BORDER) + "px");
  }

  function wide() { return !document.documentElement.classList.contains("is-narrow"); }

  // The scale or the text size moved (a snapshot, or Auto and a resize): the
  // rows, the columns and the layout follow.
  UI.display.onChange(function () {
    roster.measure();
    if (snap) render();
    else layout();
  });

  // ---------------------------------------------------------------- snapshot
  snrom.on("snapshot", function (s) {
    if (!s || s.schemaVersion !== SCHEMA) {
      $("summary").textContent = "This dashboard reads snapshot version " + SCHEMA + "; the game sent " +
        (s ? s.schemaVersion : "nothing") + ". Update the mod so both halves match.";
      return;
    }
    snap = s;
    // The game's developer setting rides in every snapshot (mode.js). When it
    // flips, what depends on it is rebuilt before anything is drawn with it.
    if (UI.mode.apply(s)) { buildStateFilter(); renderBadge(); }
    // So do the scale and the text size (display.js). A change re-measures
    // the rows and draws the page through onChange, above; otherwise it is
    // drawn here.
    if (!UI.display.apply(s)) render();
  });

  snrom.on("notice", function (n) { toast(n.text, n.level === "error" ? "error" : n.level === "warn" ? "warn" : "info"); });
  snrom.on("connection", function (c) { if (!c.ok) toast(c.message, "error"); });
  snrom.on("opened", function () { closeDialog(); roster.focus(); });

  // ---------------------------------------------------------------- roster status
  // Where the roster stands (snapshot.roster, WP2). The game shows this page
  // at once with whatever it last sent, then refreshes it; this says how that
  // is going, and "current" says nothing. The page stays usable in every
  // status: the roster, the filters and the detail all work on what is here.
  // An empty roster that is not current must never read as "nobody".
  function rosterStatus() {
    var r = snap.roster, some = snap.bonds.length > 0;
    if (r.status === "reading") {
      return some ? { line: "Refreshing from the game\u2026", warn: false } :
        { line: "Reading your roster from the game\u2026", warn: false, summary: "Reading your roster from the game\u2026",
          title: "Reading the roster", body: "The game is sending it now. It appears here as soon as it arrives." };
    }
    if (r.status === "not ready") {
      var why = r.message || "The game did not say why.";
      return { line: "Relationships isn't ready: " + why, warn: true, summary: "Relationships isn't ready.",
        title: "Relationships isn't ready", body: why };
    }
    if (r.status === "no answer") {
      return { line: "The game's scripts haven't answered yet, so this may be out of date. It updates when they do.", warn: true,
        summary: "No answer from the game yet.", title: "No answer from the game yet",
        body: "Its scripts may be running behind. Your roster appears here when they answer." };
    }
    return null;
  }

  // The empty state is set as HTML, and roster.message is the game's words:
  // escaped, so nothing it says can become markup.
  function escapeHtml(text) {
    return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function renderRosterStatus(st) {
    var line = $("roster-status");
    line.hidden = !st;
    line.textContent = st ? st.line : "";
    line.className = "roster-status" + (st && st.warn ? " is-warn" : "");
  }

  function render() {
    layout();
    var c = M.counts(snap.bonds);
    var st = rosterStatus();
    $("summary").textContent = c.total === 0 ? (st ? st.summary : "Nobody on your roster yet.") :
      c.total + " on your roster · " + c.following + " following you · " +
      c.romantic + " romantic, " + c.platonic + " platonic";
    renderRosterStatus(c.total === 0 ? null : st);
    renderCrosshair();
    renderRoster();
    renderStore();
    var b = openKey ? findBond(openKey) : null;
    if (openKey && !b) { openKey = null; }
    if (b) detail.show(b, snap, busy);
    else showSummaryOrHide();
    roster.setOpenKey(openKey);
  }

  function renderRoster() {
    var rows = M.view(snap.bonds, filters, sort);
    roster.setNow(snap.generatedAt);
    $("count").textContent = rows.length === snap.bonds.length ? rows.length + " shown" :
      rows.length + " of " + snap.bonds.length + " shown";
    var emptyHtml;
    var st = rosterStatus();
    if (!snap.bonds.length && st) {
      emptyHtml = "<h2>" + escapeHtml(st.title) + "</h2><p>" + escapeHtml(st.body) + "</p>";
    } else if (!snap.bonds.length) {
      emptyHtml = "<h2>Nobody on your roster yet</h2><p>Followers join automatically once they have travelled " +
        "with you a little while. Anyone else joins when you choose: look at them, open this dashboard, and enroll them.</p>";
    } else {
      emptyHtml = "<h2>Nobody matches</h2><p>No one on your roster fits these filters.</p>";
    }
    roster.setData(rows, snap.ladder, emptyHtml);
  }

  function renderCrosshair() {
    var t = snap.crosshairTarget;
    var box = $("crosshair");
    if (!t) { box.hidden = true; return; }
    box.hidden = false;
    var text = $("crosshair-text");
    var btn = $("crosshair-btn");
    text.innerHTML = "";
    text.appendChild(document.createTextNode("You were looking at "));
    var strong = document.createElement("strong");
    strong.textContent = t.name;
    text.appendChild(strong);
    if (t.enrolled === null) {
      // The sender cannot tell (the DLL's own snapshot, before WP2): name them
      // and offer nothing, rather than guess which button is right.
      text.appendChild(document.createTextNode("."));
      btn.hidden = true;
      return;
    }
    btn.hidden = false;
    if (t.enrolled) {
      text.appendChild(document.createTextNode(", who is on your roster."));
      btn.textContent = "Show " + t.name;
      btn.className = "btn";
      btn.removeAttribute("data-op");
      btn.onclick = function () {
        var b = findBondBySubject(t.formId);
        if (!b) return;
        clearFilters();
        openBond(b);
        roster.revealKey(M.bondKey(b));
      };
    } else {
      text.appendChild(document.createTextNode(", who is not on your roster."));
      btn.textContent = "Enroll " + t.name;
      btn.className = "btn btn-accent";
      btn.setAttribute("data-op", "EnrollActor");
      btn.onclick = function () { runAction(A.byOp("EnrollActor"), null, [], btn, t); };
    }
    btn.disabled = !!busy.EnrollActor;
  }

  function renderStore() {
    var p = snap.playthrough;
    var line = $("store");
    line.innerHTML = "";
    if (p.store === null) {
      line.appendChild(document.createTextNode("Store: not reported yet"));
      return;
    }
    line.appendChild(document.createTextNode("Store: "));
    var code = document.createElement("code");
    code.textContent = p.store;
    line.appendChild(code);
    var what = { legacy: " (this playthrough owns the main store)", own: " (this playthrough's own store)", undecided: " (not yet assigned to this playthrough)" };
    line.appendChild(document.createTextNode(what[p.storeDecision] || ""));
  }

  function findBond(key) {
    for (var i = 0; i < snap.bonds.length; i++) if (M.bondKey(snap.bonds[i]) === key) return snap.bonds[i];
    return null;
  }
  function findBondBySubject(formId) {
    for (var i = 0; i < snap.bonds.length; i++) if (snap.bonds[i].subject.formId === formId) return snap.bonds[i];
    return null;
  }

  // ---------------------------------------------------------------- detail
  function showSummaryOrHide() {
    if (wide() && snap) { $("detail").hidden = false; detail.showSummary(snap); }
    else $("detail").hidden = true;
  }

  function openBond(b) {
    openKey = M.bondKey(b);
    $("detail").hidden = false;
    detail.show(b, snap, busy);
    roster.setOpenKey(openKey);
    detail.focus();
  }

  function closeDetail() {
    if (!openKey) return false;
    openKey = null;
    roster.setOpenKey(null);
    showSummaryOrHide();
    roster.focus();
    return true;
  }

  window.addEventListener("resize", function () {
    layout();
    if (snap && !openKey) showSummaryOrHide();
  });

  // ---------------------------------------------------------------- filters
  // Player mode offers only spoken states to filter by: a filter for a hidden
  // state would reveal it by its count (mode.js). Rebuilt when the mode flips;
  // a choice that is no longer offered falls back to Any.
  function buildStateFilter() {
    var sel = $("f-state");
    var keep = sel.value;
    while (sel.options.length > 1) sel.remove(1);
    UI.mode.shownStates(L.STATE_ORDER).forEach(function (s) {
      var o = document.createElement("option");
      o.value = s; o.textContent = L.stateFilterLabel(s);
      sel.appendChild(o);
    });
    sel.value = keep;
    if (sel.value !== keep) sel.value = "all";
    filters.state = sel.value;
  }
  buildStateFilter();

  function readFilters() {
    filters.text = $("f-text").value;
    filters.following = $("f-following").value;
    filters.track = $("f-track").value;
    filters.state = $("f-state").value;
    filters.commitment = $("f-commitment").value;
    sort = $("f-sort").value;
    if (snap) renderRoster();
  }
  function clearFilters() {
    $("f-text").value = ""; $("f-following").value = "all"; $("f-track").value = "all"; $("f-state").value = "all";
    $("f-commitment").value = "all";
    readFilters();
  }
  ["f-following", "f-track", "f-state", "f-commitment", "f-sort"].forEach(function (id) { $(id).addEventListener("change", readFilters); });
  $("f-text").addEventListener("input", readFilters);
  $("f-text").addEventListener("keydown", function (e) {
    if (e.key === "ArrowDown" || e.key === "Enter") { e.preventDefault(); roster.focus(); }
  });

  // ---------------------------------------------------------------- actions
  function runAction(a, b, args, btn, crosshair) {
    if (!a || busy[a.op]) return;
    var who = b ? b.subject.name : crosshair ? crosshair.name : null;
    var go = function () { send(a, b ? b.subject.formId : crosshair ? crosshair.formId : null, args, who); };
    if (a.confirm) confirmThen(a, who, go, btn);
    else go();
  }

  function send(a, subject, args, who) {
    busy[a.op] = true;
    if (a.op === "EnrollActor") $("crosshair-btn").disabled = true;
    refreshBusy();
    snrom.request("action", { op: a.op, subject: subject, args: args }).then(function (r) {
      delete busy[a.op];
      refreshBusy();
      if (a.op === "EnrollActor" && snap) renderCrosshair();
      toast(r.message || (r.ok ? a.label + (who ? ": " + who : "") + " sent." : a.label + " failed."), r.ok ? "info" : "error");
    });
  }

  // In place, not by re-rendering: rebuilding the detail would take keyboard
  // focus off the button the player just pressed.
  function refreshBusy() {
    var buttons = document.querySelectorAll("button[data-op]");
    for (var i = 0; i < buttons.length; i++) {
      var on = !!busy[buttons[i].getAttribute("data-op")];
      buttons[i].className = buttons[i].className.replace(/ ?is-busy/g, "") + (on ? " is-busy" : "");
      if (on) buttons[i].setAttribute("aria-busy", "true"); else buttons[i].removeAttribute("aria-busy");
    }
  }

  // ---------------------------------------------------------------- dialogs
  function openDialog(title, bodyNodes, buttons, returnFocus) {
    dialogReturn = returnFocus || document.activeElement;
    $("dialog-title").textContent = title;
    var body = $("dialog-body");
    body.innerHTML = "";
    bodyNodes.forEach(function (n) { body.appendChild(n); });
    var bar = $("dialog-buttons");
    bar.innerHTML = "";
    buttons.forEach(function (bt) {
      var e = document.createElement("button");
      e.type = "button";
      e.className = "btn " + (bt.cls || "");
      e.textContent = bt.label;
      if (bt.id) e.id = bt.id;
      e.addEventListener("click", bt.run);
      bar.appendChild(e);
    });
    $("scrim").hidden = false;
    $("dialog").hidden = false;
    var first = $("dialog").querySelector("button");
    if (first) first.focus();
  }

  function closeDialog() {
    if ($("dialog").hidden) return false;
    $("dialog").hidden = true;
    $("scrim").hidden = true;
    var back = dialogReturn;
    dialogReturn = null;
    if (back && document.body.contains(back) && !back.disabled) back.focus();
    else if (openKey) detail.focus();
    else roster.focus();
    return true;
  }

  function para(text, cls) { var p = document.createElement("p"); p.textContent = text; if (cls) p.className = cls; return p; }

  function confirmThen(a, who, go, btn) {
    // Cancel is first, so Enter on a freshly opened dialog does nothing harmful.
    openDialog(a.label + (who ? ": " + who : "") + "?", [para(a.confirm), para("→ " + a.calls, "act-calls")], [
      { label: "Cancel", id: "dialog-cancel", run: closeDialog },
      { label: a.label, id: "dialog-confirm", cls: "btn-danger", run: function () { closeDialog(); go(); } }
    ], btn);
  }

  // The playthrough-wide actions a dialog offers, one block each. The button
  // that opened the dialog gets the focus back after an action.
  function actionList(actions, opener) {
    var list = document.createElement("div");
    actions.forEach(function (a) {
      var wrap = document.createElement("div");
      wrap.className = "act";
      var row = document.createElement("div");
      row.className = "act-row";
      row.appendChild(para(a.help, "act-help"));
      var b = document.createElement("button");
      b.type = "button";
      b.className = "btn";
      b.textContent = a.label;
      b.setAttribute("data-op", a.op);
      var current = (a.op === "StartFreshStore" && snap.playthrough.storeDecision === "own") ||
                    (a.op === "AdoptLegacyStore" && snap.playthrough.storeDecision === "legacy");
      b.disabled = current;
      b.addEventListener("click", function () {
        closeDialog();
        runAction(a, null, [], opener);
      });
      row.appendChild(b);
      wrap.appendChild(row);
      wrap.appendChild(para("→ " + a.calls, "act-calls"));
      if (current) wrap.appendChild(para("Already the case for this playthrough.", "act-needs"));
      list.appendChild(wrap);
    });
    return list;
  }

  // The store repairs, where players find them. Never a developer tool.
  $("repairs-btn").addEventListener("click", function () {
    if (!snap) return;
    openDialog("Playthrough repairs", [
      para("For the playthrough as a whole, not one person. The two store repairs are safe to undo: neither deletes anything."),
      actionList(A.available("playthrough"), $("repairs-btn"))
    ], [{ label: "Close", id: "dialog-cancel", run: closeDialog }], $("repairs-btn"));
  });

  // The developer tools that are not about one person. The button exists only
  // in the developer view (renderBadge); those about one person are in their
  // detail, under Developer tools.
  $("devtools-btn").addEventListener("click", function () {
    if (!snap || !UI.mode.developer) return;
    openDialog("Developer tools", [
      para("Shown because the developer view is on. For looking under the hood; a player never needs them. The tools for one person are in their detail, under Developer tools."),
      actionList(A.developerTools("playthrough"), $("devtools-btn"))
    ], [{ label: "Close", id: "dialog-cancel", run: closeDialog }], $("devtools-btn"));
  });

  // Tab stays inside an open dialog.
  $("dialog").addEventListener("keydown", function (e) {
    if (e.key !== "Tab") return;
    var f = Array.prototype.filter.call($("dialog").querySelectorAll("button, select, input"), function (x) { return !x.disabled; });
    if (!f.length) return;
    var i = f.indexOf(document.activeElement);
    if (e.shiftKey && i <= 0) { e.preventDefault(); f[f.length - 1].focus(); }
    else if (!e.shiftKey && i === f.length - 1) { e.preventDefault(); f[0].focus(); }
  });

  // ---------------------------------------------------------------- toasts
  function toast(text, level) {
    if (!text) return;
    var t = document.createElement("div");
    t.className = "toast" + (level === "error" ? " is-error" : level === "warn" ? " is-warn" : "");
    t.textContent = text;
    var box = $("toasts");
    box.appendChild(t);
    while (box.children.length > 4) box.removeChild(box.firstChild);
    setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t); }, 6500);
  }

  // ---------------------------------------------------------------- escape
  // Innermost first: a dialog, then the open bond, then the dashboard itself
  // through the one registered close function (Meridian's guide: resolve the
  // page's own layers before calling it).
  document.addEventListener("keydown", function (e) {
    if (e.key !== "Escape" && e.key !== "Esc") return;
    e.preventDefault();
    if (closeDialog()) return;
    if (closeDetail()) return;
    snrom.request("close", { reason: "escape" });
  });
  $("close-btn").addEventListener("click", function () { snrom.request("close", { reason: "button" }); });

  // THE HOTKEY CLOSES IT TOO, where the DLL cannot hear it: Magelight UI mutes
  // the game's keyboard while the dashboard has input, so the DLL sends the
  // key as settings.closeKey there, and nowhere else (snapshot.schema.json).
  // Not while typing in a field, unless a modifier is part of the key.
  document.addEventListener("keydown", function (e) {
    var k = snap && snap.settings && snap.settings.closeKey;
    if (!k || e.repeat || e.keyCode !== k.key) return;
    if (k.modifier === "shift" ? !e.shiftKey : k.modifier === "ctrl" ? !e.ctrlKey : k.modifier === "alt" ? !e.altKey :
        (e.shiftKey || e.ctrlKey || e.altKey)) return;
    var t = e.target;
    if (!k.modifier && t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA")) return;
    e.preventDefault();
    if (UI.picker) UI.picker.close();
    snrom.request("close", { reason: "hotkey" });
  });

  // ---------------------------------------------------------------- start
  // Developer mode says so on screen, so a screenshot of it is never mistaken
  // for what a player sees.
  function renderBadge() {
    $("devtools-btn").hidden = !UI.mode.developer;
    if (!UI.mode.developer && !$("dialog").hidden && $("dialog-title").textContent === "Developer tools") closeDialog();
    var badge = $("dev-badge");
    if (UI.mode.developer && !badge) {
      badge = document.createElement("span");
      badge.className = "dev-badge";
      badge.id = "dev-badge";
      badge.textContent = "Developer view: shows what characters have not said";
      $("panel").querySelector(".head-title").appendChild(badge);
    } else if (!UI.mode.developer && badge) {
      badge.parentNode.removeChild(badge);
    }
  }
  renderBadge();
  layout();
  $("summary").textContent = "Waiting for the game…";
  snrom.request("snapshot", {}).then(function (r) {
    if (!r.ok && r.message) toast(r.message, "error");
  });
  roster.focus();
})(window.SNRomUI = window.SNRomUI || {});
