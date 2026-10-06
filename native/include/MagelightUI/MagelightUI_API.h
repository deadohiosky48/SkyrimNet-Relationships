// MagelightUI_API.h — the public API header other SKSE plugins compile
// against (SeverActions is the first consumer).
//
// Pattern: versioned structs of C function pointers served by the exported
// factory `Magelight_RequestApi(version)` — resolved at runtime via
// GetModuleHandle/GetProcAddress, so consumers need no import library and a
// missing Magelight.dll degrades to a null API (soft no-op). Versions are
// additive: MagelightApi2 is
// MagelightApi1's members followed by the v2 additions, so a consumer that
// needs the newer surface requests 2 and falls back to 1.
//
// ABI rules (published): C ABI only; every struct starts with its members in
// declaration order and only ever APPENDS; enums never renumber; an unknown
// version returns null; v-N stays served for at least two minor host
// versions after v-N+1 ships; a breaking change means a new DLL name and a
// new export, never an in-place change.
//
// Threading contract (identical to the host's internal one):
//  - Every function is callable from any thread; view/image mutations marshal
//    internally (render thread owns Ultralight; EnterUIMode/ExitUIMode post a
//    task to the game thread).
//  - JS listener callbacks fire on the RENDER thread mid-frame — snapshot
//    what you need, then post the game-state work with PostGameTask (0.30.1+).
//  - Never call SKSE's AddTask or AddUITask from a callback the host makes
//    inside a frame: JS listeners, DOM ready, VR callbacks, and for a
//    RenderThread mod its events and EvalJS results (and onLog for a call made
//    from one of these). They run inside the game's Present, and on Skyrim VR
//    SKSE also drains its task queues on game job threads, holding a queue's
//    lock until it is empty, so the post can wait forever on a job that waits
//    for the frame. PostGameTask hands the post to a host thread instead (task
//    lane only). On a host older than 0.30.1, post from a thread of your own.
//    The same holds for your OWN main-thread entry points (an input sink, an
//    engine menu, a Present hook, a Papyrus native): PostGameTask is hang-safe
//    only inside the host's callbacks, so hand those posts to a thread of your
//    own.
//  - GameThread events keep their order within one source, not across: a
//    page event (DOM ready, console, resize, destroy, render death) and a
//    UI-mode event can arrive in either order.
//  - "The game thread" below means wherever SKSE runs its tasks: the main
//    thread on SE/AE, possibly a game job thread on VR. RE:: state is safe
//    there as in any SKSE task.
//  - The UI-mode exit callback fires on the GAME thread, on every exit path
//    (programmatic, Escape, toggle key, load boundary, render-death).
//    Host 0.9.1+: registrations are MULTICAST — every plugin that calls
//    SetUIModeExitCallback hears every exit with the exiting ViewId and
//    filters by the views it owns (0.9.0 kept only the last registration).
//    There is no unregister in v1-v3; register a static function once.
//  - v4 mod events (ModDesc.onEvent): GameThread (default) = delivered as
//    an SKSE task, safe to touch game state, may still arrive shortly after
//    UnregisterMod returns (the host drops them, but keep `user` alive until
//    the next game-thread tick). RenderThread = called INLINE ON THE EMITTING
//    THREAD, not always the render thread: page/console/resize events come
//    from the render thread, UIModeEntered/Exited/Refused from the game
//    thread, FocusDenied from the requesting mod's thread, RenderDead from
//    whichever present thread saw the kill switch. Pick RenderThread only if
//    your handler is thread-agnostic. A faulting handler disables that mod's
//    sink, never the overlay.
//  - ModDesc.onLog fires synchronously on the thread of the failing API
//    call, outside the host's locks (calling back into the API is allowed).
//  - const char* arguments are valid only for the duration of the call.
//
// Geometry (v1-v3): x/y are pixels from the swapchain's top-left; negative
// x/y anchor from the right/bottom edge. w == 0 && h == 0 = fullscreen
// (tracks the backbuffer). htmlPath is relative to Magelight's runtime dir,
// or an absolute Windows path (drive-letter form). v4's ViewDesc carries an
// explicit Anchor instead of the sign convention.
//
// Texture images (v2): render into a D3D11 texture you own on the GAME's
// device, register its SRV under a name, place ImageUrl(id) in an <img> or
// CSS url() — the page treats it as a normal image, and you InvalidateImage
// after each update. sRGB-encoded bytes behind a UNORM SRV, premultiplied
// alpha; bilinear/no-mip sampling (keep within ~2x the CSS box). GPU path
// only — IsGpuAccelerated() false means everything returns 0 / no-ops.
//
// Known engine limit (Ultralight 1.4 GPU path, both drivers): a ROUNDED box
// whose border sides differ (accent stripe, coloured top bar, top-only
// separator) draws its sides as filled wedges when the box is not fully
// opaque (translucent side colour, translucent/transparent background, or a
// translucent gradient layer). Keep such boxes opaque, or drop the radius.

