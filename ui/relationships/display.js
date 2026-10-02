/* display.js - how big the page is drawn: the SkyrimNet settings dashboardScale
   and dashboardTextSize, which arrive in every snapshot as settings.scale and
   settings.textSize, exactly as settings.developer does (mode.js).

   TWO KNOBS, ONE RULE EACH:
     - the scale sizes everything, text and spacing alike. It is the root font
       size, and every length in style.css is in rem. Auto follows the view's
       height, with 1080 as 100%, so the page looks the same at 1080p, 1440p
       (about 133%) or 4K; a fixed choice ignores the height;
     - the text size, on top of the scale, sizes the text and the boxes that
       hold it (the columns, rows, fields and panels), but not the spacing
       around them. It is --t in style.css, a factor every font size and every
       text box is multiplied by.

   Until the first snapshot the page is drawn at Auto and Normal, the settings'
   defaults, which is what the DLL starts from too. */

(function (UI) {
  "use strict";

  // 100% is a 16px root at 1080 lines. Auto stays within the fixed choices,
  // 75% to 200%: below 75% the text stops being readable, and a view taller
  // than 2160 lines is not a screen anyone plays on.
  var BASE_PX = 16;
  var BASE_HEIGHT = 1080;
  var AUTO_MIN = 0.75;
  var AUTO_MAX = 2;

  // dashboardTextSize, as the DLL names it in the snapshot.
  var TEXT = { normal: 1, large: 1.15, larger: 1.3 };

  // A row's height, in rem of text, before --t (roster.js reads the result):
  // the record's 3.5, and 1.1 for its last change underneath (.row-last).
  var ROW_REM = 4.6;

  var scale = "auto";   // "auto", or a percent
  var textSize = "normal";
  var listeners = [];
  var applied = "";

  function factor() {
    if (scale === "auto") {
      var h = window.innerHeight || BASE_HEIGHT;
      return Math.max(AUTO_MIN, Math.min(AUTO_MAX, h / BASE_HEIGHT));
    }
    return scale / 100;
  }

  function text() { return TEXT[textSize] || 1; }

  // The root font size in px: one rem, at the current scale.
  function rootPx() { return BASE_PX * factor(); }

  // A length in rem of text (a column, a panel), in px: rem times --t.
  function textPx(rem) { return rem * rootPx() * text(); }

  // Sets the root font size, --t and --row-h, and tells whoever listens when
  // any of them moved. A resize moves Auto; a snapshot may move either.
  function draw() {
    var root = document.documentElement;
    var px = rootPx();
    var t = text();
    var row = Math.round(ROW_REM * px * t);
    var key = px.toFixed(3) + "|" + t + "|" + row;
    if (key === applied) return false;
    applied = key;
    root.style.fontSize = px.toFixed(3) + "px";
    root.style.setProperty("--t", String(t));
    root.style.setProperty("--row-h", row + "px");
    listeners.forEach(function (fn) { fn(); });
    return true;
  }

  // Takes the game's settings from a snapshot. A value the page cannot use (a
  // scale that is neither "auto" nor a percent from 50 to 300, or a text size
  // it does not know) leaves that setting as it was: the DLL sends only the
  // manifest's options, so anything else comes from a newer DLL than this
  // page, and guessing would be worse.
  function apply(snapshot) {
    var s = snapshot && snapshot.settings;
    if (s) {
      if (s.scale === "auto" || (typeof s.scale === "number" && s.scale >= 50 && s.scale <= 300)) scale = s.scale;
      if (Object.prototype.hasOwnProperty.call(TEXT, s.textSize)) textSize = s.textSize;
    }
    return draw();
  }

  window.addEventListener("resize", function () { if (scale === "auto") draw(); });

  UI.display = {
    apply: apply,
    draw: draw,
    rootPx: rootPx,
    textPx: textPx,
    text: text,
    scale: function () { return scale; },
    textSize: function () { return textSize; },
    onChange: function (fn) { listeners.push(fn); }
  };
  draw();
})(window.SNRomUI = window.SNRomUI || {});
