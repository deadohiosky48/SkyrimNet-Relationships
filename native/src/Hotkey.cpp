#include "Hotkey.h"

#include "PCH.h"

#include "Dashboard.h"
#include "Notices.h"

#include <mutex>

// MapVirtualKeyW, GetAsyncKeyState and the VK_ constants. After PCH.h on
// purpose: Windows.h defines macros (SendMessage, GetObject and friends) that
// would rewrite CommonLib's declarations if it came first.
#include <Windows.h>

namespace SNRom::Hotkey {

    namespace {

        // What the input sink checks: the DirectInput scan code of the key (0,
        // unbound) and the virtual key of the modifier that must be held with
        // it (0, none). ONE atomic, so the sink never sees a new key with the
        // old modifier. Written by Bind, read on the input thread, which is
        // not the main thread.
        struct Bound {
            std::uint32_t scan = 0;
            std::uint32_t modifier = 0;
        };

        std::array<std::atomic<Bound>, kKeys> g_bound{};

        // ONE ACTION PER PRESS. Set by the sink when it queues one and cleared
        // when that task runs, so two key-down events delivered in the same
        // frame (a repeat, or a second device reporting the same key) cannot
        // queue an open and then a close.
        std::array<std::atomic<bool>, kKeys> g_queued{};

        // The last request and what Bind made of it, per key. Guarded, because
        // Papyrus and the settings watcher both call Bind.
        std::mutex                                g_lock;
        std::array<std::optional<Request>, kKeys> g_requested;
        std::array<bool, kKeys>                   g_result{ true, true, true, true };

        constexpr std::array<std::string_view, kKeys> kNames{ "dashboard", "reread", "reauthor", "enroll" };
        constexpr std::array<std::string_view, kKeys> kLabels{ "Dashboard hotkey", "Re-read hotkey",
                                                               "Re-author hotkey", "Enroll hotkey" };
        constexpr std::array<std::string_view, kKeys> kSettings{ "dashboardHotkey", "rereadKey", "reauthorKey",
                                                                 "enrollKey" };

        constexpr std::size_t Index(Key a_key) {
            return static_cast<std::size_t>(a_key);
        }

        // THE dashboardHotkeyModifier OPTIONS (manifest.yaml), in both
        // directions: name to virtual key for the watcher, virtual key to name
        // for the log. One side of the keyboard each, because GetAsyncKeyState
        // tells the sides apart and a player who chose Left Ctrl should not
        // find Right Ctrl opening it too.
        struct Modifier {
            std::int32_t     vk;
            std::string_view name;
        };

        constexpr std::array kModifiers{
            Modifier{ 0, "None" },
            Modifier{ VK_LSHIFT, "Left Shift" },
            Modifier{ VK_RSHIFT, "Right Shift" },
            Modifier{ VK_LCONTROL, "Left Ctrl" },
            Modifier{ VK_RCONTROL, "Right Ctrl" },
            Modifier{ VK_LMENU, "Left Alt" },
            Modifier{ VK_RMENU, "Right Alt" },
        };

        const Modifier* FindModifier(std::int32_t a_vk) {
            for (const auto& modifier : kModifiers) {
                if (modifier.vk == a_vk) {
                    return &modifier;
                }
            }
            return nullptr;
        }

        // ASCII only, and no locale: the option names are ASCII, and a
        // locale-aware compare would be one more thing a system setting could
        // change under us.
        constexpr char Lower(char a_char) {
            return a_char >= 'A' && a_char <= 'Z' ? static_cast<char>(a_char - 'A' + 'a') : a_char;
        }

        bool SameIgnoringCase(std::string_view a_left, std::string_view a_right) {
            if (a_left.size() != a_right.size()) {
                return false;
            }
            for (std::size_t i = 0; i < a_left.size(); ++i) {
                if (Lower(a_left[i]) != Lower(a_right[i])) {
                    return false;
                }
            }
            return true;
        }