#pragma once

#include <cstdint>

#ifndef MAGELIGHT_API_NO_LOADER
    #include <windows.h>
#endif

struct ID3D11ShaderResourceView;

namespace MAGELIGHT_API {

    using ViewId = std::uint64_t;  // 0 = invalid
    using ImageId = std::uint32_t; // 0 = invalid
    using JsListenerFn = void (*)(const char* argument);
    using DomReadyFn = void (*)(ViewId view);
    using UIModeExitFn = void (*)(ViewId view);

    inline constexpr std::uint32_t kApiVersion1 = 1;
    inline constexpr std::uint32_t kApiVersion2 = 2;
    inline constexpr std::uint32_t kApiVersion3 = 3;
    inline constexpr std::uint32_t kApiVersion4 = 4;

    struct MagelightApi1 {
        std::uint32_t apiVersion;   // = kApiVersion1
        const char* hostVersion;    // e.g. "0.8.0" (static storage)

        ViewId (*CreateView)(const char* htmlPath, int x, int y, int w, int h,
                             DomReadyFn onDomReady, bool clickThrough, bool startVisible);
        bool (*IsViewValid)(ViewId view);
        void (*ShowView)(ViewId view, bool show);
        void (*SetViewBounds)(ViewId view, int x, int y, int w, int h);
        void (*RegisterJSListener)(ViewId view, const char* name, JsListenerFn callback);
        void (*InteropCall)(ViewId view, const char* functionName, const char* argument);
        void (*InvokeJS)(ViewId view, const char* script);

        void (*EnterUIMode)(ViewId view);   // show + focus + cursor + control suspension
        void (*ExitUIMode)();               // drops UI mode; deliberately does NOT hide
        bool (*IsUIModeActive)();           // cross-surface mutex / hotkey gate
        void (*SetUIModeExitCallback)(UIModeExitFn cb);  // every exit path, game thread
    };

    // v1 members first (same layout), then the texture-image surface.
    struct MagelightApi2 {
        std::uint32_t apiVersion;   // = kApiVersion2
        const char* hostVersion;

        ViewId (*CreateView)(const char* htmlPath, int x, int y, int w, int h,
                             DomReadyFn onDomReady, bool clickThrough, bool startVisible);
        bool (*IsViewValid)(ViewId view);
        void (*ShowView)(ViewId view, bool show);
        void (*SetViewBounds)(ViewId view, int x, int y, int w, int h);
        void (*RegisterJSListener)(ViewId view, const char* name, JsListenerFn callback);
        void (*InteropCall)(ViewId view, const char* functionName, const char* argument);
        void (*InvokeJS)(ViewId view, const char* script);
        void (*EnterUIMode)(ViewId view);
        void (*ExitUIMode)();
        bool (*IsUIModeActive)();
        void (*SetUIModeExitCallback)(UIModeExitFn cb);

        bool (*IsGpuAccelerated)();
        ImageId (*RegisterTextureImage)(const char* name, ID3D11ShaderResourceView* srv,
                                        std::uint32_t width, std::uint32_t height);
        void (*UpdateTextureImage)(ImageId image, ID3D11ShaderResourceView* srv);  // re-point (resize)
        void (*InvalidateImage)(ImageId image);   // after every content change
        void (*UnregisterImage)(ImageId image);   // only once no page references it
        const char* (*ImageUrl)(ImageId image);   // file:/// URL of the .imgsrc; "" if invalid
    };

    // v2 members first (same layout), then: pausing UI mode. The host pushes
    // its own engine menu on UI-mode entry; pauseGame adds kPausesGame to it
    // (the world freezes, Papyrus keeps running — vanilla menu semantics).
    struct MagelightApi3 {
        std::uint32_t apiVersion;   // = kApiVersion3
        const char* hostVersion;

        ViewId (*CreateView)(const char* htmlPath, int x, int y, int w, int h,
                             DomReadyFn onDomReady, bool clickThrough, bool startVisible);
        bool (*IsViewValid)(ViewId view);
        void (*ShowView)(ViewId view, bool show);
        void (*SetViewBounds)(ViewId view, int x, int y, int w, int h);
        void (*RegisterJSListener)(ViewId view, const char* name, JsListenerFn callback);
        void (*InteropCall)(ViewId view, const char* functionName, const char* argument);
        void (*InvokeJS)(ViewId view, const char* script);
        void (*EnterUIMode)(ViewId view);
        void (*ExitUIMode)();
        bool (*IsUIModeActive)();
        void (*SetUIModeExitCallback)(UIModeExitFn cb);
        bool (*IsGpuAccelerated)();
        ImageId (*RegisterTextureImage)(const char* name, ID3D11ShaderResourceView* srv,
                                        std::uint32_t width, std::uint32_t height);
        void (*UpdateTextureImage)(ImageId image, ID3D11ShaderResourceView* srv);
        void (*InvalidateImage)(ImageId image);
        void (*UnregisterImage)(ImageId image);
        const char* (*ImageUrl)(ImageId image);

