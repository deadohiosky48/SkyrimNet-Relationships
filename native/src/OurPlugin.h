#pragma once

#include <string_view>

// OUR PLUGIN, AS AN .esl OR A LIGHT-FLAGGED .esp (2.5; the author, 2026-10-25).
// The same file either way, with the same FormIDs, chosen by the player in the
// installer. An .esl always loads among the masters, ahead of every .esp, so
// adding one moves every light-flagged .esp after it down a slot; on a large
// load order that broke an existing save for a mod that does not follow its
// saved forms (Schlongs of Skyrim on 1.5.97). The .esp can be placed last,
// where it moves nothing. Everything that looks up one of our records asks
// here for the name. The Papyrus twin is SNRom_Bridge.OurPlugin.
namespace SNRom {

    inline constexpr std::string_view kPluginEsl = "SNRom_Integration.esl";
    inline constexpr std::string_view kPluginEsp = "SNRom_Integration.esp";

    // Whichever is loaded, remembered once found; the .esl while neither is
    // (before the plugins load, when no lookup can succeed anyway).
    inline const char* OurPlugin() {
        static const char* name = nullptr;
        if (!name) {
            auto* data = RE::TESDataHandler::GetSingleton();
            if (data && data->LookupModByName(kPluginEsl)) {
                name = kPluginEsl.data();
            } else if (data && data->LookupModByName(kPluginEsp)) {
                name = kPluginEsp.data();
            } else {
                return kPluginEsl.data();
            }
        }
        return name;
    }

    // One of our records by its plugin-local FormID.
    template <class T>
    T* OurForm(RE::FormID a_local) {
        auto* data = RE::TESDataHandler::GetSingleton();
        return data ? data->LookupForm<T>(a_local, OurPlugin()) : nullptr;
    }
}
