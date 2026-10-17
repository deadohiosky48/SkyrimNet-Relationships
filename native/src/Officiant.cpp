#include "Officiant.h"

#include "PCH.h"

#include "Marriage.h"

namespace SNRom::Officiant {

    namespace {

        RE::TESFaction* VanillaFaction(RE::FormID a_id) {
            auto* data = RE::TESDataHandler::GetSingleton();
            return data ? data->LookupForm<RE::TESFaction>(a_id, "Skyrim.esm") : nullptr;
        }
    }

    bool Is(RE::Actor* a_actor) {
        // Verified against Skyrim.esm's FACT records: JobPriestFaction and
        // JobJarlFaction.
        static auto* priests = VanillaFaction(0x0005159A);
        static auto* jarls = VanillaFaction(0x00050920);
        if (!a_actor || a_actor->IsDead() || a_actor->IsChild() || a_actor->IsPlayerRef()) {
            return false;
        }
        return (priests && a_actor->IsInFaction(priests)) || (jarls && a_actor->IsInFaction(jarls));
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
