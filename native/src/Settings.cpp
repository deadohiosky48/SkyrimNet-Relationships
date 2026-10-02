#include "Settings.h"

#include "PCH.h"

#include "Dashboard.h"
#include "Hotkey.h"

#include <charconv>
#include <chrono>
#include <filesystem>
#include <format>
#include <thread>
#include <utility>

// CreateFileW, ReadFile and GetModuleFileNameW. After PCH.h for the reason
// given in Hotkey.cpp.
#include <Windows.h>

namespace SNRom::Settings {

    namespace {

        namespace fs = std::filesystem;

        // SkyrimNet's saved settings for this mod, relative to the game folder.
        // Resolved at runtime against the folder the game runs from, so no
        // machine's layout is written here or baked into the DLL. Under Mod
        // Organizer the file lives in a mod or the overwrite folder, and the
        // virtual file system answers for it at this path all the same.
        constexpr std::string_view kRelative =
            "Data/SKSE/Plugins/SkyrimNet/config/plugins/SkyrimNet Relationships/settings.yaml";

        // HOW OFTEN THE FILE IS LOOKED AT. A plain timestamp check, not a
        // change notification, which may not work under Mod Organizer's
        // virtual file system: SkyrimNet's write lands in a mod or the
        // overwrite folder, and a notification on the game's own folder need
        // not hear it. A look is two small file queries.
        constexpr auto kInterval = std::chrono::seconds{ 2 };

        // settings.yaml is a few kilobytes. Anything this big is not it.
        constexpr std::size_t kMaxBytes = 1024 * 1024;

        constexpr std::string_view kHotkey = "dashboardHotkey";
        constexpr std::string_view kModifier = "dashboardHotkeyModifier";
        constexpr std::string_view kDeveloper = "dashboardDeveloperView";
        constexpr std::string_view kScale = "dashboardScale";
        constexpr std::string_view kTextSize = "dashboardTextSize";
        // The crosshair keys, in Values' order: re-read, re-author, enroll.
        constexpr std::array<std::string_view, 3> kCrosshairKey{ "rereadKey", "reauthorKey", "enrollKey" };
        constexpr std::array<std::string_view, 3> kCrosshairModifier{ "rereadKeyModifier", "reauthorKeyModifier",
                                                                      "enrollKeyModifier" };
        constexpr std::array<Hotkey::Key, 3> kCrosshairWhich{ Hotkey::Key::kReread, Hotkey::Key::kReauthor,
                                                              Hotkey::Key::kEnroll };

        // Which crosshair key a settings key names, and whether it is the
        // modifier; nothing for any other key.
        std::optional<std::pair<std::size_t, bool>> CrosshairSetting(std::string_view a_key) {
            for (std::size_t i = 0; i < 3; ++i) {
                if (a_key == kCrosshairKey[i]) {
                    return std::pair{ i, false };
                }
                if (a_key == kCrosshairModifier[i]) {
                    return std::pair{ i, true };
                }
            }
            return std::nullopt;
        }

        constexpr auto kKeyRefused =
            "[Relationships] That dashboard key can't be used - choose another in the settings.";
        constexpr auto kModifierRefused =
            "[Relationships] That dashboard modifier can't be used - choose another in the settings.";

        // ------------------------------------------------------------------
        // Parsing. settings.yaml is flat `key: value` lines; this reads that
        // much YAML and no more.
        // ------------------------------------------------------------------
        std::string_view Trim(std::string_view a_text) {
            constexpr auto kSpace = " \t\r\n"sv;
            const auto     first = a_text.find_first_not_of(kSpace);
            if (first == std::string_view::npos) {
                return {};
            }
            return a_text.substr(first, a_text.find_last_not_of(kSpace) - first + 1);
        }

        // A scalar as SkyrimNet writes one: bare, or in double or single
        // quotes. A bare value loses a trailing comment, which YAML starts at
        // a # after whitespace. Nothing for an unclosed quote.
        std::optional<std::string_view> Scalar(std::string_view a_value) {
            if (!a_value.empty() && (a_value.front() == '"' || a_value.front() == '\'')) {
                const auto close = a_value.find(a_value.front(), 1);
                if (close == std::string_view::npos) {
                    return std::nullopt;
                }
                return a_value.substr(1, close - 1);
            }
            if (a_value.starts_with('#')) {
                return std::string_view{};
            }
            for (std::size_t i = 1; i < a_value.size(); ++i) {
                if (a_value[i] == '#' && (a_value[i - 1] == ' ' || a_value[i - 1] == '\t')) {
                    return Trim(a_value.substr(0, i));
                }
            }
            return a_value;
        }

