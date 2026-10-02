/* mock/host.js - the mock host: the dashboard page in an ordinary browser.

   Plays the part of the game: loads mock/*.json and answers every request the
   way Papyrus would, refusals included, following every action with a fresh
   snapshot. Also draws the MOCK HOST strip, the one developer strip the page
   has.

   NEVER SHIPPED. bridge.js loads this only when the page is served over
   http(s), which no game host does, and tools/package.ps1 stages the page
   without mock/ and refuses to package if the strip or these test hooks turn up
   anywhere else. So a player can never see invented people, in either host. */

(function () {
  "use strict";

  // bridge.js hands over the few internals a host needs: how to deliver a
  // message to the page, and the protocol constants.
  window.SNRomMockHost = function (bridge) {
    var PROTOCOL = bridge.PROTOCOL;
    var FN_CLOSE = bridge.FN_CLOSE;
    var receive = bridge.receive;
    var reportError = bridge.reportError;
    var parseQuery = bridge.parseQuery;

    var state = null;
    var loading = null;
    var index = null;
    var current = null;
    var closes = [];
    var log = [];
    var params = parseQuery();

    // THE DISPLAY SETTINGS, as the DLL sends them once its settings watcher
    // sees a change: from ?scale=125&text=large, the strip's two selects, or
    // __snromMock.settings. They outlast a change of mock, as a setting
    // outlasts a save loading. Unset, each mock's own settings stand.
    var display = {};
    if (params.scale) display.scale = params.scale === "auto" ? "auto" : Number(params.scale);
    if (params.text) display.textSize = params.text;
    function withDisplay(snap) {
      if (snap && snap.settings) for (var k in display) snap.settings[k] = display[k];
      return snap;
    }
    function setDisplay(values) {
      for (var k in values) display[k] = values[k];
      if (state) { withDisplay(state); pushSnapshot(); }
      renderDevBar();
    }

    function later(ms, fn) { setTimeout(fn, ms); }
    function push(kind, payload, extra) {
      var m = { v: PROTOCOL, kind: kind, payload: payload };
      if (extra) for (var k in extra) m[k] = extra[k];
      // Round-trip through text, exactly as a native host would deliver it.
      receive(JSON.stringify(m));
    }
    function pushSnapshot() { if (state) push("snapshot", JSON.parse(JSON.stringify(state))); }
    function answer(id, ok, message) { push("result", { ok: ok, message: message }, { re: id }); }
    function notice(text, level) { push("notice", { text: text, level: level || "info" }); }

    function getJson(url) {
      return fetch(url, { cache: "no-store" }).then(function (r) {
        if (!r.ok) throw new Error(url + ": HTTP " + r.status);
        return r.json();
      });
    }

    function load(id) {
      loading = (index ? Promise.resolve(index) : getJson("mock/index.json")).then(function (ix) {
        index = ix;
        current = id || params.mock || ix["default"];
        return getJson("mock/" + encodeURIComponent(current) + ".json");
      }).then(function (snap) {
        state = withDisplay(snap);
        renderDevBar();
        return state;
      });
      return loading;
    }

    function bondOf(formId) {
      if (!state) return null;
      for (var i = 0; i < state.bonds.length; i++) {
        if (state.bonds[i].subject.formId === formId) return state.bonds[i];
      }
      return null;
    }

    function tierOf(points) {
      var t = 0, th = state.ladder.thresholds;
      for (var i = 0; i < th.length; i++) if (points >= th[i]) t = i;
      return t;
    }

    // One function per op, each shaped like the Papyrus it stands in for.
    var ops = {
      ReseedActor: function (b) {
        // No follow requirement from 1.9: the points are Relationships' own
        // (WP4), so a re-read lands wherever they are.
        later(700, function () {
          // HoldShortOfLover's cases: never judged, or sparked with the question
          // unanswered (a declined bond reopens to unanswered at the line).
          var held = b.state === "unexamined" || b.state === "interested" || b.state === "declined";
          var target = b.depth.points + 60;
          if (held && target > 1999) target = 1999;
          var raised = target > b.depth.points;
          if (raised) { b.depth.points = target; b.depth.tier = tierOf(target); }
          b.seeded = true;
          notice("Seed read for " + b.subject.name + (raised ? ": the record supports a little more than they had." : ": they already hold what the record supports."));
          pushSnapshot();
        });
        return [true, "Re-reading the record for " + b.subject.name + "..."];
      },
      ReauthorCharacter: function (b) {
        later(900, function () {
          b.traits.authored = true;
          if (!b.prose.why) b.prose.why = b.subject.name.split(" ")[0] + " has been written again from the record as it stands.";
          notice("Character written for " + b.subject.name + ".");
          pushSnapshot();
        });
        return [true, "Re-authoring " + b.subject.name + "'s character. Their old one is in the log."];
      },
      SetCharacterField: function (b, args) {
        var field = args[0], value = args[1];
        if (field === 0) {
          var rank = Math.max(0, Math.min(3, value | 0));
          b.traits.intimacy = ["casual", "romantic", "guarded", "never"][rank];
        } else if (field === 1) {
          b.traits.ardor = Math.max(0, Math.min(4, value | 0));
        } else if (field === 2) {
          b.traits.exclusivity = Math.max(0, Math.min(100, value | 0));
        } else {
          return [false, "SetCharacterField: field must be 0, 1 or 2."];
        }
        later(80, pushSnapshot);
        return [true, "Repair written for " + b.subject.name + "."];
      },
      UnenrollActor: function (b) {
        state.bonds.splice(state.bonds.indexOf(b), 1);
        if (state.crosshairTarget && state.crosshairTarget.formId === b.subject.formId) state.crosshairTarget.enrolled = false;
        later(80, pushSnapshot);
        return [true, b.subject.name + " is off the roster and no longer observed."];
      },
      RequestSparkNow: function (b) {
        if (b.spark.sparked || b.spark.decided) return [false, b.subject.name + " already has a spark verdict."];
        return [true, "Asking the spark assessor about " + b.subject.name + " out of turn."];
      },
      UnsparkActor: function (b) {
        b.spark.sparked = false; b.spark.sparkedAt = null;
        later(80, pushSnapshot);
        return [true, b.subject.name + " is back on the platonic ladder with points intact."];
      },
      ForceDriftReview: function (b) {
        return [true, "Forced drift review for " + b.subject.name + " sent. A quiet history should come back NO."];
      }
    };

    var playthroughOps = {
      StartFreshStore: function () {
        var id = state.playthrough.id || "unknown";
        state.playthrough.storeDecision = "own";
        state.playthrough.store = "SNRom_Dispositions_" + id;
        later(80, pushSnapshot);
        return [true, "This playthrough now has its own store. Nothing was deleted."];
      },
      AdoptLegacyStore: function () {
        state.playthrough.storeDecision = "legacy";
        state.playthrough.store = "SNRom_Dispositions";
        later(80, pushSnapshot);
        return [true, "Adopted the main store. Authored characters are visible again."];
      },
      // The DLL answers this one at once; the count arrives as a notice.
      CheckDisplay: function () {
        var n = state.bonds.length;
        later(600, function () { notice(n + " bonds checked, 0 disagreements (see SkyrimNetRelationships.log)."); });
        return [true, "Checking every bond against the rules. About a minute with 120 bonds; the answer arrives here."];
      }
    };

    function enroll(formId) {
      var t = state.crosshairTarget;
      if (!t || t.formId !== formId) return [false, "Enrolling needs the person who was under your crosshair."];
      if (t.enrolled || bondOf(formId)) return [false, t.name + " is already on your roster."];
      t.enrolled = true;
      var b = {
        subject: { formId: t.formId, name: t.name, isPlayer: false },
        object: JSON.parse(JSON.stringify(state.player)),
        following: false, nearby: true, lastFollowingAt: null,
        enrollment: { by: "player", joinedAt: state.generatedAt },
        depth: { points: 0, tier: 0, banked: 0 },
        track: "platonic", state: "unexamined", foreclosure: null,
        stance: "unanswered", askPending: false,
        spark: { sparked: false, decided: false, sparkedAt: null, lastCheckedAt: null },
        commitment: "none", seeded: false,
        traits: { authored: false, intimacy: "romantic", ardor: 2, exclusivity: 50, orientation: "both", orientationBasis: "unknown" },
        prose: { why: "", limit: "", address: "" }
      };
      state.bonds.push(b);
      later(80, pushSnapshot);
      later(1200, function () {
        b.traits = { authored: true, intimacy: "casual", ardor: 3, exclusivity: 25, orientation: "both", orientationBasis: "inferred" };
        b.prose = { why: t.name.split(" ")[0] + " is quick to size up a stranger and slow to change the verdict.", limit: t.name.split(" ")[0] + " will not be made a fool of twice.", address: "'Traveler', for now." };
        notice("Disposition authored for " + t.name + ".");
        pushSnapshot();
      });
      return [true, t.name + " is on your roster. Their character is being written."];
    }

    function act(p) {
      var op = p && p.op;
      if (op === "EnrollActor") return enroll(p.subject);
      if (playthroughOps[op]) return playthroughOps[op]();
      if (!ops[op]) return [false, "Unknown operation " + op + "."];
      var b = bondOf(p.subject);
      if (!b) return [false, "Nobody with that form id is on the roster."];
      return ops[op](b, p.args || []);
    }

    function send(envelope) {
      log.push(JSON.parse(JSON.stringify(envelope)));
      later(60, function () {
        var ready = state ? Promise.resolve(state) : (loading || load());
        ready.then(function () {
          if (envelope.kind === "snapshot") {
            pushSnapshot();
            answer(envelope.id, true, "");
          } else if (envelope.kind === "action") {
            var r = act(envelope.payload);
            answer(envelope.id, r[0], r[1]);
          } else {
            answer(envelope.id, false, "Unknown request kind " + envelope.kind + ".");
          }
        }, function (e) {
          answer(envelope.id, false, "Mock data did not load: " + (e && e.message ? e.message : e) +
            ". Serve the folder over http (see ui/README.md); a file URL cannot fetch it.");
        });
      });
    }

    function close(reason) {
      closes.push(reason);
      renderDevBar();
      notice("Mock host: the game would close the dashboard now (" + FN_CLOSE + ", " + reason + ").");
    }

    // A strip for whoever runs this in a browser: which mock, and what the page
    // asked the game to do. Belongs to the mock host, never to the page, so it
    // cannot exist in game. ?devbar=0 hides it for screenshots.
    function renderDevBar() {
      if (params.devbar === "0" || !document.body) return;
      var bar = document.getElementById("snrom-mock-bar");
      if (!bar) {
        bar = document.createElement("div");
        bar.id = "snrom-mock-bar";
        bar.setAttribute("aria-label", "Mock host controls");
        bar.style.cssText = "position:fixed;left:8px;bottom:8px;z-index:99;padding:6px 8px;border-radius:6px;" +
          "background:#2b1d0e;color:#f3d9a4;border:1px solid #7a5a2a;font:12px/1.3 sans-serif;display:flex;gap:8px;align-items:center";
        var label = document.createElement("span");
        label.textContent = "MOCK HOST";
        label.style.fontWeight = "bold";
        var select = document.createElement("select");
        select.id = "snrom-mock-select";
        select.setAttribute("aria-label", "Mock snapshot");
        select.addEventListener("change", function () {
          state = null;
          load(select.value).then(pushSnapshot, reportError);
        });
        var status = document.createElement("span");
        status.id = "snrom-mock-status";
        bar.appendChild(label); bar.appendChild(select);
        bar.appendChild(pick("snrom-mock-scale", "Scale", ["auto", "75", "90", "100", "110", "125", "150", "175", "200"],
          function (v) { setDisplay({ scale: v === "auto" ? "auto" : Number(v) }); }));
        bar.appendChild(pick("snrom-mock-text", "Text size", ["normal", "large", "larger"],
          function (v) { setDisplay({ textSize: v }); }));
        bar.appendChild(status);
        document.body.appendChild(bar);
      }
      var shown = state && state.settings ? state.settings : display;
      if (shown.scale !== undefined) document.getElementById("snrom-mock-scale").value = String(shown.scale);
      if (shown.textSize !== undefined) document.getElementById("snrom-mock-text").value = shown.textSize;
      var sel = document.getElementById("snrom-mock-select");
      if (index && sel.options.length !== index.mocks.length) {
        sel.innerHTML = "";
        index.mocks.forEach(function (m) {
          var o = document.createElement("option");
          o.value = m.id; o.textContent = m.title;
          sel.appendChild(o);
        });
      }
      if (current) sel.value = current;
      document.getElementById("snrom-mock-status").textContent = closes.length ? "close requested x" + closes.length : "";
    }

    function pick(id, label, values, onChange) {
      var sel = document.createElement("select");
      sel.id = id;
      sel.setAttribute("aria-label", label);
      sel.title = label;
      values.forEach(function (v) {
        var o = document.createElement("option");
        o.value = v; o.textContent = label + ": " + v + (/^\d+$/.test(v) ? "%" : "");
        sel.appendChild(o);
      });
      sel.addEventListener("change", function () { onChange(sel.value); });
      return sel;
    }

    // Test hooks. Present only in the mock host.
    window.__snromMock = {
      closes: closes,
      log: log,
      use: function (id) { state = null; return load(id).then(pushSnapshot); },
      // The live mock state, changed WITHOUT pushing a snapshot: how a test
      // makes the game disagree with what the page was last told.
      peek: function () { return state; },
      load: function (snap) { state = withDisplay(JSON.parse(JSON.stringify(snap))); pushSnapshot(); },
      // A display setting saved in the game's panel: the DLL's watcher sends
      // an open dashboard a snapshot carrying it.
      settings: setDisplay
    };

    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", renderDevBar);

    return { name: "mock", send: send, close: close };
  };
})();
