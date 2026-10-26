#include "SkyrimNetLink.h"

#include "PCH.h"

#include <format>
#include <mutex>

namespace SNRom::SkyrimNetLink {

    namespace {

        using json = nlohmann::json;

        // Signatures from SkyrimNet's PublicAPI.h. std::string crosses the
        // boundary by value, which that header makes the contract: both DLLs
        // are MSVC with the dynamic CRT (/MD, CMakeLists.txt).
        using VersionFn = int (*)();
        using ReadyFn = bool (*)();
        using RelatedFn = std::string (*)(std::uint32_t, int, double, double);   // v3
        using QueryMemoriesFn = std::string (*)(std::uint32_t, const char*);     // v10

        constexpr std::uint32_t kPlayer = 0x14;
        constexpr double kDay = 86400.0;  // SkyrimNet's windows and times are game seconds

        std::once_flag g_bind;
        int g_api = 0;
        ReadyFn g_ready = nullptr;
        RelatedFn g_related = nullptr;
        QueryMemoriesFn g_queryMemories = nullptr;
        std::once_flag g_firstMemoryLogged;

        void Bind() {
            const auto mod = GetModuleHandleW(L"SkyrimNet.dll");
            if (!mod) {
                SKSE::log::warn("Time known: SkyrimNet.dll is not loaded, so its database cannot be read");
                return;
            }
            const auto version = reinterpret_cast<VersionFn>(GetProcAddress(mod, "PublicGetVersion"));
            g_api = version ? version() : 0;
            if (g_api >= 3) {
                g_ready = reinterpret_cast<ReadyFn>(GetProcAddress(mod, "PublicIsMemorySystemReady"));
                g_related = reinterpret_cast<RelatedFn>(GetProcAddress(mod, "PublicGetRelatedActors"));
            }
            if (g_api >= 10) {
                g_queryMemories = reinterpret_cast<QueryMemoriesFn>(GetProcAddress(mod, "PublicQueryMemoriesForActor"));
            }
            SKSE::log::info("Time known: SkyrimNet API v{} (related actors {}, memory query {})", g_api,
                            g_related != nullptr, g_queryMemories != nullptr);
        }

        std::uint32_t FormIdOf(const json& a_value) {
            if (a_value.is_number_unsigned() || a_value.is_number_integer()) {
                return static_cast<std::uint32_t>(a_value.get<std::int64_t>());
            }
            if (a_value.is_string()) {
                try {
                    return static_cast<std::uint32_t>(std::stoull(a_value.get<std::string>(), nullptr, 0));
                } catch (...) {
                }
            }
            return 0;
        }

        std::int64_t Count(const json& a_row, const char* a_key) {
            const auto it = a_row.find(a_key);
            return it != a_row.end() && it->is_number() ? it->get<std::int64_t>() : 0;
        }

        struct Shared {
            bool found = false;
            std::int64_t total = 0;
            std::int64_t inShort = 0;
            std::int64_t inMedium = 0;
        };

        // The player's shared-event counts with one person, all time and
        // within the two windows. Absent from the list means none at all.
        Shared SharedWith(std::uint32_t a_formId, double a_shortDays, double a_mediumDays) {
            Shared out;
            const auto raw = g_related(kPlayer, 0, a_shortDays * kDay, a_mediumDays * kDay);
            const auto rows = json::parse(raw, nullptr, false);
            if (!rows.is_array()) {
                return out;
            }
            for (const auto& row : rows) {
                if (row.is_object() && row.contains("formId") && FormIdOf(row["formId"]) == a_formId) {
                    out.found = true;
                    out.total = Count(row, "sharedEventCount");
                    out.inShort = Count(row, "recentSharedEventsShort");
                    out.inMedium = Count(row, "recentSharedEventsMedium");
                    break;
                }
            }
            return out;
        }

        double MemoryTime(const json& a_row) {
            for (const auto* key : { "game_time", "gameTime", "timestamp" }) {
                const auto it = a_row.find(key);
                if (it != a_row.end() && it->is_number()) {
                    return it->get<double>();
                }
            }
            return 0.0;
        }

        // This person's oldest memory, every row in SQL, active or not. Rows
        // without a game time are skipped (gameTimeAfter), or they would sort first.
        double OldestMemory(std::uint32_t a_formId) {
            if (!g_queryMemories) {
                return -1.0;
            }
            const auto raw =
                g_queryMemories(a_formId, R"({"maxCount":1,"gameTimeAfter":1,"isActive":null,"orderBy":"GameTimeAsc"})");
            const auto rows = json::parse(raw, nullptr, false);
            if (!rows.is_array() || rows.empty() || !rows[0].is_object()) {
                return 0.0;
            }
            std::call_once(g_firstMemoryLogged, [&] {
                auto shown = rows[0];
                for (const auto* key : { "text", "content" }) {
                    if (shown.contains(key)) {
                        shown[key] = "(omitted)";
                    }
                }
                SKSE::log::info("Time known: an oldest-memory row looks like {}", shown.dump());
            });
            return MemoryTime(rows[0]);
        }
    }

    std::string KnownProof(std::uint32_t a_formId) {
        std::call_once(g_bind, Bind);
        if (!g_related || !g_queryMemories || (g_ready && !g_ready())) {
            return {};
        }
        try {
            const auto week = SharedWith(a_formId, 2.0, 7.0);
            const auto month = SharedWith(a_formId, 30.0, 30.0);
            const auto oldest = OldestMemory(a_formId);
            if (oldest < 0.0) {
                return {};
            }
            return std::format("KNOWNPROOF {} {} {} {} {} {:.0f}", g_api, week.total, week.inShort, week.inMedium,
                               month.inShort, oldest);
        } catch (const std::exception& e) {
            SKSE::log::error("Time known: reading SkyrimNet's database failed: {}", e.what());
            return {};
        }
    }
}
