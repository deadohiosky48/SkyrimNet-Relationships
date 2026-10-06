/* picker.js - every <select> opens our own list, never the engine's.

   WHY. A <select>'s list is a popup the browser engine draws itself, outside
   the page. Under Magelight UI, clicking the Following filter's arrow overran
   the stack in Magelight's frame work (SEH 0xC00000FD, 2026-10-06), and
   Magelight turns its overlay off for the rest of the session after that: no
   dashboard until the game restarts. Magelight renders Ultralight on the
   game's present thread, and the engine's popup path is the one part of the
   page that leaves the DOM. So the page never asks for it, under any host.

   HOW. The <select> stays where it is and keeps the value: everything else
   reads .value and listens for "change" exactly as before. Only the opening
   is ours. A mouse press or an opening key on a select is stopped before the
   engine sees it (its default action is the popup), and a plain list of
   buttons is drawn under the select instead. Choosing sets .value and fires
   "change". Arrow keys on a closed select step its value, as a select's own
   arrows do, without opening anything.

   Listeners sit on window in the capture phase, so selects made later (the
   detail panel's trait form) are covered with no setup. */

(function (UI) {
  "use strict";

  var list = null;     // the open list, or null
  var owner = null;    // the select it belongs to
  var active = -1;     // the highlighted option's index

  function isSelect(t) { return !!t && t.tagName === "SELECT" && !t.disabled; }

  function fireChange(sel) {
    var ev;
    try { ev = new Event("change", { bubbles: true }); }
    catch (e) { ev = document.createEvent("HTMLEvents"); ev.initEvent("change", true, false); }
    sel.dispatchEvent(ev);
  }

  function choose(i) {
    var sel = owner;
    close();
    if (!sel) return;
    sel.focus();
    if (i < 0 || i >= sel.options.length || i === sel.selectedIndex) return;
    sel.selectedIndex = i;
    fireChange(sel);
  }

  function step(sel, by) {
    var i = sel.selectedIndex + by;
    while (i >= 0 && i < sel.options.length && sel.options[i].disabled) i += by;
    if (i < 0 || i >= sel.options.length) return;
    sel.selectedIndex = i;
    fireChange(sel);
  }

  function highlight(i) {
    if (!list) return;
    var items = list.children;
    if (i < 0 || i >= items.length) return;
    if (active >= 0 && items[active]) items[active].className = "picker-item";
    active = i;
    items[i].className = "picker-item is-active";
    var top = items[i].offsetTop, bottom = top + items[i].offsetHeight;
    if (top < list.scrollTop) list.scrollTop = top;
    else if (bottom > list.scrollTop + list.clientHeight) list.scrollTop = bottom - list.clientHeight;
  }

  function open(sel) {
    close();
    owner = sel;
    list = document.createElement("div");
    list.className = "picker";
    list.setAttribute("role", "listbox");
    for (var i = 0; i < sel.options.length; i++) {
      var o = sel.options[i];
      var item = document.createElement("button");
      item.type = "button";
      item.className = "picker-item";
      item.setAttribute("role", "option");
      item.setAttribute("data-i", String(i));
      item.tabIndex = -1;
      item.disabled = o.disabled;
      item.textContent = o.textContent;
      if (i === sel.selectedIndex) item.setAttribute("aria-selected", "true");
      list.appendChild(item);
    }
    document.body.appendChild(list);

    // Under the select, at least as wide; above it when there is no room below.
    var r = sel.getBoundingClientRect();
    var vh = window.innerHeight, vw = window.innerWidth;
    list.style.minWidth = r.width + "px";
    var h = list.offsetHeight, w = list.offsetWidth;
    var top = r.bottom + 2;
    if (top + h > vh - 4 && r.top - 2 - h >= 4) top = r.top - 2 - h;
    list.style.top = Math.max(4, Math.min(top, vh - h - 4)) + "px";
    list.style.left = Math.max(4, Math.min(r.left, vw - w - 4)) + "px";

    active = -1;
    highlight(Math.max(0, sel.selectedIndex));
  }

  function close() {
    if (list && list.parentNode) list.parentNode.removeChild(list);
    list = null; owner = null; active = -1;
  }

  // Mouse: a press on a select opens or closes ours; a press elsewhere closes.
  window.addEventListener("mousedown", function (e) {
    var t = e.target;
    if (list && list.contains(t)) { e.preventDefault(); return; }   // keep focus; the click chooses
    if (isSelect(t)) {
      e.preventDefault();
      e.stopPropagation();
      var again = owner === t;
      close();
      t.focus();
      if (!again) open(t);
      return;
    }
    if (list) close();
  }, true);

  window.addEventListener("click", function (e) {
    if (!list) return;
    var t = e.target;
    while (t && t !== list && !(t.getAttribute && t.getAttribute("data-i") !== null)) t = t.parentNode;
    if (t && t !== list) { e.preventDefault(); e.stopPropagation(); choose(parseInt(t.getAttribute("data-i"), 10)); }
  }, true);

  window.addEventListener("mousemove", function (e) {
    if (!list) return;
    var t = e.target;
    if (t && t.parentNode === list && !t.disabled) {
      var i = parseInt(t.getAttribute("data-i"), 10);
      if (i !== active) highlight(i);
    }
  }, true);

  // Keys. Everything a select would answer is answered here first.
  window.addEventListener("keydown", function (e) {
    var k = e.key;
    if (list) {
      var stop = true;
      if (k === "ArrowDown" || k === "Down") {
        var d = active + 1; while (d < list.children.length && list.children[d].disabled) d++; highlight(d);
      } else if (k === "ArrowUp" || k === "Up") {
        var u = active - 1; while (u >= 0 && list.children[u].disabled) u--; highlight(u);
      } else if (k === "Home") { highlight(0); }
      else if (k === "End") { highlight(list.children.length - 1); }
      else if (k === "Enter" || k === " " || k === "Spacebar") { choose(active); }
      else if (k === "Escape" || k === "Esc") { var s = owner; close(); if (s) s.focus(); }
      else if (k === "Tab") { close(); stop = false; }
      else stop = false;
      if (stop) { e.preventDefault(); e.stopImmediatePropagation(); }
      return;
    }
    var t = e.target;
    if (!isSelect(t)) return;
    if (k === "Enter" || k === " " || k === "Spacebar" || k === "F4" ||
        (e.altKey && (k === "ArrowDown" || k === "Down" || k === "ArrowUp" || k === "Up"))) {
      e.preventDefault(); e.stopImmediatePropagation(); open(t);
    } else if (k === "ArrowDown" || k === "Down" || k === "ArrowRight" || k === "Right") {
      e.preventDefault(); e.stopImmediatePropagation(); step(t, 1);
    } else if (k === "ArrowUp" || k === "Up" || k === "ArrowLeft" || k === "Left") {
      e.preventDefault(); e.stopImmediatePropagation(); step(t, -1);
    } else if (k === "Home" || k === "End" || k === "PageUp" || k === "PageDown") {
      e.preventDefault(); e.stopImmediatePropagation();
    }
  }, true);

  // Anything that moves the select away from the list closes it.
  window.addEventListener("resize", close);
  window.addEventListener("blur", close);
  window.addEventListener("scroll", function (e) {
    if (list && e.target !== list) close();
  }, true);

  UI.picker = { close: close, isOpen: function () { return !!list; } };
})(window.SNRomUI = window.SNRomUI || {});
