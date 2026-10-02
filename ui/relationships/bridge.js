/* bridge.js - window.snrom, the only way the page talks to the game.

   ==========================================================================
   THE CONTRACT THE DLL IMPLEMENTS (WP3). Same names in both native hosts.
   ==========================================================================

   Meridian (Meridian.View/1, RegisterListener) and PrismaUI (RegisterJSListener)
   both expose a registered listener to the page as a function on `window`,
   called with ONE string argument. So the page calls the same two functions
   under either host, and the DLL registers the same two names in either:

   PAGE -> NATIVE  (registered by the DLL; the page only calls them)

     window.snromRequest(json)
         Every request. `json` is JSON text:
           {"v":1, "id":"r7", "kind":"snapshot"|"action", "payload":{...}}
         kind "snapshot"  payload {}. Send the current snapshot: what the
                          DLL's read model holds now (design 7.3, the WP2
                          transport). Costs no Papyrus. The DLL refreshes the
                          model from Papyrus on every open, not on this
                          request, and pushes the result as its own
                          "snapshot" message; snapshot.roster.status says
                          where that stands.
         kind "action"    payload {"op":"ReseedActor", "subject":<formId>|null,
                                   "args":[...]}.
                          `op` is a KEY INTO A FIXED TABLE on the native side
                          (actions.js lists every one, with the SNRom_Bridge
                          function it maps to). Never call a Papyrus function
                          named by the page without looking it up first: the
                          page is data, and the table is the permission.
                          `subject` is Actor.GetFormID() as a signed 32-bit int.
         The native side answers EVERY request with exactly one "result"
         message carrying the same id. An action's result is Papyrus's own
         answer, or the DLL's refusal when the op, its arguments or the
         developer lock rule it out. A fresh snapshot follows every answer.
         A re-read or re-author answers that it has
         started; a "notice" says when it finishes. If Papyrus has not
         answered in ten seconds the result says so, and a late answer
         arrives as a "notice".

     window.snromClose(json)
         The one registered close function. `json` is {"v":1,"reason":"escape"}
         or {"v":1,"reason":"button"}. The DLL unfocuses and hides the view.
         Escape is handled here in the page, as Meridian's guide asks: it closes
         any dialog or detail first, and only then calls this.

   NATIVE -> PAGE  (defined here; the DLL calls it)

     window.snromReceive(json)
         Meridian: ExecuteJavaScript(view, "snromReceive(<json>)").
         Prisma:   InteropCall(view, "snromReceive", json).
         Takes JSON text or an already-parsed object, so either quoting works:
           {"v":1, "kind":"snapshot", "payload":<snapshot.schema.json>}
           {"v":1, "kind":"result",   "re":"r7", "payload":{"ok":true,"message":"..."}}
           {"v":1, "kind":"notice",   "payload":{"text":"...","level":"info"|"warn"|"error"}}
           {"v":1, "kind":"opened"}   the dashboard was just shown and focused
         "notice" carries an answer that arrives later and belongs to no request,
         such as a seed read coming back from the LLM seconds after the re-read
         was dispatched, or the DLL saying the game's scripts have not answered
         a refresh yet. Unknown kinds are ignored, so the DLL can add one before
         the page knows it.

   Payloads are copied by the DLL before it hands them to SKSE's task queue:
   Meridian's listener payload is valid only during the callback (its guide).

   ==========================================================================
   THE PAGE'S SIDE. Application code uses only these:
   ==========================================================================

     snrom.request(kind, payload) -> Promise<{ok, message}>
         kind "snapshot" | "action" as above, or "close" ({reason}), which goes
         to snromClose and resolves at once.
     snrom.on(kind, handler) -> unsubscribe function
         kind "snapshot" | "notice" | "opened" | "result" | "connection".
         A "snapshot" handler registered late is handed the last one at once.
     snrom.host
         "meridian", "prisma" or "mock". For display only; nothing may branch
         on it.

   Which host: a `mod:` page is Meridian. A page served over http(s) is the
   mock, because neither game host serves pages over http. Anything else is a
   native host whose listeners may not be registered yet (Prisma registers
   them after DOM ready), so requests wait for them and fail loudly if they
   never come. A page in the game never falls back to mock data: showing a
   player invented people would be worse than showing nothing.

   Kept to plain ES2017 in one IIFE, no modules and no optional chaining:
   PrismaUI renders with Ultralight rather than Chromium, and a classic script
   is the one thing both hosts and a file URL all load the same way. */

