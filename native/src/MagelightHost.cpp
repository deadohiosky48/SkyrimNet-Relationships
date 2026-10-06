#include "MagelightHost.h"

#include "PCH.h"

#include "MagelightUI/MagelightUI_API.h"

#include <atomic>
#include <filesystem>
#include <mutex>
#include <vector>

// Written from the vendored header (include/MagelightUI/README.md), Magelight's
// C++ guide and its Papyrus tier's documentation. Magelight renders with
// Ultralight, as Prisma does, so the page stays on plain ES2017.
//
// WHAT DIFFERS FROM THE OTHER TWO HOSTS, and why:
//
//  - Page events must not post SKSE tasks. Magelight calls listeners on the
//    render thread inside the game's Present, and forbids SKSE's AddTask there:
//    on Skyrim VR SKSE drains its queues on job threads that can wait on that
//    frame, so the post can hang the game. The dashboard's listeners do call
//    AddTask, so each is wrapped: the text is copied and handed to Magelight's
//    PostGameTask (0.30.1+), which runs it on the game thread, where AddTask is
//    safe.
//  - Leaving UI mode does not hide a Magelight view. Escape, a load, or a
//    render fault can end UI mode without the page asking to close, which would
//    leave the dashboard on screen with no input. UIModeExited for our view
//    hides it.
//  - The page path is absolute, resolved from this DLL's own location (the
//    guide: not from the working directory), and the page lives where Magelight
//    pins this mod's file reads: Data/Magelight/snrelationships/.
namespace SNRom {

    namespace {

        namespace API = MAGELIGHT_API;

        constexpr auto kModId = "snrelationships";
        // 0.30.5, packed MAJOR*10000 + MINOR*100 + PATCH: what SeverActions
        // 4.2.0 bundles. v4 is older (0.10.0); PostGameTask needs 0.30.1.
        constexpr std::uint32_t kMinHost = 3005;

        std::atomic_bool g_domReady{ false };
        std::atomic<API::ViewId> g_view{ 0 };

        std::string PagePath() {
            // <Data>/SKSE/Plugins/SkyrimNetRelationships.dll -> <Data>/Magelight/snrelationships/index.html
            wchar_t buffer[MAX_PATH]{};
            const HMODULE self = GetModuleHandleW(L"SkyrimNetRelationships.dll");
            if (!self || GetModuleFileNameW(self, buffer, MAX_PATH) == 0) {
                return {};
            }
            const auto data = std::filesystem::path(buffer).parent_path().parent_path().parent_path();
            return (data / "Magelight" / kModId / "index.html").string();
        }

        void OnDomReady(API::ViewId) {
            // Inside the frame: a flag and a log line, nothing that posts.
            g_domReady = true;
            SKSE::log::info("Dashboard page loaded (Magelight/{}/index.html)", kModId);
        }

        // Events arrive as SKSE tasks on the game thread (CallbackThread::GameThread).
        void OnEvent(const API::EventData* a_event, void* a_user);

        void OnLog(int a_level, const char* a_message, void*) {
            if (a_level >= 2) {
                SKSE::log::error("Magelight: {}", a_message ? a_message : "");
            } else if (a_level == 1) {
                SKSE::log::warn("Magelight: {}", a_message ? a_message : "");
            } else {
                SKSE::log::info("Magelight: {}", a_message ? a_message : "");
            }
        }

        // One registered listener: the dashboard's function, called later on
        // the game thread with a copy of the text.
        struct Listener {
            const API::MagelightApi4* api;
            ListenerFn                fn;
        };

        struct Posted {
            ListenerFn  fn;
            std::string text;
        };

        void RunPosted(void* a_user) {
            std::unique_ptr<Posted> posted{ static_cast<Posted*>(a_user) };
            posted->fn(posted->text.c_str());
        }