        std::optional<std::int32_t> ToInt(std::string_view a_text) {
            if (a_text.empty()) {
                return std::nullopt;
            }
            std::int32_t result = 0;
            const auto*  last = a_text.data() + a_text.size();
            const auto [end, error] = std::from_chars(a_text.data(), last, result);
            if (error != std::errc{} || end != last) {
                return std::nullopt;
            }
            return result;
        }

        std::string Lower(std::string_view a_text) {
            std::string lower{ a_text };
            for (auto& c : lower) {
                if (c >= 'A' && c <= 'Z') {
                    c = static_cast<char>(c - 'A' + 'a');
                }
            }
            return lower;
        }

        std::optional<bool> ToBool(std::string_view a_text) {
            const auto lower = Lower(a_text);
            if (lower == "true" || lower == "yes" || lower == "on" || lower == "1") {
                return true;
            }
            if (lower == "false" || lower == "no" || lower == "off" || lower == "0") {
                return false;
            }
            return std::nullopt;
        }

        // ------------------------------------------------------------------
        // The file.
        // ------------------------------------------------------------------
        std::optional<fs::path> GameFolder() {
            std::wstring buffer(MAX_PATH, L'\0');
            while (buffer.size() <= 32768) {
                const auto length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
                if (length == 0) {
                    return std::nullopt;
                }
                if (length < buffer.size()) {
                    buffer.resize(length);
                    return fs::path{ buffer }.parent_path();
                }
                buffer.resize(buffer.size() * 2);
            }
            return std::nullopt;
        }

        // What changes when SkyrimNet saves. The size rides along with the
        // timestamp because two writes inside one clock tick share a
        // timestamp, and the first of them may be the empty file.
        struct Stamp {
            fs::file_time_type written;
            std::uintmax_t     size = 0;

            bool operator==(const Stamp&) const = default;
        };

        std::optional<Stamp> Look(const fs::path& a_path, std::error_code& a_error) {
            Stamp stamp;
            stamp.written = fs::last_write_time(a_path, a_error);
            if (a_error) {
                return std::nullopt;
            }
            stamp.size = fs::file_size(a_path, a_error);
            if (a_error) {
                return std::nullopt;
            }
            return stamp;
        }