        // Windows virtual-key code -> the DirectInput scan code SKSE input
        // events carry. Nothing when the key has no single keyboard scan code:
        // mouse buttons, and anything else MapVirtualKeyW cannot place.
        std::optional<std::uint32_t> ToScanCode(std::uint32_t a_vk) {
            // TWO KEYS ARE LOOKED UP, NOT COMPUTED, because Windows and
            // DirectInput disagree about them and the general rule below would
            // bind the wrong one:
            //   Pause    sends E1 1D 45, and MapVirtualKeyW answers with the
            //            E1 sequence (or 45, Num Lock's code, without _EX).
            //            DirectInput calls it DIK_PAUSE, 0xC5.
            //   Num Lock is reported as E0 45 on some Windows versions, which
            //            the E0 rule would turn into 0xC5 - Pause.
            //            DirectInput calls it DIK_NUMLOCK, 0x45.
            if (a_vk == VK_PAUSE) {
                return 0xC5u;
            }
            if (a_vk == VK_NUMLOCK) {
                return 0x45u;
            }
            // THE EXTENDED KEYS ARE LOOKED UP TOO. MapVirtualKeyW leaves the E0
            // prefix off the navigation keys on some systems, and their bare
            // codes are the NUMPAD's: Home came back as 0x47, Numpad 7. Bound
            // that way, the re-author key fired on OStim's numpad navigation
            // and rewrote the scene partner five times in two minutes (in
            // play, 2026-10-01). DirectInput's codes for these are fixed.
            switch (a_vk) {
            case VK_HOME: return 0xC7u;
            case VK_END: return 0xCFu;
            case VK_PRIOR: return 0xC9u;
            case VK_NEXT: return 0xD1u;
            case VK_INSERT: return 0xD2u;
            case VK_DELETE: return 0xD3u;
            case VK_UP: return 0xC8u;
            case VK_DOWN: return 0xD0u;
            case VK_LEFT: return 0xCBu;
            case VK_RIGHT: return 0xCDu;
            case VK_DIVIDE: return 0xB5u;
            case VK_RCONTROL: return 0x9Du;
            case VK_RMENU: return 0xB8u;
            case VK_LWIN: return 0xDBu;
            case VK_RWIN: return 0xDCu;
            case VK_APPS: return 0xDDu;
            default: break;
            }

            const auto sc = MapVirtualKeyW(a_vk, MAPVK_VK_TO_VSC_EX);
            const auto prefix = sc & 0xFF00u;
            const auto code = sc & 0xFFu;
            if (sc == 0 || code == 0 || code >= 0x80u) {
                return std::nullopt;
            }
            if (prefix == 0) {
                return code;
            }
            // An extended key (E0 prefix): right Ctrl and Alt, the arrows, Home,
            // End, Insert, Delete, Page Up/Down, keypad Enter and /. DirectInput
            // gives them the same code with the high bit set: Home, E0 47, is
            // DIK_HOME, 0xC7.
            if (prefix == 0xE000u) {
                return code | 0x80u;
            }
            return std::nullopt;
        }

        // Same rule as the Papyrus hotkeys (Utility.IsInMenuMode): never over
        // another menu, never over the console, never before a save is loaded.
        // Reads UI state, so it runs in the queued task on the main thread, not
        // in the sink.
        bool Blocked() {
            auto* ui = RE::UI::GetSingleton();
            auto* player = RE::PlayerCharacter::GetSingleton();
            return !ui || !player || !player->Is3DLoaded() ||
                   ui->GameIsPaused() || ui->IsMenuOpen(RE::Console::MENU_NAME);
        }

