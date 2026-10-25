#include "Officiant.h"

#include "PCH.h"

#include "OurPlugin.h"

#include "Marriage.h"

#include <cctype>

namespace SNRom::Officiant {

    namespace {

        RE::TESFaction* Faction(RE::FormID a_id, const char* a_plugin) {
            auto* data = RE::TESDataHandler::GetSingleton();
            return data ? data->LookupForm<RE::TESFaction>(a_id, a_plugin) : nullptr;
        }

        // Verified against Skyrim.esm's FACT records: JobPriestFaction and
        // JobJarlFaction. Ours is FACT SNRom_Officiant.
        RE::TESFaction* Priests() {
            static auto* f = Faction(0x0005159A, "Skyrim.esm");
            return f;
        }
        RE::TESFaction* Jarls() {
            static auto* f = Faction(0x00050920, "Skyrim.esm");
            return f;
        }
        RE::TESFaction* Ours() {
            static auto* f = Faction(0xD71, OurPlugin());
            return f;
        }
        RE::TESFaction* PlannerFaction() {
            static auto* f = Faction(0xD87, OurPlugin());
            return f;
        }

        // Every officiant's record, found at kDataLoaded from the plugins.
        std::vector<RE::TESNPC*> g_officiants;

        // THE WEDDING PLANNERS (Build B, M4p; the author, 2026-10-20: "a
        // handful of base-game NPCs"). A priestess in each of five temples,
        // so there is one in every major city's reach: Mara's in Riften, the
        // Divines' in Solitude, Kynareth's in Whiterun, Dibella's in Markarth,
        // Talos's in Windhelm. Found by name among the unique NPCs.
        constexpr const char* kPlannerNames[] = { "Dinya Balu", "Silana Petreia", "Danica Pure-Spring", "Senna",
                                                  "Jora" };
        std::vector<RE::TESNPC*> g_planners;

        // THE PLANNER'S BOOK lists these by hand (tools/rings/
        // add_ring_records.py, BOOK_TEXT): checked once at kDataLoaded, so a
        // name the book gets wrong is in the log, not discovered in play.
        constexpr const char* kBookOfficiants[] = {
            "Maramal", "Dinya Balu", "Rorlund", "Silana Petreia", "Freir", "Danica Pure-Spring", "Hamal", "Senna",
            "Jora", "Lortheim", "Andurs", "Styrr", "Brother Verulus", "Helgird", "Runil", "Balgruuf the Greater",
            "Vignar Gray-Mane", "Elisif the Fair", "Ulfric Stormcloak", "Brunwulf Free-Winter", "Laila Law-Giver",
            "Maven Black-Briar", "Igmund", "Thongvor Silver-Blood", "Siddgeir", "Dengeir of Stuhn",
            "Idgrod Ravencrone", "Sorli the Builder", "Skald the Elder", "Brina Merilis", "Korir", "Kraldar"
        };

        void Mark(RE::TESNPC* a_npc, RE::TESFaction* a_ours);

        // The record lists a_faction, at any rank.
        bool Lists(const RE::TESNPC* a_npc, const RE::TESFaction* a_faction) {
            if (!a_npc || !a_faction) {
                return false;
            }
            for (const auto& entry : a_npc->factions) {
                if (entry.faction == a_faction) {
                    return true;
                }
            }
            return false;
        }
    }

    void MarkAll() {
        auto* data = RE::TESDataHandler::GetSingleton();
        auto* ours = Ours();
        if (!data || !ours) {
            SKSE::log::warn("Officiants: SNRom_Officiant not found; no one can marry the player");
            return;
        }
        if (Marriage::MarasOwns()) {
            SKSE::log::info("Officiants: none marked; MARAS runs marriage");
            return;
        }
        g_officiants.clear();
        for (auto* npc : data->GetFormArray<RE::TESNPC>()) {
            if (npc && (Lists(npc, Priests()) || Lists(npc, Jarls()))) {
                g_officiants.push_back(npc);
                Mark(npc, ours);
            }
        }
        SKSE::log::info("Officiants: {} priests, priestesses and jarls can marry the player", g_officiants.size());

        g_planners.clear();
        if (auto* planners = PlannerFaction()) {
            for (auto* npc : data->GetFormArray<RE::TESNPC>()) {
                const char* name = npc && npc->IsUnique() ? npc->GetFullName() : nullptr;
                if (!name || !*name) {
                    continue;
                }
                for (const auto* wanted : kPlannerNames) {
                    if (_stricmp(name, wanted) == 0) {
                        g_planners.push_back(npc);
                        Mark(npc, planners);
                        break;
                    }
                }
            }
        }
        SKSE::log::info("Officiants: {} wedding planners", g_planners.size());

        std::string missing;
        for (const auto* name : kBookOfficiants) {
            const bool known = std::any_of(g_officiants.begin(), g_officiants.end(), [name](RE::TESNPC* a_npc) {
                const char* full = a_npc ? a_npc->GetFullName() : nullptr;
                return full && _stricmp(full, name) == 0;
            });
            if (!known) {
                missing += (missing.empty() ? "" : ", ") + std::string(name);
            }
        }
        if (!missing.empty()) {
            SKSE::log::warn("Officiants: the planner's book names some who are not officiants here: {}", missing);
        }
    }