        void (*EnterUIModeEx)(ViewId view, bool pauseGame);
    };

    // ── v4: mod identity, result codes, events, view lifecycle ─────────────
    //
    // A consumer REGISTERS ITSELF once (RegisterMod) and receives a ModId that
    // scopes everything it creates: views, listeners, texture images, its
    // UI-mode ownership, its error string and its event sink. Two plugins can
    // no longer overwrite each other's hooks, and every failure names itself
    // (Result + GetLastErrorMessage) instead of returning 0.
    //
    // Version gate: ModDesc.minHostVersion is a packed MAJOR*10000 +
    // MINOR*100 + PATCH; an older host returns HostTooOld from RegisterMod
    // (the consumer then no-ops — never fail hard). hostVersionNumber at the
    // end of the struct is the running host's packed version.

    using ModId = std::uint32_t;   // 0 = invalid

    enum class Result : std::int32_t {
        Ok = 0,
        HostAbsent = 1,       // (consumer-side only: RequestApi returned null)
        HostTooOld = 2,       // ModDesc.minHostVersion > host
        NotReady = 3,         // before the renderer exists (world not ready)
        RenderDead = 4,       // the overlay disabled itself after a render fault
        InvalidView = 5,
        InvalidMod = 6,
        FileNotFound = 7,
        Busy = 8,             // UI mode is owned by another mod (see FocusDenied)
        Denied = 9,           // policy: e.g. a non-file:// URL, releasing UI mode you don't own
        Unsupported = 10,     // capability missing on this host/path
        InvalidArgument = 11,
        Internal = 12,
    };

    enum class CallbackThread : std::uint8_t {
        GameThread = 0,       // default: events as SKSE tasks — safe for game state
        RenderThread = 1,     // inline on the EMITTING thread (see the threading contract) — no RE:: access
    };

    // z-order tiers, low to high. Within a tier: creation order, RaiseView
    // moves to the top of its tier. Hud and click-through views are refused
    // UI mode (RequestUIMode → Denied).
    enum class Layer : std::uint8_t { Hud = 0, Panel = 1, Popup = 2, System = 3 };

    enum class Anchor : std::uint8_t { TopLeft = 0, TopRight = 1, BottomLeft = 2, BottomRight = 3 };
    // 0.28.2: what a mod's pages may reach over the network (SetNetworkPolicy).
    // File reads are always pinned to the page's own mod folder and the host
    // runtime dir. FileOnly (the default since 0.30.0): nothing over the
    // network. LoopbackOnly: also http(s) to this machine (localhost, 127.x,
    // [::1]); it was the default before 0.30.0, so a mod that talks to a
    // local server now opts in. Any: any host, any scheme — the reach a page
    // has in a browser. A manifest or a script may pick FileOnly or
    // LoopbackOnly; Any is a plugin's call. Each change is logged.
    enum class NetworkPolicy : std::uint8_t {
        LoopbackOnly = 0,
        Any = 1,
        FileOnly = 2,   // 0.30.0 — gate on hostVersionNumber >= 3000 (an older host reads it as LoopbackOnly)
    };

    enum class Event : std::uint32_t {
        ViewDomReady = 0,     // page scripts ran; safe to InteropCall
        ViewLoadFailed = 1,   // detail = "<url>: <description> (<domain>:<code>)"
        ViewReloaded = 2,     // a ReloadView/Navigate landed (DOM ready again; re-send state)
        ViewDestroyed = 3,    // DestroyView completed on the render thread
        UIModeEntered = 4,    // view = the UI-mode view; detail "switched" when you retargeted an active mode
        UIModeExited = 5,     // every exit path (programmatic, Escape, key, load boundary, render-death)
        FocusDenied = 6,      // another mod asked for UI mode while you own it; detail = its modId
        DisplayResized = 7,   // x = width, y = height (backbuffer pixels)
        ConsoleMessage = 8,   // detail = every console argument stringified and space-joined (objects as
                              // JSON); x = level (0 log, 1 warning, 2 error); y = source line
        RenderDead = 9,       // the overlay disabled itself for the session (also sent at RegisterMod if already dead)
        HostShutdown = 10,    // reserved
        UIModeRefused = 11,   // your RequestUIMode lost the race on the game thread; detail = reason
    };

    struct EventData {
        Event type;
        ViewId view;          // 0 when not view-specific
        std::int32_t x, y;    // event-specific integers (see Event)
        const char* detail;   // event-specific text ("" when none); valid for the call only
    };