        bool ReadAll(const fs::path& a_path, std::string& a_text, std::string& a_why) {
            // EVERY SHARE FLAG, DELETE INCLUDED. SkyrimNet may save by writing
            // a new file and renaming it over this one, and a rename fails
            // while anyone holds the file without FILE_SHARE_DELETE: our look
            // would break its save.
            const HANDLE file = CreateFileW(a_path.c_str(), GENERIC_READ,
                                            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (file == INVALID_HANDLE_VALUE) {
                a_why = std::format("could not be opened (Windows error {})", GetLastError());
                return false;
            }
            a_text.clear();
            bool ok = true;
            char chunk[4096];
            for (;;) {
                DWORD got = 0;
                if (!ReadFile(file, chunk, static_cast<DWORD>(sizeof(chunk)), &got, nullptr)) {
                    a_why = std::format("could not be read (Windows error {})", GetLastError());
                    ok = false;
                    break;
                }
                if (got == 0) {
                    break;
                }
                a_text.append(chunk, got);
                if (a_text.size() > kMaxBytes) {
                    a_why = "is over a megabyte, which no settings file is";
                    ok = false;
                    break;
                }
            }
            CloseHandle(file);
            return ok;
        }

        // ------------------------------------------------------------------
        // Applying, on the main thread.
        // ------------------------------------------------------------------
        void Apply(const Values& a_values) {
            if (a_values.developer) {
                Dashboard::SetDeveloperView(*a_values.developer);
            }
            if (a_values.scale || a_values.textSize) {
                Dashboard::SetDisplay(a_values.scale, a_values.textSize);
            }
            // The crosshair keys: logged when refused, never announced - the
            // log names the setting, and only the dashboard key has a
            // refusal notice of its own.
            for (std::size_t i = 0; i < 3; ++i) {
                if (!a_values.crosshairKey[i] && !a_values.crosshairModifier[i]) {
                    continue;
                }
                const auto which = kCrosshairWhich[i];
                const auto current = Hotkey::Requested(which);
                Hotkey::Bind(which, a_values.crosshairKey[i].value_or(current ? current->virtualKey : 0),
                             a_values.crosshairModifier[i].value_or(current ? current->modifier : 0));
            }
            if (!a_values.hotkey && !a_values.modifier) {
                return;
            }
            // A file with one of the two keys changes that one and keeps the
            // other.
            const auto            current = Hotkey::Requested();
            const Hotkey::Request wanted{ a_values.hotkey.value_or(current ? current->virtualKey : 0),
                                          a_values.modifier.value_or(current ? current->modifier : 0) };
            if (current == wanted) {
                return;
            }
            if (Hotkey::Bind(wanted.virtualKey, wanted.modifier)) {
                return;
            }
            // SAID ON SCREEN, as Papyrus says it at bootstrap: the player has
            // just chosen this key. Only in a game, because the first look is
            // at the main menu, where there is no HUD and the next bootstrap
            // will say it anyway.
            auto* player = RE::PlayerCharacter::GetSingleton();
            if (player && player->Is3DLoaded()) {
                RE::SendHUDMessage::ShowHUDMessage(wanted.modifier < 0 ? kModifierRefused : kKeyRefused);
            }
        }

        // ------------------------------------------------------------------
        // The watcher. One instance, on its own thread.
        // ------------------------------------------------------------------
        class Watcher {
        public:
            explicit Watcher(fs::path a_path) :
                _path(std::move(a_path)) {}

            void Tick() {
                std::error_code error;
                const auto      before = Look(_path, error);
                if (!before) {
                    // Gone, so whatever comes back is read afresh.
                    _applied.reset();
                    _suspect.reset();
                    _reported.reset();
                    if (error == std::errc::no_such_file_or_directory) {
                        Trouble("is not there (SkyrimNet writes it when its panel saves)");
                    } else {
                        Trouble(std::format("cannot be looked at (error {})", error.value()));
                    }
                    return;
                }
                if (before == _applied || before == _reported) {
                    return;
                }

                std::string text;
                std::string why;
                if (!ReadAll(_path, text, why)) {
                    Failed(*before, why, {});
                    return;
                }
                // STILL THE SAME FILE? If SkyrimNet wrote while we read, what
                // we hold may be half of it: drop it, and the next look reads
                // the finished file.
                const auto after = Look(_path, error);
                if (!after || *after != *before || text.size() != before->size) {
                    return;
                }

                auto values = Parse(text);
                if (!values.Any()) {
                    Failed(*before,
                           std::format("has no {}, {}, {}, {} or {} that can be read", kHotkey, kModifier, kDeveloper,
                                       kScale, kTextSize),
                           values.complaints);
                    return;
                }
                _applied = before;
                _suspect.reset();
                _reported.reset();
                if (!_trouble.empty()) {
                    SKSE::log::info("{} is readable again", kRelative);
                    _trouble.clear();
                }
                Complain(values.complaints);
                values.complaints.clear();
                SKSE::GetTaskInterface()->AddTask([values = std::move(values)]() { Apply(values); });
            }

        private:
            // TWICE ON THE SAME VERSION BEFORE IT COUNTS. A look that lands
            // between SkyrimNet emptying the file and writing it sees a file
            // with nothing in it, and that is not worth a warning. Once it has
            // counted, that version is not read again until it changes.
            void Failed(const Stamp& a_stamp, const std::string& a_why, const std::vector<std::string>& a_complaints) {
                if (_suspect != a_stamp) {
                    _suspect = a_stamp;
                    return;
                }
                _reported = a_stamp;
                Complain(a_complaints);
                Trouble(a_why);
            }

            static void Complain(const std::vector<std::string>& a_complaints) {
                for (const auto& complaint : a_complaints) {
                    SKSE::log::warn("{}: {}", kRelative, complaint);
                }
            }

            // ONCE, until it is fixed or the trouble changes. The current
            // values stay in force throughout.
            void Trouble(const std::string& a_why) {
                if (a_why == _trouble) {
                    return;
                }
                _trouble = a_why;
                SKSE::log::warn("{} {}. The dashboard keeps its current settings.", kRelative, a_why);
            }

            fs::path             _path;
            std::optional<Stamp> _applied;   // the version whose values are in force
            std::optional<Stamp> _suspect;   // failed once
            std::optional<Stamp> _reported;  // failed twice, and logged
            std::string          _trouble;   // what was last logged as wrong; empty when all is well
        };
    }

