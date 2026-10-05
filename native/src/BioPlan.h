#pragma once

#include <cstdint>
#include <string>
#include <vector>

// WP-B (2.1): the Relationships bio blocks, decided natively.
//
// Papyrus can reach SeverActions' block data only through SeverActions' own
// Papyrus natives, and the mod's stored traits only through PapyrusUtil, which
// has no C++ interface either. So Papyrus gathers one person's block titles
// and stored values, and this decides everything else in one call: which
// categories are ours alone, which the player holds, what the player's own
// blocks say about the traits, what to apply, swap, lift or take off. Papyrus
// then carries the plan out. That replaced about 250 Papyrus string calls per
// person on every load (25-35 s of background Papyrus for 130 people) with a
// dozen calls.
//
// Pure: reads nothing from the game except whether the actor is a child, and
// keeps no state, so it is safe to call from a Papyrus tasklet.
namespace SNRom::BioPlan {

    // aiState, as SNRom_Bridge.BioState builds it.
    enum State : std::size_t {
        kOrientation = 0,  // 0 none, 1 men, 2 women, 3 both
        kOrientationKnown,  // 0 unknown, 1 implied, 2 stated
        kArdor,             // 0..4
        kExclusivity,       // 0..100
        kRecord0,           // SNRom_BioOurs_0..3, as stored (see BioRecGet)
        kRecord1,
        kRecord2,
        kRecord3,
        kMarriedToPlayer,  // 1 when the game records a marriage to the player
        kFlags,            // Flag bits below
        kLimitPicks,       // -1 = leave Limits alone, else the authoring picks as bits
        kStateCount
    };

    enum Flag : std::int32_t {
        kApiReady = 1 << 0,  // SeverActions' Bio Blocks API v1+ is there
        kAssignOn = 1 << 1,  // "Assign Relationships Bio Blocks"
        kEnrolled = 1 << 2,
        kEnforce = 1 << 3,  // the player's blocks set the traits
        kSync = 1 << 4,     // our blocks follow the character
        kLift = 1 << 5,     // take ours off before a re-author
    };

    // The plan. Fields are -1 when unchanged; records are kUnchanged.
    enum Out : std::size_t {
        kNewOrientation = 0,
        kNewOrientationKnown,
        kNewArdor,
        kNewExclusivity,
        kHasBits,          // categories holding any block, after the actions
        kPlayerHoldsBits,  // categories holding a block that is not ours alone, before them
        kNewRecord0,
        kNewRecord1,
        kNewRecord2,
        kNewRecord3,
        kNoteBits,           // NoteBit below
        kLiftedLimits,       // Limits bits lifted by kLift
        kActionCount,        // then that many (op, category, index) triples
        kHeaderCount
    };

    enum NoteBit : std::int32_t {
        kNoteTakenOff = 0,    // bits 0-3: the player took ours off in that category
        kNoteUnreadable = 4,  // bits 4-7: two different answers, or one we do not know
        kNoteMarriage = 8,    // bit 8: a Drawn To block contradicts a recorded marriage
        kNoteWithdrawn = 9,   // bit 9: ours came off a child
    };

    enum Op : std::int32_t { kApply = 1, kUnapply = 2 };

    inline constexpr std::int32_t kUnchanged = -999;

    std::vector<std::int32_t> Plan(const RE::Actor* a_actor, const std::vector<std::string>& a_titles,
                                   const std::vector<std::int32_t>& a_state);
}