    using EventFn = void (*)(const EventData* ev, void* user);
    using LogFn = void (*)(int level, const char* message, void* user);   // 0 info, 1 warning, 2 error
    using JsListenerFn4 = void (*)(ViewId view, const char* argument, void* user);
    // EvalJS completion: result = String(completion value) ("" for undefined);
    // exception = the thrown value's string, "" when the script succeeded.
    using JsResultFn = void (*)(ViewId view, const char* result, const char* exception, void* user);
    // PostGameTask (0.30.1): runs once, on the game thread, with the user pointer it was posted with.
    using GameTaskFn = void (*)(void* user);

    struct ModDesc {
        std::uint32_t size;              // = sizeof(ModDesc) — forward-compat
        const char* modId;               // slug, [A-Za-z0-9_.-], 1..32 chars, unique per process (case-insensitive)
        const char* displayName;         // for user-facing messages; nullptr = modId
        std::uint32_t modVersion;        // packed, for logs
        std::uint32_t minHostVersion;    // packed; host refuses (HostTooOld) if older
        CallbackThread callbackThread;   // where onEvent runs (default GameThread)
        EventFn onEvent;                 // optional
        LogFn onLog;                     // optional: host log lines about THIS mod, mirrored
        void* user;                      // handed back to onEvent/onLog
        const char* sessionName;         // storage isolation for this mod's views: nullptr/"isolated" = own
                                         // persistent jar named by modId (localStorage/IndexedDB/cookies
                                         // never collide between mods); "default" = the shared session
                                         // v1-v3 views use; any other name = a jar shared by every mod
                                         // that names it and by a mod whose modId is that name (scripts
                                         // cannot drive a mod whose jar a plugin uses). Decided at
                                         // RegisterMod; a manifest mod's choice wins when a plugin adopts it
    };

    struct ViewDesc {
        std::uint32_t size;              // = sizeof(ViewDesc)
        const char* name;                // unique within the mod (for logs / GetViewInfo)
        const char* htmlPath;            // relative to Magelight's runtime dir, or absolute
        Anchor anchor;                   // which display corner x/y offset from
        std::int32_t x, y, w, h;         // offset from the anchor corner; w/h in pixels
        bool fullscreen;                 // tracks the backbuffer; x/y/w/h ignored
        bool clickThrough;               // HUD: never receives input, never focused
        bool startVisible;
        Layer layer;
        float uiScale;                   // Ultralight DEVICE scale (0 = 1.0): the page lays out and
                                         // rasterizes at this scale — real DPI, sharp — instead of a
                                         // CSS transform that resamples a 1x raster. Change at runtime
                                         // with SetViewScale (0.26.9). window.devicePixelRatio mirrors it.
                                         // Clamped 1.0..3.0 since 0.30.3: to shrink a page, use a CSS transform
        DomReadyFn onDomReady;           // optional; the ViewDomReady event carries the same
    };

    // Flags for RequestUIMode.
    inline constexpr std::uint32_t kUIModeFlagNone = 0;
    inline constexpr std::uint32_t kUIModeFlagPause = 1;   // = EnterUIModeEx(view, true)
    inline constexpr std::uint32_t kUIModeFlagQueue = 2;   // held by someone else → wait your turn instead of
                                                            // Busy: Ok now, UIModeEntered when the holder releases
                                                            // (FIFO; ReleaseUIMode withdraws your queued requests)
    inline constexpr std::uint32_t kUIModeFlagNoTextEntry = 4;   // (0.26.6) do NOT raise the engine's text-entry
                                                            // gate for this UI mode. For pages with no text
                                                            // fields (a radial, a yes/no card): on Skyrim VR the
                                                            // gate starts the engine's virtual keyboard device,
                                                            // which OpenComposite hooks to raise ITS keyboard.

    // ── VR (0.18.0) ────────────────────────────────────────────────────────
    // Per-view placement in the headset. mode: 0 HeadLocked (glued to the head
    // — HUD widgets), 1 WorldLocked (placed once, never follows), 3 LazyFollow
    // (the default for panels: placed level in front, stays put until the gaze
    // drifts ~30 deg or the head moves ~0.5 m, then glides back). Zero for
    // distanceMeters/widthMeters keeps the host default for the view's layer.
    // Ignored on a flat runtime.
    struct VRPlacementDesc {
        std::uint32_t size;              // = sizeof(VRPlacementDesc)
        std::uint8_t  mode;
        float distanceMeters;            // metres in front of the head
        float widthMeters;               // panel width; height follows the texture aspect
        float heightOffset;              // metres above/below eye height
        float curvature;                 // reserved (IVROverlay_016 has no curvature)
        float autoCloseMeters;           // reserved
    };