    Values Parse(std::string_view a_text) {
        // A byte order mark, if an editor added one.
        if (a_text.starts_with("\xEF\xBB\xBF"sv)) {
            a_text.remove_prefix(3);
        }
        Values values;
        while (!a_text.empty()) {
            const auto end = a_text.find('\n');
            const auto line = Trim(a_text.substr(0, end));
            a_text = end == std::string_view::npos ? std::string_view{} : a_text.substr(end + 1);

            if (line.empty() || line.front() == '#') {
                continue;
            }
            const auto colon = line.find(':');
            if (colon == std::string_view::npos) {
                continue;
            }
            const auto key = Trim(line.substr(0, colon));
            const auto crosshair = CrosshairSetting(key);
            if (!crosshair && key != kHotkey && key != kModifier && key != kDeveloper && key != kScale &&
                key != kTextSize) {
                continue;
            }
            const auto value = Scalar(Trim(line.substr(colon + 1)));
            if (!value) {
                values.complaints.push_back(std::format("{} has an unclosed quote, so it stays as it is", key));
                continue;
            }

            if (crosshair) {
                const auto [i, isModifier] = *crosshair;
                if (isModifier) {
                    values.crosshairModifier[i] = Hotkey::ModifierFromName(*value);
                    if (!values.crosshairModifier[i]) {
                        // REFUSED, as the dashboard's is: the bare key would
                        // fire without the modifier the player meant.
                        values.complaints.push_back(
                            std::format("{} '{}' is not one of the options, so that key is refused", key, *value));
                        values.crosshairModifier[i] = -1;
                    }
                } else {
                    values.crosshairKey[i] = ToInt(*value);
                    if (!values.crosshairKey[i]) {
                        values.complaints.push_back(
                            std::format("{} '{}' is not a number, so that key stays as it is", key, *value));
                    }
                }
            } else if (key == kHotkey) {
                values.hotkey = ToInt(*value);
                if (!values.hotkey) {
                    values.complaints.push_back(
                        std::format("{} '{}' is not a number, so the dashboard key stays as it is", key, *value));
                }
            } else if (key == kModifier) {
                values.modifier = Hotkey::ModifierFromName(*value);
                if (!values.modifier) {
                    // REFUSED, as Papyrus refuses it: binding the bare key
                    // would open the dashboard without the modifier the
                    // player meant to require.
                    values.complaints.push_back(
                        std::format("{} '{}' is not one of the options, so the dashboard key is refused", key, *value));
                    values.modifier = -1;
                }
            } else if (key == kDeveloper) {
                values.developer = ToBool(*value);
                if (!values.developer) {
                    values.complaints.push_back(std::format(
                        "{} '{}' is not true or false, so the developer view stays as it is", key, *value));
                }
            } else if (key == kScale) {
                values.scale = ScaleFromName(*value);
                if (!values.scale) {
                    values.complaints.push_back(std::format(
                        "{} '{}' is not one of the options, so the dashboard's scale stays as it is", key, *value));
                }
            } else {
                values.textSize = TextSizeFromName(*value);
                if (!values.textSize) {
                    values.complaints.push_back(std::format(
                        "{} '{}' is not one of the options, so the dashboard's text size stays as it is", key, *value));
                }
            }
        }
        return values;
    }

    std::optional<std::int32_t> ScaleFromName(std::string_view a_name) {
        // The manifest's options, in its order. Auto first, as the default.
        constexpr std::pair<std::string_view, std::int32_t> kScales[] = {
            { "auto", 0 },   { "75%", 75 },   { "90%", 90 },   { "100%", 100 }, { "110%", 110 },
            { "125%", 125 }, { "150%", 150 }, { "175%", 175 }, { "200%", 200 },
        };
        const auto lower = Lower(Trim(a_name));
        for (const auto& [name, percent] : kScales) {
            if (lower == name) {
                return percent;
            }
        }
        return std::nullopt;
    }

    std::optional<std::int32_t> TextSizeFromName(std::string_view a_name) {
        constexpr std::pair<std::string_view, std::int32_t> kSizes[] = {
            { "normal", 0 },
            { "large", 1 },
            { "larger", 2 },
        };
        const auto lower = Lower(Trim(a_name));
        for (const auto& [name, size] : kSizes) {
            if (lower == name) {
                return size;
            }
        }
        return std::nullopt;
    }

    void StartWatching() {
        const auto folder = GameFolder();
        if (!folder) {
            SKSE::log::error("Could not find the game folder, so dashboard settings changed in game take effect at "
                             "the next load");
            return;
        }
        auto path = *folder / fs::path{ kRelative }.make_preferred();
        SKSE::log::info("Watching {} for dashboard settings, every {} seconds", kRelative, kInterval.count());
        std::thread([path = std::move(path)]() {
            Watcher watcher{ path };
            for (;;) {
                // NOTHING ESCAPES THIS THREAD: an exception here would end the
                // game. Whatever went wrong is logged and the next look tries
                // again.
                try {
                    watcher.Tick();
                } catch (const std::exception& e) {
                    SKSE::log::error("Settings watcher: {}", e.what());
                }
                std::this_thread::sleep_for(kInterval);
            }
        }).detach();
    }
}
