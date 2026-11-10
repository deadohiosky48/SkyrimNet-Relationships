#include "FactionBlock.h"

#include "PCH.h"

#include "OurPlugin.h"

#include <algorithm>
#include <filesystem>
#include <format>
#include <fstream>
#include <mutex>
#include <set>
#include <string>
#include <vector>

namespace SNRom::FactionBlock {

    namespace {

        namespace fs = std::filesystem;
        using json = nlohmann::json;

        // Relative to the game's folder, which is the working directory, as
        // for our logs (Natives.cpp). No release ships this file.
        const fs::path kFile{ "Data/SKSE/Plugins/SkyrimNet Relationships/blocked_factions.json" };

        struct Entry {
            std::string plugin;
            RE::FormID  local = 0;
            std::string name;      // as it was named when blocked, for a plugin since removed
            RE::FormID  runtime = 0;  // 0 while its plugin is not loaded
        };

        std::mutex         g_lock;
        bool               g_loaded = false;
        std::vector<Entry> g_entries;

        std::string Key(std::string_view a_plugin, RE::FormID a_local) {
            return std::format("{}|{:06X}", a_plugin, a_local);
        }

        bool ParseKey(const std::string& a_key, std::string& a_plugin, RE::FormID& a_local) {
            const auto bar = a_key.rfind('|');
            if (bar == std::string::npos || bar == 0 || bar + 1 >= a_key.size()) {
                return false;
            }
            a_plugin = a_key.substr(0, bar);
            try {
                std::size_t used = 0;
                const auto  value = std::stoul(a_key.substr(bar + 1), &used, 16);
                if (used != a_key.size() - bar - 1 || value == 0 || value > 0xFFFFFF) {
                    return false;
                }
                a_local = static_cast<RE::FormID>(value);
            } catch (...) {
                return false;
            }
            return true;
        }

        RE::FormID Resolve(const std::string& a_plugin, RE::FormID a_local) {
            auto* data = RE::TESDataHandler::GetSingleton();
            if (!data || !data->LookupModByName(a_plugin)) {
                return 0;
            }
            const auto id = data->LookupFormID(a_local, a_plugin);
            auto*      form = id ? RE::TESForm::LookupByID(id) : nullptr;
            return form && form->Is(RE::FormType::Faction) ? id : 0;
        }

        // Where a faction comes from: its plugin's file name and its FormID
        // within it. False for one made at runtime, which has no plugin.
        bool Origin(const RE::TESFaction* a_faction, std::string& a_plugin, RE::FormID& a_local) {
            const auto* file = a_faction ? a_faction->GetFile(0) : nullptr;
            if (!file || a_faction->IsDynamicForm()) {
                return false;
            }
            a_plugin = std::string(file->GetFilename());
            a_local = a_faction->GetLocalFormID();
            return !a_plugin.empty() && a_local != 0;
        }

        // A person's factions as they stand: what their record gives them,
        // then what has changed since, which wins (a rank below 0 is one they
        // were taken out of).
        std::vector<RE::TESFaction*> MemberOf(RE::Actor* a_actor) {
            std::vector<std::pair<RE::TESFaction*, std::int8_t>> ranks;
            a_actor->VisitFactions([&](RE::TESFaction* a_faction, std::int8_t a_rank) {
                if (a_faction) {
                    const auto at = std::ranges::find_if(ranks, [&](const auto& r) { return r.first == a_faction; });
                    if (at != ranks.end()) {
                        at->second = a_rank;
                    } else {
                        ranks.emplace_back(a_faction, a_rank);
                    }
                }
                return false;
            });
            std::vector<RE::TESFaction*> out;
            for (const auto& [faction, rank] : ranks) {
                if (rank >= 0) {
                    out.push_back(faction);
                }
            }
            return out;
        }