    // Bind a view to a CONTROLLER button (VR only). Polled from the runtime
    // every frame whether or not UI mode is on — that is how a view opens with
    // no keyboard — then gated on the game thread exactly like a key binding
    // (no engine menu, no console, no text entry; while a page holds focus only
    // ITS OWN binding fires, to close). A bare button also fires during
    // gameplay, so prefer a modifier. button = 0 clears the binding.
    inline constexpr std::uint32_t kVRButtonNone       = 0;
    inline constexpr std::uint32_t kVRButtonMenu       = 1;    // B / Y
    inline constexpr std::uint32_t kVRButtonGrip       = 2;
    inline constexpr std::uint32_t kVRButtonA          = 7;    // A / X
    inline constexpr std::uint32_t kVRButtonStickClick = 32;
    inline constexpr std::uint32_t kVRButtonTrigger    = 33;
    inline constexpr std::uint32_t kVRButtonTouchpad   = 35;
    // Callback form (BindVRHotkeyCallback). Runs on the PRESENT thread the
    // moment the button edge is seen — post game work with PostGameTask.
    using VRHotkeyFn = void (*)(ViewId view, void* user);
    // SetVRButtonListener (0.26.0). PRESENT thread (post with PostGameTask).
    using VRButtonEdgeFn = void (*)(std::uint32_t button, std::uint32_t heldOther,
                                    std::uint8_t hand, void* user);
    struct VRHotkeyDesc {
        std::uint32_t size;              // = sizeof(VRHotkeyDesc)
        std::uint32_t button;            // kVRButton*
        std::uint32_t modifier;          // kVRButton* held alongside; kVRButtonNone = bare
        std::uint32_t action;            // kHotkeyAction*
        std::uint8_t  hand;              // 0 either, 1 left, 2 right
    };

    // Actions for BindHotkey (one binding per DirectInput scancode, process-wide).
    inline constexpr std::uint32_t kHotkeyActionUnbind = 0;             // scancode 0 = every binding of the view
    inline constexpr std::uint32_t kHotkeyActionToggleUIMode = 1;       // RequestUIMode / ReleaseUIMode + hide
    inline constexpr std::uint32_t kHotkeyActionToggleUIModePaused = 2; // same, with kUIModeFlagPause
    inline constexpr std::uint32_t kHotkeyActionToggleVisible = 3;      // ShowView on/off (the only action a Hud view may bind)

    // Trust model: this ABI carries no caller identity. Any consumer that
    // knows a ViewId can act on it — ShowView/Navigate/DestroyView/EvalJS and
    // listener registration — including ids owned by another mod (views are
    // addressable, not owned; the cooperative model is deliberate). What the
    // host DOES scope per mod: file reads, storage sessions, network policy,
    // hotkeys. Since 0.30.0 the Papyrus tier cannot touch a mod registered
    // through this API (its slug or its views) or a script-tier mod whose
    // storage jar a plugin uses, and a page's listener calls act only as that
    // page's own view. See docs/CPP.md "Trust model".
    struct MagelightApi4 {
        std::uint32_t apiVersion;   // = kApiVersion4
        const char* hostVersion;

        // v3 surface, identical layout
        ViewId (*CreateView)(const char* htmlPath, int x, int y, int w, int h,
                             DomReadyFn onDomReady, bool clickThrough, bool startVisible);
        bool (*IsViewValid)(ViewId view);
        void (*ShowView)(ViewId view, bool show);
        void (*SetViewBounds)(ViewId view, int x, int y, int w, int h);
        void (*RegisterJSListener)(ViewId view, const char* name, JsListenerFn callback);
        void (*InteropCall)(ViewId view, const char* functionName, const char* argument);
        void (*InvokeJS)(ViewId view, const char* script);
        void (*EnterUIMode)(ViewId view);
        void (*ExitUIMode)();
        bool (*IsUIModeActive)();
        void (*SetUIModeExitCallback)(UIModeExitFn cb);
        bool (*IsGpuAccelerated)();
        ImageId (*RegisterTextureImage)(const char* name, ID3D11ShaderResourceView* srv,
                                        std::uint32_t width, std::uint32_t height);
        void (*UpdateTextureImage)(ImageId image, ID3D11ShaderResourceView* srv);
        void (*InvalidateImage)(ImageId image);
        void (*UnregisterImage)(ImageId image);
        const char* (*ImageUrl)(ImageId image);
        void (*EnterUIModeEx)(ViewId view, bool pauseGame);

