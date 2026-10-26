#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace RE {
    class Actor;
}

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
    // bornKnown (born is the birth, not the day an existing child was recorded),
    // otherParent, adopted, stage }]. Empty without Kinship 1.10.
    nlohmann::json PlayerChildren();

    // THE PLAYER'S DESCENDANTS (wpm47), for the roster's family filter and
    // its "Your daughter" lines. Their children from Kinship, by reference
    // (Kinship 1.10.0-dev4's refId); each further generation from the game's
    // parent and child records, down from each descendant's base. Read again
    // by RefreshKin, once per snapshot, before KinOf is asked. Main thread.
    void RefreshKin();

    // { "generation": 1 child, 2 grandchild, ..., "adopted": bool }, or null
    // for someone who is not the player's descendant. Spouses are not here:
    // the page has them from the marriage record. Main thread.
    nlohmann::json KinOf(std::int32_t a_formId);

    // A PERSON'S RELATIVES BY RELATION (wpm52), for guests named as family:
    // "mother", "father", "parents", "brother(s)", "sister(s)", "siblings",
    // "son(s)", "daughter(s)", "children" (also "kids"). From the game's
    // parent and child records (siblings are their parents' other children),
    // and for the player their children from Kinship. The living only;
    // empty for a relation it does not know. Main thread.
    std::vector<RE::Actor*> Relatives(RE::Actor* a_of, const std::string& a_relation);

    // "female", "male", or "" when a_formId is no actor. Main thread.
    std::string SexOf(std::int32_t a_formId);
}
