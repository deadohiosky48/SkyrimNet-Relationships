#pragma once

#include <cstdint>
#include <optional>
#include <string_view>

namespace SNRom::Hotkey {

    // THE MOD'S KEYS, all here from 2.0 (WP8): the dashboard, and three that
    // act on whoever is under the crosshair - the re-read, the re-author and
    // the enroll key. Papyrus once bound the re-read and re-author keys itself
    // with RegisterForKey, which takes a SCAN code, while SkyrimNet's hotkey
    // widget stores a VIRTUAL key: End (VK 35) armed H (scan 35). Each binding
    // here converts, takes a modifier, and follows the settings within seconds.
    enum class Key : std::size_t { kDashboard, kReread, kReauthor, kEnroll };
    inline constexpr std::size_t kKeys = 4;

    // "dashboard", "reread", "reauthor", "enroll": the ModEvent's word for a
    // crosshair key (SNRom_Bridge.OnHotkey), and the log's.
    std::string_view NameOf(Key a_key);

    // kInputLoaded: listen to keyboard input for the keys. The sink runs on the
    // input thread; it only decides, and queues the action to the main thread.
    // The dashboard key toggles the dashboard; a crosshair key sends the
    // ModEvent SNRom_Hotkey, strArg its NameOf, sender the actor under the
    // crosshair at the press (or none).
    void Attach();

    // What the settings last asked for: both halves as VIRTUAL-KEY codes, the
    // modifier 0 for none.
    struct Request {
        std::int32_t virtualKey = 0;
        std::int32_t modifier = 0;

        bool operator==(const Request&) const = default;
    };

    // Binds the dashboard key, from the SkyrimNet settings dashboardHotkey and
    // dashboardHotkeyModifier. Two callers hand them over: Papyrus at every
    // bootstrap (SNRom_Native.SetDashboardHotkey) and the settings watcher
    // (Settings.cpp) whenever the file changes. Main thread.
    //
    // a_virtualKey is a Windows VIRTUAL-KEY code, because that is what
    // SkyrimNet's hotkey widget stores. Keyboard input reaches us as DirectInput
    // SCAN codes, so it is converted here. 0 or less unbinds the key.
    //
    // a_modifier is 0, or the virtual key of one side of Shift, Ctrl or Alt
    // (VK_LSHIFT to VK_RMENU), which must be held when the key goes down.
    //
    // Returns false when the key has no scan code or the modifier is not one of
    // those six, and then binds NOTHING. A key that silently lands on a different
    // key is the bug this replaces (design 6.5): the re-read hotkey once
    // registered End's VK, 35, as scan code 35, which is H.
    //
    // A request identical to the last one changes nothing and logs nothing: the
    // watcher and Papyrus both hand the same settings over at startup.
    bool Bind(std::int32_t a_virtualKey, std::int32_t a_modifier);

    // The same, for any key. The settings watcher binds the crosshair keys from
    // rereadKey, reauthorKey, enrollKey and their ...Modifier settings.
    bool Bind(Key a_key, std::int32_t a_virtualKey, std::int32_t a_modifier);

    // The last request, or nothing before the first.
    std::optional<Request> Requested();
    std::optional<Request> Requested(Key a_key);

    // A dashboardHotkeyModifier option (manifest.yaml) as a virtual key: "None"
    // or empty is 0, "Left Shift" is VK_LSHIFT, and so on, in any case. Nothing
    // for a name that is not an option. SNRom_Bridge.DashboardModifierVK is the
    // same table in Papyrus; the two and the manifest's options must agree.
    std::optional<std::int32_t> ModifierFromName(std::string_view a_name);
}