        // v4 additions
        Result (*RegisterMod)(const ModDesc* desc, ModId* outMod);  // same modId as a manifest mod = ADOPT it
        void   (*UnregisterMod)(ModId mod);                 // releases UI mode, then destroys its views (game-thread
                                                            // tasks; no ViewDestroyed events reach the gone mod)
        Result (*CreateViewEx)(ModId mod, const ViewDesc* desc, ViewId* outView);
        Result (*DestroyView)(ViewId view);                 // async; Busy if it is the UI-mode view
        Result (*ReloadView)(ViewId view);                  // ViewReloaded follows DOM ready
        Result (*Navigate)(ViewId view, const char* url);   // file:/// (or a path); http = Denied
        Result (*RegisterJSListenerEx)(ViewId view, const char* name, JsListenerFn4 cb, void* user);
                                                            // "magelight" and names starting "__" belong to
                                                            // the host's page script: InvalidArgument (0.30.0;
                                                            // RegisterJSListener drops them the same way)
        Result (*RequestUIMode)(ViewId view, std::uint32_t flags);   // Ok = entry queued: UIModeEntered confirms,
                                                            // UIModeRefused reports a lost race. Busy → the
                                                            // holder hears FocusDenied. Hud/click-through → Denied.
                                                            // While YOU hold UI mode, another of your views
                                                            // switches in place (UIModeEntered, detail "switched")
        Result (*ReleaseUIMode)(ModId mod);                 // only the owner may release
        ModId  (*GetUIModeOwner)();                         // 0 = none
        Result (*RaiseView)(ViewId view);                   // to the top of its layer
        Result (*GetViewInfo)(ViewId view, ViewDesc* out);  // v4-owned views; out->size set by caller; anchor
                                                            // reconstructed so the desc round-trips; startVisible
                                                            // = current visibility; strings live until DestroyView
        void   (*GetDisplaySize)(std::int32_t* w, std::int32_t* h);   // 0,0 before the first frame
        std::int32_t (*QueryCapability)(const char* name);  // 1/0. Case-insensitive here. The authoritative
                                                            // name list is QueryCapability() in the host; as of
                                                            // 0.28.4: "gpu" "textureImage" "clipPathHole"
                                                            // "pause" "events" "clipboard" "networkDeny"
                                                            // "sessions" "manifest" "http" "vr" "hotkeys"
                                                            // "evaljs" "pagebridge" "cutout" "hibernate"
                                                            // "inspector" "ime" (0.27.0) "loopback"
                                                            // "escapeCapture" "viewOrder" "scrollStep" (0.28.0)
                                                            // "networkPolicy" (0.28.2) "sound" (0.29.0). The page-injected
                                                            // window.__MAGELIGHT__.capabilities (SDK: host.can)
                                                            // and the SDK mock carry
                                                            // this same set under the camelCase spellings shown
                                                            // (the page side is a plain key lookup).
        const char* (*GetLastErrorMessage)(ModId mod);      // per-mod storage, valid until the mod's next failing
                                                            // call or UnregisterMod — copy it; "" if none
        Result (*BindHotkey)(ViewId view, std::uint32_t dxScancode, std::uint32_t action);  // kHotkeyAction*; Busy names
                                                            // the mod holding the key, Denied = the host's toggle key.
                                                            // Fires on key-down outside engine menus/console/text entry;
                                                            // while a page has key focus only ITS OWN key fires (close)
        Result (*RegisterTextureImageEx)(ModId mod, const char* name, ID3D11ShaderResourceView* srv,
                                         std::uint32_t width, std::uint32_t height, ImageId* out);

        std::uint32_t hostVersionNumber;                    // packed MAJOR*10000 + MINOR*100 + PATCH

        // ── appended in 0.14.0 — gate on hostVersionNumber >= 1400 ──
        Result (*EvalJS)(ViewId view, const char* script, JsResultFn cb, void* user);   // runs on the page's
                                                            // JS thread next frame; cb on your callback thread.
                                                            // The synchronous twin of InvokeJS: read state back,
                                                            // catch exceptions (InvokeJS only logs them)

        // ── appended in 0.16.0 — gate on hostVersionNumber >= 1600 ──
        Result (*SetViewCutout)(ViewId view, std::int32_t x, std::int32_t y, std::int32_t w, std::int32_t h);
                                                            // the compositor DISCARDS this rect of the view (view
                                                            // pixels) so the game shows through; w or h <= 0 clears.
                                                            // Works on the GPU and CPU paths alike (no clip-path)
        Result (*SetViewHibernate)(ViewId view, std::uint32_t idleMs);   // hidden this long -> the View and its
                                                            // texture are released; ShowView(true) reloads the page,
                                                            // calls sent meanwhile land after DOM ready, and your
                                                            // onDomReady/ViewDomReady fire again. 0 = never

