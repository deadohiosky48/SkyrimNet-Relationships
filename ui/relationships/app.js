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
  var SCHEMA = 4;

  var $ = function (id) { return document.getElementById(id); };

  var snap = null;
  var openKey = null;
  var busy = {};
  var dialogReturn = null;
  var filters = { text: "", following: "all", track: "all", state: "all", commitment: "all", standing: "all" };
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

  var t = UI.t;

  // THE PAGE'S FIXED TEXT in the player's language (2.3, WP-L). index.html
  // marks it: data-t="key" for an element's text, data-t-title,
  // data-t-placeholder and data-t-aria-label for those attributes. The
  // English written there is kept (data-en...) as the fallback, so switching
  // back to English restores it.
  // The page's language and direction (2.3): Arabic and Hebrew read right to
  // left, and the layout is flex throughout, so dir="rtl" mirrors it.
  function applyLanguage(code) {
    var lang = typeof code === "string" && code ? code : "en";
    var root = document.documentElement;
    if (root.getAttribute("lang") !== lang) root.setAttribute("lang", lang);
    var dir = lang === "ar" || lang === "he" ? "rtl" : "ltr";
    if (root.getAttribute("dir") !== dir) root.setAttribute("dir", dir);
  }

  function applyStaticText() {
    function each(sel, fn) { Array.prototype.forEach.call(document.querySelectorAll(sel), fn); }
    each("[data-t]", function (e) {
      if (!e.hasAttribute("data-en")) e.setAttribute("data-en", e.textContent);
      e.textContent = t(e.getAttribute("data-t"), e.getAttribute("data-en"));
    });
    ["title", "placeholder", "aria-label"].forEach(function (attr) {
      each("[data-t-" + attr + "]", function (e) {
        if (!e.hasAttribute("data-en-" + attr)) e.setAttribute("data-en-" + attr, e.getAttribute(attr) || "");
        e.setAttribute(attr, t(e.getAttribute("data-t-" + attr), e.getAttribute("data-en-" + attr)));
      });
    });
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
      $("summary").textContent = t("app.schemaMismatch", "This dashboard reads snapshot version {0}; the game sent {1}. Update the mod so both halves match.",
        SCHEMA, s ? s.schemaVersion : t("app.schemaNothing", "nothing"));
      return;
    }
    snap = s;
    // The player's language rides in every snapshot too (2.3, WP-L): when its
    // table changed, the words drawn once - the page's fixed text, the state
    // filter, the roster's header, the badge - are drawn again.
    applyLanguage(s.settings && s.settings.language);
    if (L.setStrings(s.strings)) { A.relabel(); applyStaticText(); buildStateFilter(); roster.relabel(); renderBadge(true); }
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
      var reading = t("status.reading", "Reading your roster from the game\u2026");
      return some ? { line: t("status.refreshing", "Refreshing from the game\u2026"), warn: false } :
        { line: reading, warn: false, summary: reading,
          title: t("status.reading.title", "Reading the roster"), body: t("status.reading.body", "The game is sending it now. It appears here as soon as it arrives.") };
    }
    if (r.status === "not ready") {
      var why = r.message || t("status.notReady.noReason", "The game did not say why.");
      return { line: t("status.notReady.line", "Relationships isn't ready: {0}", why), warn: true, summary: t("status.notReady.summary", "Relationships isn't ready."),
        title: t("status.notReady.title", "Relationships isn't ready"), body: why };
    }
    if (r.status === "no answer") {
      return { line: t("status.noAnswer.line", "The game's scripts haven't answered yet, so this may be out of date. It updates when they do."), warn: true,
        summary: t("status.noAnswer.summary", "No answer from the game yet."), title: t("status.noAnswer.title", "No answer from the game yet"),
        body: t("status.noAnswer.body", "Its scripts may be running behind. Your roster appears here when they answer.") };
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
    $("summary").textContent = c.total === 0 ? (st ? st.summary : t("app.nobody", "Nobody on your roster yet.")) :
      t("app.summary.roster", "{0} on your roster", c.total) + " · " + t("app.summary.following", "{0} following you", c.following) + " · " +
      t("app.summary.tracks", "{0} romantic, {1} platonic", c.romantic, c.platonic);
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
    $("count").textContent = rows.length === snap.bonds.length ? t("app.count.all", "{0} shown", rows.length) :
      t("app.count.some", "{0} of {1} shown", rows.length, snap.bonds.length);
    var emptyHtml;
    var st = rosterStatus();
    if (!snap.bonds.length && st) {
      emptyHtml = "<h2>" + escapeHtml(st.title) + "</h2><p>" + escapeHtml(st.body) + "</p>";
    } else if (!snap.bonds.length) {
      emptyHtml = "<h2>" + escapeHtml(t("app.empty.title", "Nobody on your roster yet")) + "</h2><p>" +
        escapeHtml(t("app.empty.body", "Followers join automatically once they have travelled with you a little while. Anyone else joins when you choose: look at them, open this dashboard, and enroll them.")) + "</p>";
    } else {
      emptyHtml = "<h2>" + escapeHtml(t("app.noMatch.title", "Nobody matches")) + "</h2><p>" + escapeHtml(t("app.noMatch.body", "No one on your roster fits these filters.")) + "</p>";
    }
    roster.setData(rows, snap.ladder, emptyHtml);
  }

  function renderCrosshair() {
    var ct = snap.crosshairTarget;
    var box = $("crosshair");
    if (!ct) { box.hidden = true; return; }
    box.hidden = false;
    var text = $("crosshair-text");
    var btn = $("crosshair-btn");
    text.innerHTML = "";
    // The sentence is translated whole and the name set in bold where {0}
    // stands, since another language may put the name elsewhere.
    var sentence = ct.enrolled === null ? t("crosshair.looking", "You were looking at {0}.") :
      ct.enrolled ? t("crosshair.onRoster", "You were looking at {0}, who is on your roster.") :
      t("crosshair.notOnRoster", "You were looking at {0}, who is not on your roster.");
    var parts = sentence.split("{0}");
    text.appendChild(document.createTextNode(parts[0]));
    var strong = document.createElement("strong");
    strong.textContent = ct.name;
    text.appendChild(strong);
    text.appendChild(document.createTextNode(parts.slice(1).join("{0}")));
    if (ct.enrolled === null) {
      // The sender cannot tell (the DLL's own snapshot, before WP2): name them
      // and offer nothing, rather than guess which button is right.
      btn.hidden = true;
      return;
    }
    btn.hidden = false;
    if (ct.enrolled) {
      btn.textContent = t("crosshair.show", "Show {0}", ct.name);
      btn.className = "btn";
      btn.removeAttribute("data-op");
      btn.onclick = function () {
        var b = findBondBySubject(ct.formId);
        if (!b) return;
        clearFilters();
        openBond(b);
        roster.revealKey(M.bondKey(b));
      };
    } else {
      btn.textContent = t("crosshair.enroll", "Enroll {0}", ct.name);
      btn.className = "btn btn-accent";
      btn.setAttribute("data-op", "EnrollActor");
      btn.onclick = function () { runAction(A.byOp("EnrollActor"), null, [], btn, ct); };
    }
    btn.disabled = !!busy.EnrollActor;
  }

  function renderStore() {
    var p = snap.playthrough;
    var line = $("store");
    line.innerHTML = "";
    if (p.store === null) {
      line.appendChild(document.createTextNode(t("store.notReported", "Store: not reported yet")));
      return;
    }
    line.appendChild(document.createTextNode(t("store.label", "Store:") + " "));
    var code = document.createElement("code");
    code.textContent = p.store;
    line.appendChild(code);
    var what = { legacy: t("store.legacy", "this playthrough owns the main store"), own: t("store.own", "this playthrough's own store"),
      undecided: t("store.undecided", "not yet assigned to this playthrough") };
    line.appendChild(document.createTextNode(what[p.storeDecision] ? " (" + what[p.storeDecision] + ")" : ""));
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
    filters.standing = $("f-standing").value;
    sort = $("f-sort").value;
    if (snap) renderRoster();
  }
  function clearFilters() {
    $("f-text").value = ""; $("f-following").value = "all"; $("f-track").value = "all"; $("f-state").value = "all";
    $("f-commitment").value = "all"; $("f-standing").value = "all";
    readFilters();
  }
  ["f-following", "f-track", "f-state", "f-commitment", "f-standing", "f-sort"].forEach(function (id) { $(id).addEventListener("change", readFilters); });
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
    // An op that takes text (2.4: SetPlayerHistory) passes { text: ... }.
    var payload = args && !Array.isArray(args) && typeof args.text === "string" ?
      { op: a.op, subject: subject, args: [], text: args.text } : { op: a.op, subject: subject, args: args };
    snrom.request("action", payload).then(function (r) {
      delete busy[a.op];
      refreshBusy();
      if (a.op === "EnrollActor" && snap) renderCrosshair();
      toast(r.message || (r.ok ? t("act.sent", "{0} sent.", a.label + (who ? ": " + who : "")) : t("act.failed", "{0} failed.", a.label)), r.ok ? "info" : "error");
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
    $("dialog").removeAttribute("data-kind");
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
      { label: t("dialog.cancel", "Cancel"), id: "dialog-cancel", run: closeDialog },
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
      if (current) wrap.appendChild(para(t("act.alreadyTheCase", "Already the case for this playthrough."), "act-needs"));
      list.appendChild(wrap);
    });
    return list;
  }

  // The store repairs, where players find them. Never a developer tool.
  $("repairs-btn").addEventListener("click", function () {
    if (!snap) return;
    openDialog(t("repairs.title", "Playthrough repairs"), [
      para(t("repairs.intro", "For the playthrough as a whole, not one person. The two store repairs are safe to undo: neither deletes anything.")),
      actionList(A.available("playthrough"), $("repairs-btn"))
    ], [{ label: t("dialog.close", "Close"), id: "dialog-cancel", run: closeDialog }], $("repairs-btn"));
  });

  // The developer tools that are not about one person. The button exists only
  // in the developer view (renderBadge); those about one person are in their
  // detail, under Developer tools.
  $("devtools-btn").addEventListener("click", function () {
    if (!snap || !UI.mode.developer) return;
    openDialog(t("devtools.title", "Developer tools"), [
      para(t("devtools.intro", "Shown because the developer view is on. For looking under the hood; a player never needs them. The tools for one person are in their detail, under Developer tools.")),
      actionList(A.developerTools("playthrough"), $("devtools-btn"))
    ], [{ label: t("dialog.close", "Close"), id: "dialog-cancel", run: closeDialog }], $("devtools-btn"));
    $("dialog").setAttribute("data-kind", "devtools");
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
  function renderBadge(relabel) {
    $("devtools-btn").hidden = !UI.mode.developer;
    if (!UI.mode.developer && !$("dialog").hidden && $("dialog").getAttribute("data-kind") === "devtools") closeDialog();
    var badge = $("dev-badge");
    if (relabel && badge) badge.textContent = t("app.devBadge", "Developer view: shows what characters have not said");
    if (UI.mode.developer && !badge) {
      badge = document.createElement("span");
      badge.className = "dev-badge";
      badge.id = "dev-badge";
      badge.textContent = t("app.devBadge", "Developer view: shows what characters have not said");
      $("panel").querySelector(".head-title").appendChild(badge);
    } else if (!UI.mode.developer && badge) {
      badge.parentNode.removeChild(badge);
    }
  }
  renderBadge();
  layout();
  $("summary").textContent = t("app.waiting", "Waiting for the game…");
  snrom.request("snapshot", {}).then(function (r) {
    if (!r.ok && r.message) toast(r.message, "error");
  });
  roster.focus();
})(window.SNRomUI = window.SNRomUI || {});
