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

    // The co-save (Cosave.cpp dispatches to these).
    inline constexpr std::uint32_t kRecordType = 'MARR';
    void Save(SKSE::SerializationInterface* a_intfc);
    void Load(SKSE::SerializationInterface* a_intfc, std::uint32_t a_version);
    void Revert();
}
