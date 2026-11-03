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

  // SEVERACTIONS' PORTRAITS (wpm44): the face SeverActions keeps for each
  // companion, asked for once per person a session and kept here, since the
  // panel is rebuilt after every action. A string is the picture, "" none.
  var portraits = {};
  snrom.on("portrait", function (p) {
    if (!p || typeof p.formId !== "number") return;
    portraits[p.formId] = typeof p.src === "string" ? p.src : "";
    var slot = document.querySelector(".detail-portrait[data-form='" + p.formId + "']");
    if (slot) fillPortrait(slot, portraits[p.formId]);
  });
  function fillPortrait(slot, src) {
    slot.innerHTML = "";
    if (!src) { slot.hidden = true; return; }
    var img = document.createElement("img");
    img.src = src;
    img.alt = "";
    slot.appendChild(img);
    slot.hidden = false;
  }
  function portraitSlot(formId) {
    var slot = el("div", "detail-portrait");
    slot.setAttribute("data-form", String(formId));
    slot.hidden = true;
    if (formId in portraits) fillPortrait(slot, portraits[formId]);
    else {
      portraits[formId] = "";
      snrom.request("portrait", { formId: formId }).then(function (r) {
        if (!r.ok) delete portraits[formId];
      });
    }
    return slot;
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
    // THE HERO (wpm45, chosen 2026-10-26): the name and the depth at a
    // glance on the left, SeverActions' portrait on the right, all in the
    // head, so the face stays in view as the page scrolls.
    var head = el("div", "detail-head");
    var h = el("div", "detail-title");
    h.appendChild(el("h2", null, b.subject.name));
    var meta = el("p", "detail-meta");
    var bits = [];
    var kin = L.kinWord(b);
    if (kin) bits.push(kin);
    if (b.following) bits.push(t("detail.following", "Following you"));
    bits.push(b.nearby ? t("detail.near", "Near you") : t("detail.elsewhere", "Elsewhere"));
    meta.appendChild(document.createTextNode(bits.join(" · ") + " · "));
    meta.appendChild(el("code", null, L.hexId(b.subject.formId)));
    h.appendChild(meta);
    head.appendChild(h);
    head.appendChild(portraitSlot(b.subject.formId));
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

    // Depth: the at-a-glance number, big, in the head under the name; the
    // section below keeps what moved it.
    var depth = section(t("detail.whatMoved", "What moved it"));
    var glance = el("div", "depth-glance");
    h.appendChild(glance);
    var big = el("div", "depth-big");
    big.appendChild(el("span", "tier " + L.tierClass(b), L.tierName(b.track, b.depth.tier, b.depth.estranged)));
    big.appendChild(el("span", "pts", t("detail.points", "{0} points", L.number(b.depth.points))));
    glance.appendChild(big);
    var prog = M.progress(b, snap.ladder);
    var bar = el("div", "bar");
    var fill = el("div", "fill " + L.tierClass(b) + (prog.held ? " is-held" : ""));
    fill.style.width = Math.round(prog.pct * 100) + "%";
    bar.appendChild(fill);
    glance.appendChild(bar);
    glance.appendChild(el("p", "depth-note", prog.note));
    if (UI.mode.developer && b.depth.banked > 0) {
      glance.appendChild(el("p", "depth-note", t("detail.banked", "{0} more points are held back until you answer their question. A yes releases all of them.", L.number(b.depth.banked))));
    }
    // WHAT MOVED IT: the last several changes, newest first, as the roster's
    // line shows the newest (labels.js, CHANGE, for what a player sees).
    var changes = L.visibleChanges(b.history, UI.mode.developer);
    var undo = A.byOp("UndoChange");
    if (changes.length) {
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

    // MARAS OR RELATIONSHIPS (2026-10-25): with MARAS installed it runs
    // marriage, and our record stands aside until its marriages are imported
    // and MARAS is removed.
    var marasRuns = !!(snap.playthrough && snap.playthrough.marasOwnsMarriage);
    if (marasRuns && b.state !== "foreclosed") {
      kind.appendChild(el("p", "blurb", t("detail.marasRuns", "MARAS runs marriage until its marriages are brought over. Import them from Playthrough repairs and restart the game: Relationships then runs marriage, and MARAS is set aside even while it stays installed. Removing MARAS afterwards is the clean finish.")));
    }

    // MARRIAGE (2.5, M8b): Relationships' own record, a section of its own.
    var m = b.marriage;
    if (m && m.state !== "none" && b.state !== "foreclosed" && !marasRuns) {
      var ms = section(t("detail.marriageSection", "Marriage"));
      var mdl = el("dl");
      var MARRIAGE = { none: t("marriage.none", "None"), engaged: t("marriage.engaged", "Engaged"),
        married: t("marriage.married", "Married"), broken_off: t("marriage.broken_off", "Broken off"),
        divorced: t("marriage.divorced", "Divorced"), widowed: t("marriage.widowed", "Widowed"),
        separated: t("marriage.separated", "Separated") };
      var mState = MARRIAGE[m.state] || m.state;
      // An imported record's "since" is the day of the import, not when it
      // happened: said as brought over from MARAS instead, with the wedding's
      // own day when one is known.
      if (m.imported && m.weddingDay !== null) mState += " (" + t("marriage.importedOn",
        "{0}, brought over from MARAS", L.daysAgo(m.weddingDay, snap.generatedAt)) + ")";
      else if (m.imported) mState += " (" + t("marriage.imported", "brought over from MARAS") + ")";
      else if (m.since !== null) mState += " (" + L.daysAgo(m.since, snap.generatedAt) + ")";
      kv(mdl, t("detail.marriageState", "Now"), mState);
      if (m.officiant) kv(mdl, m.eloped ? t("detail.elopedBy", "Eloped, married by") : t("detail.marriedBy", "Married by"), m.officiant);
      if (m.ringFromPlayer) kv(mdl, t("detail.ringFromYou", "Your ring to them"), m.ringFromPlayer);
      if (m.ringToPlayer) kv(mdl, t("detail.ringToYou", "Their ring to you"), m.ringToPlayer);
      ms.appendChild(mdl);
      if (m.plan) ms.appendChild(this.planBlock(m.plan, b, snap));
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

  // THE WEDDING PLAN (2.5, Build B, M4p). The author, 2026-10-27: too much
  // in too small a space as one long list. Now the day and the place first,
  // as a heading; then one line on what is left (required before the day:
  // day, hour, place, an officiant who agreed; the rest never gates it);
  // then the ceremony, the rings, the clothes and the guests, grouped.
  Detail.prototype.planBlock = function (p, b, snap) {
    var C = UI.calendar;
    var who = b.subject.name.split(" ")[0];
    var today = p.status === "underWay";
    var wrap = el("div", "plan");
    wrap.appendChild(el("h4", "sub-head", today ? t("plan.todayHeading", "The wedding: today") : t("plan.title", "The wedding plan")));

    // WHEN AND WHERE: the date in the calendar's words where the snapshot
    // has a calendar, how far off it is, and the place.
    var when = el("div", "plan-when");
    var date = el("div", "plan-date");
    if (p.day === null) {
      date.textContent = t("plan.noDay", "No day chosen yet");
      date.className += " is-open";
    } else {
      var words = C.dateWords(snap, p.day) || L.daysAhead(p.day, snap.generatedAt);
      date.textContent = p.hour >= 0 ? t("plan.dateAt", "{0}, {1}", words, C.hourWords(p.hour)) : words;
      if (p.hour < 0) date.appendChild(el("span", "plan-flag", t("plan.hourNotSet", "hour not set")));
    }
    when.appendChild(date);
    var where = el("div", "plan-where");
    if (p.day !== null && C.dateWords(snap, p.day)) where.appendChild(el("span", null, L.daysAhead(p.day, snap.generatedAt)));
    where.appendChild(p.place ? el("span", null, p.near ? t("plan.placeBy", "{0}, by {1}", p.place, p.near) : p.place) : el("span", "is-open", t("plan.noPlace", "no place chosen yet")));
    when.appendChild(where);
    wrap.appendChild(when);

    // WHAT IS LEFT, in one line: what the day needs before what is only not
    // yet talked through.
    var NEEDS = { day: t("plan.need.day", "the day"), hour: t("plan.need.hour", "the hour"), place: t("plan.need.place", "the place"),
      officiant: t("plan.need.officiant", "someone to marry you") };
    var TALK = { near: t("plan.talk.near", "what the place is by"), guests: t("plan.talk.guests", "the guests"),
      sides: t("plan.talk.sides", "whose guests they are"), layout: t("plan.talk.layout", "where everyone will stand"), ceremony: t("plan.talk.ceremony", "the ceremony"),
      theirRing: t("plan.talk.theirRing", "{0}'s ring", who), yourRing: t("plan.talk.yourRing", "your ring"),
      outfit: t("plan.talk.outfit", "what {0} will wear", who) };
    var open = (p.open || []).map(function (o) { return NEEDS[o] || o; });
    var talk = (p.unsettled || []).map(function (o) { return TALK[o] || o; });
    if (open.length) wrap.appendChild(el("p", "plan-status is-open", t("plan.stillNeeded", "Needed before the day: {0}.", names(open))));
    else if (talk.length) wrap.appendChild(el("p", "plan-status", t("plan.stillToTalk", "Still to talk through: {0}.", names(talk))));
    else if (!today) wrap.appendChild(el("p", "plan-status is-ready", t("plan.allSettled", "Everything is settled.")));

    var dl = el("dl", "plan-list");
    // Who marries them, and who plans it: one line when they are the same.
    if (!p.officiant) kv(dl, t("plan.officiant", "Marrying you"), t("plan.notAgreed", "no one has agreed yet")).className += " is-open";
    else if (p.planner === p.officiant) kv(dl, t("plan.officiant", "Marrying you"), t("plan.alsoPlanning", "{0}, who is also planning it", p.officiant));
    else kv(dl, t("plan.officiant", "Marrying you"), p.officiant);
    if (p.planner && p.planner !== p.officiant) kv(dl, t("plan.planner", "Planner"), p.planner);

    // The ceremony, in its order: each part a chip, a part left out struck
    // through rather than missing, so "no kiss" reads as chosen.
    var parts = el("span", "plan-parts");
    [[t("plan.address", "address"), p.parts.address], [t("plan.reading", "reading"), p.parts.reading],
     [t("plan.vows", "vows"), true], [t("plan.rings", "rings"), p.parts.rings], [t("plan.kiss", "kiss"), p.parts.kiss]]
      .forEach(function (pt) {
        var c = el("span", "plan-part" + (pt[1] ? "" : " is-out"), pt[0]);
        if (!pt[1]) c.title = t("plan.leftOut", "left out");
        parts.appendChild(c);
      });
    kv(dl, t("plan.ceremony", "Ceremony"), parts);

    // Each of the couple's ring (wpm51): style and metal, the same choices
    // for both. Theirs and yours, one line each.
    function ringWords(r) {
      if (!r || (r.style < 0 && !r.metal)) return null;
      var style = r.style === 1 ? t("plan.ringWide", "wide band") : r.style === 0 ? t("plan.ringSlim", "slim set") : "";
      // wpm85: a style nobody chose is the usual one, the wide band for a man
      // and the slim set for a woman, and is shown as such.
      if (style && r.chosen === false) style = t("plan.ringUsual", "{0} (the usual)", style);
      return [style, r.metal].filter(function (x) { return x; }).join(", ");
    }
    var rings = el("span", "plan-rings");
    [[who, p.theirRing], [t("plan.you", "You"), p.yourRing]].forEach(function (r) {
      var line = el("span", "plan-ring");
      line.appendChild(el("span", "plan-ring-who", r[0]));
      var w = ringWords(r[1]);
      line.appendChild(el("span", w ? null : "plan-not", w || t("plan.ringsNot", "not chosen yet")));
      rings.appendChild(line);
    });
    kv(dl, t("plan.ringsRow", "Rings"), rings);

    kv(dl, t("plan.clothes", "Clothes"), p.outfit ? t("plan.clothesChosen", "{0} has chosen", who) :
      el("span", "plan-not", t("plan.clothesNot", "{0} has not chosen yet", who)));

    // WHERE EVERYONE STANDS (wpm61), as the player marked it at the place.
    if (p.place) {
      var MARK = { officiant: t("plan.mark.officiant", "who marries you"), you: t("plan.mark.you", "you"), betrothed: t("plan.mark.betrothed", "{0}", who),
        theirs: t("plan.mark.theirs", "{0}'s guests", who), yours: t("plan.mark.yours", "your guests") };
      var marked = (p.marked || []).map(function (m) { return MARK[m] || m; });
      kv(dl, t("plan.marks", "Marked"), marked.length ? names(marked) : el("span", "plan-not", t("plan.noMarks", "nothing yet")));
    }
    // The guests last, as the longest: a count, then the names, smaller.
    var guests = p.guests.length ? el("span", "plan-guests", names(p.guests)) : el("span", "plan-not", t("plan.noGuests", "none invited"));
    kv(dl, p.guests.length ? t("plan.guestsCount", "Guests ({0})", p.guests.length) : t("plan.guests", "Guests"), guests);
    wrap.appendChild(dl);
    if (p.missedDay !== null && p.missedDay !== undefined) {
      wrap.appendChild(el("p", "depth-note", t("plan.missedNote", "You did not come on the day you had set ({0}).", L.daysAgo(p.missedDay, snap.generatedAt))));
    }
    if (!today) wrap.appendChild(this.planEditor(p, b, snap));
    return wrap;
  };

  // THE PLAN BY HAND (wpm85; the author, 2026-11-03: "allowing the user to
  // edit the wedding plan in the UI as a last resort"). What was agreed in
  // conversation is recorded by the planner's actions and by the judge that
  // hears them (PlanJudge); when neither took, it is set here. Behind a
  // button, so the plan reads as it was agreed and this is the exception.
  // Each row changes one thing (SNRom_Bridge.EditWeddingPlanByHand).
  var planEditOpen = null;   // whose plan editor is open (a form id)
  Detail.prototype.planEditor = function (p, b, snap) {
    var self = this;
    var C = UI.calendar;
    var who = b.subject.name.split(" ")[0];
    var EDIT = A.byOp("EditWeddingPlan");
    var box = el("div", "plan-edit");
    var toggle = el("button", "btn btn-quiet", t("plan.edit.open", "Change the plan by hand"));
    toggle.type = "button";
    toggle.setAttribute("aria-expanded", "false");
    var body = el("div", "plan-edit-body");
    // Open stays open across the redraw each change brings, for this person.
    body.hidden = planEditOpen !== b.subject.formId;
    toggle.setAttribute("aria-expanded", body.hidden ? "false" : "true");
    toggle.addEventListener("click", function () {
      body.hidden = !body.hidden;
      planEditOpen = body.hidden ? null : b.subject.formId;
      toggle.setAttribute("aria-expanded", body.hidden ? "false" : "true");
    });
    box.appendChild(toggle);
    body.appendChild(el("p", "act-help", t("plan.edit.help", "For when something you agreed with {0} or the planner was not written into the plan. Each change is made as if {0} had agreed to it.", who)));
    box.appendChild(body);

    function send(args, text, btn) { self.onAction(EDIT, b, { args: args, text: text || "" }, btn); }
    function button(label, run) {
      var bt = el("button", "btn", label);
      bt.type = "button";
      bt.setAttribute("data-op", "EditWeddingPlan");
      bt.addEventListener("click", function () { run(bt); });
      return bt;
    }
    function input(value, label) {
      var i = el("input", "is-wide");
      i.type = "text";
      i.value = value || "";
      i.setAttribute("aria-label", label);
      return i;
    }
    function select(options, current, label) {
      var sel = el("select");
      sel.setAttribute("aria-label", label);
      options.forEach(function (o) {
        var opt = el("option", null, o[1]);
        opt.value = String(o[0]);
        if (String(o[0]) === String(current)) opt.selected = true;
        sel.appendChild(opt);
      });
      return sel;
    }
    function row(label, nodes) {
      var r = el("div", "plan-edit-row");
      r.appendChild(el("span", "plan-edit-label", label));
      var f = el("div", "act-form");
      nodes.forEach(function (n) { f.appendChild(n); });
      r.appendChild(f);
      body.appendChild(r);
    }

    // The day: how many days from today, and the hour.
    var ahead = p.day !== null && p.day !== undefined ? Math.max(0, Math.floor(p.day) - Math.floor(snap.generatedAt)) : 2;
    var days = el("input");
    days.type = "number"; days.min = "0"; days.max = "365"; days.step = "1"; days.value = String(ahead);
    days.setAttribute("aria-label", t("plan.edit.daysAhead", "Days from today"));
    var hours = [[-1, t("plan.edit.keepHour", "keep the hour")]];
    for (var h = 0; h < 24; h++) hours.push([h, C.hourWords(h)]);
    var hour = select(hours, p.hour >= 0 ? p.hour : 12, t("plan.edit.hour", "Hour"));
    row(t("plan.edit.day", "The day"), [days, el("span", "plan-edit-note", t("plan.edit.daysFromToday", "days from today, at")), hour,
      button(t("plan.edit.set", "Set"), function (bt) {
        send([1, Math.max(0, Math.min(365, parseInt(days.value, 10) || 0)), parseInt(hour.value, 10)], "", bt);
      }),
      button(t("plan.edit.postpone", "Put the day off"), function (bt) { send([10], "", bt); })]);

    // The place, and what it is by.
    var place = input(p.place, t("plan.edit.place", "The place"));
    row(t("plan.edit.place", "The place"), [place, button(t("plan.edit.set", "Set"), function (bt) { send([2], place.value, bt); })]);
    var near = input(p.near, t("plan.edit.near", "What it is by"));
    row(t("plan.edit.near", "What it is by"), [near, button(t("plan.edit.set", "Set"), function (bt) { send([3], near.value, bt); })]);

    // Who marries them: any priest, priestess or jarl, by name.
    var off = input(p.officiant, t("plan.edit.officiant", "Who marries you"));
    row(t("plan.edit.officiant", "Who marries you"), [off, button(t("plan.edit.set", "Set"), function (bt) { send([4], off.value, bt); })]);

    // The ceremony's parts; the vows are always theirs.
    var bits = [[1, "address", t("plan.address", "address")], [2, "reading", t("plan.reading", "reading")],
      [4, "rings", t("plan.rings", "rings")], [8, "kiss", t("plan.kiss", "kiss")]];
    var boxes = bits.map(function (bt) {
      var lab = el("label", "plan-edit-check");
      var c = el("input");
      c.type = "checkbox";
      c.checked = !!(p.parts && p.parts[bt[1]]);
      lab.appendChild(c);
      lab.appendChild(document.createTextNode(" " + bt[2]));
      lab._bit = bt[0]; lab._box = c;
      return lab;
    });
    row(t("plan.ceremony", "Ceremony"), boxes.concat([button(t("plan.edit.set", "Set"), function (bt) {
      var parts = 0;
      boxes.forEach(function (lb) { if (lb._box.checked) parts += lb._bit; });
      send([8, parts], "", bt);
    })]));

    // The rings: style and metal, theirs and yours.
    var STYLES = [[0, t("plan.ringSlim", "slim set")], [1, t("plan.ringWide", "wide band")]];
    var METALS = [[-1, t("plan.edit.noMetal", "metal not chosen")], [0, t("plan.metal.gold", "gold")], [1, t("plan.metal.silver", "silver")], [2, t("plan.metal.ebony", "ebony")]];
    var METAL_OF = { gold: 0, silver: 1, ebony: 2 };
    function ringPick(r, label) {
      var st = select(STYLES, r && r.style >= 0 ? r.style : 0, t("plan.edit.style", "{0}: style", label));
      var mt = select(METALS, r && r.metal ? METAL_OF[r.metal] : -1, t("plan.edit.metal", "{0}: metal", label));
      return [st, mt];
    }
    var theirs = ringPick(p.theirRing, who);
    var yours = ringPick(p.yourRing, t("plan.you", "You"));
    row(t("plan.edit.theirRing", "{0}'s ring", who), theirs);
    row(t("plan.edit.yourRing", "Your ring"), yours.concat([button(t("plan.edit.setRings", "Set both rings"), function (bt) {
      send([9, parseInt(yours[0].value, 10), parseInt(yours[1].value, 10), parseInt(theirs[0].value, 10), parseInt(theirs[1].value, 10)], "", bt);
    })]));

    // The guests: each one's side, or off the list; and more invited.
    var SIDES = [[-1, t("plan.edit.sideUnknown", "side not known")], [0, t("plan.edit.sideTheirs", "{0}'s", who)],
      [1, t("plan.edit.sideYours", "yours")], [2, t("plan.edit.sideBoth", "both")]];
    var SIDE_OF = { theirs: 0, yours: 1, both: 2 };
    var listed = p.guestSides || (p.guests || []).map(function (n) { return { name: n, side: "" }; });
    listed.forEach(function (g) {
      var side = select(SIDES, g.side in SIDE_OF ? SIDE_OF[g.side] : -1, t("plan.edit.sideOf", "{0}: whose guest", g.name));
      row(g.name, [side,
        button(t("plan.edit.set", "Set"), function (bt) { if (parseInt(side.value, 10) >= 0) send([7, parseInt(side.value, 10)], g.name, bt); }),
        button(t("plan.edit.uninvite", "Take off the list"), function (bt) { send([6], g.name, bt); })]);
    });
    var more = input("", t("plan.edit.invite", "Invite"));
    more.placeholder = t("plan.edit.invitePlaceholder", "names, separated by commas");
    var moreSide = select(SIDES, -1, t("plan.edit.inviteSide", "Whose guests"));
    row(t("plan.edit.invite", "Invite"), [more, moreSide, button(t("plan.edit.inviteGo", "Invite"), function (bt) {
      if (more.value.trim()) send([5, parseInt(moreSide.value, 10)], more.value, bt);
    })]);

    // What they wear: what they have on now, kept for the day.
    row(t("plan.clothes", "Clothes"), [button(t("plan.edit.outfit", "Keep what {0} wears now", who), function (bt) { send([11], "", bt); })]);
    return box;
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
