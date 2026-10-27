#pragma once

#include <cstdint>
#include <string>

namespace RE {
    class Actor;
}

// THE WEDDING, SPOKEN AND DIRECTED (2.5; the author, 2026-10-20). A wedding
// runs as a fixed script, held here, that moves on when it HEARS the right
// person speak (SkyrimNet's dialogue events), never on a model choosing an
// action at the right moment: in wpm17 that never happened for the betrothed's
// "I do", and the wedding stalled.
//
// THE MINIMUM, for any ceremony (the author): the officiant opens and asks for
// vows; the player says theirs; the betrothed says theirs; the officiant asks
// the player "do you take..."; the player answers; the officiant asks the
// betrothed; the betrothed answers; the officiant pronounces them married. The
// two answers are judged yes, no or unclear by a small prompt of their own
// (snrom_ceremony_judge): a no ends the wedding, an unclear answer is asked
// again. More elaborate ceremonies add steps to the same list (and one day a
// wedding planner composes it, STANDALONE_PLAN_2.5.md, M4w).
//
// The model writes every word. The DLL decides whose turn it is, cues them
// (a ModEvent Papyrus turns into SkyrimNetApi.DirectNarration once the room is
// quiet), and records the marriage only when the officiant has pronounced it.
// A no, cold feet, someone leaving, or nobody going on ends it; they stay
// engaged and can begin again another time.
//
// One at a time. The step number is also the rank of FACT SNRom_Ceremony on
// the officiant and the betrothed, which the two remaining actions' eligibility
// reads: MarriageBless (begin) and MarriageColdFeet (stop).
namespace SNRom::Ceremony {

    // kDataLoaded: SkyrimNet's dialogue events and custom prompts.
    void Register();

    // Begins one, or refuses (false) when one is under way, either is None, or
    // SkyrimNet has no dialogue events. a_variant: the OpenRouter variant the
    // answers are judged with (SNRom_Bridge.VariantName).
    // a_planned: a planned wedding (Build B, M4p), with a_parts
    // (WeddingPlan::Part) added to the minimum; otherwise an elopement, the
    // minimum alone.
    bool Begin(RE::Actor* a_officiant, RE::Actor* a_betrothed, std::string a_variant, std::uint32_t a_parts = 0,
               bool a_planned = false);

    // WHAT IS HAPPENING NOW, as a step's kind (Ceremony.cpp, Kind): 1 the
    // opening, 2 the player's vows, 3 the betrothed's, 4-5 the player asked
    // and answering, 6-7 the betrothed, 8 the pronouncement; a planned
    // wedding's 10 the address, 11 a reading, 12 the rings. 0 when nothing is
    // under way. Also the FACT SNRom_Ceremony rank.
    std::int32_t Now();

    // The wedding under way is a planned one, and its parts.
    bool          Planned();
    std::uint32_t Parts();

    // The two taking part, or null when nothing is under way. LastOfficiant
    // outlives the ceremony, for SNRom_CeremonyMarried's handler.
    RE::Actor* Officiant();
    RE::Actor* Betrothed();
    RE::Actor* LastOfficiant();

    // A cue (SNRom_CeremonyCue, numArg the token): whom it addresses, and
    // whether it is still wanted when it is sent (the step is still on, and
    // its speaker has not spoken on their own). CueSent starts the step's
    // patience.
    RE::Actor* CueTarget(std::int32_t a_token);
    bool       CueWanted(std::int32_t a_token);
    // Seconds to hold a cue back: the line before is still being said, for
    // longer than SkyrimNet's directed turn waits for the floor.
    float      CueDelay(std::int32_t a_token);
    void       CueSent(std::int32_t a_token);

    // Over, short of a marriage (cold feet, a no, someone gone):
    // SNRom_CeremonyEnded (strArg a_why, sender the betrothed) tells Papyrus.
    void Stop(std::string a_why);

    // kPostLoadGame: a ceremony is never carried across a load, and a rank a
    // save kept from one is cleared from everyone near.
    void Reset();

    // For get_officiant and get_romance: a_actor's part in the ceremony under
    // way: 1 the officiant, 2 the betrothed, 0 none.
    std::int32_t RoleOf(RE::Actor* a_actor);
    std::int32_t RoleOf(std::int32_t a_formId);

    // WAS IT SAID (seen in play, wpm58): the planner's action, seeing only her
    // own line ("He is written into the roll"), invited Brenuin, a beggar
    // standing nearby, for the brother Olfina had named a line before. True
    // when a_name (whole, its first word, or a word within a letter or two of
    // it) was in a line someone spoke lately - and always true when
    // SkyrimNet's dialogue is not heard, so nothing is refused for want of it.
    bool Said(const std::string& a_name);
}
