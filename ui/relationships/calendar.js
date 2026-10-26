/* calendar.js - Tamriel's calendar, with what Relationships knows to put on it.

   THE AUTHOR, 2026-10-26: a calendar in our own view, for weddings now and for
   dating later. Built from the snapshot's calendar block (Model.cpp: today's
   year, month, day, weekday and game day, as the engine keeps them), so every
   date here is the game's own. Anything the snapshot dates in game days - a
   wedding plan's day, the day a marriage was made - is placed by counting days
   from today across the months' real lengths.

   WHAT IS ON IT: planned weddings, with the hour and the place; anniversaries
   of every marriage in Relationships' record; the player's children's
   birthdays, from Kinship (1.10); and the holidays of Tamriel. New
   kinds of appointment (dates, the reception) add themselves in eventsFor. */

(function (UI) {
  "use strict";

  var t = UI.t;

  // The Fourth Era's months, as Calendar::Month numbers them (0 Morning Star).
  var LENGTHS = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  function monthNames() {
    return [t("cal.month.0", "Morning Star"), t("cal.month.1", "Sun's Dawn"), t("cal.month.2", "First Seed"),
      t("cal.month.3", "Rain's Hand"), t("cal.month.4", "Second Seed"), t("cal.month.5", "Midyear"),
      t("cal.month.6", "Sun's Height"), t("cal.month.7", "Last Seed"), t("cal.month.8", "Hearthfire"),
      t("cal.month.9", "Frostfall"), t("cal.month.10", "Sun's Dusk"), t("cal.month.11", "Evening Star")];
  }
  function weekdayNames() {
    return [t("cal.day.0", "Sundas"), t("cal.day.1", "Morndas"), t("cal.day.2", "Tirdas"), t("cal.day.3", "Middas"),
      t("cal.day.4", "Turdas"), t("cal.day.5", "Fredas"), t("cal.day.6", "Loredas")];
  }

  // The holidays of Tamriel, kept in Skyrim's time: [month, day, name].
  function holidays() {
    return [
      [0, 1, t("cal.h.newLife", "New Life Festival")], [0, 15, t("cal.h.southWind", "South Wind's Prayer")],
      [1, 16, t("cal.h.heartsDay", "Heart's Day")], [2, 7, t("cal.h.firstPlanting", "First Planting")],
      [3, 28, t("cal.h.jestersDay", "Jester's Day")], [4, 7, t("cal.h.secondPlanting", "Second Planting")],
      [5, 16, t("cal.h.midYear", "Mid Year Celebration")], [6, 10, t("cal.h.merchants", "Merchants' Festival")],
      [6, 20, t("cal.h.sunsRest", "Sun's Rest")], [7, 27, t("cal.h.harvestsEnd", "Harvest's End")],
      [8, 3, t("cal.h.talesTallows", "Tales and Tallows")], [9, 13, t("cal.h.witches", "Witches' Festival")],
      [10, 20, t("cal.h.warriors", "Warriors' Festival")], [11, 15, t("cal.h.northWind", "North Wind's Prayer")],
      [11, 25, t("cal.h.saturalia", "Saturalia")], [11, 31, t("cal.h.oldLife", "Old Life")]
    ];
  }

  // Days from the first of Morning Star, year 0, to (year, month, day): an
  // absolute count, so two dates' difference is days between them.
  function ordinal(year, month, day) {
    var n = year * 365;
    for (var m = 0; m < month; m++) n += LENGTHS[m];
    return n + day - 1;
  }

  function fromOrdinal(n) {
    var year = Math.floor(n / 365);
    var rest = n - year * 365;
    var month = 0;
    while (rest >= LENGTHS[month]) { rest -= LENGTHS[month]; month++; }
    return { year: year, month: month, day: rest + 1 };
  }

  // The calendar's anchor: today, from the snapshot. Null without one (a
  // snapshot from before 2.5, or a mock without a game).
  function today(snap) {
    var c = snap && snap.calendar;
    if (!c || typeof c.gameDay !== "number") return null;
    return { year: c.year, month: c.month, day: c.day, weekday: c.weekday, hour: c.hour,
      gameDay: Math.floor(c.gameDay), ord: ordinal(c.year, c.month, c.day) };
  }

  // A game day (Calendar::GetCurrentGameTime) as a date.
  function dateOfGameDay(now, gameDay) {
    return fromOrdinal(now.ord + (Math.floor(gameDay) - now.gameDay));
  }

  function weekdayOf(now, year, month, day) {
    var diff = ordinal(year, month, day) - now.ord;
    return (((now.weekday + diff) % 7) + 7) % 7;
  }

  function hourWords(hour) {
    if (hour < 0) return "";
    return hour < 11 ? t("cal.morning", "in the morning") : hour < 14 ? t("cal.noon", "at noon") :
      hour < 17 ? t("cal.afternoon", "in the afternoon") : hour < 21 ? t("cal.evening", "in the evening") : t("cal.night", "at night");
  }

  // Everything on a given month: { day: [ { kind, text } ] }.
  function eventsFor(snap, now, year, month) {
    var out = {};
    function add(day, kind, text) { (out[day] = out[day] || []).push({ kind: kind, text: text }); }
    holidays().forEach(function (h) { if (h[0] === month) add(h[1], "holiday", h[2]); });
    // The player's children (Kinship): each birthday, every year after the
    // year they were born.
    ((snap.calendar && snap.calendar.children) || []).forEach(function (c) {
      // Only a real birth day: a child taken into Kinship's record by hand,
      // in a sweep or by adoption has the day it was recorded, and 23 of the
      // author's would all have shared one (2026-10-25).
      if (!c.born || !c.bornKnown) return;
      var b = dateOfGameDay(now, c.born);
      if (b.month !== month || year < b.year) return;
      var age = year - b.year;
      var text = age === 0 ? t("cal.born", "{0} was born", c.name) :
        t("cal.birthday", "{0} turns {1}", c.name, age);
      if (c.otherParent) text += " " + t("cal.withParent", "(with {0})", c.otherParent);
      add(b.day, "birthday", text);
    });
    (snap.bonds || []).forEach(function (b) {
      var m = b.marriage;
      if (!m) return;
      var name = b.subject.name;
      // A planned wedding, on its day.
      if (m.plan && m.plan.day !== null && m.plan.day !== undefined) {
        var w = dateOfGameDay(now, m.plan.day);
        if (w.year === year && w.month === month) {
          var when = hourWords(m.plan.hour);
          add(w.day, "wedding", t("cal.wedding", "Your wedding to {0}", name) +
            (when ? " " + when : "") + (m.plan.place ? ", " + t("cal.at", "at {0}", m.plan.place) : ""));
        }
      }
      // Anniversaries of a marriage, every year after the first.
      if ((m.state === "married" || m.state === "separated") && m.weddingDay) {
        var d = dateOfGameDay(now, m.weddingDay);
        if (d.month === month && year > d.year) {
          var years = year - d.year;
          add(d.day, "anniversary", years === 1 ? t("cal.anniversary1", "A year married to {0}", name) :
            t("cal.anniversary", "{0} years married to {1}", years, name));
        } else if (d.month === month && year === d.year) {
          add(d.day, "anniversary", t("cal.married", "You married {0}", name));
        }
      }
    });
    return out;
  }

  // The view: a month at a time, opening on today's.
  function build(snap) {
    var now = today(snap);
    var root = document.createElement("div");
    root.className = "cal";
    if (!now) {
      var p = document.createElement("p");
      p.className = "cal-none";
      p.textContent = t("cal.none", "The calendar needs the game: open the dashboard in play.");
      root.appendChild(p);
      return root;
    }
    var shown = { year: now.year, month: now.month };
    var picked = now.day;

    function el(tag, cls, text) {
      var e = document.createElement(tag);
      if (cls) e.className = cls;
      if (text !== undefined) e.textContent = text;
      return e;
    }

    function draw() {
      root.innerHTML = "";
      var nav = el("div", "cal-nav");
      var prev = el("button", "btn btn-quiet", "‹");
      prev.type = "button";
      prev.setAttribute("aria-label", t("cal.prev", "Previous month"));
      var next = el("button", "btn btn-quiet", "›");
      next.type = "button";
      next.setAttribute("aria-label", t("cal.next", "Next month"));
      var title = el("h3", "cal-title", monthNames()[shown.month] + ", 4E " + shown.year);
      var back = el("button", "btn btn-quiet cal-today", t("cal.today", "Today"));
      back.type = "button";
      prev.addEventListener("click", function () { step(-1); });
      next.addEventListener("click", function () { step(1); });
      back.addEventListener("click", function () { shown = { year: now.year, month: now.month }; picked = now.day; draw(); });
      nav.appendChild(prev); nav.appendChild(title); nav.appendChild(next); nav.appendChild(back);
      root.appendChild(nav);

      var events = eventsFor(snap, now, shown.year, shown.month);
      var grid = el("div", "cal-grid");
      grid.setAttribute("role", "grid");
      weekdayNames().forEach(function (w) { grid.appendChild(el("div", "cal-wd", w.slice(0, 3))); });
      var first = weekdayOf(now, shown.year, shown.month, 1);
      for (var i = 0; i < first; i++) grid.appendChild(el("div", "cal-blank"));
      for (var d = 1; d <= LENGTHS[shown.month]; d++) {
        var cell = el("button", "cal-day");
        cell.type = "button";
        var isToday = shown.year === now.year && shown.month === now.month && d === now.day;
        if (isToday) cell.className += " is-today";
        if (d === picked) cell.className += " is-picked";
        cell.appendChild(el("span", "cal-num", String(d)));
        (events[d] || []).forEach(function (e) {
          cell.appendChild(el("span", "cal-mark k-" + e.kind, ""));
        });
        cell.setAttribute("aria-label", d + " " + monthNames()[shown.month] + ((events[d] || []).length ?
          ": " + events[d].map(function (e) { return e.text; }).join("; ") : ""));
        (function (day) {
          cell.addEventListener("click", function () { picked = day; draw(); });
        })(d);
        grid.appendChild(cell);
      }
      root.appendChild(grid);

      // The day picked, in words.
      var info = el("div", "cal-info");
      var wd = weekdayNames()[weekdayOf(now, shown.year, shown.month, picked)];
      info.appendChild(el("h4", "sub-head", wd + ", " + picked + " " + monthNames()[shown.month]));
      var list = events[picked] || [];
      if (!list.length) info.appendChild(el("p", "cal-empty", t("cal.nothing", "Nothing on this day.")));
      list.forEach(function (e) { info.appendChild(el("p", "cal-event k-" + e.kind, e.text)); });
      root.appendChild(info);
    }

    function step(by) {
      var m = shown.month + by;
      shown = { year: shown.year + Math.floor(m / 12), month: ((m % 12) + 12) % 12 };
      picked = Math.min(picked, LENGTHS[shown.month]);
      draw();
    }

    draw();
    return root;
  }

  UI.calendar = { build: build, dateOfGameDay: dateOfGameDay, today: today };
})(window.SNRomUI = window.SNRomUI || {});