        std::string NameOf(const RE::TESFaction* a_faction, std::string_view a_plugin, RE::FormID a_local) {
            if (a_faction) {
                if (const char* full = a_faction->GetFullName(); full && *full) {
                    return full;
                }
                // Kept only where something keeps editor IDs (powerofthree's
                // Tweaks); otherwise empty.
                if (const char* editor = a_faction->GetFormEditorID(); editor && *editor) {
                    return editor;
                }
            }
            return std::format("a faction from {} ({:06X})", a_plugin, a_local);
        }

        // Under g_lock.
        void LoadLocked() {
            if (g_loaded) {
                return;
            }
            g_loaded = true;
            std::error_code error;
            if (!fs::exists(kFile, error)) {
                SKSE::log::info("Blocked factions: none yet ({} not there)", kFile.generic_string());
                return;
            }
            std::ifstream in(kFile, std::ios::binary);
            const auto    root = json::parse(in, nullptr, false);
            if (root.is_discarded() || !root.is_object()) {
                SKSE::log::warn("Blocked factions: {} is not a JSON object, so nothing is blocked", kFile.generic_string());
                return;
            }
            const auto list = root.find("factions");
            if (list == root.end() || !list->is_array()) {
                return;
            }
            for (const auto& each : *list) {
                if (!each.is_object()) {
                    continue;
                }
                Entry entry;
                entry.plugin = each.value("plugin", std::string{});
                entry.name = each.value("name", std::string{});
                RE::FormID local = 0;
                if (!ParseKey(entry.plugin + "|" + each.value("id", std::string{}), entry.plugin, local)) {
                    SKSE::log::warn("Blocked factions: skipped an entry that names no plugin and FormID");
                    continue;
                }
                entry.local = local;
                entry.runtime = Resolve(entry.plugin, entry.local);
                SKSE::log::info("Blocked factions: {} - {}", Key(entry.plugin, entry.local),
                                entry.runtime ? std::format("{} ({:08X})", entry.name, entry.runtime)
                                              : std::format("{} (its plugin is not loaded)", entry.name));
                g_entries.push_back(std::move(entry));
            }
        }

        // Under g_lock. Written beside, then moved over, so a crash mid-write
        // never leaves half a list.
        std::string SaveLocked() {
            auto list = json::array();
            for (const auto& entry : g_entries) {
                list.push_back({ { "plugin", entry.plugin },
                                 { "id", std::format("{:06X}", entry.local) },
                                 { "name", entry.name } });
            }
            const json root{ { "about", "Factions Relationships never enrolls anyone from. Edited from the dashboard." },
                             { "factions", list } };
            std::error_code error;
            fs::create_directories(kFile.parent_path(), error);
            auto temp = kFile;
            temp += ".tmp";
            {
                std::ofstream out(temp, std::ios::binary | std::ios::trunc);
                if (!out) {
                    return "The list of blocked factions could not be written.";
                }
                out << root.dump(2, ' ', false, json::error_handler_t::replace);
                if (!out) {
                    return "The list of blocked factions could not be written.";
                }
            }
            fs::rename(temp, kFile, error);
            if (error) {
                fs::remove(temp, error);
                return "The list of blocked factions could not be saved.";
            }
            return {};
        }
    }

    std::string BlockedFactionOf(RE::Actor* a_actor) {
        if (!a_actor) {
            return {};
        }
        std::set<RE::FormID> blocked;
        std::vector<std::pair<RE::FormID, std::string>> names;
        {
            std::lock_guard guard(g_lock);
            LoadLocked();
            for (const auto& entry : g_entries) {
                if (entry.runtime) {
                    blocked.insert(entry.runtime);
                    names.emplace_back(entry.runtime, entry.name);
                }
            }
        }
        if (blocked.empty()) {
            return {};
        }
        RE::FormID hit = 0;
        for (const auto id : blocked) {
            const auto* faction = RE::TESForm::LookupByID<RE::TESFaction>(id);
            if (faction && a_actor->IsInFaction(faction)) {
                hit = id;
                break;
            }
        }
        if (!hit) {
            return {};
        }
        for (const auto& [id, name] : names) {
            if (id == hit) {
                return name.empty() ? std::format("{:08X}", hit) : name;
            }
        }
        return std::format("{:08X}", hit);
    }

