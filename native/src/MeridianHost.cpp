#include "MeridianHost.h"

#include "PCH.h"

// ViewDllLoader.h defines WIN32_LEAN_AND_MEAN, NOGDI and NOMINMAX itself and
// undefines them afterwards. CMakeLists.txt defines two of those project-wide,
// so the header's #define is a redefinition (C4005) and its #undef drops ours
// for the rest of this file, where nothing else includes Windows.h. The header
// is vendored unmodified (include/MeridianUIAPI/README.md), so the warning is
// silenced around it rather than edited out of it.
#pragma warning(push)
#pragma warning(disable: 4005)
#include "MeridianUIAPI/ViewDllLoader.h"
#pragma warning(pop)

namespace SNRom {

    namespace {

        namespace View = Meridian::UI::View;

        // The page is shipped at Data/MeridianUI/snrelationships/index.html.
        // ownerName must equal the URL's host: Meridian pins the native
        // bindings to that origin and refuses any other.
        constexpr auto kOwner = "snrelationships";
        constexpr auto kView = "dashboard";
        constexpr auto kUrl = "mod://snrelationships/index.html";

        void __cdecl OnDOMReady(View::ViewHandle) {
            SKSE::log::info("Dashboard page loaded ({})", kUrl);
        }

        class MeridianHost final : public ViewHost {
        public:
            explicit MeridianHost(View::IViewAPI* a_api) : _api(a_api) {}

            [[nodiscard]] const char* Name() const override { return "Meridian UI"; }

            bool Create() override {
                View::ViewCreateInfo info{};
                info.ownerName = kOwner;
                info.viewName = kView;
                info.startUrl = kUrl;
                info.initiallyVisible = false;
                info.onDOMReady = OnDOMReady;
                _view = _api->CreateView(&info);
                return _view != View::INVALID_VIEW_HANDLE;
            }

            bool Listen(const char* a_name, ListenerFn a_fn) override {
                return _api->RegisterListener(_view, a_name, a_fn);
            }

            bool Show() override { return _api->Show(_view); }

            FocusOutcome Focus() override {
                // TryFocus never steals focus from another mod's Meridian
                // view; it answers Busy instead.
                switch (_api->TryFocus(_view, View::FocusMode::PauseGame)) {
                case View::FocusResult::Granted:
                case View::FocusResult::AlreadyFocused:
                    return FocusOutcome::Granted;
                case View::FocusResult::Busy:
                    return FocusOutcome::Busy;
                case View::FocusResult::NotReady:
                    return FocusOutcome::NotReady;
                default:
                    return FocusOutcome::Failed;
                }
            }

            void Hide() override {
                // Both are idempotent, and a hidden view gives up focus on its
                // own; Unfocus first says which one we meant.
                _api->Unfocus(_view);
                _api->Hide(_view);
            }

            [[nodiscard]] bool HasFocus() const override { return _api->HasFocus(_view); }

            bool Send(const std::string& a_json) override {
                // An object literal, not a quoted string: the JSON is ASCII-only
                // (the caller dumps it with ensure_ascii), so U+2028 and every
                // other character that could end a script early is escaped.
                // snromReceive accepts an object or text alike.
                const std::string script = "snromReceive(" + a_json + ")";
                return _api->ExecuteJavaScript(_view, script.c_str());
            }

        private:
            View::IViewAPI*  _api;
            View::ViewHandle _view{ View::INVALID_VIEW_HANDLE };
        };
    }

    std::unique_ptr<ViewHost> AcquireMeridian() {
        Meridian::UI::Settings settings{};
        auto* api = View::Query(&settings, "SkyrimNetRelationships");
        if (!api) {
            return nullptr;
        }
        return std::make_unique<MeridianHost>(api);
    }
}
