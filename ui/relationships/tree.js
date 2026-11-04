/* tree.js - the player's family tree (2.6).

   THE AUTHOR, 2026-11-04: a harem playthrough has 18 spouses and 77 children,
   and no tree drawn all at once is legible at that size. So two views:

   - THE OVERVIEW, opening first: you, then one card per partner, in a grid
     that wraps - every spouse, children or not, then former spouses, the
     other parents of your children, and children of yours alone. Each card
     has a few of the children's faces.
   - A BRANCH, from a card: a real tree for you and that partner. Your
     children together, born or adopted; their own children by others, set
     apart; and every child's children after them, as deep as the game's
     records go. Pan by dragging and zoom by buttons, only when it overflows:
     a wheel may not reach the page in every host, and VR has none.

   The data is Family::Tree (Family.h), asked for when the view opens and
   never polled. Clicking anyone enrolled opens their card; anyone else is
   only drawn. Colours of the frames say what each is to you; the legend
   under the tree says which is which. */

(function (UI) {
  "use strict";

  var t = UI.t;
  var FACE_PX = [48, 64, 96, 128, 160, 192, 256];
  var FACE_REM = 3.4;     // .ft-face in style.css

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }

  // ------------------------------------------------------------ the data
  var waiting = null;     // resolve, while a tree is asked for
  snrom.on("familyTree", function (p) {
    if (waiting) { var w = waiting; waiting = null; w(p); }
  });

  // FACES: thumbnails at one size, shared with nothing else. src by form id,
  // "" for nobody's; slots waiting by form id.
  var px = 0;
  var faces = {};
  var asked = {};
  snrom.on("thumbnails", function (p) {
    if (!p || p.px !== px || !p.items) return;
    p.items.forEach(function (it) {
      faces[it.formId] = typeof it.src === "string" ? it.src : "";
      var slots = document.querySelectorAll(".ft-face[data-face='" + it.formId + "']");
      Array.prototype.forEach.call(slots, function (s) { paintFace(s, faces[it.formId]); });
    });
  });
  function facePx() {
    var root = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16;
    var tv = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--t")) || 1;
    var want = FACE_REM * root * tv * (window.devicePixelRatio || 1);
    for (var i = 0; i < FACE_PX.length; i++) if (FACE_PX[i] >= want) return FACE_PX[i];
    return FACE_PX[FACE_PX.length - 1];
  }
  function askFaces(ids) {
    var p = facePx();
    if (p !== px) { px = p; faces = {}; asked = {}; }
    var want = ids.filter(function (id) { return id && !(id in faces) && !asked[id]; });
    if (!want.length) return;
    want.forEach(function (id) { asked[id] = true; });
    for (var i = 0; i < want.length; i += 200) {
      snrom.request("thumbnails", { formIds: want.slice(i, i + 200), px: px });
    }
  }
  function initials(name) {
    var parts = String(name || "").split(/[\s-]+/).filter(function (s) { return s; });
    if (!parts.length) return "?";
    return (parts[0].charAt(0) + (parts.length > 1 ? parts[parts.length - 1].charAt(0) : "")).toUpperCase();
  }
  // A child with no body in the world yet: a swaddled baby, drawn here.
  var BABY = '<svg viewBox="0 0 64 64" aria-hidden="true"><ellipse cx="32" cy="40" rx="15" ry="19" fill="currentColor" opacity="0.35"/>' +
    '<circle cx="32" cy="22" r="10" fill="currentColor" opacity="0.6"/><path d="M19 34c8 5 18 5 26 0" stroke="currentColor" stroke-width="2.5" fill="none" opacity="0.7"/></svg>';
  function paintFace(slot, src) {
    var name = slot.getAttribute("data-name") || "";
    slot.innerHTML = "";
    if (src) {
      var img = document.createElement("img");
      img.src = src;
      img.alt = "";
      slot.appendChild(img);
    } else {
      slot.appendChild(el("span", "ft-initials", initials(name)));
    }
  }
  function face(person, cls) {
    var slot = el("span", "ft-face" + (cls ? " " + cls : ""));
    slot.setAttribute("data-name", person.name || "");
    if (!person.formId) {
      slot.className += " is-record";
      slot.innerHTML = BABY;
      return slot;
    }
    slot.setAttribute("data-face", String(person.formId));
    paintFace(slot, faces[person.formId] || "");
    return slot;
  }

  // ------------------------------------------------------------ words
  function sexed(sex, f, m, x) { return sex === "female" ? f : sex === "male" ? m : x; }

  function statusWords(p) {
    var s = p.sex;
    switch (p.status) {
      case "married": return sexed(s, t("kin.wife", "Your wife"), t("kin.husband", "Your husband"), t("kin.spouse", "Your spouse"));
      case "separated": return t("kin.separated", "{0}, separated", sexed(s, t("kin.wife", "Your wife"), t("kin.husband", "Your husband"), t("kin.spouse", "Your spouse")));
      case "engaged": return t("tree.engaged", "Engaged to you");
      case "divorced": return sexed(s, t("tree.formerWife", "Your former wife"), t("tree.formerHusband", "Your former husband"), t("tree.formerSpouse", "Your former spouse"));
      case "late": return sexed(s, t("tree.lateWife", "Your late wife"), t("tree.lateHusband", "Your late husband"), t("tree.lateSpouse", "Your late spouse"));
      case "coparent": return sexed(s, t("tree.motherOf", "Mother of your children"), t("tree.fatherOf", "Father of your children"), t("tree.parentOf", "Parent of your children"));
      default: return t("tree.aloneWhat", "Children with no other parent");
    }
  }
  function partnerName(p) { return p.status === "alone" ? t("tree.alone", "Yours alone") : p.name; }

  var STAGES = null;
  function stageWord(stage) {
    STAGES = STAGES || [t("stage.newborn", "newborn"), t("stage.infant", "infant"), t("stage.toddler", "toddler"),
      t("stage.child", "child"), t("stage.adolescent", "adolescent"), t("stage.grown", "grown")];
    return stage >= 0 && stage < STAGES.length ? STAGES[stage] : "";
  }

  // What a person in a branch is to you: "Your daughter", "Your adopted son",
  // "Your granddaughter"; a partner's child by someone else, "Daighre's
  // daughter", and their children, "Daighre's granddaughter".
  function relationWords(n, depth, ofPartner) {
    var s = n.sex;
    if (ofPartner) {
      if (depth === 1) return sexed(s, t("tree.theirDaughter", "{0}'s daughter", ofPartner), t("tree.theirSon", "{0}'s son", ofPartner), t("tree.theirChild", "{0}'s child", ofPartner));
      var g = "";
      for (var j = 2; j < depth; j++) g += t("kin.great", "great-");
      return sexed(s, t("tree.theirGranddaughter", "{0}'s {1}granddaughter", ofPartner, g), t("tree.theirGrandson", "{0}'s {1}grandson", ofPartner, g), t("tree.theirGrandchild", "{0}'s {1}grandchild", ofPartner, g));
    }
    if (depth === 1) {
      if (n.kind === "adopted") return sexed(s, t("kin.adoptedDaughter", "Your adopted daughter"), t("kin.adoptedSon", "Your adopted son"), t("kin.adoptedChild", "Your adopted child"));
      return sexed(s, t("kin.daughter", "Your daughter"), t("kin.son", "Your son"), t("kin.child", "Your child"));
    }
    var greats = "";
    for (var i = 2; i < depth; i++) greats += t("kin.great", "great-");
    return sexed(s, t("kin.granddaughter", "Your {0}granddaughter", greats), t("kin.grandson", "Your {0}grandson", greats), t("kin.grandchild", "Your {0}grandchild", greats));
  }

  function countWords(n) {
    return n === 0 ? t("tree.noChildren", "No children together") : n === 1 ? t("tree.oneChild", "1 child") : t("tree.children", "{0} children", n);
  }

  // Everyone under a list of people, depth first.
  function walk(list, fn, depth) {
    (list || []).forEach(function (n) { fn(n, depth || 1); walk(n.children, fn, (depth || 1) + 1); });
  }

  // ------------------------------------------------------------ the view
  // ctx: { snap, focus (a form id, or null), openBond(formId) }
  function build(ctx) {
    var root = el("div", "ft-root");
    var data = null;
    var at = -1;            // -1 the overview, else the branch shown
    var found = null;       // the person to highlight once drawn
    var scale = 1;
    var enrolled = {};
    ((ctx.snap && ctx.snap.bonds) || []).forEach(function (b) { enrolled[b.subject.formId] = true; });

    var bar = el("div", "ft-bar");
    var findWrap = el("div", "ft-find");
    var find = el("input", "ft-find-input");
    find.type = "text";
    find.placeholder = t("tree.find", "Find someone in the family");
    find.setAttribute("aria-label", t("tree.find", "Find someone in the family"));
    find.autocomplete = "off";
    find.spellcheck = false;
    var results = el("div", "ft-results");
    results.hidden = true;
    findWrap.appendChild(find);
    findWrap.appendChild(results);
    bar.appendChild(findWrap);
    var navBox = el("div", "ft-nav");
    bar.appendChild(navBox);
    root.appendChild(bar);
    var stage = el("div", "ft-stage");
    root.appendChild(stage);
    var legend = el("div", "ft-legend");
    root.appendChild(legend);

    var loadingP = el("p", "ft-none", t("tree.reading", "Reading your family…"));
    stage.appendChild(loadingP);

    // Every person, with the branch they are in, for the search box and
    // for opening on someone.
    var everyone = [];
    function index() {
      everyone = [];
      data.partners.forEach(function (p, i) {
        if (p.status !== "alone") everyone.push({ name: p.name, formId: p.formId, branch: i, key: "p" + i, what: statusWords(p) });
        walk(p.children, function (n, d) { everyone.push({ name: n.name, formId: n.formId, branch: i, key: n._key, what: relationWords(n, d, null) }); });
        walk(p.theirs, function (n, d) { everyone.push({ name: n.name, formId: n.formId, branch: i, key: n._key, what: relationWords(n, d, p.name) }); });
      });
    }
    function keys() {
      var k = 0;
      data.partners.forEach(function (p) {
        walk(p.children, function (n) { n._key = "n" + (k++); });
        walk(p.theirs, function (n) { n._key = "n" + (k++); });
      });
    }

    find.addEventListener("input", function () {
      var q = find.value.trim().toLowerCase();
      results.innerHTML = "";
      if (!q || !data) { results.hidden = true; return; }
      var hits = everyone.filter(function (e) { return e.name && e.name.toLowerCase().indexOf(q) >= 0; }).slice(0, 8);
      if (!hits.length) results.appendChild(el("p", "ft-result-none", t("tree.noMatch", "Nobody in the family by that name.")));
      hits.forEach(function (h) {
        var b = el("button", "ft-result");
        b.type = "button";
        b.appendChild(el("span", "ft-result-name", h.name));
        var p = data.partners[h.branch];
        b.appendChild(el("span", "ft-result-what", h.what + (h.key.charAt(0) === "n" ? " · " + t("tree.inBranch", "{0}'s branch", partnerName(p)) : "")));
        b.addEventListener("click", function () { goTo(h); });
        results.appendChild(b);
      });
      results.hidden = false;
    });
    find.addEventListener("keydown", function (e) {
      if (e.key === "Enter") {
        var first = results.querySelector(".ft-result");
        if (first) { e.preventDefault(); first.click(); }
      } else if (e.key === "Escape" && find.value) {
        e.stopPropagation();
        find.value = "";
        results.hidden = true;
      }
    });

    function goTo(h) {
      find.value = "";
      results.hidden = true;
      found = h.key;
      showBranch(h.branch);
    }

    // -------------------------------------------------------- the overview
    function showOverview() {
      at = -1;
      navBox.innerHTML = "";
      stage.innerHTML = "";
      stage.className = "ft-stage is-overview";
      var you = el("div", "ft-you");
      you.appendChild(face(data.you, "s-you"));
      var yt = el("div", "ft-you-text");
      yt.appendChild(el("span", "ft-name", data.you.name || t("tree.you", "You")));
      var spouses = data.partners.filter(function (p) { return p.status === "married" || p.status === "separated"; }).length;
      var kids = 0;
      data.partners.forEach(function (p) { kids += p.children.length; });
      yt.appendChild(el("span", "ft-what", t("tree.summary", "{0} spouses · {1} children", spouses, kids)));
      you.appendChild(yt);
      stage.appendChild(you);

      var groups = [
        [t("tree.g.spouses", "Spouses"), ["married", "separated", "engaged"]],
        [t("tree.g.former", "Former and late spouses"), ["divorced", "late"]],
        [t("tree.g.coparents", "Other parents of your children"), ["coparent"]],
        [t("tree.g.alone", "Yours alone"), ["alone"]]
      ];
      var ids = [];
      groups.forEach(function (g) {
        var members = [];
        data.partners.forEach(function (p, i) { if (g[1].indexOf(p.status) >= 0) members.push(i); });
        if (!members.length) return;
        stage.appendChild(el("h4", "sub-head ft-group", g[0]));
        var grid = el("div", "ft-grid");
        members.forEach(function (i) {
          var p = data.partners[i];
          var card = el("button", "ft-card s-" + p.status + (p.dead ? " is-dead" : ""));
          card.type = "button";
          if (p.status === "alone") {
            var me = face(data.you, "s-alone");
            card.appendChild(me);
          } else {
            card.appendChild(face(p, "s-" + p.status));
            if (p.formId) ids.push(p.formId);
          }
          var txt = el("span", "ft-card-text");
          txt.appendChild(el("span", "ft-name", partnerName(p)));
          txt.appendChild(el("span", "ft-what", statusWords(p)));
          var count = countWords(p.children.length);
          if (p.theirs.length) count += " · " + t("tree.ofTheirOwn", "{0} of their own", p.theirs.length);
          txt.appendChild(el("span", "ft-count", count));
          card.appendChild(txt);
          if (p.children.length) {
            var strip = el("span", "ft-strip");
            p.children.slice(0, 5).forEach(function (c) {
              strip.appendChild(face(c, "ft-mini k-" + c.kind));
              if (c.formId) ids.push(c.formId);
            });
            if (p.children.length > 5) strip.appendChild(el("span", "ft-more", "+" + (p.children.length - 5)));
            card.appendChild(strip);
          }
          card.addEventListener("click", function () { showBranch(i); });
          grid.appendChild(card);
        });
        stage.appendChild(grid);
      });
      if (!data.partners.length) {
        stage.appendChild(el("p", "ft-none", t("tree.empty", "No spouses or children yet. Marriages in Relationships and children in SkyrimNet Kinship appear here.")));
      }
      if (data.you.formId) ids.push(data.you.formId);
      askFaces(ids);
      drawLegend(false);
    }

    // -------------------------------------------------------- a branch
    function node(n, depth, ofPartner, ids) {
      var can = !!(n.formId && enrolled[n.formId]);
      var box = el(can ? "button" : "div", "ft-node k-" + n.kind + (n.dead ? " is-dead" : "") + (can ? " is-open" : ""));
      if (can) box.type = "button";
      box.setAttribute("data-key", n._key);
      box.appendChild(face(n));
      if (n.formId) ids.push(n.formId);
      box.appendChild(el("span", "ft-name", n.name || t("tree.unnamed", "Unnamed")));
      box.appendChild(el("span", "ft-what", relationWords(n, depth, ofPartner)));
      var bits = [];
      var st = stageWord(n.stage);
      if (st) bits.push(st);
      if (n.dead) bits.push(t("tree.died", "died"));
      if (!n.inWorld) bits.push(t("family.recordOnly", "not yet in the world"));
      if (n.with) bits.push(t("family.with", "with {0}", n.with));
      if (bits.length) box.appendChild(el("span", "ft-stage-word", bits.join(" · ")));
      if (can) {
        box.title = t("tree.openCard", "Open their card");
        box.addEventListener("click", function () { ctx.openBond(n.formId); });
      } else if (n.inWorld) {
        box.title = t("tree.notEnrolled", "Not enrolled in Relationships");
      }
      return box;
    }
    function level(list, depth, ofPartner, ids) {
      var ul = el("ul", "ft-level");
      list.forEach(function (n) {
        var li = el("li");
        li.appendChild(node(n, depth, ofPartner, ids));
        if (n.children && n.children.length) li.appendChild(level(n.children, depth + 1, ofPartner, ids));
        ul.appendChild(li);
      });
      return ul;
    }
    function personNode(p, cls, ids) {
      var can = !!(p.formId && enrolled[p.formId]) && cls !== "s-you";
      var box = el(can ? "button" : "div", "ft-node ft-top " + cls + (p.dead ? " is-dead" : "") + (can ? " is-open" : ""));
      if (can) {
        box.type = "button";
        box.title = t("tree.openCard", "Open their card");
        box.addEventListener("click", function () { ctx.openBond(p.formId); });
      }
      box.setAttribute("data-key", cls === "s-you" ? "you" : "p" + at);
      box.appendChild(face(p, cls));
      if (p.formId) ids.push(p.formId);
      box.appendChild(el("span", "ft-name", cls === "s-you" ? (p.name || t("tree.you", "You")) : partnerName(p)));
      box.appendChild(el("span", "ft-what", cls === "s-you" ? t("tree.you", "You") : statusWords(p)));
      return box;
    }

    var canvas = null, sizer = null, inner = null, zoomBox = null;

    function showBranch(i) {
      at = i;
      var p = data.partners[i];
      navBox.innerHTML = "";
      var back = el("button", "btn btn-quiet", "‹ " + t("tree.allBranches", "All branches"));
      back.type = "button";
      back.addEventListener("click", showOverview);
      var prev = el("button", "btn btn-quiet", "‹");
      prev.type = "button";
      prev.setAttribute("aria-label", t("tree.prev", "Previous branch"));
      prev.disabled = i === 0;
      prev.addEventListener("click", function () { showBranch(i - 1); });
      var next = el("button", "btn btn-quiet", "›");
      next.type = "button";
      next.setAttribute("aria-label", t("tree.next", "Next branch"));
      next.disabled = i === data.partners.length - 1;
      next.addEventListener("click", function () { showBranch(i + 1); });
      var title = el("h3", "ft-title", p.status === "alone" ? t("tree.alone", "Yours alone") : t("tree.youAnd", "You and {0}", p.name));
      zoomBox = el("div", "ft-zoom");
      [["−", t("tree.zoomOut", "Zoom out"), function () { zoom(scale / 1.25); }],
       [t("tree.fit", "Fit"), t("tree.fitAria", "Fit the branch in view"), function () { fit(); }],
       ["+", t("tree.zoomIn", "Zoom in"), function () { zoom(scale * 1.25); }]].forEach(function (z) {
        var b = el("button", "btn btn-quiet", z[0]);
        b.type = "button";
        b.setAttribute("aria-label", z[1]);
        b.addEventListener("click", z[2]);
        zoomBox.appendChild(b);
      });
      navBox.appendChild(back);
      navBox.appendChild(prev);
      navBox.appendChild(title);
      navBox.appendChild(next);
      navBox.appendChild(zoomBox);

      stage.innerHTML = "";
      stage.className = "ft-stage is-branch";
      canvas = el("div", "ft-canvas");
      sizer = el("div", "ft-sizer");
      inner = el("div", "ft-tree");
      var ids = [];

      var main = el("div", "ft-family");
      var couple = el("div", "ft-couple");
      couple.appendChild(personNode(data.you, "s-you", ids));
      if (p.status !== "alone") {
        couple.appendChild(el("span", "ft-bond s-" + p.status));
        couple.appendChild(personNode(p, "s-" + p.status, ids));
      }
      main.appendChild(couple);
      if (p.children.length) main.appendChild(level(p.children, 1, null, ids));
      else main.appendChild(el("p", "ft-none ft-none-small", t("tree.noChildren", "No children together")));
      inner.appendChild(main);

      if (p.theirs.length) {
        var side = el("div", "ft-family ft-theirs");
        side.appendChild(el("h4", "sub-head", t("tree.theirsBy", "{0}'s children by others", p.name)));
        var anchor = el("div", "ft-couple");
        anchor.appendChild(personNode(p, "s-" + p.status, ids));
        side.appendChild(anchor);
        side.appendChild(level(p.theirs, 1, p.name, ids));
        inner.appendChild(side);
      }

      sizer.appendChild(inner);
      canvas.appendChild(sizer);
      stage.appendChild(canvas);
      pan(canvas);
      askFaces(ids);
      drawLegend(true);
      scale = 1;
      // Laid out, then sized and the found one brought into view.
      setTimeout(function () {
        zoom(1);
        if (found) {
          var hit = inner.querySelector("[data-key='" + found + "']");
          found = null;
          if (hit) {
            hit.classList.add("is-found");
            canvas.scrollLeft = Math.max(0, hit.offsetLeft * scale + hit.offsetWidth * scale / 2 - canvas.clientWidth / 2);
            canvas.scrollTop = Math.max(0, hit.offsetTop * scale + hit.offsetHeight * scale / 2 - canvas.clientHeight / 2);
            if (hit.focus) hit.focus();
          }
        }
      }, 0);
    }

    function zoom(to) {
      if (!inner) return;
      scale = Math.max(0.3, Math.min(1.6, to));
      var w = inner.offsetWidth, h = inner.offsetHeight;
      inner.style.transform = "scale(" + scale + ")";
      sizer.style.width = Math.ceil(w * scale) + "px";
      sizer.style.height = Math.ceil(h * scale) + "px";
      // The controls only when there is something to zoom: a branch larger
      // than the view at full size, or one already zoomed.
      var over = w > canvas.clientWidth + 1 || h > canvas.clientHeight + 1;
      zoomBox.hidden = !over && scale === 1;
      canvas.classList.toggle("can-pan", w * scale > canvas.clientWidth + 1 || h * scale > canvas.clientHeight + 1);
    }
    function fit() {
      if (!inner) return;
      var s = Math.min(canvas.clientWidth / inner.offsetWidth, canvas.clientHeight / inner.offsetHeight, 1);
      zoom(s);
      canvas.scrollLeft = 0;
      canvas.scrollTop = 0;
    }

    // Dragging the background pans; a node is still a button.
    function pan(area) {
      var from = null;
      area.addEventListener("mousedown", function (e) {
        if (e.button !== 0 || (e.target.closest && e.target.closest("button"))) return;
        from = { x: e.clientX, y: e.clientY, l: area.scrollLeft, t: area.scrollTop };
        area.classList.add("is-panning");
        e.preventDefault();
      });
      window.addEventListener("mousemove", function (e) {
        if (!from) return;
        area.scrollLeft = from.l - (e.clientX - from.x);
        area.scrollTop = from.t - (e.clientY - from.y);
      });
      window.addEventListener("mouseup", function () { from = null; area.classList.remove("is-panning"); });
      area.addEventListener("wheel", function (e) {
        if (!e.ctrlKey) return;
        e.preventDefault();
        zoom(e.deltaY < 0 ? scale * 1.1 : scale / 1.1);
      });
    }

    function drawLegend(branch) {
      legend.innerHTML = "";
      var items = branch ?
        [["k-born", t("tree.l.born", "Born to you")], ["k-adopted", t("tree.l.adopted", "Adopted")],
         ["k-theirs", t("tree.l.theirs", "Their child by another")], ["k-descendant", t("tree.l.descendant", "Later generations")]] :
        [["s-married", t("tree.l.married", "Spouse")], ["s-engaged", t("tree.l.engaged", "Engaged")],
         ["s-divorced", t("tree.l.former", "Former or late spouse")], ["s-coparent", t("tree.l.coparent", "Other parent")]];
      items.forEach(function (it) {
        var i = el("span", "ft-key");
        i.appendChild(el("span", "ft-swatch " + it[0]));
        i.appendChild(el("span", "", it[1]));
        legend.appendChild(i);
      });
      if (branch) legend.appendChild(el("span", "ft-key ft-key-hint", t("tree.hint", "Click anyone enrolled to open their card.")));
    }

    waiting = function (payload) {
      data = payload && payload.partners ? payload : { you: { formId: 0, name: "" }, partners: [] };
      data.you = data.you || { formId: 0, name: "" };
      keys();
      index();
      // Opened on someone (a card's "Show in family tree"): their branch,
      // and them found in it.
      if (ctx.focus) {
        var hit = everyone.filter(function (e) { return e.formId === ctx.focus; })[0];
        if (hit) { goTo(hit); return; }
      }
      showOverview();
    };
    snrom.request("familyTree", {}).then(function (r) {
      if (!r.ok && waiting) { waiting = null; loadingP.textContent = r.message || t("tree.failed", "The family could not be read."); }
    });
    return root;
  }

  // Whether a bond belongs on the tree: a spouse of any kind, or a child or
  // later descendant of the player's, or a parent of the player's children.
  function onTree(b) {
    var m = b.marriage;
    if (m && ["married", "separated", "engaged", "divorced", "widowed"].indexOf(m.state) >= 0) return true;
    if (b.kin && b.kin.generation) return true;
    var fam = b.family;
    return !!(fam && fam.children && fam.children.some(function (c) { return c.withPlayer; }));
  }

  UI.tree = { build: build, onTree: onTree };
})(window.SNRomUI = window.SNRomUI || {});