        // On the main thread, once a press has been decided.
        void Fire(Key a_key) {
            if (a_key == Key::kDashboard) {
                Dashboard::Toggle();
                return;
            }
            // NEVER IN A SCENE OR A CONVERSATION. The crosshair then rests on a
            // scene partner or the speaker, and scene frameworks drive their
            // menus from the keyboard: a key shared with one would act on the
            // partner at every press.
            if (Notices::PlayerInScene()) {
                SKSE::log::info("{} ignored: the player is in a scene", kLabels[Index(a_key)]);
                return;
            }
            if (auto* ui = RE::UI::GetSingleton(); ui && ui->IsMenuOpen(RE::DialogueMenu::MENU_NAME)) {
                return;
            }
            // WHO IS UNDER THE CROSSHAIR AT THE PRESS, read here as the
            // dashboard reads it at an open; Papyrus is handed the actor, so
            // nothing it does later depends on where the player looks next.
            RE::Actor* target = nullptr;
            if (auto* pick = RE::CrosshairPickData::GetSingleton()) {
                if (auto ref = pick->GetActiveTarget().get()) {
                    target = ref->As<RE::Actor>();
                }
            }
            // The display name, as the dashboard reads it: TESForm::GetName()
            // on a reference is empty, because the name is the base's, so it
            // logged "nobody" for whoever was there.
            const char* name = target ? target->GetDisplayFullName() : nullptr;
            SKSE::log::info("{} pressed: {}", kLabels[Index(a_key)],
                            !target ? "nobody under the crosshair" : name && *name ? name : "someone with no name");
            SKSE::ModCallbackEvent event{ "SNRom_Hotkey", RE::BSFixedString(NameOf(a_key)), 0.0f, target };
            if (auto* source = SKSE::GetModCallbackEventSource()) {
                source->SendEvent(&event);
            }
        }

        class Sink final : public RE::BSTEventSink<RE::InputEvent*> {
        public:
            static Sink* GetSingleton() {
                static Sink singleton;
                return &singleton;
            }

            RE::BSEventNotifyControl ProcessEvent(RE::InputEvent* const* a_event,
                                                  RE::BSTEventSource<RE::InputEvent*>*) override {
                if (!a_event) {
                    return RE::BSEventNotifyControl::kContinue;
                }
                std::array<Bound, kKeys> bound;
                bool                     any = false;
                for (std::size_t k = 0; k < kKeys; ++k) {
                    bound[k] = g_bound[k].load();
                    any = any || bound[k].scan != 0;
                }
                if (!any) {
                    return RE::BSEventNotifyControl::kContinue;
                }
                for (auto* event = *a_event; event; event = event->next) {
                    if (event->GetEventType() != RE::INPUT_EVENT_TYPE::kButton ||
                        event->GetDevice() != RE::INPUT_DEVICE::kKeyboard) {
                        continue;
                    }
                    const auto* button = event->AsButtonEvent();
                    if (!button || !button->IsDown()) {
                        continue;
                    }
                    const auto code = button->GetIDCode();
                    // THE MODIFIER AS WINDOWS SEES IT NOW, not as we tracked it
                    // from key events: a Shift released while the game was
                    // alt-tabbed away never reaches this sink, and tracked state
                    // would call it held until it was pressed again.
                    //
                    // THE MOST SPECIFIC BINDING WINS. Shift+K for one key and K
                    // for another: Shift+K fires only the first, since a bare
                    // binding accepts any modifier.
                    std::array<bool, kKeys> hit{};
                    bool                    withModifier = false;
                    for (std::size_t k = 0; k < kKeys; ++k) {
                        if (bound[k].scan == 0 || bound[k].scan != code) {
                            continue;
                        }
                        const bool held = bound[k].modifier == 0 ||
                                          (GetAsyncKeyState(static_cast<int>(bound[k].modifier)) & 0x8000) != 0;
                        hit[k] = held;
                        withModifier = withModifier || (held && bound[k].modifier != 0);
                    }
                    for (std::size_t k = 0; k < kKeys; ++k) {
                        if (!hit[k] || (withModifier && bound[k].modifier == 0)) {
                            continue;
                        }
                        // THE SINK ONLY DECIDES; THE MAIN THREAD ACTS. This runs
                        // on the input thread: the WP3 test logged "Dashboard
                        // opened" from two different threads while every SKSE
                        // task ran on a third, so opening raced the queued close
                        // and snapshot sends. Everything past this point reads
                        // game and view state, so it is queued (Dashboard.cpp's
                        // invariant).
                        if (!g_queued[k].exchange(true)) {
                            SKSE::GetTaskInterface()->AddTask([k]() {
                                g_queued[k] = false;
                                if (!Blocked()) {
                                    Fire(static_cast<Key>(k));
                                }
                            });
                        }
                    }
                }
                // Never consume the key. Anything else bound to it still fires,
                // modifier or not, which is why the setting ships unbound and
                // the player chooses.
                return RE::BSEventNotifyControl::kContinue;
            }
        };

