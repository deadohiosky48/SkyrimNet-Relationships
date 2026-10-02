#include "PrismaHost.h"

#include "PCH.h"

// The header calls GetModuleHandle with a wide string, which assumes a UNICODE
// build; this project is not one, so the macro names the ANSI function. The
// header may not be edited (include/PrismaUI/README.md), so the macro is
// pointed at the wide function around it instead, and put back after.
#pragma push_macro("GetModuleHandle")
#undef GetModuleHandle
#define GetModuleHandle GetModuleHandleW
#include "PrismaUI/PrismaUI_API.h"
#pragma pop_macro("GetModuleHandle")

// Written from the vendored header and Prisma UI's public API documentation
// only (include/PrismaUI/README.md). Prisma renders with Ultralight, not
// Chromium, so the page stays on plain ES2017 and conservative CSS (design 7.1).
namespace SNRom {

    namespace {

        namespace API = PRISMA_UI_API;

        // Relative to Data/PrismaUI/views/, Prisma's base directory. The page
        // ships there as well as under Data/MeridianUI/ (tools/package.ps1).
        constexpr auto kPage = "snrelationships/index.html";

        // Set by Prisma's DOM-ready callback. Until then the page cannot take
        // focus, which Meridian reports as NotReady and Prisma does not, so
        // the host tracks it itself.
        std::atomic_bool g_domReady{ false };

        void OnDomReady(PrismaView) {
            g_domReady = true;
            SKSE::log::info("Dashboard page loaded (PrismaUI/views/{})", kPage);
        }

        class PrismaHost final : public ViewHost {
        public:
            explicit PrismaHost(API::IVPrismaUI1* a_api) : _api(a_api) {}

            [[nodiscard]] const char* Name() const override { return "Prisma UI"; }

            bool Create() override {
                // ONE VIEW PER PLUGIN, as Prisma's documentation asks; the page
                // already manages everything it shows. A new view is visible,
                // so it is hidden at once and stays so until the hotkey.
                _view = _api->CreateView(kPage, OnDomReady);
                if (!_api->IsValid(_view)) {
                    return false;
                }
                _api->Hide(_view);
                return true;
            }

            bool Listen(const char* a_name, ListenerFn a_fn) override {
                // Becomes window.<a_name>, as Meridian's RegisterListener does.
                // Returns nothing, so success is the view being valid.
                _api->RegisterJSListener(_view, a_name, a_fn);
                return _api->IsValid(_view);
            }

            bool Show() override {
                _api->Show(_view);
                return !_api->IsHidden(_view);
            }

            FocusOutcome Focus() override {
                if (!g_domReady) {
                    return FocusOutcome::NotReady;
                }
                if (_api->HasFocus(_view)) {
                    return FocusOutcome::Granted;
                }
                // NEVER STEAL FOCUS, as with Meridian's TryFocus. Prisma's
                // Focus answers only yes or no, so another Prisma view holding
                // focus - SkyrimNet's own chat, SeverActions' prompts - is
                // checked first and reported as Busy.
                if (_api->HasAnyActiveFocus()) {
                    return FocusOutcome::Busy;
                }
                return _api->Focus(_view, true) ? FocusOutcome::Granted : FocusOutcome::Failed;
            }

            void Hide() override {
                // Hide unfocuses a focused view itself, and unpauses the game;
                // Unfocus first says which one we meant, as with Meridian.
                if (_api->HasFocus(_view)) {
                    _api->Unfocus(_view);
                }
                _api->Hide(_view);
            }

            [[nodiscard]] bool HasFocus() const override { return _api->HasFocus(_view); }

            bool Send(const std::string& a_json) override {
                // Handed over as a string, which snromReceive accepts as well
                // as an object. InteropCall is Prisma's fast path and returns
                // nothing.
                _api->InteropCall(_view, "snromReceive", a_json.c_str());
                return _api->IsValid(_view);
            }

        private:
            API::IVPrismaUI1* _api;
            PrismaView        _view{ 0 };
        };
    }

    std::unique_ptr<ViewHost> AcquirePrisma() {
        auto* api = API::RequestPluginAPI<API::IVPrismaUI1>();
        if (!api) {
            return nullptr;
        }
        return std::make_unique<PrismaHost>(api);
    }
}
