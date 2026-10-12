#include "L10n.h"

#include "PCH.h"

#include <fstream>
#include <mutex>
#include <unordered_map>

namespace SNRom::L10n {
    namespace {
        using json = nlohmann::json;

        constexpr std::string_view kFolder = "Data/SKSE/Plugins/SkyrimNet Relationships/l10n/";

        std::mutex                                   g_lock;
        std::string                                  g_setting;  // the setting as last applied
        std::string                                  g_code = "en";
        std::unordered_map<std::string, std::string> g_table;
        json                                         g_json = json::object();

        std::string Lower(std::string_view a_text) {
            std::string out(a_text);
            for (auto& c : out) {
                c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            }
            return out;
        }

        // A language's name, in English as the setting offers it or in capitals
        // as Skyrim's sLanguage writes it, to its code.
        std::string CodeFor(std::string_view a_name) {
            // SkyrimNet's plugin publishing form's languages (2.3), in English
            // as the setting offers them; Skyrim's own sLanguage values are
            // the same words in capitals.
            static const std::pair<std::string_view, std::string_view> kNames[] = {
                { "english", "en" },  { "arabic", "ar" },    { "chinese", "zh" },  { "czech", "cs" },
                { "dutch", "nl" },    { "french", "fr" },    { "german", "de" },   { "hebrew", "he" },
                { "hindi", "hi" },    { "hungarian", "hu" }, { "italian", "it" },  { "japanese", "ja" },
                { "korean", "ko" },   { "polish", "pl" },    { "portuguese", "pt" }, { "russian", "ru" },
                { "spanish", "es" },  { "turkish", "tr" },
            };
            const auto lower = Lower(a_name);
            for (const auto& [name, code] : kNames) {
                if (lower == name) {
                    return std::string(code);
                }
            }
            return "en";
        }

        // Skyrim's own language, sLanguage:General in Skyrim.ini.
        std::string GameLanguage() {
            if (auto* inis = RE::INISettingCollection::GetSingleton()) {
                if (auto* setting = inis->GetSetting("sLanguage:General")) {
                    if (const char* value = setting->GetString()) {
                        return value;
                    }
                }
            }
            return "ENGLISH";
        }

        void Replace(std::string& a_text, std::string_view a_what, std::string_view a_with) {
            if (a_what.empty()) {
                return;
            }
            for (std::size_t at = a_text.find(a_what); at != std::string::npos;
                 at = a_text.find(a_what, at + a_with.size())) {
                a_text.replace(at, a_what.size(), a_with);
            }
        }
    }

    void SetLanguage(std::string_view a_setting) {
        std::string setting(a_setting.empty() ? "Game" : a_setting);
        const bool fromGame = Lower(setting) == "game";
        // Resolved every time, not cached by the setting: "Game" read before
        // Skyrim has its ini settings answers English, and must be able to
        // change its mind once they are there (Refresh, at data loaded).
        const std::string name = fromGame ? GameLanguage() : setting;
        const std::string code = CodeFor(name);
        {
            std::scoped_lock lock(g_lock);
            if (setting == g_setting && code == g_code) {
                return;
            }
        }

        std::unordered_map<std::string, std::string> table;
        json                                         loaded = json::object();
        std::string                                  note;
        if (code != "en") {
            const std::string path = std::string(kFolder) + code + ".json";
            std::ifstream     file(path, std::ios::binary);
            if (!file) {
                note = std::format("no {}.json, so the player reads English", code);
            } else {
                // A broken file is the translator's mistake, not the player's
                // problem: English, and say so in the log.
                loaded = json::parse(file, nullptr, false);
                if (loaded.is_discarded() || !loaded.is_object()) {
                    loaded = json::object();
                    note = std::format("{}.json is not a JSON object, so the player reads English", code);
                } else {
                    for (const auto& [key, value] : loaded.items()) {
                        if (value.is_string() && !key.empty() && key.front() != '_') {
                            table.emplace(key, value.get<std::string>());
                        }
                    }
                    note = std::format("{} strings from {}.json", table.size(), code);
                }
            }
        }
        {
            std::scoped_lock lock(g_lock);
            g_setting = std::move(setting);
            g_code = code;
            g_table = std::move(table);
            g_json = json::object();
            for (const auto& [key, value] : g_table) {
                g_json[key] = value;
            }
        }
        SKSE::log::info("Language: {}{} ({}){}", fromGame ? "the game's, " : "", name, code,
                        note.empty() ? "" : " - " + note);
    }

    void Refresh() {
        std::string setting;
        {
            std::scoped_lock lock(g_lock);
            setting = g_setting;
            g_setting.clear();  // so SetLanguage does not take it as unchanged
        }
        SetLanguage(setting);
    }

    std::string Code() {
        std::scoped_lock lock(g_lock);
        return g_code;
    }

    std::string Text(std::string_view a_key, std::string_view a_english, std::string_view a_arg0,
                     std::string_view a_arg1) {
        std::string text;
        {
            std::scoped_lock lock(g_lock);
            const auto it = g_table.find(std::string(a_key));
            text = it != g_table.end() ? it->second : std::string(a_english);
        }
        Replace(text, "{0}", a_arg0);
        Replace(text, "{1}", a_arg1);
        return text;
    }

    nlohmann::json Table() {
        std::scoped_lock lock(g_lock);
        return g_json;
    }
}
