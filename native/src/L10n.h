#pragma once

#include <nlohmann/json.hpp>

#include <string>
#include <string_view>

// L10n (2.3, WP-L step 2) - the words this mod shows the player, in the
// player's language.
//
// ONE TABLE PER LANGUAGE, flat `key -> text`, in
// Data/SKSE/Plugins/SkyrimNet Relationships/l10n/<code>.json. English is not
// a table: it lives in the code, at every call, as the fallback, so a missing
// file, a missing key or a broken file costs nothing but the translation.
// tools/gen-l10n.ps1 collects every key and its English into l10n/en.json, the
// template a translator works from.
//
// Placeholders are {0} and {1}, filled the same way in every language, so a
// translation may move them.
//
// THE LANGUAGE is the `outputLanguage` setting (Settings.cpp), the same one
// that decides what language the model writes in: "Game" follows Skyrim's own
// sLanguage, any other value names a language in English ("German").
//
// Read by Papyrus (SNRom_Native.Text) and by the dashboard (the snapshot's
// settings.language and strings). Thread-safe: Papyrus asks from its own
// threads, the snapshot is built on the main thread.
namespace SNRom::L10n {
    // Sets the language from the setting's value; loads its table, or clears
    // it for English. Logs what it did. Cheap when nothing changed.
    void SetLanguage(std::string_view a_setting);

    // Resolves the current setting again: "Game" read before Skyrim had its
    // ini settings. Called at data loaded and after each load.
    void Refresh();

    // The language in use, as a code ("en", "de", ...).
    std::string Code();

    // The text for a key, or a_english when this language has none; {0} and
    // {1} filled from a_arg0 and a_arg1 either way.
    std::string Text(std::string_view a_key, std::string_view a_english, std::string_view a_arg0 = {},
                     std::string_view a_arg1 = {});

    // The whole table for the dashboard; an empty object for English.
    nlohmann::json Table();
}
