/* roster.js - the roster list: one row per bond, virtualized.

   PrismaUI scrolls slowly (design 7.5), and a roster can pass 150 once anyone
   can be enrolled. So the list never holds more rows than fit on screen plus a
   few either side: a fixed pool of row elements is re-pointed at whichever
   bonds are in view, and scrolling changes text and one transform per row.
   The DOM stays the same size at 20 bonds or 2,000.

   Keyboard: the list is one tab stop (a listbox using aria-activedescendant),
   with Up/Down, Page Up/Down, Home/End to move and Enter or Space to open.
   A controller can drive the same keys later through Meridian.Input/1. */

(function (UI) {
  "use strict";

  var L = UI.labels;
  var M = UI.model;
  var OVERSCAN = 6;

  // The columns, in order: class, header, and the --w-* style.css reads.
  var COLUMNS = [["c-name", "Name", "name"], ["c-depth", "Depth", "depth"], ["c-track", "Track", "track"],
    ["c-state", "State", "state"], ["c-com", "Commitment", "com"], ["c-int", "Intimacy", "int"], ["c-ard", "Ardor", "ard"],
    ["c-exc", "Exclusivity", "exc"], ["c-ori", "Drawn to", "ori"]];
  // .cols in style.css: the gap between columns and the padding either side,
  // in rem. Spacing, so not multiplied by the text size.
  var COL_GAP_REM = 0.75;
  var COL_PAD_REM = 1.25;
  var DEPTH_GAP_REM = 0.5;    // .depth-top's gap
  // A name wider than this ellipsizes rather than widen every row: a mod's
  // long-named NPC should not push the whole list across the screen.
  var NAME_MAX_REM = 16;
  // How many of the longest names, and of the longest point notes, are
  // measured: in one font, the widest is almost always among the longest,
  // and 2,000 bonds need not all be laid out to find it.
  var LONGEST = 24;

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }

  function Roster(root, opts) {
    this.root = root;
    this.onOpen = opts.onOpen;
    this.rows = [];
    this.ladder = null;
    this.active = -1;
    this.openKey = null;
    this.pool = [];
    this.rowH = 56;
    this.frame = 0;
    this.fitKey = "";
    this.natural = 0;
    this.build();
  }

  Roster.prototype.build = function () {
    var self = this;
    var head = el("div", "cols roster-head");
    head.setAttribute("aria-hidden", "true");
    COLUMNS.forEach(function (c) { head.appendChild(el("div", c[0], c[1])); });
    this.probe = el("div", "fit-probe");
    this.probe.setAttribute("aria-hidden", "true");

    this.viewport = el("div", "viewport");
    this.viewport.id = "roster-list";
    this.viewport.tabIndex = 0;
    this.viewport.setAttribute("role", "listbox");
    this.viewport.setAttribute("aria-label", "Roster");
    this.spacer = el("div", "spacer");
    this.viewport.appendChild(this.spacer);
    this.empty = el("div", "empty");
    this.empty.hidden = true;

    this.root.appendChild(head);
    this.root.appendChild(this.viewport);
    this.root.appendChild(this.empty);
    this.root.appendChild(this.probe);

    this.viewport.addEventListener("scroll", function () { self.schedule(); });
    this.viewport.addEventListener("keydown", function (e) { self.key(e); });
    this.viewport.addEventListener("click", function (e) {
      var row = e.target.closest ? e.target.closest(".row") : null;
      if (!row) return;
      var i = Number(row.getAttribute("data-index"));
      self.setActive(i, false);
      self.open(i);
    });
    window.addEventListener("resize", function () { self.measure(); self.render(); });
    this.measure();
  };

  // The row height display.js set, in px.
  Roster.prototype.measure = function () {
    var v = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--row-h"));
    this.rowH = v > 0 ? v : 56;
  };

  // The longest few of a list of strings, without repeats.
  function longest(list) {
    var seen = {}, out = [];
    list.forEach(function (s) { if (!seen[s]) { seen[s] = true; out.push(s); } });
    out.sort(function (a, b) { return b.length - a.length; });
    return out.slice(0, LONGEST);
  }

  // What each column can show, as [class, text] pairs laid out in the row's
  // own styles. Chip columns are their whole vocabulary, so a column does not
  // change width as bonds come and go or the filters change; the name and the
  // points are what the roster holds. Every state is measured, player mode or
  // not, so the developer view does not move the columns either.
  function candidates(bonds, ladder) {
    var chips = function (cls, words) { return words.map(function (w) { return [cls, w]; }); };
    var tiers = L.TIER_NAMES.romantic.concat(L.TIER_NAMES.platonic);
    var states = L.STATE_ORDER.map(function (s) { return L.STATES[s].label; }).concat([L.STATES.courting.devoted.label]);
    var intimacy = Object.keys(L.INTIMACY).map(function (k) { return L.INTIMACY[k]; }).concat(["\u2014"]);
    var exclusivity = [0, 25, 50, 75, 100].map(function (v) { return L.exclusivityWord(v) + " 100"; }).concat(["\u2014"]);
    var orientation = ["Unknown", "\u2014"].concat(Object.keys(L.ORIENTATION).map(function (k) {
      return L.orientationChip({ orientationBasis: "inferred", orientation: k }).text;
    }));
    var names = longest(bonds.map(function (b) { return b.subject.name; }));
    var pts = ladder ? longest(bonds.map(function (b) {
      return L.number(b.depth.points) + " \u00b7 " + M.progress(b, ladder).note;
    })) : [];
    return {
      name: chips("name", names).concat(chips("name-sub", ["Following", "Enrolled by you"])),
      tier: chips("tier", tiers),
      pts: chips("pts", pts),
      track: chips("chip", [L.TRACKS.platonic.label, L.TRACKS.romantic.label]),
      state: chips("chip", states),
      com: chips("chip", Object.keys(L.COMMITMENT_CHIP).map(function (k) { return L.COMMITMENT_CHIP[k].label; })),
      int: chips("chip trait", intimacy),
      ard: chips("chip trait", L.ARDOR),
      exc: chips("chip trait", exclusivity),
      ori: chips("chip trait", orientation)
    };
  }

  // SIZES THE COLUMNS TO THEIR CONTENT: lays out what each column can show,
  // unseen, reads the widest, and sets --w-* on the roster for style.css.
  // Returns the roster's natural width in px: the columns, their gaps and
  // padding, and room for the list's scrollbar. Only re-measures when the
  // strings or the display settings change, so calling it on every snapshot
  // costs a string comparison.
  Roster.prototype.fit = function (bonds, ladder) {
    var D = UI.display;
    var c = candidates(bonds, ladder);
    var key = [D.rootPx(), D.text(), UI.mode.developer].join("|") + "\n" +
      Object.keys(c).map(function (k) { return c[k].map(function (p) { return p[1]; }).join("\t"); }).join("\n");
    if (key === this.fitKey) return this.natural;
    this.fitKey = key;

    var probe = this.probe;
    probe.innerHTML = "";
    var groups = {};
    Object.keys(c).forEach(function (k) {
      var g = el("div", "fit-col");
      c[k].forEach(function (p) {
        var line = el("div");
        line.appendChild(el("span", p[0], p[1]));
        g.appendChild(line);
      });
      probe.appendChild(g);
      groups[k] = g;
    });
    var heads = {};
    COLUMNS.forEach(function (col) {
      var g = el("div", "fit-col");
      g.appendChild(el("div", "roster-head", col[1]));
      probe.appendChild(g);
      heads[col[2]] = g;
    });
    var sb = el("div");
    sb.style.cssText = "position:absolute;left:0;top:0;width:100px;height:100px;overflow:scroll;visibility:hidden";
    probe.appendChild(sb);

    var w = function (g) { return g ? g.getBoundingClientRect().width : 0; };
    var px = D.rootPx();
    var widths = {
      name: Math.min(w(groups.name), D.textPx(NAME_MAX_REM)),
      depth: w(groups.tier) + DEPTH_GAP_REM * px + w(groups.pts),
      track: w(groups.track), state: w(groups.state), com: w(groups.com), int: w(groups.int),
      ard: w(groups.ard), exc: w(groups.exc), ori: w(groups.ori)
    };
    var scrollbar = sb.offsetWidth - sb.clientWidth;
    var total = 0;
    var root = this.root;
    COLUMNS.forEach(function (col) {
      var k = col[2];
      var v = Math.ceil(Math.max(widths[k], w(heads[k])) + 1);
      root.style.setProperty("--w-" + k, v + "px");
      total += v;
    });
    probe.innerHTML = "";
    this.natural = Math.ceil(total + (COLUMNS.length - 1) * COL_GAP_REM * px + 2 * COL_PAD_REM * px + scrollbar);
    return this.natural;
  };

  Roster.prototype.makeRow = function () {
    var r = el("div", "row cols");
    r.setAttribute("role", "option");
    var name = el("div", "c-name");
    var nm = el("span", "name");
    var sub = el("span", "name-sub");
    name.appendChild(nm); name.appendChild(sub);

    var depth = el("div", "c-depth");
    var top = el("div", "depth-top");
    var tier = el("span", "tier");
    var pts = el("span", "pts");
    top.appendChild(tier); top.appendChild(pts);
    var bar = el("div", "bar");
    var fill = el("div", "fill");
    bar.appendChild(fill);
    depth.appendChild(top); depth.appendChild(bar);

    function chipCell(cls) {
      var c = el("div", cls);
      var chip = el("span", "chip");
      c.appendChild(chip);
      return chip;
    }
    r.appendChild(name);
    r.appendChild(depth);
    var parts = {
      nm: nm, sub: sub, tier: tier, pts: pts, fill: fill,
      track: chipCell("c-track"), state: chipCell("c-state"), commitment: chipCell("c-com"),
      intimacy: chipCell("c-int"), ardor: chipCell("c-ard"),
      exclusivity: chipCell("c-exc"), orientation: chipCell("c-ori")
    };
    [parts.track, parts.state, parts.commitment, parts.intimacy, parts.ardor, parts.exclusivity, parts.orientation]
      .forEach(function (chip) { r.appendChild(chip.parentNode); });
    // THE LAST CHANGE, under the record (asked for 2026-10-01): a line that
    // starts at the Depth column, so it reads as part of this row and as an
    // account of the depth beside it. After the columns, so the row's
    // children still line up one to one with the header's; positioned in the
    // room .row leaves at its foot.
    var last = el("div", "row-last");
    parts.lastAmount = el("span", "delta");
    parts.lastWhen = el("span", "when");
    parts.lastWhy = el("span", "why");
    last.appendChild(parts.lastAmount);
    last.appendChild(parts.lastWhen);
    last.appendChild(parts.lastWhy);
    r.appendChild(last);
    r._parts = parts;
    return r;
  };

  // The snapshot's game time, which "3 days ago" on each row is measured from.
  Roster.prototype.setNow = function (now) {
    this.now = now;
  };

  Roster.prototype.setData = function (rows, ladder, emptyHtml) {
    var keepKey = this.active >= 0 && this.rows[this.active] ? M.bondKey(this.rows[this.active]) : null;
    this.rows = rows;
    this.ladder = ladder;
    this.spacer.style.height = (rows.length * this.rowH) + "px";
    this.active = -1;
    if (keepKey) {
      for (var i = 0; i < rows.length; i++) if (M.bondKey(rows[i]) === keepKey) { this.active = i; break; }
    }
    if (this.active < 0 && rows.length) this.active = 0;
    if (this.active >= rows.length) this.active = rows.length - 1;
    this.empty.hidden = rows.length > 0;
    this.viewport.hidden = rows.length === 0;
    if (!rows.length) this.empty.innerHTML = emptyHtml || "";
    this.render();
  };

  Roster.prototype.setOpenKey = function (key) {
    this.openKey = key;
    this.render();
  };

  Roster.prototype.schedule = function () {
    var self = this;
    if (this.frame) return;
    this.frame = requestAnimationFrame(function () { self.frame = 0; self.render(); });
  };

  Roster.prototype.render = function () {
    this.spacer.style.height = (this.rows.length * this.rowH) + "px";
    var h = this.viewport.clientHeight || 600;
    var first = Math.max(0, Math.floor(this.viewport.scrollTop / this.rowH) - OVERSCAN);
    var last = Math.min(this.rows.length, Math.ceil((this.viewport.scrollTop + h) / this.rowH) + OVERSCAN);
    var need = last - first;
    while (this.pool.length < need) {
      var r = this.makeRow();
      this.pool.push(r);
      this.spacer.appendChild(r);
    }
    for (var k = 0; k < this.pool.length; k++) {
      var row = this.pool[k];
      var i = first + k;
      if (k >= need) { row.hidden = true; continue; }
      row.hidden = false;
      this.fill(row, this.rows[i], i);
    }
    var activeRow = this.active >= 0 ? "roster-row-" + this.active : "";
    if (activeRow) this.viewport.setAttribute("aria-activedescendant", activeRow);
    else this.viewport.removeAttribute("aria-activedescendant");
  };

  Roster.prototype.fill = function (row, b, i) {
    var p = row._parts;
    row.style.transform = "translateY(" + (i * this.rowH) + "px)";
    row.setAttribute("data-index", String(i));
    row.id = "roster-row-" + i;
    var key = M.bondKey(b);
    var isOpen = key === this.openKey;
    row.className = "row cols" + (i === this.active ? " is-active" : "") + (isOpen ? " is-open" : "");
    row.setAttribute("aria-selected", isOpen ? "true" : "false");

    p.nm.textContent = b.subject.name;
    p.sub.textContent = b.following ? "Following" : (b.enrollment.by === "player" ? "Enrolled by you" : "");
    p.sub.className = "name-sub" + (b.following ? " tag-follow" : "");

    var prog = M.progress(b, this.ladder);
    p.tier.textContent = L.tierName(b.track, b.depth.tier);
    p.tier.className = "tier t-" + b.track;
    p.pts.textContent = L.number(b.depth.points) + " · " + prog.note;
    p.fill.style.width = Math.round(prog.pct * 100) + "%";
    p.fill.className = "fill t-" + b.track + (prog.held ? " is-held" : "");

    p.track.textContent = L.TRACKS[b.track].label;
    p.track.className = "chip t-" + b.track;
    // Only a spoken state gets a chip in player mode (mode.js). No chip is the
    // ordinary case: nothing has been said between them either way.
    var shown = UI.mode.shownState(b);
    p.state.hidden = !shown;
    p.state.textContent = shown ? L.stateLabel(shown, b) : "";
    p.state.className = "chip s-" + (shown || "none");
    p.state.title = shown === "foreclosed" ? L.FORECLOSURE[b.foreclosure] : "";

    // Commitment is a recorded fact (MARAS, vanilla marriage), shown in both
    // modes - the detail does too. Not for a foreclosed pair, as there.
    var com = b.state !== "foreclosed" ? L.COMMITMENT_CHIP[b.commitment] : null;
    p.commitment.hidden = !com;
    p.commitment.textContent = com ? com.label : "";
    p.commitment.className = "chip k-" + (com ? b.commitment : "none");
    p.commitment.title = com ? com.hint : "";

    var dev = UI.mode.developer;
    var newest = L.visibleChanges(b.history, dev)[0];
    p.lastAmount.textContent = newest ? L.changeAmount(newest) : "";
    p.lastAmount.className = "delta" + (newest ? " " + L.changeClass(newest) : "");
    p.lastWhen.textContent = newest ? L.daysAgo(newest.day, this.now) : "";
    p.lastWhy.textContent = newest ? L.changeText(newest, dev) : "";
    p.lastWhy.parentNode.title = newest ? L.changeText(newest, dev) : "";

    var t = b.traits;
    var dflt = t.authored ? "" : " is-default";
    var dfltHint = t.authored ? "" : "Not authored yet: this is the default, not a judgement.";
    // Foreclosed pairs are never on the romantic axis (design 5.2): no
    // intimacy, exclusivity or orientation for them, only how they show what
    // they feel.
    var romanticAxis = b.state !== "foreclosed";
    setChip(p.intimacy, romanticAxis ? L.INTIMACY[t.intimacy] : "—", romanticAxis ? dflt : " is-na", romanticAxis ? dfltHint : "Not on the romantic axis");
    setChip(p.ardor, L.ARDOR[t.ardor], dflt, dfltHint);
    setChip(p.exclusivity, romanticAxis ? L.exclusivityWord(t.exclusivity) + " " + t.exclusivity : "—", romanticAxis ? dflt : " is-na", romanticAxis ? dfltHint : "Not on the romantic axis");
    var o = L.orientationChip(t);
    setChip(p.orientation, romanticAxis ? o.text : "—", romanticAxis ? dflt : " is-na", romanticAxis ? (dfltHint || o.hint) : "Not on the romantic axis");
  };

  function setChip(chip, text, extra, hint) {
    chip.textContent = text;
    chip.className = "chip trait" + extra;
    chip.title = hint || "";
  }

  Roster.prototype.visibleCount = function () {
    return Math.max(1, Math.floor((this.viewport.clientHeight || 600) / this.rowH));
  };

  Roster.prototype.setActive = function (i, scroll) {
    if (!this.rows.length) return;
    this.active = Math.max(0, Math.min(this.rows.length - 1, i));
    if (scroll) {
      var top = this.active * this.rowH;
      var vh = this.viewport.clientHeight;
      if (top < this.viewport.scrollTop) this.viewport.scrollTop = top;
      else if (top + this.rowH > this.viewport.scrollTop + vh) this.viewport.scrollTop = top + this.rowH - vh;
    }
    this.render();
  };

  Roster.prototype.open = function (i) {
    var b = this.rows[i];
    if (b) this.onOpen(b);
  };

  Roster.prototype.key = function (e) {
    var k = e.key;
    var page = this.visibleCount();
    var handled = true;
    if (k === "ArrowDown" || k === "Down") this.setActive(this.active + 1, true);
    else if (k === "ArrowUp" || k === "Up") this.setActive(this.active - 1, true);
    else if (k === "PageDown") this.setActive(this.active + page, true);
    else if (k === "PageUp") this.setActive(this.active - page, true);
    else if (k === "Home") this.setActive(0, true);
    else if (k === "End") this.setActive(this.rows.length - 1, true);
    else if (k === "Enter" || k === " " || k === "Spacebar") this.open(this.active);
    else handled = false;
    if (handled) e.preventDefault();
  };

  Roster.prototype.focus = function () {
    if (!this.viewport.hidden) this.viewport.focus();
  };

  Roster.prototype.revealKey = function (key) {
    for (var i = 0; i < this.rows.length; i++) {
      if (M.bondKey(this.rows[i]) === key) { this.setActive(i, true); return true; }
    }
    return false;
  };

  UI.Roster = Roster;
})(window.SNRomUI = window.SNRomUI || {});