        void OnPageCall(API::ViewId, const char* a_argument, void* a_user) {
            // RENDER THREAD, inside the frame. Copy, post, return.
            const auto* listener = static_cast<const Listener*>(a_user);
            auto* posted = new Posted{ listener->fn, a_argument ? a_argument : "" };
            if (listener->api->PostGameTask(RunPosted, posted) != API::Result::Ok) {
                delete posted;
                SKSE::log::warn("Magelight refused to post a page event to the game thread; it was dropped");
            }
        }

        class MagelightHost final : public ViewHost {
        public:
            explicit MagelightHost(const API::MagelightApi4* a_api) : _api(a_api) {}

            ~MagelightHost() override {
                if (_mod) {
                    _api->UnregisterMod(_mod);
                }
            }

            [[nodiscard]] const char* Name() const override { return "Magelight UI"; }

            bool Create() override {
                API::ModDesc mod{};
                mod.size = sizeof(mod);
                mod.modId = kModId;
                mod.displayName = "SkyrimNet Relationships";
                mod.modVersion = 0;
                mod.minHostVersion = kMinHost;
                mod.callbackThread = API::CallbackThread::GameThread;
                mod.onEvent = OnEvent;
                mod.onLog = OnLog;
                mod.user = this;
                mod.sessionName = nullptr;  // our own storage jar
                if (const auto r = _api->RegisterMod(&mod, &_mod); r != API::Result::Ok) {
                    SKSE::log::error("Magelight UI refused to register this mod (result {}{})", static_cast<int>(r),
                                     r == API::Result::HostTooOld ? ": Magelight UI 0.30.5 or newer is needed" : "");
                    _mod = 0;
                    return false;
                }
                return EnsureView();
            }

            bool Listen(const char* a_name, ListenerFn a_fn) override {
                // Becomes window.<a_name>(text) on the page, as with Prisma.
                _listeners.push_back(std::make_unique<Listener>(Listener{ _api, a_fn }));
                _names.emplace_back(a_name);
                return !g_view || Register(_names.size() - 1);
            }

            bool Show() override {
                if (!EnsureView()) {
                    return false;
                }
                _api->ShowView(g_view, true);
                return _api->IsViewValid(g_view);
            }

            FocusOutcome Focus() override {
                if (!EnsureView() || !g_domReady) {
                    return FocusOutcome::NotReady;
                }
                if (HasFocus()) {
                    return FocusOutcome::Granted;
                }
                // NEVER STEAL FOCUS, as with the other hosts: a page of another
                // mod holding UI mode (SeverActions' menus) is reported as Busy.
                if (_api->GetUIModeOwner() != 0) {
                    return FocusOutcome::Busy;
                }
                _api->ShowView(g_view, true);
                switch (_api->RequestUIMode(g_view, API::kUIModeFlagPause)) {
                case API::Result::Ok:
                    return FocusOutcome::Granted;  // UIModeEntered confirms on the game thread
                case API::Result::Busy:
                    _api->ShowView(g_view, false);
                    return FocusOutcome::Busy;
                case API::Result::NotReady:
                    _api->ShowView(g_view, false);
                    return FocusOutcome::NotReady;
                default:
                    _api->ShowView(g_view, false);
                    SKSE::log::warn("Magelight UI would not give the dashboard input: {}", _api->GetLastErrorMessage(_mod));
                    return FocusOutcome::Failed;
                }
            }

            void Hide() override {
                if (!g_view) {
                    return;
                }
                if (HasFocus()) {
                    _api->ReleaseUIMode(_mod);
                }
                _api->ShowView(g_view, false);
            }

            [[nodiscard]] bool HasFocus() const override { return _mod && _api->GetUIModeOwner() == _mod; }

            // Magelight mutes the game's keyboard device while UI mode is on
            // ("keyboard device poll hooked (muted while UI mode is on)"), so
            // the dashboard hotkey opened it and could not close it (wpb16,
            // 2026-10-06). The page hears the key instead.
            [[nodiscard]] bool PageClosesOnHotkey() const override { return true; }

