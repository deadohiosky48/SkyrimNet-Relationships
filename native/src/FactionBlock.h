#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace RE {
    class Actor;
}

// FACTIONS NEVER ENROLLED (2.6; a player's request, the author 2026-11-10).
// Someone in a blocked faction is never enrolled automatically: not for
// following the player, not by the spark action, not for talking with them.
// Enrolling by hand still works, as it does for someone the player took off
// the roster. Nobody already enrolled is touched.
//
// ONE LIST FOR EVERY PLAYTHROUGH, as a preference is: kept in
// Data/SKSE/Plugins/SkyrimNet Relationships/blocked_factions.json, which no
// release ships, so an update leaves it. Each faction by its plugin's file
// name and its FormID within that plugin, which survive a changed load order.
namespace SNRom::FactionBlock {

    // The name of the first blocked faction a_actor belongs to (rank 0 or
    // above), or "" when none. Any thread.
    std::string BlockedFactionOf(RE::Actor* a_actor);

    // For the page (the dashboard's "factions" message):
    //   { "formId": a_formId,
    //     "factions": [{ "key", "name", "blocked" }],   a_formId's own; [] for 0
    //     "blocked":  [{ "key", "name", "found", "enrolled" }] }  the whole list
    // key is "<plugin>|<local FormID, 6 hex>". name is the faction's own name,
    // else its editor ID where the game kept one, else "a faction from
    // <plugin> (<id>)". found is false for one whose plugin is not loaded now.
    // enrolled: those of a_roster (the page's bonds) who belong to it, who
    // stay enrolled until the player removes them.
    // Our own plugin's factions are never offered. Main thread.
    nlohmann::json Describe(std::int32_t a_formId, const std::vector<std::int32_t>& a_roster);

    // Block (a_block) or allow again one faction by key. "" when done, else
    // why not, for the page. Main thread.
    std::string Set(const std::string& a_key, bool a_block);
}
