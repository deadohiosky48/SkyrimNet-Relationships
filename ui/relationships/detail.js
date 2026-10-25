/* detail.js - one bond in full, or the roster at a glance when none is open.

   The roster row leads with points and traits (the author's decision,
   2026-09-28: "a wall of prose will be hard to digest"); this is where the
   prose lives, with stance, spark, banked points and when they joined. */

(function (UI) {
  "use strict";

  var L = UI.labels;
  var M = UI.model;
  var A = UI.actions;
  var t = UI.t;

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

  // "A", "A and B", "A, B and C".
  function names(list) {
    if (list.length < 2) return list.join("");
    return t("list.and", "{0} and {1}", list.slice(0, -1).join(", "), list[list.length - 1]);
  }

  // MARRIED, ENGAGED OR SEPARATED in Relationships' own record (2.5).
  function wedded(b) {
    var m = b.marriage;
    return !!m && (m.state === "engaged" || m.state === "married" || m.state === "separated");
  }

  // A PARTNER: wedded, or courting at Lover or above.
  function partner(b) {
    return wedded(b) || (b.state === "courting" && b.depth.tier >= 4);
  }

  // THE COMMITMENT LINE (2.5, M8b; the author, 2026-10-17): for everyone
  // the Marriage section does not cover, what the bond already records -
  // courting, a partner worded by their sex, and more than two together,
  // named. Living together waits for the household phase. Null for nothing.
  function commitmentWords(b, snap) {
    if (b.commitment === "candidate") return L.COMMITMENT.candidate;
    if (b.state !== "courting") return b.commitment !== "none" ? L.COMMITMENT[b.commitment] : null;
    if (b.depth.tier < 4) return t("commitment.courting", "Courting");
    var sex = b.subject.sex;
    var word = sex === "female" ? t("commitment.girlfriend", "Girlfriend") :
      sex === "male" ? t("commitment.boyfriend", "Boyfriend") : t("commitment.partner", "Partner");
    var others = (snap.bonds || []).filter(function (o) { return o !== b && partner(o); })
      .map(function (o) { return o.subject.name; });
    return others.length ? t("commitment.together", "{0}, with {1} too", word, names(others)) : word;
  }

  var STAGES = null;
  function stageWord(stage) {
    STAGES = STAGES || [t("stage.newborn", "newborn"), t("stage.infant", "infant"), t("stage.toddler", "toddler"),
      t("stage.child", "child"), t("stage.adolescent", "adolescent"), t("stage.grown", "grown")];
    return stage >= 0 && stage < STAGES.length ? STAGES[stage] : "";
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
    this.root.setAttribute("aria-label", t("detail.summary.aria", "Roster at a glance"));
    var head = el("div", "detail-head");
    var h = el("div");
    h.appendChild(el("h2", null, t("detail.summary.title", "At a glance")));
    h.appendChild(el("p", "detail-meta", t("detail.summary.hint", "Select someone to see where they stand and why.")));
    head.appendChild(h);
    this.root.appendChild(head);
    var scroll = el("div", "detail-scroll");
    var c = M.counts(snap.bonds);

    var tracks = section(t("detail.tracks", "Tracks"));
    [["platonic", c.platonic], ["romantic", c.romantic]].forEach(function (t) {
      var r = el("div", "legend-row");
      r.appendChild(el("span", "n", String(t[1])));
      r.appendChild(chip("t-" + t[0], L.TRACKS[t[0]].label));
      r.appendChild(el("p", null, t[0] === "romantic" ? UI.t("detail.tracks.romantic", "Mutual: they asked, and you said yes.") : UI.t("detail.tracks.platonic", "Everyone else, however deep.")));
      tracks.appendChild(r);
    });
    scroll.appendChild(tracks);

    var states = section(t("detail.states", "States"));
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
      r.appendChild(el("p", null, t("detail.states.unspoken", "Nothing said between you either way.")));
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
    this.root.setAttribute("aria-label", t("detail.aria", "Details: {0}", b.subject.name));

    // Head
    var head = el("div", "detail-head");
    var h = el("div");
    h.appendChild(el("h2", null, b.subject.name));
    var meta = el("p", "detail-meta");
    var bits = [];
    if (b.following) bits.push(t("detail.following", "Following you"));
    bits.push(b.nearby ? t("detail.near", "Near you") : t("detail.elsewhere", "Elsewhere"));
    meta.appendChild(document.createTextNode(bits.join(" · ") + " · "));
    meta.appendChild(el("code", null, L.hexId(b.subject.formId)));
    h.appendChild(meta);
    head.appendChild(h);
    var close = el("button", "icon-btn", "×");
    close.type = "button";
    close.id = "detail-close";
    close.title = t("detail.close.title", "Back to the roster (Esc)");
    close.setAttribute("aria-label", t("detail.close.aria", "Close details"));
    close.addEventListener("click", function () { self.onClose(); });
    head.appendChild(close);
    this.root.appendChild(head);

    var scroll = el("div", "detail-scroll");
    this.scroller = scroll;

    // Depth: the at-a-glance number, big.
    var depth = section(t("detail.depth", "Depth"));
    var big = el("div", "depth-big");
    big.appendChild(el("span", "tier " + L.tierClass(b), L.tierName(b.track, b.depth.tier, b.depth.estranged)));
    big.appendChild(el("span", "pts", t("detail.points", "{0} points", L.number(b.depth.points))));
    depth.appendChild(big);
    var prog = M.progress(b, snap.ladder);
    var bar = el("div", "bar");
    var fill = el("div", "fill " + L.tierClass(b) + (prog.held ? " is-held" : ""));
    fill.style.width = Math.round(prog.pct * 100) + "%";
    bar.appendChild(fill);
    depth.appendChild(bar);
    depth.appendChild(el("p", "depth-note", prog.note));
    if (UI.mode.developer && b.depth.banked > 0) {
      depth.appendChild(el("p", "depth-note", t("detail.banked", "{0} more points are held back until you answer their question. A yes releases all of them.", L.number(b.depth.banked))));
    }
    // WHAT MOVED IT: the last several changes, newest first, as the roster's
    // line shows the newest (labels.js, CHANGE, for what a player sees).
    var changes = L.visibleChanges(b.history, UI.mode.developer);
    var undo = A.byOp("UndoChange");
    if (changes.length) {
      depth.appendChild(el("h4", "sub-head", t("detail.whatMoved", "What moved it")));
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
        // UNDO (2.5): a change that moved points can be taken back, by where
        // it is in the whole history (not the visible list) and what it was,
        // which the game checks before removing anything.
        if (undo && e.delta !== 0 && e.kind !== "withheld") {
          var ub = el("button", "btn btn-quiet change-undo", t("change.undo", "Undo"));
          ub.type = "button";
          ub.setAttribute("data-op", undo.op);
          ub.title = undo.help;
          ub.setAttribute("aria-label", t("change.undo.aria", "Undo this change of {0}", L.changeAmount(e)));
          if (busy && busy[undo.op]) { ub.className += " is-busy"; ub.setAttribute("aria-busy", "true"); }
          ub.addEventListener("click", function () {
            self.onAction(undo, b, [b.history.indexOf(e), e.delta, e.total], ub);
          });
          li.appendChild(ub);
        }
        list.appendChild(li);
      });
      depth.appendChild(list);
    } else {
      depth.appendChild(el("p", "depth-note", t("detail.noChanges", "No changes recorded yet.")));
    }
    scroll.appendChild(depth);

    // Kind: track and state, separately (design 7.1). In player mode only a
    // spoken state is drawn, and the stance, the owed question and the spark
    // are not drawn at all: each is something the character has not said
    // (mode.js). A declined or courting chip already says what the player
    // answered.
    var kind = section(t("detail.bond", "The bond"));
    var dl = el("dl");
    var trackLine = el("span");
    trackLine.appendChild(chip("t-" + b.track, L.TRACKS[b.track].label));
    kv(dl, t("detail.track", "Track"), trackLine);
    var shown = UI.mode.shownState(b);
    if (shown) {
      var stateLine = el("span");
      stateLine.appendChild(chip("s-" + shown, L.stateLabel(shown, b)));
      if (shown === "foreclosed") stateLine.appendChild(document.createTextNode("  " + L.FORECLOSURE[b.foreclosure]));
      kv(dl, t("detail.state", "State"), stateLine);
    }
    kind.appendChild(dl);
    if (shown) kind.appendChild(el("p", "blurb", L.stateBlurb(shown, b)));
    var dl2 = el("dl");
    if (b.state !== "foreclosed") {
      if (UI.mode.developer) {
        kv(dl2, t("detail.yourAnswer", "Your answer"), L.STANCE[b.stance]);
        if (b.askPending) kv(dl2, t("detail.question", "Question"), t("detail.question.owed", "Owed. They will raise it themselves, in person."));
        var spark = b.spark.sparked
          ? (b.spark.sparkedAt !== null ? t("detail.spark.on", "Sparked on {0}", L.gameDay(b.spark.sparkedAt)) : t("detail.spark.yes", "Sparked"))
          : (b.spark.decided ? t("detail.spark.no", "Judged: nothing romantic") : t("detail.spark.notYet", "Not judged yet"));
        kv(dl2, t("detail.spark", "Spark"), spark);
      }
      // While engaged or married the Marriage section says it, and this
      // row does not (M8b).
      var together = wedded(b) ? null : commitmentWords(b, snap);
      if (together) kv(dl2, t("detail.commitment", "Commitment"), together);
    }
    kind.appendChild(dl2);
    scroll.appendChild(kind);

    // MARRIAGE (2.5, M8b): Relationships' own record, a section of its own.
    var m = b.marriage;
    if (m && m.state !== "none" && b.state !== "foreclosed") {
      var ms = section(t("detail.marriageSection", "Marriage"));
      var mdl = el("dl");
      var MARRIAGE = { none: t("marriage.none", "None"), engaged: t("marriage.engaged", "Engaged"),
        married: t("marriage.married", "Married"), broken_off: t("marriage.broken_off", "Broken off"),
        divorced: t("marriage.divorced", "Divorced"), widowed: t("marriage.widowed", "Widowed"),
        separated: t("marriage.separated", "Separated") };
      var mState = MARRIAGE[m.state] || m.state;
      if (m.since !== null) mState += " (" + L.daysAgo(m.since, snap.generatedAt) + ")";
      kv(mdl, t("detail.marriageState", "Now"), mState);
      if (m.officiant) kv(mdl, m.eloped ? t("detail.elopedBy", "Eloped, married by") : t("detail.marriedBy", "Married by"), m.officiant);
      if (m.ringFromPlayer) kv(mdl, t("detail.ringFromYou", "Your ring to them"), m.ringFromPlayer);
      if (m.ringToPlayer) kv(mdl, t("detail.ringToYou", "Their ring to you"), m.ringToPlayer);
      ms.appendChild(mdl);
      if (m.plan) ms.appendChild(this.planBlock(m.plan, snap));
      scroll.appendChild(ms);
    }

    // FAMILY (2.5, M8b): parents, and children born or adopted, each with
    // the other parent. A child with no body in the world is still listed.
    var fam = b.family;
    if (fam && (fam.parents.length || fam.children.length)) {
      var fs = section(t("detail.family", "Family"));
      if (fam.parents.length) {
        var pdl = el("dl");
        kv(pdl, t("detail.parents", "Parents"), names(fam.parents.map(function (p) { return p.name; })));
        fs.appendChild(pdl);
      }
      if (fam.children.length) {
        fs.appendChild(el("h4", "sub-head", t("detail.children", "Children")));
        var cl = el("ul", "family-list");
        fam.children.forEach(function (c) {
          var li = el("li", "family-child");
          li.appendChild(el("span", "family-name", c.name));
          var bits = [];
          var kindWord = c.child === "daughter" ? t("family.daughter", "daughter") : c.child === "son" ? t("family.son", "son") : t("family.child", "child");
          if (c.adopted) kindWord = t("family.adopted", "adopted {0}", kindWord);
          var stage = stageWord(c.stage);
          bits.push(stage && stage !== kindWord ? kindWord + ", " + stage : kindWord);
          if (c.withPlayer) bits.push(t("family.withYou", "with you"));
          else if (c.otherParent) bits.push(t("family.with", "with {0}", c.otherParent));
          if (!c.inWorld) bits.push(t("family.recordOnly", "not yet in the world"));
          li.appendChild(el("span", "family-what", bits.join(" · ")));
          cl.appendChild(li);
        });
        fs.appendChild(cl);
      }
      scroll.appendChild(fs);
    }

    // Character: the traits in words, then the prose.
    var ch = section(t("detail.whoTheyAre", "Who they are"));
    var tr = b.traits;
    var traits = el("div", "traits");
    function box(k, v) {
      var d = el("div", "trait-box");
      d.appendChild(el("span", "k", k));
      d.appendChild(el("span", "v", v));
      traits.appendChild(d);
    }
    if (b.state !== "foreclosed") {
      box(UI.t("trait.intimacy", "Intimacy"), L.INTIMACY[tr.intimacy]);
      box(UI.t("trait.ardor", "Ardor"), UI.t("trait.ardor.value", "{0} ({1} of 4)", L.ARDOR[tr.ardor], tr.ardor));
      box(UI.t("trait.exclusivity", "Exclusivity"), UI.t("trait.exclusivity.value", "{0} ({1} of 100)", L.exclusivityWord(tr.exclusivity), tr.exclusivity));
      box(UI.t("trait.drawnTo", "Drawn to"), L.ORIENTATION[tr.orientation] + (tr.orientationBasis === "known" ? "" :
        " (" + (tr.orientationBasis === "inferred" ? UI.t("trait.basis.inferred", "inferred") : UI.t("trait.basis.unknown", "unknown")) + ")"));
    } else {
      box(UI.t("trait.ardor", "Ardor"), UI.t("trait.ardor.value", "{0} ({1} of 4)", L.ARDOR[tr.ardor], tr.ardor));
    }
    ch.appendChild(traits);
    if (!tr.authored) ch.appendChild(el("p", "trait-note", UI.t("trait.notAuthored", "Not authored yet. These are defaults until their character is written.")));
    // "Calls you" is prose.address (decided 2026-09-30): the label changes,
    // the data does not. Its hint says what the line is, since unlike Why and
    // Limit it is not authored but kept: the talk assessment owns it, and
    // authoring takes one only if a model volunteers it (ApplyProse).
    [[UI.t("prose.why", "Why"), b.prose.why], [UI.t("prose.limit", "Limit"), b.prose.limit],
     [UI.t("prose.callsYou", "Calls you"), b.prose.address, UI.t("prose.callsYou.hint", "What they call you, saved so they don't forget it, and changed only when a conversation changes it.")]]
      .concat(b.prose.playerSays ? [[UI.t("prose.playerSays", "Your history together"), b.prose.playerSays,
        UI.t("prose.playerSays.hint", "In your own words. Their record is read with it as fact. Change it under Repairs.")]] : [])
      .forEach(function (pr) {
        var d = el("div", "prose");
        d.appendChild(el("span", "k", pr[0]));
        if (pr[2]) d.appendChild(el("span", "prose-hint", pr[2]));
        d.appendChild(pr[1] ? el("p", null, pr[1]) : el("p", "is-missing", UI.t("prose.missing", "Not written yet.")));
        ch.appendChild(d);
      });
    scroll.appendChild(ch);

    // On the roster
    var ros = section(t("detail.roster", "On your roster"));
    var dl3 = el("dl");
    var joined = b.enrollment.joinedAt === null ? t("detail.joined.unknown", "Before join dates were kept") :
      L.gameDay(b.enrollment.joinedAt) + " (" + L.daysAgo(b.enrollment.joinedAt, snap.generatedAt) + ")";
    kv(dl3, t("detail.joined", "Joined"), joined);
    kv(dl3, t("detail.enrolled", "Enrolled"), L.ENROLLED_BY[b.enrollment.by]);
    if (!b.following) {
      kv(dl3, t("detail.lastFollowing", "Last following"), b.lastFollowingAt === null ? t("detail.never", "Never") :
        L.gameDay(b.lastFollowingAt) + " (" + L.daysAgo(b.lastFollowingAt, snap.generatedAt) + ")");
    }
    kv(dl3, t("detail.seeded", "Starting standing"), b.seeded ? t("detail.seeded.yes", "Read from the record") : t("detail.seeded.no", "Not read yet"));
    ros.appendChild(dl3);
    scroll.appendChild(ros);

    // Actions
    var acts = section(t("detail.repairs", "Repairs"));
    A.available("bond").forEach(function (a) { acts.appendChild(self.actionBlock(a, b, busy)); });
    scroll.appendChild(acts);

    // Developer tools, apart from the repairs and labelled as what they are.
    // Only in the developer view; the list is empty otherwise.
    var tools = A.developerTools("bond");
    if (tools.length) {
      var dev = section(t("detail.devTools", "Developer tools"));
      dev.className += " sec-dev";
      dev.appendChild(el("p", "act-needs", t("detail.devTools.note", "Shown because the developer view is on. For looking under the hood; a player never needs them.")));
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

  // THE WEDDING PLAN (2.5, Build B, M4p): a checklist, open items first.
  // Required: the day, the place, an officiant who agreed. The rest never
  // gates the day.
  Detail.prototype.planBlock = function (p, snap) {
    var wrap = el("div", "plan");
    wrap.appendChild(el("h4", "sub-head", p.status === "underWay" ? t("plan.today", "The wedding: today") : t("plan.title", "The wedding plan")));
    var hours = p.hour >= 0 ? (p.hour < 11 ? t("plan.morning", "morning") : p.hour < 14 ? t("plan.noon", "noon") :
      p.hour < 17 ? t("plan.afternoon", "afternoon") : p.hour < 21 ? t("plan.evening", "evening") : t("plan.night", "night")) : "";
    var rows = [
      { open: p.day === null, k: t("plan.day", "Day"), v: p.day === null ? t("plan.notSet", "not set") : L.daysAhead(p.day, snap.generatedAt) + (hours ? ", " + hours : "") },
      { open: !p.place, k: t("plan.place", "Place"), v: p.place || t("plan.notSet", "not set") },
      { open: !p.officiant, k: t("plan.officiant", "Marrying you"), v: p.officiant || t("plan.notAgreed", "no one has agreed yet") },
      { k: t("plan.guests", "Guests"), v: p.guests.length ? names(p.guests) : t("plan.noGuests", "none invited") },
      { k: t("plan.ceremony", "Ceremony"), v: [p.parts.address ? t("plan.address", "address") : null, p.parts.reading ? t("plan.reading", "reading") : null,
          t("plan.vows", "vows"), p.parts.rings ? t("plan.rings", "rings") : null, p.parts.kiss ? t("plan.kiss", "kiss") : null]
          .filter(function (x) { return x; }).join(", ") },
      { k: t("plan.ringsChosen", "Rings"), v: p.ring ? t("plan.ringsAre", "theirs {0}, yours {1}", p.ring, (p.band || p.ring) + (p.bandWide === 1 ? " " + t("plan.wide", "wide") : p.bandWide === 0 ? " " + t("plan.braided", "braided") : "")) : t("plan.ringsNot", "not chosen") },
      { k: t("plan.clothes", "Their clothes"), v: p.outfit ? t("plan.clothesChosen", "chosen") : t("plan.clothesNot", "not chosen yet") }
    ];
    if (p.planner) rows.push({ k: t("plan.planner", "Planner"), v: p.planner });
    rows.sort(function (a, c) { return (c.open ? 1 : 0) - (a.open ? 1 : 0); });
    var dl = el("dl", "plan-list");
    rows.forEach(function (r) {
      var row = kv(dl, r.k, r.v);
      if (r.open) row.className += " is-open";
    });
    wrap.appendChild(dl);
    if (p.missedDay !== null && p.missedDay !== undefined) {
      wrap.appendChild(el("p", "depth-note", t("plan.missed", "You did not come on the day you had set ({0}).", L.daysAgo(p.missedDay, snap.generatedAt))));
    }
    return wrap;
  };

  Detail.prototype.actionBlock = function (a, b, busy) {
    var self = this;
    var wrap = el("div", "act");
    wrap.setAttribute("data-op", a.op);
    var row = el("div", "act-row");
    // Why the button cannot be pressed, if it cannot. Papyrus refuses with a
    // reason as well, in case the game has moved on since the snapshot.
    var blocked = a.needsFollowing && !b.following ? t("act.notFollowing", "{0} is not travelling with you.", b.subject.name) + " " + a.needs :
      a.needsNearby && !b.nearby ? t("act.notNear", "{0} is not near you.", b.subject.name) + " " + a.needs :
      a.needsAddress && !b.prose.address ? t("act.noAddress", "{0} has no saved name for you.", b.subject.name) :
      a.needsMarried && !(b.marriage && (b.marriage.state === "married" || b.marriage.state === "separated")) ?
        t("act.notMarried", "{0} is not married to you in Relationships' record.", b.subject.name) : null;
    var btn = el("button", "btn" + (a.confirm ? " btn-danger" : ""), a.label);
    btn.type = "button";
    btn.setAttribute("data-op", a.op);
    if (busy && busy[a.op]) { btn.className += " is-busy"; btn.setAttribute("aria-busy", "true"); }
    btn.disabled = !!blocked;

    if (a.form === "traitField") {
      var form = el("div", "act-form");
      var field = el("select");
      field.id = "trait-field";
      field.setAttribute("aria-label", t("act.traitToCorrect", "Trait to correct"));
      [["intimacy", t("trait.intimacy", "Intimacy")], ["ardor", t("trait.ardor", "Ardor")], ["exclusivity", t("trait.exclusivity", "Exclusivity")]].forEach(function (f) {
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
          inp.setAttribute("aria-label", t("act.exclusivityRange", "Exclusivity, 0 to 100"));
          value.appendChild(inp);
          readValue = function () { return Math.max(0, Math.min(100, parseInt(inp.value, 10) || 0)); };
        } else {
          var sel = el("select");
          sel.setAttribute("aria-label", f === "ardor" ? t("trait.ardor", "Ardor") : t("trait.intimacy", "Intimacy"));
          var words = f === "ardor" ? L.ARDOR : [L.INTIMACY.casual, L.INTIMACY.romantic, L.INTIMACY.guarded, L.INTIMACY.never];
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
      btn.textContent = t("act.write", "Write");
      btn.addEventListener("click", function () {
        self.onAction(a, b, [A.FIELD[field.value], readValue()], btn);
      });
      row.appendChild(el("strong", null, a.label));
      wrap.appendChild(row);
      form.appendChild(btn);
      wrap.appendChild(form);
    } else if (a.form === "historyText") {
      // THE PLAYER'S OWN ACCOUNT (2.4, WP-T): one line of their history with
      // this person, which a seed read takes as fact. Saved empty, it clears.
      var hform = el("div", "act-form act-form-text");
      var ta = el("textarea");
      ta.id = "history-text";
      ta.maxLength = 400;
      ta.rows = 3;
      ta.value = b.prose.playerSays || "";
      ta.setAttribute("aria-label", a.label);
      ta.placeholder = t("act.history.placeholder", "For example: {0} and I have been on-and-off lovers for years.", b.subject.name);
      btn.textContent = t("act.save", "Save");
      btn.addEventListener("click", function () { self.onAction(a, b, { text: ta.value }, btn); });
      row.appendChild(el("strong", null, a.label));
      wrap.appendChild(row);
      hform.appendChild(ta);
      hform.appendChild(btn);
      wrap.appendChild(hform);
      wrap.appendChild(el("p", "act-help", a.help));
    } else if (a.form === "intChoice") {
      // A fixed list of numbered choices (2.5: a marriage state).
      var cform = el("div", "act-form");
      var csel = el("select");
      csel.setAttribute("aria-label", a.label);
      a.choices.forEach(function (c) { var o = el("option", null, c[1]); o.value = String(c[0]); csel.appendChild(o); });
      btn.textContent = t("act.write", "Write");
      btn.addEventListener("click", function () { self.onAction(a, b, [parseInt(csel.value, 10)], btn); });
      row.appendChild(el("strong", null, a.label));
      wrap.appendChild(row);
      cform.appendChild(csel);
      cform.appendChild(btn);
      wrap.appendChild(cform);
      wrap.appendChild(el("p", "act-help", a.help));
    } else if (a.form === "reauthorBlocks") {
      // THE OVERRIDE (2.4): checked, the player's own blocks in the tabs we
      // pick from come off too, and the confirmation says so.
      var cb = el("input");
      cb.type = "checkbox";
      cb.id = "reauthor-replace";
      var cbl = el("label", "act-check");
      cbl.appendChild(cb);
      cbl.appendChild(document.createTextNode(" " + a.replaceLabel));
      btn.addEventListener("click", function () {
        var act = a;
        if (cb.checked) {
          act = {};
          for (var k in a) if (Object.prototype.hasOwnProperty.call(a, k)) act[k] = a[k];
          act.confirm = a.confirmReplace;
        }
        self.onAction(act, b, [cb.checked ? 1 : 0], btn);
      });
      row.appendChild(el("span", "act-help", a.help));
      row.appendChild(btn);
      wrap.appendChild(row);
      wrap.appendChild(cbl);
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
