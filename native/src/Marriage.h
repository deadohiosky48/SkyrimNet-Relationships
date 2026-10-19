#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace SKSE {
    class SerializationInterface;
}

// THE MARRIAGE RECORD (2.5, marriage phase 1, M1). Until 2.5 Relationships never
// recorded a marriage: it read vanilla's PlayerMarriedFaction and MARAS, which
// owned the state machine. Phase 1 makes it ours, so a player can drop MARAS
// (docs: STANDALONE_SPEC_MARRIAGE.md, 5.1).
//
// IN THE CO-SAVE, beside the bond history, so an older save rolls the marriage
// back with the points that earned it. One writer, Set, which refuses a step
// that is not a legal one unless forced, and announces every change as the mod
// event SNRom_MarriageChanged.
//
// READ WHEREVER MARRIAGE IS READ: Display::MarriedToPlayer and
// Display::Commitment count it, and so do their Papyrus originals
// (SNRom_Bridge.IsMarriedToPlayer, CommitmentState) through SNRom_Native.
//
// Thread-safe: every function takes the lock.
namespace SNRom::Marriage {

    // As SNRom_Native.psc numbers them. COURTING is not stored: it is the spark
    // and a yes, which the bond already records.
    enum class State : std::int32_t {
        kNone = 0,
        kEngaged = 1,
        kMarried = 2,
        kBrokenOff = 3,  // an engagement ended
        kDivorced = 4,
        kWidowed = 5,    // they died while engaged or married
        kSeparated = 6,  // married, and the marriage is in question
    };

    const char* Name(State a_state);

    // Their state, kNone for anyone with no record.
    State StateOf(std::int32_t a_formId);

    // Married to the player: MARRIED, or SEPARATED (still married).
    bool Married(std::int32_t a_formId);
    bool Engaged(std::int32_t a_formId);

    // The one writer. Refuses an illegal step unless a_force (the developer
    // repair, an import, an external marriage). a_officiant 0 for none. Returns
    // false, and logs why, when refused or unchanged.
    bool Set(std::int32_t a_formId, State a_to, std::string a_why, bool a_force, std::int32_t a_officiant,
             bool a_eloped);

    // Everyone in a state, ascending form id.
    std::vector<std::int32_t> WithState(State a_state);

    // Mara's exception (spec 5.4): may the player marry again while married.
    bool Exception();
    void SetException(bool a_granted);

    // One person's record as the snapshot carries it; null for no record.
    nlohmann::json Of(std::int32_t a_formId);

    // ENGAGEMENT RINGS (Build A, M3r; spec 5.2a). The item each gave the
    // other, by form id; 0 none. Kept on an engaged or married record only.
    bool         SetRing(std::int32_t a_formId, bool a_fromPlayer, std::int32_t a_item);
    std::int32_t Ring(std::int32_t a_formId, bool a_fromPlayer);

    // A PROPOSAL DECLINED (spec 5.2): a no is an answer for now. Kept apart
    // from the records, since most who decline have none. Game days since the
    // last one, or -1 for never.
    void  NoteDeclined(std::int32_t a_formId);
    float DaysSinceDeclined(std::int32_t a_formId);

    // What Papyrus knows and pushes (SNRom_Bridge.ApiPushDecoratorFacts):
    // the player's spouses across every record, and the cooldown after a no,
    // in game days (Bond Pace).
    void         SetFacts(std::int32_t a_spouses, float a_cooldownDays);
    std::int32_t Spouses();
    bool         InCooldown(std::int32_t a_formId);

    // One more spouse allowed: none yet, or Mara's exception (spec 5.4).
    bool MayMarryAnother();

    // Everyone engaged to the player, ascending form id.
    std::vector<std::int32_t> AllEngaged();

    // THE STATE AS A FACTION RANK, for SkyrimNet's eligibility rules, which
    // evaluate get_faction_rank but not our own decorators (measured
    // 2026-10-17): FACT SNRom_Marriage, rank the State number, -1 for none.
    // Set on every change (Announce) and, after a load, for everyone with a
    // record who can be found; ranks are kept in the save as well.
    void SyncFactionsSoon();

    // The co-save (Cosave.cpp dispatches to these).
    inline constexpr std::uint32_t kRecordType = 'MARR';
    void Save(SKSE::SerializationInterface* a_intfc);
    void Load(SKSE::SerializationInterface* a_intfc, std::uint32_t a_version);
    void Revert();
}
