/* detail.js - one bond in full, or the roster at a glance when none is open.

   The roster row leads with points and traits (the author's decision,
   2026-09-28: "a wall of prose will be hard to digest"); this is where the
   prose lives, with stance, spark, banked points and when they joined. */

(function (UI) {
  "use strict";

  var L = UI.labels;
  var M = UI.model;
  var A = UI.actions;

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = text;
    return e;
  }

  function section(title) {
    var s = el("section", "sec");
    s.appendChild(el("h3", null, title));
    return s;
  }

  function kv(list, k, v) {
    var row = el("div", "kv");
    row.appendChild(el("dt", null, k));
    var dd = el("dd");
    if (typeof v === "string") dd.textContent = v; else dd.appendChild(v);
    row.appendChild(dd);
    list.appendChild(row);
    return row;
  }

  function chip(cls, text, title) {
    var c = el("span", "chip " + cls, text);
    if (title) c.title = title;
    return c;
  }

  function Detail(root, opts) {
    this.root = root;
    this.onAction = opts.onAction;
    this.onClose = opts.onClose;
    this.bond = null;
  }

  // ---------------------------------------------------------------- summary
  Detail.prototype.showSummary = function (snap) {
    this.bond = null;
    this.root.innerHTML = "";
    this.root.className = "detail is-summary";
    this.root.setAttribute("aria-label", "Roster at a glance");
    var head = el("div", "detail-head");
    var h = el("div");
    h.appendChild(el("h2", null, "At a glance"));
    h.appendChild(el("p", "detail-meta", "Select someone to see where they stand and why."));
    head.appendChild(h);
    this.root.appendChild(head);
    var scroll = el("div", "detail-scroll");
    var c = M.counts(snap.bonds);

    var tracks = section("Tracks");
    [["platonic", c.platonic], ["romantic", c.romantic]].forEach(function (t) {
      var r = el("div", "legend-row");
      r.appendChild(el("span", "n", String(t[1])));
      r.appendChild(chip("t-" + t[0], L.TRACKS[t[0]].label));
      r.appendChild(el("p", null, t[0] === "romantic" ? "Mutual: they asked, and you said yes." : "Everyone else, however deep."));
      tracks.appendChild(r);
    });
    scroll.appendChild(tracks);

    var states = section("States");
    var shownStates = UI.mode.shownStates(L.STATE_ORDER);
    var unspoken = c.total;
    shownStates.forEach(function (s) {
      unspoken -= c.states[s];
      var r = el("div", "legend-row");
      r.appendChild(el("span", "n", String(c.states[s])));
      r.appendChild(chip("s-" + s, L.stateFilterLabel(s)));
      r.appendChild(el("p", null, L.STATES[s].blurb));
      states.appendChild(r);
    });
    // Player mode: everyone without a spoken state, as ONE number. Splitting it
    // would tell the player how many have sparked without saying so.
    if (!UI.mode.developer) {
      var r = el("div", "legend-row");
      r.appendChild(el("span", "n", String(unspoken)));
      r.appendChild(el("p", null, "Nothing said between you either way."));
      states.appendChild(r);
    }
    scroll.appendChild(states);
    this.root.appendChild(scroll);
  };

  // ---------------------------------------------------------------- one bond
  Detail.prototype.show = function (b, snap, busy) {
    var self = this;
    var same = this.bond && M.bondKey(this.bond) === M.bondKey(b);
    var scrollTop = same && this.scroller ? this.scroller.scrollTop : 0;
    // A fresh snapshot follows every action and rebuilds this panel. Put focus
    // back where it was, or a keyboard player is thrown to the top of the page.
    var refocus = null;
    var ae = document.activeElement;
    if (same && ae && this.root.contains(ae)) {
      refocus = ae.id ? "#" + ae.id : ae.getAttribute("data-op") ? "button[data-op='" + ae.getAttribute("data-op") + "']" : null;
    }
    this.bond = b;
    this.root.innerHTML = "";
    this.root.className = "detail";
    this.root.setAttribute("aria-label", "Details: " + b.subject.name);

    // Head
    var head = el("div", "detail-head");
    var h = el("div");
    h.appendChild(el("h2", null, b.subject.name));
    var meta = el("p", "detail-meta");
    var bits = [];
    if (b.following) bits.push("Following you");
    bits.push(b.nearby ? "Near you" : "Elsewhere");
    meta.appendChild(document.createTextNode(bits.join(" · ") + " · "));
    meta.appendChild(el("code", null, L.hexId(b.subject.formId)));
    h.appendChild(meta);
    head.appendChild(h);
    var close = el("button", "icon-btn", "×");
    close.type = "button";
    close.id = "detail-close";
    close.title = "Back to the roster (Esc)";
    close.setAttribute("aria-label", "Close details");
    close.addEventListener("click", function () { self.onClose(); });
    head.appendChild(close);
    this.root.appendChild(head);

    var scroll = el("div", "detail-scroll");
    this.scroller = scroll;

    // Depth: the at-a-glance number, big.
    var depth = section("Depth");
    var big = el("div", "depth-big");
    big.appendChild(el("span", "tier t-" + b.track, L.tierName(b.track, b.depth.tier)));
    big.appendChild(el("span", "pts", L.number(b.depth.points) + " points"));
    depth.appendChild(big);
    var prog = M.progress(b, snap.ladder);
    var bar = el("div", "bar");
    var fill = el("div", "fill t-" + b.track + (prog.held ? " is-held" : ""));
    fill.style.width = Math.round(prog.pct * 100) + "%";
    bar.appendChild(fill);
    depth.appendChild(bar);
    depth.appendChild(el("p", "depth-note", prog.note));
    if (UI.mode.developer && b.depth.banked > 0) {
      depth.appendChild(el("p", "depth-note", L.number(b.depth.banked) +
        " more points are held back until you answer their question. A yes releases all of them."));
    }
    // WHAT MOVED IT: the last several changes, newest first, as the roster's
    // line shows the newest (labels.js, CHANGE, for what a player sees).
    var changes = L.visibleChanges(b.history, UI.mode.developer);
    if (changes.length) {
      depth.appendChild(el("h4", "sub-head", "What moved it"));
      var list = el("ol", "change-list");
      changes.forEach(function (e) {
        var li = el("li", "change");
        li.appendChild(el("span", "delta " + L.changeClass(e), L.changeAmount(e)));
        var body = el("div", "change-body");
        var when = L.changeKind(e.kind).label + " · " + L.daysAgo(e.day, snap.generatedAt);
        body.appendChild(el("span", "when", when));
        var text = L.changeText(e, UI.mode.developer);
        if (text !== L.changeKind(e.kind).label) body.appendChild(el("p", "why", text));
        li.appendChild(body);
        list.appendChild(li);
      });
      depth.appendChild(list);
    } else {
      depth.appendChild(el("p", "depth-note", "No changes recorded yet."));
    }
    scroll.appendChild(depth);

    // Kind: track and state, separately (design 7.1). In player mode only a
    // spoken state is drawn, and the stance, the owed question and the spark
    // are not drawn at all: each is something the character has not said
    // (mode.js). A declined or courting chip already says what the player
    // answered.
    var kind = section("The bond");
    var dl = el("dl");
    var trackLine = el("span");
    trackLine.appendChild(chip("t-" + b.track, L.TRACKS[b.track].label));
    kv(dl, "Track", trackLine);
    var shown = UI.mode.shownState(b);
    if (shown) {
      var stateLine = el("span");
      stateLine.appendChild(chip("s-" + shown, L.stateLabel(shown, b)));
      if (shown === "foreclosed") stateLine.appendChild(document.createTextNode("  " + L.FORECLOSURE[b.foreclosure]));
      kv(dl, "State", stateLine);
    }
    kind.appendChild(dl);
    if (shown) kind.appendChild(el("p", "blurb", L.stateBlurb(shown, b)));
    var dl2 = el("dl");
    if (b.state !== "foreclosed") {
      if (UI.mode.developer) {
        kv(dl2, "Your answer", L.STANCE[b.stance]);
        if (b.askPending) kv(dl2, "Question", "Owed. They will raise it themselves, in person.");
        var spark = b.spark.sparked
          ? "Sparked" + (b.spark.sparkedAt !== null ? " on " + L.gameDay(b.spark.sparkedAt) : "")
          : (b.spark.decided ? "Judged: nothing romantic" : "Not judged yet");
        kv(dl2, "Spark", spark);
      }
      if (b.commitment !== "none") kv(dl2, "Commitment", L.COMMITMENT[b.commitment]);
    }
    kind.appendChild(dl2);
    scroll.appendChild(kind);

    // Character: the traits in words, then the prose.
    var ch = section("Who they are");
    var t = b.traits;
    var traits = el("div", "traits");
    function box(k, v) {
      var d = el("div", "trait-box");
      d.appendChild(el("span", "k", k));
      d.appendChild(el("span", "v", v));
      traits.appendChild(d);
    }
    if (b.state !== "foreclosed") {
      box("Intimacy", L.INTIMACY[t.intimacy]);
      box("Ardor", L.ARDOR[t.ardor] + " (" + t.ardor + " of 4)");
      box("Exclusivity", L.exclusivityWord(t.exclusivity) + " (" + t.exclusivity + " of 100)");
      box("Drawn to", L.ORIENTATION[t.orientation] + (t.orientationBasis === "known" ? "" : " (" + t.orientationBasis + ")"));
    } else {
      box("Ardor", L.ARDOR[t.ardor] + " (" + t.ardor + " of 4)");
    }
    ch.appendChild(traits);
    if (!t.authored) ch.appendChild(el("p", "trait-note", "Not authored yet. These are defaults until their character is written."));
    // "Calls you" is prose.address (decided 2026-09-30): the label changes,
    // the data does not. Its hint says what the line is, since unlike Why and
    // Limit it is not authored but kept: the talk assessment owns it, and
    // authoring takes one only if a model volunteers it (ApplyProse).
    [["Why", b.prose.why], ["Limit", b.prose.limit],
     ["Calls you", b.prose.address, "What they call you, saved so they don't forget it, and changed only when a conversation changes it."]]
      .forEach(function (pr) {
        var d = el("div", "prose");
        d.appendChild(el("span", "k", pr[0]));
        if (pr[2]) d.appendChild(el("span", "prose-hint", pr[2]));
        d.appendChild(pr[1] ? el("p", null, pr[1]) : el("p", "is-missing", "Not written yet."));
        ch.appendChild(d);
      });
    scroll.appendChild(ch);

    // On the roster
    var ros = section("On your roster");
    var dl3 = el("dl");
    var joined = b.enrollment.joinedAt === null ? "Before join dates were kept" :
      L.gameDay(b.enrollment.joinedAt) + " (" + L.daysAgo(b.enrollment.joinedAt, snap.generatedAt) + ")";
    kv(dl3, "Joined", joined);
    kv(dl3, "Enrolled", L.ENROLLED_BY[b.enrollment.by]);
    if (!b.following) {
      kv(dl3, "Last following", b.lastFollowingAt === null ? "Never" :
        L.gameDay(b.lastFollowingAt) + " (" + L.daysAgo(b.lastFollowingAt, snap.generatedAt) + ")");
    }
    kv(dl3, "Starting standing", b.seeded ? "Read from the record" : "Not read yet");
    ros.appendChild(dl3);
    scroll.appendChild(ros);

    // Actions
    var acts = section("Repairs");
    A.available("bond").forEach(function (a) { acts.appendChild(self.actionBlock(a, b, busy)); });
    scroll.appendChild(acts);

    // Developer tools, apart from the repairs and labelled as what they are.
    // Only in the developer view; the list is empty otherwise.
    var tools = A.developerTools("bond");
    if (tools.length) {
      var dev = section("Developer tools");
      dev.className += " sec-dev";
      dev.appendChild(el("p", "act-needs", "Shown because the developer view is on. For looking under the hood; a player never needs them."));
      tools.forEach(function (a) { dev.appendChild(self.actionBlock(a, b, busy)); });
      scroll.appendChild(dev);
    }

    this.root.appendChild(scroll);
    scroll.scrollTop = scrollTop;
    if (refocus) {
      var target = this.root.querySelector(refocus);
      if (target && !target.disabled) target.focus();
    }
  };

  Detail.prototype.actionBlock = function (a, b, busy) {
    var self = this;
    var wrap = el("div", "act");
    wrap.setAttribute("data-op", a.op);
    var row = el("div", "act-row");
    // Why the button cannot be pressed, if it cannot. Papyrus refuses with a
    // reason as well, in case the game has moved on since the snapshot.
    var blocked = a.needsFollowing && !b.following ? b.subject.name + " is not travelling with you. " + a.needs :
      a.needsNearby && !b.nearby ? b.subject.name + " is not near you. " + a.needs : null;
    var btn = el("button", "btn" + (a.confirm ? " btn-danger" : ""), a.label);
    btn.type = "button";
    btn.setAttribute("data-op", a.op);
    if (busy && busy[a.op]) { btn.className += " is-busy"; btn.setAttribute("aria-busy", "true"); }
    btn.disabled = !!blocked;

    if (a.form === "traitField") {
      var form = el("div", "act-form");
      var field = el("select");
      field.id = "trait-field";
      field.setAttribute("aria-label", "Trait to correct");
      [["intimacy", "Intimacy"], ["ardor", "Ardor"], ["exclusivity", "Exclusivity"]].forEach(function (f) {
        var o = el("option", null, f[1]); o.value = f[0]; field.appendChild(o);
      });
      var value = el("span");
      var readValue = null;
      function renderValue() {
        value.innerHTML = "";
        var f = field.value;
        if (f === "exclusivity") {
          var inp = el("input");
          inp.type = "number"; inp.min = "0"; inp.max = "100"; inp.step = "5";
          inp.value = String(b.traits.exclusivity);
          inp.setAttribute("aria-label", "Exclusivity, 0 to 100");
          value.appendChild(inp);
          readValue = function () { return Math.max(0, Math.min(100, parseInt(inp.value, 10) || 0)); };
        } else {
          var sel = el("select");
          sel.setAttribute("aria-label", f === "ardor" ? "Ardor" : "Intimacy");
          var words = f === "ardor" ? L.ARDOR : ["Casual", "Romantic", "Guarded", "Never"];
          var cur = f === "ardor" ? b.traits.ardor : ["casual", "romantic", "guarded", "never"].indexOf(b.traits.intimacy);
          words.forEach(function (w, i) { var o = el("option", null, w); o.value = String(i); if (i === cur) o.selected = true; sel.appendChild(o); });
          value.appendChild(sel);
          readValue = function () { return parseInt(sel.value, 10); };
        }
      }
      if (self.traitField) field.value = self.traitField;
      field.addEventListener("change", function () { self.traitField = field.value; renderValue(); });
      renderValue();
      form.appendChild(field);
      form.appendChild(value);
      btn.textContent = "Write";
      btn.addEventListener("click", function () {
        self.onAction(a, b, [A.FIELD[field.value], readValue()], btn);
      });
      row.appendChild(el("strong", null, a.label));
      wrap.appendChild(row);
      form.appendChild(btn);
      wrap.appendChild(form);
    } else {
      btn.addEventListener("click", function () { self.onAction(a, b, [], btn); });
      row.appendChild(el("span", "act-help", a.help));
      row.appendChild(btn);
      wrap.appendChild(row);
    }
    if (a.form === "traitField") wrap.appendChild(el("p", "act-help", a.help));
    if (blocked) wrap.appendChild(el("p", "act-needs is-blocking", blocked));
    else if (a.needs) wrap.appendChild(el("p", "act-needs", a.needs));
    wrap.appendChild(el("p", "act-calls", "→ " + a.calls));
    return wrap;
  };

  Detail.prototype.focus = function () {
    var c = document.getElementById("detail-close");
    if (c) c.focus();
  };

  UI.Detail = Detail;
})(window.SNRomUI = window.SNRomUI || {});
