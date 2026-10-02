#pragma once

#include <cstdint>
#include <string>

#include <nlohmann/json.hpp>

// What moved each bond, and why: the last few changes to a bond's depth, kept
// in the save itself (the SKSE co-save), so loading an older save rolls the
// history back along with the points it explains.
//
// WHY HERE AND NOT IN PAPYRUS. StorageUtil strings did not survive a reload in
// 1.x (the WHY bug), the ledger file never rolls back, and neither is per
// actor. The co-save is all three, and Papyrus feeds it with one native call
// from SNRom_Bridge.ApplyDepth, the one place a bond's depth changes - which
// needs no frame, because it touches nothing of the game's.
//
// THE DASHBOARD READS IT DIRECTLY when it builds a snapshot (Model.cpp), so no
// refresh has to carry it: the roster shows each bond's newest change and the
// detail view the rest.
namespace SNRom::History {

    // How many changes are kept per bond. The detail view shows them all; the
    // roster, the newest.
    inline constexpr std::size_t kKeep = 12;

    // From the RecordChange native (SNRom_Native.psc), on a VM thread. a_kind
    // is SNRom_Bridge's word for what happened ("moment", "talk", "seed",
    // "withheld"...), a_delta the change and a_total the points after it. The
    // game time is read here.
    void Record(std::int32_t a_formId, std::string a_kind, std::int32_t a_delta, std::int32_t a_total,
                std::string a_reason);

    // The bond's changes as the snapshot carries them, newest first. Empty for
    // a bond with none.
    nlohmann::json Recent(std::int32_t a_formId);

    // SKSEPluginLoad: claim a co-save record and the save, load and revert
    // callbacks. False if SKSE has no serialization interface for us.
    bool Register();
}
