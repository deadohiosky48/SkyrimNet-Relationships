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
    // The mock's stand-in portrait: a drawn head and shoulders, transparent
    // like SeverActions' cutouts, so the panel can be laid out without one.
    var MOCK_PORTRAIT = "data:image/svg+xml," + encodeURIComponent(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 384 480">' +
      '<path d="M40 480c10-110 70-150 152-150s142 40 152 150z" fill="#6b5a48"/>' +
      '<rect x="160" y="250" width="64" height="90" rx="20" fill="#d9b59a"/>' +
      '<ellipse cx="192" cy="190" rx="88" ry="108" fill="#e3c1a5"/>' +
      '<path d="M100 200c-10-120 70-150 92-150s110 20 92 150c-10-60-40-90-92-90s-82 30-92 90z" fill="#4a3226"/>' +
      '</svg>');
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

    var asked = false;
    function later(ms, fn) { setTimeout(fn, ms); }
    function push(kind, payload, extra) {
      var m = { v: PROTOCOL, kind: kind, payload: payload };
      if (extra) for (var k in extra) m[k] = extra[k];
      // Round-trip through text, exactly as a native host would deliver it.
      receive(JSON.stringify(m));
    }
    function pushSnapshot() {
      if (!state) return;
      var s = JSON.parse(JSON.stringify(state));
      // SeverActions' portraits, as a player with it installed has them;
      // ?faces=0 for a player without.
      if (s.settings) s.settings.portraits = params.faces !== "0";
      // The player's family (wpm47), which the mock saves predate: the two
      // kin are a daughter and an adopted son, the first minor a
      // granddaughter.
      var kin = s.bonds.filter(function (b) { return b.foreclosure === "kin"; });
      var minor = s.bonds.filter(function (b) { return b.foreclosure === "minor"; });
      var family = [[kin[0], 1, false, "female"], [kin[1], 1, true, "male"], [minor[0], 2, false, "female"]];
      family.forEach(function (f) {
        if (!f[0] || f[0].kin) return;
        f[0].kin = { generation: f[1], adopted: f[2] };
        f[0].subject.sex = f[3];
      });
      push("snapshot", s);
    }
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
        // ?ask=over or ?ask=alone: a question as the game would ask it
        // (Dashboard::Ask), over the dashboard or on its own.
        if (params.ask && !asked) {
          asked = true;
          later(400, function () {
            // M8c: a default and a timer, as SNRom_Choice asks the engagement.
            // ?q=stand: the romance question, whose buttons are the longest.
            var stand = params.q === "stand";
            push("ask", { id: 1, title: "",
              body: stand
                ? "Ysolde Brightwater has asked where the two of you stand. Whatever you answer, you will have answered it plainly."
                : "Ysolde Brightwater has said yes. Are the two of you promised to each other?",
              buttons: stand
                ? ["Tell them you feel the same", "Tell them you do not feel that way", "Say nothing of it for now"]
                : ["Yes, we are engaged", "No, I spoke too soon", "Not yet"],
              defaultButton: stand ? 2 : 0, seconds: Number(params.seconds) || 30, standalone: params.ask === "alone" });
          });
        }
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
      // wpm85: the plan by hand (SNRom_Bridge.EditWeddingPlanByHand), roughly.
      EditWeddingPlan: function (b, args, text) {
        var pl = b.marriage && b.marriage.plan;
        if (!pl) return [true, "There is no wedding to plan with them."];
        var SIDES = ["theirs", "yours", "both"];
        var METALS = ["gold", "silver", "ebony"];
        var what = args[0];
        if (what === 1) { if (args[1] >= 0) pl.day = Math.floor(state.generatedAt) + args[1]; if (args[2] >= 0) pl.hour = args[2]; }
        else if (what === 2) pl.place = text;
        else if (what === 3) pl.near = text;
        else if (what === 4) pl.officiant = text;
        else if (what === 5) text.split(",").map(function (n) { return n.trim(); }).filter(Boolean).forEach(function (n) {
          if (pl.guests.indexOf(n) < 0) pl.guests.push(n);
          pl.guestSides = (pl.guestSides || []).filter(function (g) { return g.name !== n; });
          pl.guestSides.push({ name: n, side: SIDES[args[1]] || "" });
        });
        else if (what === 6) { pl.guests = pl.guests.filter(function (n) { return n !== text; }); pl.guestSides = (pl.guestSides || []).filter(function (g) { return g.name !== text; }); }
        else if (what === 7) (pl.guestSides || []).forEach(function (g) { if (g.name === text) g.side = SIDES[args[1]] || ""; });
        else if (what === 8) pl.parts = { address: !!(args[1] & 1), reading: !!(args[1] & 2), rings: !!(args[1] & 4), kiss: !!(args[1] & 8) };
        else if (what === 9) {
          if (args[1] >= 0) pl.yourRing = { style: args[1], chosen: true, metal: pl.yourRing.metal };
          if (args[2] >= 0) pl.yourRing.metal = METALS[args[2]];
          if (args[3] >= 0) pl.theirRing = { style: args[3], chosen: true, metal: pl.theirRing.metal };
          if (args[4] >= 0) pl.theirRing.metal = METALS[args[4]];
        }
        else if (what === 10) pl.day = null;
        else if (what === 11) pl.outfit = true;
        else if (what === 12) { pl.place = text || "the spot they chose near Karthwasten"; pl.near = "Karthwasten"; pl.spot = true; pl.open = (pl.open || []).filter(function (o) { return o !== "place"; }); }
        else if (what === 13) { var R = ["officiant", "you", "theirs", "yours", "betrothed"]; pl.marked = pl.marked || []; if (pl.marked.indexOf(R[args[1]]) < 0) pl.marked.push(R[args[1]]); }
        later(80, pushSnapshot);
        return [true, "The wedding plan is changed."];
      },
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
      ClearAddress: function (b) {
        b.prose.address = "";
        later(80, pushSnapshot);
        return [true, b.subject.name + " no longer has a saved name for you."];
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
      },
      // 2.5, Build A: marriage.
      Divorce: function (b) {
        var m = b.marriage;
        if (!m || (m.state !== "married" && m.state !== "separated")) {
          return [true, b.subject.name + " is not married to you in Relationships' record. A MARAS marriage must be imported first."];
        }
        m.previous = m.state; m.state = "divorced"; m.since = state.generatedAt;
        later(80, pushSnapshot);
        return [true, "You and " + b.subject.name + " are divorced."];
      },
      SetMarriageState: function (b, args) {
        var names = ["none", "engaged", "married", "broken_off", "divorced", "widowed", "separated"];
        var s = names[args[0]];
        if (!s) return [true, "No marriage state " + args[0] + "."];
        if (s === "none") { b.marriage = null; }
        else {
          var m = b.marriage || { state: "none", previous: "none", since: null, weddingDay: null, eloped: false, officiant: "", why: "", ringFromPlayer: "", ringToPlayer: "" };
          m.previous = m.state; m.state = s; m.since = state.generatedAt; m.why = "set by hand (developer view)";
          b.marriage = m;
        }
        later(80, pushSnapshot);
        return [true, b.subject.name + " set to state " + args[0] + "."];
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
      // 2.1.1. Papyrus answers with counts; the mock has no bio blocks.
      RestoreOurBioBlocks: function () {
        return [true, "Forgot 3 taken-off record(s) on 2 people, and applied 3 of our blocks where the category was empty."];
      },
      // The DLL answers this one at once; the count arrives as a notice.
      ImportMaras: function () {
        return [true, "Brought over from MARAS: 13 married, 0 engaged."];
      },
      WeddingReport: function () {
        return [true, "Wedding report: | RelationshipMarriage running false stage 0 done false | DestinationWeddings.esp true"];
      },
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
        prose: { why: "", limit: "", address: "", playerSays: "" }
      };
      state.bonds.push(b);
      later(80, pushSnapshot);
      later(1200, function () {
        b.traits = { authored: true, intimacy: "casual", ardor: 3, exclusivity: 25, orientation: "both", orientationBasis: "inferred" };
        b.prose = { why: t.name.split(" ")[0] + " is quick to size up a stranger and slow to change the verdict.", limit: t.name.split(" ")[0] + " will not be made a fool of twice.", address: "'Traveler', for now.", playerSays: "" };
        notice("Disposition authored for " + t.name + ".");
        pushSnapshot();
      });
      return [true, t.name + " is on your roster. Their character is being written."];
    }

    function act(p) {
      var op = p && p.op;
      if (op === "EnrollActor") return enroll(p.subject);
      if (playthroughOps[op]) return playthroughOps[op](p.args || []);
      if (!ops[op]) return [false, "Unknown operation " + op + "."];
      var b = bondOf(p.subject);
      if (!b) return [false, "Nobody with that form id is on the roster."];
      return ops[op](b, p.args || [], p.text || "");
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
          } else if (envelope.kind === "portrait") {
            // A stand-in face for every other bond and none for the rest, as
            // a player with only some companions shot would see it.
            var index = (state && state.bonds || []).findIndex(function (b) {
              return b.subject.formId === envelope.payload.formId;
            });
            var src = index >= 0 && index % 2 === 0 ? MOCK_PORTRAIT : "";
            push("portrait", { formId: envelope.payload.formId, src: src });
            answer(envelope.id, true, "");
          } else if (envelope.kind === "thumbnails") {
            // The roster's faces: the same stand-in, for the same bonds.
            var items = (envelope.payload.formIds || []).map(function (id) {
              var at = (state && state.bonds || []).findIndex(function (b) { return b.subject.formId === id; });
              return { formId: id, src: at >= 0 && at % 2 === 0 ? MOCK_PORTRAIT : "" };
            });
            push("thumbnails", { px: envelope.payload.px, items: items });
            answer(envelope.id, true, "");
          } else if (envelope.kind === "answer") {
            answer(envelope.id, true, "");
            push("askEnd", {});
            notice("Mock host: question " + envelope.payload.ask + " answered " + envelope.payload.choice + ".");
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