            bool Send(const std::string& a_json) override {
                // Handed over as a string: window.snromReceive(text), as Prisma.
                if (!g_view) {
                    return false;
                }
                _api->InteropCall(g_view, "snromReceive", a_json.c_str());
                return _api->IsViewValid(g_view);
            }

            // UI mode ended for our view without the page asking: hide it, so
            // the dashboard is never left on screen with no input.
            void OnUIModeExited(API::ViewId a_view) {
                if (a_view == g_view && g_view) {
                    _api->ShowView(g_view, false);
                    SKSE::log::info("Dashboard closed by Magelight UI (UI mode ended)");
                }
            }

        private:
            // The view is created at kDataLoaded when Magelight's renderer is
            // ready, and otherwise on first use: CreateViewEx answers NotReady
            // before the renderer exists.
            bool EnsureView() {
                if (g_view) {
                    return true;
                }
                if (!_mod) {
                    return false;
                }
                const auto page = PagePath();
                if (page.empty()) {
                    SKSE::log::error("Could not work out where the dashboard page is for Magelight UI");
                    return false;
                }
                API::ViewDesc view{};
                view.size = sizeof(view);
                view.name = "dashboard";
                view.htmlPath = page.c_str();
                view.anchor = API::Anchor::TopLeft;
                view.fullscreen = true;
                view.clickThrough = false;
                view.startVisible = false;
                view.layer = API::Layer::Panel;
                view.uiScale = 0.0f;
                view.onDomReady = OnDomReady;
                API::ViewId id = 0;
                const auto r = _api->CreateViewEx(_mod, &view, &id);
                if (r == API::Result::NotReady) {
                    return false;  // tried again on first use
                }
                if (r != API::Result::Ok || !id) {
                    SKSE::log::error("Magelight UI refused the dashboard view (result {}): {}", static_cast<int>(r),
                                     _api->GetLastErrorMessage(_mod));
                    return false;
                }
                g_view = id;
                for (std::size_t i = 0; i < _names.size(); ++i) {
                    Register(i);
                }
                return true;
            }

            bool Register(std::size_t a_index) {
                const auto r = _api->RegisterJSListenerEx(g_view, _names[a_index].c_str(), OnPageCall,
                                                          _listeners[a_index].get());
                if (r != API::Result::Ok) {
                    SKSE::log::error("Magelight UI refused listener {} (result {})", _names[a_index], static_cast<int>(r));
                }
                return r == API::Result::Ok;
            }

            const API::MagelightApi4*              _api;
            API::ModId                             _mod{ 0 };
            std::vector<std::unique_ptr<Listener>> _listeners;
            std::vector<std::string>               _names;
        };

        void OnEvent(const API::EventData* a_event, void* a_user) {
            if (!a_event) {
                return;
            }
            auto* host = static_cast<MagelightHost*>(a_user);
            switch (a_event->type) {
            case API::Event::UIModeExited:
                host->OnUIModeExited(a_event->view);
                break;
            case API::Event::ViewLoadFailed:
                SKSE::log::error("Magelight UI could not load the dashboard page: {}", a_event->detail ? a_event->detail : "");
                break;
            case API::Event::ViewReloaded:
                SKSE::log::info("Magelight UI reloaded the dashboard page");
                break;
            case API::Event::RenderDead:
                SKSE::log::error("Magelight UI turned itself off after a render fault: no dashboard this session");
                break;
            default:
                break;
            }
        }
    }

    std::unique_ptr<ViewHost> AcquireMagelight() {
        const auto* api = API::RequestApi4();
        if (!api) {
            return nullptr;
        }
        if (api->hostVersionNumber < kMinHost) {
            SKSE::log::info("Magelight UI {} found, but the dashboard needs 0.30.5 or newer", api->hostVersion);
            return nullptr;
        }
        return std::make_unique<MagelightHost>(api);
    }
}
