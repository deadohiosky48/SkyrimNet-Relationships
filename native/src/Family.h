#pragma once

#include <cstdint>
#include <string>

#include <nlohmann/json.hpp>

// A PERSON'S FAMILY, for their detail (2.5, Build B, M8b; the author,
// 2026-10-17). Two sources, never parsed from anyone's private files:
//
// - The game's own relationship records: parent and child, as the plugins
//   declare them (BGSRelationship with a family association whose parent and
//   child titles differ, which is ParentChild and not Siblings). Laila
//   Law-Giver's sons, for example. Read once at kDataLoaded.
// - Their children with the player, from SkyrimNet Kinship's read API
//   (SNKinship_RequestApi, Kinship 1.10). Absent Kinship, or before that
//   version, that half is empty.
namespace SNRom::Family {

    // kDataLoaded: the game's parent and child records, indexed.
    void Index();

    // The snapshot's family object for a_formId (a reference):
    //   { "parents":  [{ "name": "..." }],
    //     "children": [{ "name": "...", "child": "son"|"daughter"|"",
    //                    "withPlayer": bool, "otherParent": "...",
    //                    "stage": -1..5, "adopted": bool, "inWorld": bool }] }
    // stage: Kinship's 0 newborn to 5 adult; for the game's records 3 for a
    // child, 5 for anyone grown, which is all a record says. Main thread.
    nlohmann::json Of(std::int32_t a_formId);

    // Every child of the player's that Kinship records (API v2), for the
    // calendar's birthdays: [{ name, child, born (game days; 0 unknown),
    // otherParent, adopted, stage }]. Empty without Kinship 1.10.
    nlohmann::json PlayerChildren();

    // "female", "male", or "" when a_formId is no actor. Main thread.
    std::string SexOf(std::int32_t a_formId);
}