        // ── appended in 0.18.0 (VR-4) — gate on hostVersionNumber >= 1800 ──
        // No-ops on a flat runtime; QueryCapability("vr") says which you got.
        Result (*SetViewVRPlacement)(ViewId view, const VRPlacementDesc* desc);   // nullptr = host defaults
        Result (*GetViewVRPlacement)(ViewId view, VRPlacementDesc* out);          // out->size set by the caller
        Result (*RecenterVRView)(ViewId view);                                    // re-place in front of the head now
        Result (*BindVRHotkey)(ViewId view, const VRHotkeyDesc* desc);            // nullptr/button 0 clears

        // ── appended in 0.21.0 — gate on hostVersionNumber >= 2100 ──
        // The same binding, but it calls YOU instead of running desc->action.
        // Needed by any mod whose open/close does more than show a view: SA
        // gathers page data, snapshots the pause setting and raises a text-
        // entry gate, none of which the host's built-in toggle knows about,
        // so a built-in binding would desync its bookkeeping. desc->action is
        // ignored. cb == nullptr (or button 0) clears the binding.
        Result (*BindVRHotkeyCallback)(ViewId view, const VRHotkeyDesc* desc,
                                       VRHotkeyFn cb, void* user);

        // ── appended in 0.26.0 — gate on hostVersionNumber >= 2600 ──
        // Raw controller button EDGES, so a mod can let the user pick a chord
        // by pressing it (the keyboard "click, then press a key" flow, for
        // controllers). While a listener is set, each button-down on either
        // hand is reported once with `heldOther` = one other kVRButton* held
        // on that hand at that moment (0 = none) — so "hold Grip, press B"
        // arrives as button=kVRButtonMenu, heldOther=kVRButtonGrip. All view
        // hotkey bindings are SUPPRESSED while a listener is set, so the
        // press being captured cannot also toggle a menu. Runs on the
        // PRESENT thread. cb == nullptr clears it.
        Result (*SetVRButtonListener)(VRButtonEdgeFn cb, void* user);

        // ── appended in 0.26.8 — gate on hostVersionNumber >= 2608 ──
        // Resolve a view NAME to its ViewId within your mod (or a manifest mod
        // your DLL adopted with the same modId). The C++ twin of the Papyrus
        // FindView — needed to drive a manifest-declared view from C++, since
        // every other call takes a ViewId. Ok + *out set on a hit; InvalidView
        // if the name is not one of your mod's views. *out is 0 on any failure.
        Result (*FindView)(ModId mod, const char* name, ViewId* out);

