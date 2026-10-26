#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace RE {
    class Actor;
}

// WHO CAN MARRY THEM (2.5, Build A, M4e; spec 5.3). Any priest or priestess at
// any temple, or any jarl: vanilla's JobPriestFaction and JobJarlFaction.
//
// AT ANY RANK, -1 INCLUDED. Vanilla lists its jarls in JobJarlFaction at rank
// -1 (Elisif, Skyrim.esm NPC_ 0x0001326A), which the engine's IsInFaction, and
// so SkyrimNet's is_in_faction, reads as not a member: Elisif was never
// offered MarriageBless (2026-10-19). So at kDataLoaded every NPC whose record
// lists either faction, at any rank, is given our own SNRom_Officiant at rank
// 0, which the action's eligibility can ask.
namespace SNRom::Officiant {

    // kDataLoaded: SNRom_Officiant onto every officiant's record. In memory
    // only; nothing reaches the save.
    void MarkAll();

    // kPostLoadGame. A SAVE REPLACES THE FACTION LIST of every NPC whose
    // factions changed in it, which takes our mark off them: Elisif, a MARAS
    // spouse with a dozen factions added, lost hers (2026-10-19). So everyone
    // MarkAll found is marked again after each load. Main thread.
    void Remark();

    // A living adult priest, priestess or jarl.
    bool Is(RE::Actor* a_actor);

    // One of the wedding planners (Build B, M4p), FACT SNRom_WeddingPlanner
    // rank 0 on their records, put there by MarkAll and Remark.
    bool IsPlanner(RE::Actor* a_actor);

    // A priest, priestess or jarl by name, wherever they are (their unique
    // actor), for a planner choosing who will marry a couple (the author,
    // 2026-10-25: any of them, assumed willing, travels to the wedding).
    // None when no officiant has that name, or they are dead. A leading
    // "Jarl" is not part of a name, and "the Jarl of <hold>" (by city or
    // hold, wpm48) is whoever rules that hold now.
    RE::Actor* Named(const std::string& a_name);

    // The officiant to send on the wedding day in place of a_officiant: the
    // same one, unless they were a hold's jarl who has since died or been
    // exiled, when it is whoever rules the hold now. Main thread.
    RE::Actor* InPlaceOf(std::uint32_t a_officiant);

    // Everyone engaged to the player who is here: loaded, alive, and within
    // a_range units of the player. Eloping needs both of them present.
    std::vector<RE::Actor*> BetrothedNear(float a_range);

    // How near counts as present for eloping: about a room's width.
    inline constexpr float kPresentRange = 1500.0f;

    // Whether a_actor may bless a marriage now: an officiant, not themselves
    // the betrothed, someone engaged to the player is here, and the household
    // rule allows one more spouse (spec 5.4).
    bool CanBless(RE::Actor* a_actor);
}
