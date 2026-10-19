#include "Officiant.h"

#include "PCH.h"

#include "Marriage.h"

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
            static auto* f = Faction(0xD71, "SNRom_Integration.esl");
            return f;
        }

        // Every officiant's record, found at kDataLoaded from the plugins.
        std::vector<RE::TESNPC*> g_officiants;

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
        g_officiants.clear();
        for (auto* npc : data->GetFormArray<RE::TESNPC>()) {
            if (npc && (Lists(npc, Priests()) || Lists(npc, Jarls()))) {
                g_officiants.push_back(npc);
                Mark(npc, ours);
            }
        }
        SKSE::log::info("Officiants: {} priests, priestesses and jarls can marry the player", g_officiants.size());
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
        SKSE::log::info("Officiants: {} marked again after the load (their factions came from the save)", again);
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