    void Remark() {
        auto* ours = Ours();
        if (!ours) {
            return;
        }
        std::size_t again = 0;
        for (auto* npc : g_officiants) {
            if (!Lists(npc, ours)) {
                Mark(npc, ours);
                ++again;
            }
        }
        if (auto* planners = PlannerFaction()) {
            for (auto* npc : g_planners) {
                if (!Lists(npc, planners)) {
                    Mark(npc, planners);
                    ++again;
                }
            }
        }
        SKSE::log::info("Officiants: {} marked again after the load (their factions came from the save)", again);
    }

    RE::Actor* Named(const std::string& a_name) {
        std::string wanted;
        for (const char c : a_name) {
            if (!std::isspace(static_cast<unsigned char>(c)) || !wanted.empty()) {
                wanted += static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            }
        }
        while (!wanted.empty() && std::isspace(static_cast<unsigned char>(wanted.back()))) {
            wanted.pop_back();
        }
        if (wanted.empty()) {
            return nullptr;
        }
        RE::Actor* partial = nullptr;
        for (auto* npc : g_officiants) {
            const char* name = npc ? npc->GetFullName() : nullptr;
            if (!name || !*name) {
                continue;
            }
            std::string lower;
            for (const char* c = name; *c; ++c) {
                lower += static_cast<char>(std::tolower(static_cast<unsigned char>(*c)));
            }
            auto* actor = npc->GetUniqueActor();
            if (!actor || actor->IsDead()) {
                continue;
            }
            if (lower == wanted) {
                return actor;
            }
            if (!partial && (lower.starts_with(wanted) || lower.find(wanted) != std::string::npos)) {
                partial = actor;
            }
        }
        return partial;
    }

    bool IsPlanner(RE::Actor* a_actor) {
        if (!a_actor || a_actor->IsDead()) {
            return false;
        }
        auto* base = a_actor->GetActorBase();
        return base && std::find(g_planners.begin(), g_planners.end(), base) != g_planners.end();
    }

    bool Is(RE::Actor* a_actor) {
        if (!a_actor || a_actor->IsDead() || a_actor->IsChild() || a_actor->IsPlayerRef()) {
            return false;
        }
        // The plugins' officiants; the factions catch someone a mod makes a
        // priest or jarl while the game runs.
        auto* base = a_actor->GetActorBase();
        if (base && std::find(g_officiants.begin(), g_officiants.end(), base) != g_officiants.end()) {
            return true;
        }
        const auto in = [&](RE::TESFaction* a_faction) { return a_faction && a_actor->IsInFaction(a_faction); };
        return in(Ours()) || in(Priests()) || in(Jarls());
    }

    namespace {
        void Mark(RE::TESNPC* a_npc, RE::TESFaction* a_ours) {
            if (Lists(a_npc, a_ours)) {
                return;
            }
            RE::FACTION_RANK entry{};
            entry.faction = a_ours;
            entry.rank = 0;
            a_npc->factions.push_back(entry);
        }
    }

    std::vector<RE::Actor*> BetrothedNear(float a_range) {
        std::vector<RE::Actor*> out;
        auto*                   player = RE::PlayerCharacter::GetSingleton();
        if (!player) {
            return out;
        }
        const auto here = player->GetPosition();
        for (const auto id : Marriage::AllEngaged()) {
            auto* actor = RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(id));
            if (!actor || actor->IsDead() || !actor->Is3DLoaded()) {
                continue;
            }
            // Indoors, the same cell; outdoors, the same worldspace (a
            // neighbouring exterior cell is still across the square).
            auto*      cell = player->GetParentCell();
            const bool indoors = cell && cell->IsInteriorCell();
            if (indoors ? actor->GetParentCell() != cell : actor->GetWorldspace() != player->GetWorldspace()) {
                continue;
            }
            if (actor->GetPosition().GetDistance(here) <= a_range) {
                out.push_back(actor);
            }
        }
        return out;
    }

    bool CanBless(RE::Actor* a_actor) {
        if (!Is(a_actor) || !Marriage::MayMarryAnother()) {
            return false;
        }
        for (auto* betrothed : BetrothedNear(kPresentRange)) {
            if (betrothed != a_actor) {
                return true;
            }
        }
        return false;
    }
}
