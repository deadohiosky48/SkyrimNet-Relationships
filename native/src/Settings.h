#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

// THE DASHBOARD SETTINGS, MADE LIVE WITHOUT PAPYRUS.
//
// SkyrimNet rewrites this mod's settings.yaml every time its panel saves.
// A background thread looks at the file's last-write time every two seconds
// and, when it moves, reads the five dashboard keys and applies them on the
// main thread. Papyrus still hands the same settings over once per bootstrap
// (SNRom_Bridge.ArmDashboard), so the DLL is right from the first load even
// if the file cannot be read.
namespace SNRom::Settings {

    // kDataLoaded: start the watcher. The first look happens at once.
    void StartWatching();

    // One read of the file, as the watcher parses it. A key that is missing,
    // or whose number or true/false cannot be read, is left empty and its
    // setting stays as it is. A modifier that is not one of the options is -1,
    // which Hotkey::Bind refuses, as it refuses it from Papyrus.
    struct Values {
        std::optional<std::int32_t> hotkey;     // dashboardHotkey, a virtual key
        std::optional<std::int32_t> modifier;   // dashboardHotkeyModifier, as a virtual key
        std::optional<bool>         developer;  // dashboardDeveloperView
        std::optional<std::int32_t> scale;      // dashboardScale, as ScaleFromName reads it
        std::optional<std::int32_t> textSize;   // dashboardTextSize, as TextSizeFromName reads it
        // attractionBypassRatio (2.1, WP-A): the intimacy gate's attraction
        // bar, which the read API works out natively (Api.cpp).
        std::optional<float>        attractionBypassRatio;

        // The crosshair keys (Hotkey.h), re-read, re-author and enroll in that
        // order: rereadKey, reauthorKey, enrollKey, each a virtual key, and
        // their ...Modifier, as a virtual key or -1 for a name that is not an
        // option.
        std::array<std::optional<std::int32_t>, 3> crosshairKey;
        std::array<std::optional<std::int32_t>, 3> crosshairModifier;

        // A line per value that could not be used, for the log. Kept rather
        // than logged, so the watcher can log them once per version of the
        // file, however many times it reads it.
        std::vector<std::string> complaints;

        bool Any() const {
            bool keys = false;
            for (std::size_t i = 0; i < 3; ++i) {
                keys = keys || crosshairKey[i] || crosshairModifier[i];
            }
            return keys || hotkey || modifier || developer || scale || textSize || attractionBypassRatio;
        }
    };

    // attractionBypassRatio as the file last said, or its manifest default (1.5).
    float AttractionBypassRatio();

    // The parser on its own: flat `key: value` lines, as SkyrimNet writes them.
    Values Parse(std::string_view a_text);

    // THE TWO DISPLAY SELECTS, BY THEIR OPTIONS' NAMES. A select reaches
    // Papyrus and the file as the option's name, and both paths hand the DLL
    // that name (SNRom_Native.SetDisplaySettings, and Parse above), so these
    // are the one table; the manifest's options must match it. Case is
    // ignored, as Papyrus ignores it. Nothing for a name that is not an option.
    //
    // dashboardScale: Auto is 0, which the page works out from the view's
    // height; 75%, 90%, 100%, 110%, 125%, 150%, 175% and 200% are that many
    // percent.
    std::optional<std::int32_t> ScaleFromName(std::string_view a_name);
    // dashboardTextSize: Normal 0, Large 1, Larger 2.
    std::optional<std::int32_t> TextSizeFromName(std::string_view a_name);
}
