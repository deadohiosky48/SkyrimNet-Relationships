#pragma once

#include <cstdint>
#include <string>

namespace RE {
    class Actor;
}

// THE WEDDING, SPOKEN (2.5; the author, 2026-10-20). The marriage happens in
// dialogue, as weddings do: the officiant opens and asks the player, then the
// betrothed, whether each takes the other, and pronounces them married once
// both have said yes. Only the pronouncement records the marriage. Anyone may
// stop short: a no, cold feet, or walking away ends the ceremony and leaves
// them engaged, to begin again another time.
//
// One ceremony at a time. The stage is kept here and mirrored as the rank of
// FACT SNRom_Ceremony on the officiant and the betrothed, which SkyrimNet's
// eligibility rules read (its get_faction_rank, not our decorators), so each
// step's action is offered only at its step. Papyrus runs the actions and
// cues the next speaker (SkyrimNetApi.DirectNarration).
//
// This is the unplanned form, an elopement: opening words, the two questions,
// the pronouncement. A planned wedding (Build B, M4w) adds to it.
namespace SNRom::Ceremony {

    enum class Stage : std::int32_t {
        kNone = 0,
        kAskPlayer = 1,     // the officiant has opened and asks the player
        kAskBetrothed = 2,  // the player said yes; the betrothed is asked
        kPronounce = 3,     // both said yes; the officiant pronounces them wed
    };

    // Begins one, or refuses (false) when one is under way or either is None.
    bool Begin(RE::Actor* a_officiant, RE::Actor* a_betrothed);

    // The step now; kNone when nothing is under way.
    Stage Now();

    // The two taking part, or null when nothing is under way.
    RE::Actor* Officiant();
    RE::Actor* Betrothed();

    // On to a_to, which must be the next step. False, changing nothing,
    // otherwise.
    bool Advance(Stage a_to);

    // Over. a_married: the officiant pronounced them; anything else ended it
    // short, and SNRom_CeremonyEnded (strArg a_why, sender the betrothed) tells
    // Papyrus, which records it.
    void End(bool a_married, std::string a_why);

    // kPostLoadGame and kPreLoadGame: a ceremony is never carried across a
    // load, and a rank a save kept from one is cleared from everyone near.
    void Reset();

    // For get_officiant and get_romance: a_actor's part in the ceremony under
    // way: 1 the officiant, 2 the betrothed, 0 none.
    std::int32_t RoleOf(RE::Actor* a_actor);
    std::int32_t RoleOf(std::int32_t a_formId);
}