(function () {
  "use strict";

  var PROTOCOL = 1;
  var FN_REQUEST = "snromRequest";
  var FN_CLOSE = "snromClose";
  var FN_RECEIVE = "snromReceive";
  var ANSWER_TIMEOUT_MS = 15000;
  var LISTENER_WAIT_MS = 10000;

  var handlers = {};
  var pending = {};
  var lastSnapshot = null;
  var nextId = 1;

  function emit(kind, payload) {
    var list = handlers[kind];
    if (!list) return;
    list.slice().forEach(function (h) {
      try { h(payload); } catch (e) { reportError(e); }
    });
  }

  function reportError(e) {
    // Surfaced rather than swallowed: a handler that throws is a page bug, and
    // the test run fails on any console error.
    if (window.console && console.error) console.error("[snrom]", e && e.stack ? e.stack : e);
  }

  function receive(message) {
    var m = message;
    if (typeof m === "string") {
      try { m = JSON.parse(m); } catch (e) {
        reportError("snromReceive got text that is not JSON: " + String(message).slice(0, 120));
        return;
      }
    }
    if (!m || typeof m !== "object" || typeof m.kind !== "string") {
      reportError("snromReceive got a message with no kind");
      return;
    }
    if (m.v !== PROTOCOL) {
      reportError("snromReceive: protocol " + m.v + ", this page speaks " + PROTOCOL);
      return;
    }
    if (m.kind === "result") {
      var p = pending[m.re];
      if (p) {
        delete pending[m.re];
        clearTimeout(p.timer);
        p.resolve(normalizeResult(m.payload));
      }
      emit("result", { re: m.re, result: normalizeResult(m.payload) });
      return;
    }
    if (m.kind === "snapshot") lastSnapshot = m.payload;
    emit(m.kind, m.payload);
  }

  function normalizeResult(r) {
    if (!r || typeof r !== "object") return { ok: false, message: "The game sent an answer with nothing in it." };
    return { ok: r.ok === true, message: typeof r.message === "string" ? r.message : "" };
  }

  window[FN_RECEIVE] = receive;

  // ------------------------------------------------------------------ native
  // Meridian and Prisma differ only in when their listeners appear, so they
  // share one implementation that waits for the function to exist.
  function nativeHost(name) {
    var queue = [];
    var waitingSince = 0;
    var pollTimer = null;

    function available(fn) { return typeof window[fn] === "function"; }

    function flush() {
      while (queue.length && available(queue[0].fn)) {
        var job = queue.shift();
        callNative(job.fn, job.text);
      }
      if (!queue.length && pollTimer) { clearInterval(pollTimer); pollTimer = null; }
    }

    function callNative(fn, text) {
      try { window[fn](text); } catch (e) { reportError(e); }
    }

    function giveUp() {
      var jobs = queue; queue = [];
      clearInterval(pollTimer); pollTimer = null;
      emit("connection", { ok: false, message: "The game never registered " + jobs[0].fn + "." });
      jobs.forEach(function (job) {
        if (job.id && pending[job.id]) {
          receive({ v: PROTOCOL, kind: "result", re: job.id,
            payload: { ok: false, message: "No connection to the game." } });
        }
      });
    }

    function enqueue(fn, text, id) {
      if (!queue.length && available(fn)) {
        callNative(fn, text);
        return;
      }
      queue.push({ fn: fn, text: text, id: id });
      if (!pollTimer) {
        waitingSince = Date.now();
        pollTimer = setInterval(function () {
          flush();
          if (queue.length && Date.now() - waitingSince > LISTENER_WAIT_MS) giveUp();
        }, 100);
      }
    }

    return {
      name: name,
      send: function (envelope) { enqueue(FN_REQUEST, JSON.stringify(envelope), envelope.id); },
      close: function (reason) { enqueue(FN_CLOSE, JSON.stringify({ v: PROTOCOL, reason: reason }), null); }
    };
  }

  // ------------------------------------------------------------------ mock
  // Runs the page in an ordinary browser. The host itself is mock/host.js,
  // which never ships (tools/package.ps1 stages the page without mock/), so
  // this only loads it and holds what the page asks until it arrives.
  function mockHost() {
    var real = null;
    var failed = null;
    var queue = [];

    function deliver(job) {
      if (job.close) real.close(job.reason);
      else real.send(job.envelope);
    }
    function refuse(job) {
      if (!job.envelope) return;
      receive({ v: PROTOCOL, kind: "result", re: job.envelope.id, payload: { ok: false, message: failed } });
    }
    function settle(ok, why) {
      if (ok) real = window.SNRomMockHost({
        PROTOCOL: PROTOCOL, FN_CLOSE: FN_CLOSE, receive: receive, reportError: reportError, parseQuery: parseQuery
      });
      else failed = why;
      queue.splice(0).forEach(ok ? deliver : refuse);
    }

    var script = document.createElement("script");
    script.src = "mock/host.js";
    script.onload = function () {
      if (typeof window.SNRomMockHost === "function") settle(true);
      else settle(false, "mock/host.js loaded but defined no mock host.");
    };
    script.onerror = function () {
      settle(false, "No game connection, and no mock host: mock/host.js did not load.");
    };
    (document.head || document.documentElement).appendChild(script);

    return {
      name: "mock",
      send: function (envelope) {
        var job = { envelope: envelope };
        if (real) deliver(job); else if (failed) refuse(job); else queue.push(job);
      },
      close: function (reason) {
        var job = { close: true, reason: reason };
        if (real) deliver(job); else if (!failed) queue.push(job);
      }
    };
  }

  function parseQuery() {
    var out = {};
    var q = (location.search || "").replace(/^\?/, "");
    if (!q) return out;
    q.split("&").forEach(function (kv) {
      var i = kv.indexOf("=");
      var k = decodeURIComponent(i < 0 ? kv : kv.slice(0, i));
      out[k] = i < 0 ? "" : decodeURIComponent(kv.slice(i + 1).replace(/\+/g, " "));
    });
    return out;
  }

  function chooseHost() {
    var proto = location.protocol;
    if (proto === "mod:") return nativeHost("meridian");
    if (typeof window[FN_REQUEST] === "function") return nativeHost("prisma");
    if (proto === "http:" || proto === "https:") return mockHost();
    return nativeHost("prisma");
  }

  var host = chooseHost();

  function request(kind, payload) {
    if (kind === "close") {
      host.close(payload && payload.reason ? payload.reason : "button");
      return Promise.resolve({ ok: true, message: "" });
    }
    var id = "r" + (nextId++);
    return new Promise(function (resolve) {
      pending[id] = {
        resolve: resolve,
        timer: setTimeout(function () {
          if (!pending[id]) return;
          delete pending[id];
          resolve({ ok: false, message: "The game did not answer." });
        }, ANSWER_TIMEOUT_MS)
      };
      host.send({ v: PROTOCOL, id: id, kind: kind, payload: payload || {} });
    });
  }

  function on(kind, handler) {
    (handlers[kind] = handlers[kind] || []).push(handler);
    if (kind === "snapshot" && lastSnapshot) {
      var snap = lastSnapshot;
      setTimeout(function () { try { handler(snap); } catch (e) { reportError(e); } }, 0);
    }
    return function () {
      var list = handlers[kind] || [];
      var i = list.indexOf(handler);
      if (i >= 0) list.splice(i, 1);
    };
  }

  window.snrom = { request: request, on: on, host: host.name };
})();
