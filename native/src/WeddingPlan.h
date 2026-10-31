#pragma once

#include <array>
#include <cstdint>
#include <map>
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
// EVERYONE IN TIME, EACH TO THEIR MARK (wpm61; the author, 2026-10-28): with
// a mark or a place found, each person sets out by how far they must come,
// a day ahead from another hold, linked to their mark (SNRom_WeddingMark) and
// sent SNRom_WeddingGo with the package to take; SNRom_WeddingRecall when the
// day will not come after all. Nothing to send them to, they are sent by the
// place's name on SNRom_WeddingDay, as before.
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
        kLayoutSettled = 1 << 3,  // wpm61: where everyone stands, marked or left to the planner
    };

    // WHOSE GUESTS (wpm61; the author, 2026-10-28): "Olfina's guests" and the
    // player's, named by each partner. Not known, the planner asks.
    inline constexpr std::int32_t kSideUnknown = -1;
    inline constexpr std::int32_t kSideTheirs = 0;  // the betrothed's
    inline constexpr std::int32_t kSideYours = 1;   // the player's
    inline constexpr std::int32_t kSideBoth = 2;    // either's: they join the smaller side

    // WHERE EVERYONE STANDS (wpm61; the author, 2026-10-28): marks the player
    // sets by standing on the spot, as they tell the planner. The officiant
    // and the betrothed hold at theirs; each side gathers around its own.
    // EACH OF THE COUPLE THEIR OWN (seen in play, wpm61): the player said "I
    // will stand here", then "Olfina will stand here"; one mark for the
    // couple had no word for either, and Olfina's became her guests'.
    enum Mark : std::int32_t {
        kMarkOfficiant = 0,
        kMarkYou = 1,        // where the player stands (wpm61: "the couple's")
        kMarkTheirs = 2,     // the betrothed's guests
        kMarkYours = 3,      // the player's guests
        kMarkBetrothed = 4,  // where the betrothed stands; unmarked, beside the player
        kMarkRoles = 5,
    };

    // A VENUE (wpm61; the author: "the option to save a particular venue and
    // its marks"): the marks are kept under the place's name, so naming the
    // same place for another wedding brings them along. Each mark is a
    // persistent marker placed where the player stood; 0 unmarked.
    struct Venue {
        std::string                            name;   // the place as first said
        std::array<std::uint32_t, kMarkRoles>  marks{};
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
        // wpm61: each guest's side (absent, not known); the reference found
        // for the place, where everyone gathers when nothing is marked; and
        // who has set out for the wedding, each sent once.
        std::map<std::uint32_t, std::int32_t> sides;
        std::uint32_t                         anchor = 0;
        std::vector<std::uint32_t>            sent;
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
    // A guest's side, kSideTheirs..kSideBoth. False when they are no guest or
    // it was so already.
    bool SetSide(std::int32_t a_betrothed, std::uint32_t a_guest, std::int32_t a_side);
    // The side as said: either partner's name ("Olfina's", the player's),
    // "yours" (said to the player), "mine" from the betrothed, or "both";
    // kSideUnknown for anything else.
    std::int32_t SideNamed(RE::Actor* a_betrothed, RE::Actor* a_speaker, const std::string& a_words);
    // The side the game's records give: the betrothed's parents, siblings
    // and children are theirs; the player's, and the player's spouses, the
    // player's. kSideUnknown otherwise. Main thread.
    std::int32_t SideOf(RE::Actor* a_betrothed, RE::Actor* a_guest);
    // A MARK WHERE THE PLAYER STANDS (wpm61), for a_role (Mark), in the venue
    // under the plan's place; the mark it replaces is deleted. Main thread.
    bool SetMark(std::int32_t a_betrothed, std::int32_t a_role);
    // Where everyone stands is left to the planner: settled, unmarked.
    bool SettleLayout(std::int32_t a_betrothed);
    // The roles marked for the plan's place, as bits (1 << Mark).
    std::uint32_t Marked(std::int32_t a_betrothed);
    // THE PLANNER'S BEST EFFORT (wpm61): the reference found for the place,
    // where everyone gathers when nothing is marked. A load door is kept as
    // its other side. Main thread.
    bool SetAnchor(std::int32_t a_betrothed, RE::TESObjectREFR* a_found);
    // One who set out for a wedding let go: their link to the mark cleared,
    // and no longer counted as sent. Papyrus removes their package. Main
    // thread.
    void LetGo(RE::Actor* a_who);
    // WHEN IT BEGINS, EACH TO THEIR PLACE (wpm65): the officiant and the
    // betrothed linked to their marks, and each guest near enough to walk it
    // to a place of their own in rows at their side's mark, facing the
    // couple. Returns those sent; each is reported settled with the mod event
    // SNRom_WeddingInPlace (strArg their role). Main thread.
    std::vector<RE::Actor*> TakePlaces(std::int32_t a_betrothed);
    // The wedding over or stopped: the guests' places removed, and everyone
    // still on their way linked to their mark again. Main thread.
    void ClearPlaces();
    // STOPPED SHORT (wpm67): a planned wedding that stalled or met a no does
    // not begin again by itself; the officiant may offer (OfficiatingFor,
    // stoppedShort), and BegunAgain clears it when they do.
    void StoppedShort(std::int32_t a_betrothed);
    void BegunAgain(std::int32_t a_betrothed);
    // The betrothed's planned wedding day has begun (everyone sent).
    bool Today(std::int32_t a_betrothed);
    // THE RECEPTION (wpm68): married, everyone who set out for it stays at
    // the place, gathered wide around the couple's mark, for two hours, then
    // goes their way (SNRom_WeddingRecall). Call before the plan is cleared.
    // How many stay; 0 for none (let them go at once). Main thread.
    std::int32_t BeginReception(std::int32_t a_betrothed);
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
    // could find, nothing marked, and nothing said of what it is by),
    // "guests", "sides" (a guest whose side is not known), "ceremony" (a
    // planner's), "theirRing", "yourRing" (a planner's), "outfit", and last
    // "layout" (a planner's: nothing marked, nor left to them).
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