        bool Apply(Key a_key, const Request& a_request) {
            const auto k = Index(a_key);
            const auto label = kLabels[k];
            if (a_request.virtualKey <= 0) {
                g_bound[k] = Bound{};
                SKSE::log::info("{} unbound ({} is not set)", label, kSettings[k]);
                return true;
            }
            // REFUSE, DON'T GUESS (design 6.5), for both halves. Unbound is
            // visible and fixable; a key that fires without the modifier the
            // player chose, or on a different key, is neither.
            const auto* modifier = FindModifier(a_request.modifier);
            if (!modifier) {
                g_bound[k] = Bound{};
                SKSE::log::warn("{} NOT bound: modifier {} is not Left or Right Shift, Ctrl or Alt. "
                                "Choose another modifier.",
                                label, a_request.modifier);
                return false;
            }
            const auto scan = ToScanCode(static_cast<std::uint32_t>(a_request.virtualKey));
            if (!scan) {
                g_bound[k] = Bound{};
                SKSE::log::warn("{} NOT bound: virtual key {} (0x{:02X}) has no keyboard scan code. "
                                "Choose another key.",
                                label, a_request.virtualKey, a_request.virtualKey);
                return false;
            }
            g_bound[k] = Bound{ *scan, static_cast<std::uint32_t>(modifier->vk) };
            SKSE::log::info("{} bound: virtual key {} (0x{:02X}) is scan code {} (0x{:02X}); modifier: {}", label,
                            a_request.virtualKey, a_request.virtualKey, *scan, *scan, modifier->name);
            return true;
        }
    }

    void Attach() {
        if (auto* input = RE::BSInputDeviceManager::GetSingleton()) {
            input->AddEventSink(Sink::GetSingleton());
            SKSE::log::info("Listening for the hotkeys");
        } else {
            SKSE::log::error("No input device manager: no hotkey can work this session");
        }
    }

    std::string_view NameOf(Key a_key) {
        return kNames[Index(a_key)];
    }

    bool Bind(Key a_key, std::int32_t a_virtualKey, std::int32_t a_modifier) {
        const auto             k = Index(a_key);
        const std::scoped_lock lock{ g_lock };
        const Request          request{ a_virtualKey, a_modifier };
        if (g_requested[k] == request) {
            return g_result[k];
        }
        g_requested[k] = request;
        g_result[k] = Apply(a_key, request);
        return g_result[k];
    }

    bool Bind(std::int32_t a_virtualKey, std::int32_t a_modifier) {
        return Bind(Key::kDashboard, a_virtualKey, a_modifier);
    }

    std::optional<Request> Requested(Key a_key) {
        const std::scoped_lock lock{ g_lock };
        return g_requested[Index(a_key)];
    }

    std::optional<Request> Requested() {
        return Requested(Key::kDashboard);
    }

    std::optional<std::int32_t> ModifierFromName(std::string_view a_name) {
        if (a_name.empty()) {
            return 0;
        }
        for (const auto& modifier : kModifiers) {
            if (SameIgnoringCase(modifier.name, a_name)) {
                return modifier.vk;
            }
        }
        return std::nullopt;
    }
}