        // ── appended in 0.26.9 — gate on hostVersionNumber >= 2609 ──
        // Set the view's Ultralight device scale at runtime (see ViewDesc::uiScale).
        // The page re-lays out; its devicePixelRatio becomes `scale`. Cutout and
        // image rects are in VIEW PIXELS = CSS px * scale. Clamped 1.0..3.0 (0.5..3.0 before
        // 0.30.3; below 1 Ultralight clipped the page): shrink a page with a CSS transform.
        Result (*SetViewScale)(ViewId view, float scale);
        // ── 0.27.0 (no new fields): native IME. Text fields in the UI-mode view take
        //    CJK composition: the window's IME context attaches on field focus (the
        //    bridge detects it — pages need NO code), the pre-edit is drawn inline as
        //    the field's selection, the candidate list opens at the caret, and keys the
        //    IME consumed never reach the page. A page that wants
        //    an indicator listens for the 'magelight:ime' window event ({state, text}).
        //    QueryCapability("ime") == 1. Flat only (VR: the runtime keyboard owns text).
        // ── 0.26.11 (no new fields): RequestUIMode on the view that ALREADY holds
        //    UI mode retargets the PAUSE flag (kUIModeFlagPause) IN PLACE — the live
        //    focus menu's kPausesGame and the engine's pause counter are adjusted;
        //    no menu is hidden or re-shown, so your close detection never fires.
        //    (0.26.10 did it by hide + show, which tripped exactly that — withdrawn.)
        //    Before 2610 a same-view re-request returned Ok and kept the old pause.
        //    Gate on hostVersionNumber >= 2611 if you rely on it.
        // ── appended in 0.28.0 — gate on hostVersionNumber >= 2800 ──
        // The page owns Escape: while set, Escape is delivered to the page as a
        // key (keydown/keyup) and does NOT leave UI mode — for a modal or an
        // editing control that closes itself. Clear it to hand Escape back.
        // A page can do the same without C++: magelight.send('__escapecapture','1'|'0').
        Result (*SetEscapeCapture)(ViewId view, bool capture);
        // Host the Web Inspector for a page (needs the runtime's inspector assets).
        Result (*ShowInspector)(ViewId view, bool show);
        Result (*IsInspectorVisible)(ViewId view, bool* outVisible);
        // Explicit z-order within the view's layer (higher draws later / on top);
        // RaiseView is "above everything so far". GetViewOrder reads it back.
        Result (*SetViewOrder)(ViewId view, std::uint64_t order);
        Result (*GetViewOrder)(ViewId view, std::uint64_t* outOrder);
        // Pixels scrolled per wheel notch for this view (default 40; 120 is a
        // common alternative).
        Result (*SetScrollStep)(ViewId view, int px);
        // ── appended in 0.28.2 — gate on hostVersionNumber >= 2802 ──
        // Network reach for EVERY page of this mod, existing views included.
        // Default FileOnly (0.30.0 — gate on hostVersionNumber >= 3000; before
        // it the default was LoopbackOnly). A mod whose page talks to a server
        // on this machine asks for LoopbackOnly; one whose dashboard talks to
        // the internet (model catalogs, plugin indexes, a user-configured
        // provider) asks for Any. Call it once after RegisterMod; other mods
        // keep the sandbox untouched. An unknown value is InvalidArgument.
        Result (*SetNetworkPolicy)(ModId mod, NetworkPolicy policy);
        // ── appended in 0.29.0 — gate on hostVersionNumber >= 2900 ──
        // UI sounds. Ultralight has no media stack (<audio> and Web Audio do
        // nothing), so the host plays through the game's own audio, which also
        // respects the player's UI volume. `name`: a built-in — "ok"/"click",
        // "cancel", "prevnext", "focus"/"hover", "open", "close", "inactive"
        // (the vanilla UIMenu* descriptors), ANY vanilla UI*/ITM* descriptor by
        // its EditorID ("UIJournalOpen", "ITMGoldUpSD" — 134, case-insensitive),
        // "none" for explicit silence — or "Plugin.esp|0xFormID" for any
        // SNDR a mod ships. Unknown names log once and stay silent. A page can
        // do the same without C++: magelight.sound('click'), or the markup
        // convention data-ml-sound="click" / data-ml-sound-hover="focus" the
        // injected bridge wires up (hover throttled host-side; page-driven
        // sounds play only while the view is visible). QueryCapability("sound").
        Result (*PlayUISound)(ViewId view, const char* name);
        // Played by the host when this view enters / leaves UI mode; "" or
        // nullptr clears either side. Manifest: "sounds": { "open": "open", "close": "close" }.
        Result (*SetViewSounds)(ViewId view, const char* open, const char* close);
        // ── appended in 0.30.1 — gate on hostVersionNumber >= 3001 ──
        // Run fn(user) once on the game thread as an SKSE task. Any thread may
        // call. From a callback inside a frame the post goes to a host thread
        // that hands it to SKSE, so the caller never waits on SKSE's task lock
        // (see the threading contract), and such posts run in call order
        // together with the host's own work from the same frames (UI-mode calls
        // made there included). Anywhere else it goes straight to SKSE, in
        // order with your own AddTask calls there; such a post can run before
        // an earlier in-frame one. fn is a plain function pointer: box what it
        // needs on the heap, pass it as user (handed back untouched, no cancel)
        // and free it in fn. Needs no registered mod. Ok = queued; a post SKSE
        // refuses is logged and fn never runs; a fault in fn is logged with its
        // module and skipped. Null fn: InvalidArgument; before SKSE's task
        // interface exists: NotReady.
        Result (*PostGameTask)(GameTaskFn fn, void* user);
    };

    inline constexpr std::uint32_t PackVersion(std::uint32_t major, std::uint32_t minor, std::uint32_t patch)
    {
        return major * 10000u + minor * 100u + patch;
    }

#ifndef MAGELIGHT_API_NO_LOADER
    // Resolve an API struct from an already-loaded Magelight.dll. Returns
    // nullptr when Magelight is absent or doesn't serve that version — treat
    // it as "host not installed" and no-op, never fail hard.
    inline const void* RequestApiRaw(std::uint32_t version)
    {
        const HMODULE mod = GetModuleHandleW(L"Magelight.dll");
        if (!mod) return nullptr;
        using RequestFn = void* (*)(std::uint32_t);
        const auto request =
            reinterpret_cast<RequestFn>(GetProcAddress(mod, "Magelight_RequestApi"));
        if (!request) return nullptr;
        return request(version);
    }
    inline const MagelightApi1* RequestApi(std::uint32_t version = kApiVersion1)
    {
        return static_cast<const MagelightApi1*>(RequestApiRaw(version));
    }
    inline const MagelightApi2* RequestApi2()
    {
        return static_cast<const MagelightApi2*>(RequestApiRaw(kApiVersion2));
    }
    inline const MagelightApi3* RequestApi3()
    {
        return static_cast<const MagelightApi3*>(RequestApiRaw(kApiVersion3));
    }
    inline const MagelightApi4* RequestApi4()
    {
        return static_cast<const MagelightApi4*>(RequestApiRaw(kApiVersion4));
    }
#endif

}  // namespace MAGELIGHT_API
