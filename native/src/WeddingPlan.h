#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace SKSE {
    class SerializationInterface;
}
namespace RE {
    class Actor;
}

// THE WEDDING PLAN (2.5, Build B, M4p; spec 5.3a; the author, 2026-10-17 and
// 2026-10-20). A wedding is planned by talking, with the betrothed, a wedding
// planner, and the officiant; what they agree is kept here, one plan per
// betrothed, and every part of it can be changed the same way.
//
// THE PLAN IS A CHECKLIST. Required for the day: a day and hour, a place, and
// an officiant who agreed (themselves: only the officiant's own action sets
// it). Optional, never gating: guests, outfits, rings, the ceremony's parts.
// The gate is native and sits on what makes the day happen; conversation is
// never gated.
//
// A WEDDING PLANNER (the author, 2026-10-20) is hired for a fee (50 gold) and
// composes the ceremony: the address to the guests, a reading, the rings
// exchanged, the kiss. Without one the ceremony is the minimum any wedding
// has (Ceremony.h). The planner is also where the rings are chosen, except
// for an elopement.
//
// THE DAY (M4w) is watched here: a few hours before, the officiant, the
// betrothed and the guests are sent to the place and the betrothed changes
// into their wedding clothes (SNRom_WeddingDay, which Papyrus carries out
// through SeverActions or IntelEngine); when the player is there with the two
// of them, the wedding begins (SNRom_WeddingBegin); a day that passes with the
// player absent is missed (SNRom_WeddingMissed).
//
// IN THE CO-SAVE, so an older save rolls the plan back with everything else.
// Thread-safe: every function takes the lock.
namespace SNRom::WeddingPlan {

    // A wedding planner's fee, in gold (the author, 2026-10-20: "maybe they
    // charge you 50 gold").
    inline constexpr std::int32_t kPlannerFee = 50;

    // The ceremony's parts, beyond the minimum (a planner's).
    enum Part : std::uint32_t {
        kAddress = 1 << 0,  // the officiant addresses everyone gathered
        kReading = 1 << 1,  // a reading or a blessing
        kRings = 1 << 2,    // the rings exchanged before the pronouncement
        kKiss = 1 << 3,     // the kiss, invited with the pronouncement
        kAllParts = kAddress | kReading | kRings | kKiss,
    };

    enum class Status : std::int32_t {
        kPlanning = 0,
        kUnderWay = 1,  // the day has begun: everyone sent to the place
    };

    struct Plan {
        std::uint32_t              planner = 0;    // a hired planner's form id; 0 none
        float                      day = -1.0f;    // the game day (whole), -1 unset
        std::int32_t               hour = -1;      // 0..23, -1 unset
        std::string                place;          // as agreed, a proper name
        std::uint32_t              officiant = 0;  // who agreed to marry them
        std::vector<std::uint32_t> guests;
        std::uint32_t              parts = 0;      // Part bits
        std::int32_t               ringMetal = -1; // the betrothed's wedding ring: 0 gold, 1 silver, 2 ebony
        std::int32_t               bandMetal = -1; // the player's band
        std::int32_t               bandWide = -1;  // 1 wide, 0 braided, -1 as the player's sex has it
        bool                       outfit = false; // the betrothed has saved what they will wear
        Status                     status = Status::kPlanning;
        float                      missedDay = -1.0f;  // the last day the player did not come
        float                      lapsedDay = -1.0f;  // the last day that passed unready
    };

    // The plan for a_betrothed, or nothing.
    std::optional<Plan> Get(std::int32_t a_betrothed);

    // The setters. Each makes the plan if there is none; the caller has
    // checked a_betrothed is engaged to the player. False when nothing changed.
    bool Hire(std::int32_t a_betrothed, std::uint32_t a_planner);
    bool SetDay(std::int32_t a_betrothed, std::int32_t a_daysFromNow, std::int32_t a_hour);
    bool SetPlace(std::int32_t a_betrothed, std::string a_place);
    bool SetOfficiant(std::int32_t a_betrothed, std::uint32_t a_officiant);
    bool AddGuest(std::int32_t a_betrothed, std::uint32_t a_guest);
    bool RemoveGuest(std::int32_t a_betrothed, std::uint32_t a_guest);
    bool SetParts(std::int32_t a_betrothed, std::uint32_t a_parts);
    bool SetRings(std::int32_t a_betrothed, std::int32_t a_ringMetal, std::int32_t a_bandMetal, std::int32_t a_bandWide);
    bool SetOutfit(std::int32_t a_betrothed, bool a_saved);
    // The day cleared, the rest kept: a postponement agreed in conversation.
    bool Postpone(std::int32_t a_betrothed);
    // Gone: married, broken off, or called off.
    void Clear(std::int32_t a_betrothed);

    // The required items still open: "day", "place", "officiant", in that
    // order. Empty when the day can happen.
    std::vector<std::string> Open(const Plan& a_plan);

    // What a prompt reads (0330, 0331, 0332), relative to now: the day in
    // words, the place, the officiant's and guests' names, what is open, and
    // anything that went wrong. Null for no plan.
    nlohmann::json ForPrompt(std::int32_t a_betrothed);
    // Every plan a_officiant agreed to officiate, for get_officiant.
    nlohmann::json OfficiatingFor(std::uint32_t a_officiant);
    // The snapshot's plan (snapshot.schema.json, marriage.plan); null for none.
    nlohmann::json ForSnapshot(std::int32_t a_betrothed);

    // Someone by name: anyone loaded, then anyone on the roster. Main thread
    // or a VM thread; reads the engine only.
    RE::Actor* PersonNamed(const std::string& a_name);

    // A time of day in words ("morning", "noon", "evening"...) or an hour as
    // digits, to an hour; -1 when it means nothing.
    std::int32_t HourOf(const std::string& a_words);

    // kDataLoaded: the watch over the day, every few seconds of game time.
    void Start();

    // The co-save (Cosave.cpp dispatches to these).
    inline constexpr std::uint32_t kRecordType = 'WPLN';
    void Save(SKSE::SerializationInterface* a_intfc);
    void Load(SKSE::SerializationInterface* a_intfc, std::uint32_t a_version);
    void Revert();
}
