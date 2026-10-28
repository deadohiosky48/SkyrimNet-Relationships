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
    class TESObjectREFR;
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
// of them at the hour, the wedding begins (SNRom_WeddingBegin); a day that passes with the
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

    // THE WALKTHROUGH (wpm51; the author, 2026-10-26): the planner asks about
    // each part of the plan not yet settled, one at a time. An optional part
    // is settled once it has been answered, a "no" included ("no guests",
    // "the usual ceremony"), so it is not asked again; anything can still be
    // changed until the day. Rings are settled per person, when both their
    // style and metal are chosen.
    enum Settled : std::uint32_t {
        kGuestsSettled = 1 << 0,
        kCeremonySettled = 1 << 1,
        kOutfitSettled = 1 << 2,
    };

    // A WEDDING RING'S STYLE (wpm51; the author: whoever gave whom an
    // engagement ring, and whatever either of them is): each of the couple
    // chooses the slim set - the engagement ring joined to its band when
    // they wear one, else the braided band - or the wide plain band. Both
    // may choose the same.
    inline constexpr std::int32_t kSlim = 0;
    inline constexpr std::int32_t kWide = 1;

    struct Plan {
        std::uint32_t              planner = 0;    // a hired planner's form id; 0 none
        float                      day = -1.0f;    // the game day (whole), -1 unset
        std::int32_t               hour = -1;      // 0..23, -1 unset
        std::string                place;          // as agreed, a proper name
        // A PLACE PEOPLE CAN FIND (seen in play, wpm59): "Under the
        // Gildergreen" was no place SeverActions knew, and all fourteen sent
        // to it went nowhere. nearTo is what the place is by, as said ("Temple
        // of Kynareth"); travelTo whichever of the two Papyrus found, and
        // findable -1 not yet looked for, 0 neither found, 1 travelTo found.
        std::string                nearTo;
        std::string                travelTo;
        std::int32_t               findable = -1;
        std::uint32_t              officiant = 0;  // who agreed to marry them
        std::vector<std::uint32_t> guests;
        std::uint32_t              parts = 0;      // Part bits
        // The rings, per person: style kSlim or kWide, metal 0 gold, 1 silver,
        // 2 ebony; -1 not chosen.
        std::int32_t               theirStyle = -1;
        std::int32_t               theirMetal = -1;
        std::int32_t               yourStyle = -1;
        std::int32_t               yourMetal = -1;
        bool                       outfit = false; // the betrothed has saved what they will wear
        std::uint32_t              settled = 0;    // Settled bits
        Status                     status = Status::kPlanning;
        float                      missedDay = -1.0f;  // the last day the player did not come
        float                      lapsedDay = -1.0f;  // the last day that passed unready
    };

    // The plan for a_betrothed, or nothing.
    std::optional<Plan> Get(std::int32_t a_betrothed);

    // The setters. Each makes the plan if there is none; the caller has
    // checked a_betrothed is engaged to the player. False when nothing changed.
    bool Hire(std::int32_t a_betrothed, std::uint32_t a_planner);
    // a_daysFromNow or a_hour -1: that one left as it is.
    bool SetDay(std::int32_t a_betrothed, std::int32_t a_daysFromNow, std::int32_t a_hour);
    // THE DAY AS SAID (wpm51): a date ("the 4th of Sun's Height", "Loredas,
    // 4 Sun's Height"), a weekday ("next Loredas"), or how far off
    // ("tomorrow", "in a week", "7"), read against Skyrim's calendar; and a
    // time of day. What cannot be read changes nothing, and is logged. A
    // model that could not turn "4 Sun's Height" into a count of days sent
    // nothing at all, and nothing read as today at noon (2026-10-26).
    bool SetDayFromWords(std::int32_t a_betrothed, const std::string& a_day, const std::string& a_time);
    // Days from today for a day as said; nothing when it cannot be read.
    std::optional<std::int32_t> DaysFromWords(const std::string& a_words);
    // An empty a_place keeps the place (only what it is by is said); a new
    // place clears what it was by unless a_near says it.
    bool SetPlace(std::int32_t a_betrothed, std::string a_place, std::string a_near);
    // What Papyrus found to send people to: "" when it found neither.
    bool SetFindable(std::int32_t a_betrothed, std::string a_travelTo);
    // ANYONE NOT THERE WHEN IT BEGINS (wpm60; the author, 2026-10-28) is
    // brought to this side of the door nearest a_near, where they would come
    // out had they walked from elsewhere. False when no door is near; then
    // they are not moved. Main thread or a VM thread; the move is queued.
    bool BringBeside(RE::Actor* a_who, RE::TESObjectREFR* a_near);
    bool SetOfficiant(std::int32_t a_betrothed, std::uint32_t a_officiant);
    bool AddGuest(std::int32_t a_betrothed, std::uint32_t a_guest);
    bool RemoveGuest(std::int32_t a_betrothed, std::uint32_t a_guest);
    bool SetParts(std::int32_t a_betrothed, std::uint32_t a_parts);
    // Each -1 left as it is.
    bool SetRings(std::int32_t a_betrothed, std::int32_t a_yourStyle, std::int32_t a_yourMetal,
                  std::int32_t a_theirStyle, std::int32_t a_theirMetal);
    // "No guests": the guests settled with none invited.
    bool SettleGuests(std::int32_t a_betrothed);
    bool SetOutfit(std::int32_t a_betrothed, bool a_saved);
    // The day cleared, the rest kept: a postponement agreed in conversation.
    bool Postpone(std::int32_t a_betrothed);
    // Gone: married, broken off, or called off.
    void Clear(std::int32_t a_betrothed);

    // The required items still open, in the order a planner asks them:
    // "place", "officiant", "day", "hour". Empty when the day can happen.
    std::vector<std::string> Open(const Plan& a_plan);
    // The optional parts not yet settled, in order: "near" (a place no one
    // could find, and nothing said of what it is by), "guests", "ceremony" (a
    // planner's), "theirRing", "yourRing" (a planner's), "outfit".
    std::vector<std::string> Unsettled(const Plan& a_plan);

    // What a prompt reads (0330, 0331, 0332), relative to now: the day in
    // words, the place, the officiant's and guests' names, what is open, and
    // anything that went wrong. Null for no plan.
    nlohmann::json ForPrompt(std::int32_t a_betrothed);
    // Every plan a_officiant agreed to officiate, for get_officiant.
    nlohmann::json OfficiatingFor(std::uint32_t a_officiant);
    // The snapshot's plan (snapshot.schema.json, marriage.plan); null for none.
    nlohmann::json ForSnapshot(std::int32_t a_betrothed);

    // Someone by name, living (wpm52: anyone in Skyrim, not only those
    // loaded or on the roster - Eorlund Gray-Mane, invited from Whiterun's
    // market, was neither). The best match wins: the whole name, then the
    // first name ("Eorlund"), then part of one; between equals, someone
    // loaded, then someone on the roster, then anyone. Main thread or a VM
    // thread; reads the engine only.
    RE::Actor* PersonNamed(const std::string& a_name);

    // GUESTS AS THEY ARE SAID (wpm52): a list, by commas or "and", of names
    // ("Eorlund"), relations ("Olfina's mother", "my brothers", "her
    // parents"), and names behind a title ("Uncle Vignar"). a_speaker is who
    // said it ("my"); the player is "your". Each one read is logged, and
    // each that could not be. The living only, no one twice.
    std::vector<RE::Actor*> GuestsNamed(RE::Actor* a_speaker, const std::string& a_list);

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