    nlohmann::json Describe(std::int32_t a_formId, const std::vector<std::int32_t>& a_roster) {
        std::set<std::string> blockedKeys;
        auto                  blocked = json::array();
        {
            std::lock_guard guard(g_lock);
            LoadLocked();
            for (const auto& entry : g_entries) {
                const auto key = Key(entry.plugin, entry.local);
                blockedKeys.insert(key);
                auto  enrolled = json::array();
                auto* faction = entry.runtime ? RE::TESForm::LookupByID<RE::TESFaction>(entry.runtime) : nullptr;
                for (const auto id : faction ? a_roster : std::vector<std::int32_t>{}) {
                    auto* member = RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(id));
                    if (member && member->IsInFaction(faction)) {
                        enrolled.push_back(id);
                    }
                }
                blocked.push_back({ { "key", key }, { "name", entry.name }, { "found", entry.runtime != 0 },
                                    { "enrolled", enrolled } });
            }
        }

        auto  factions = json::array();
        auto* actor = a_formId ? RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(a_formId)) : nullptr;
        if (actor) {
            const std::string_view ours = OurPlugin();
            std::set<std::string>  seen;
            std::vector<json>      named;
            std::vector<json>      unnamed;
            for (auto* faction : MemberOf(actor)) {
                std::string plugin;
                RE::FormID  local = 0;
                if (!Origin(faction, plugin, local) || plugin == ours) {
                    continue;
                }
                auto key = Key(plugin, local);
                if (!seen.insert(key).second) {
                    continue;
                }
                const char* full = faction->GetFullName();
                const char* editor = faction->GetFormEditorID();
                const bool  hasName = (full && *full) || (editor && *editor);
                json        row{ { "key", key },
                                 { "name", NameOf(faction, plugin, local) },
                                 { "blocked", blockedKeys.contains(key) } };
                (hasName ? named : unnamed).push_back(std::move(row));
            }
            const auto byName = [](const json& a, const json& b) {
                return a.value("name", std::string{}) < b.value("name", std::string{});
            };
            std::ranges::sort(named, byName);
            std::ranges::sort(unnamed, byName);
            for (auto& row : named) {
                factions.push_back(std::move(row));
            }
            for (auto& row : unnamed) {
                factions.push_back(std::move(row));
            }
            SKSE::log::info("Blocked factions: {} belongs to {} faction(s) that can be blocked", actor->GetDisplayFullName(),
                            factions.size());
        }
        return { { "formId", a_formId }, { "factions", factions }, { "blocked", blocked } };
    }

    std::string Set(const std::string& a_key, bool a_block) {
        std::string plugin;
        RE::FormID  local = 0;
        if (!ParseKey(a_key, plugin, local)) {
            return "That is not a faction the game knows.";
        }
        std::lock_guard guard(g_lock);
        LoadLocked();
        const auto at = std::ranges::find_if(g_entries, [&](const Entry& e) {
            return e.local == local && _stricmp(e.plugin.c_str(), plugin.c_str()) == 0;
        });
        if (!a_block) {
            if (at == g_entries.end()) {
                return {};
            }
            const auto name = at->name;
            g_entries.erase(at);
            auto why = SaveLocked();
            SKSE::log::info("Blocked factions: {} ({}) allowed again{}", name, a_key, why.empty() ? "" : " - " + why);
            return why;
        }
        if (at != g_entries.end()) {
            return {};
        }
        Entry entry;
        entry.plugin = plugin;
        entry.local = local;
        entry.runtime = Resolve(plugin, local);
        if (!entry.runtime) {
            return "That faction is not in this game's plugins.";
        }
        entry.name = NameOf(RE::TESForm::LookupByID<RE::TESFaction>(entry.runtime), plugin, local);
        g_entries.push_back(entry);
        auto why = SaveLocked();
        if (!why.empty()) {
            g_entries.pop_back();
        }
        SKSE::log::info("Blocked factions: {} ({}) blocked{}", entry.name, a_key, why.empty() ? "" : " - " + why);
        return why;
    }
}
