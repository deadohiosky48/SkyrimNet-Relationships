#pragma once

#include <cstdint>
#include <string>

// 2.4 (WP-T): SkyrimNet's own C++ API, for the one question no template can
// answer - how long the player and someone have known each other.
//
// A template sees only SkyrimNet's live event feed, a couple of game days deep,
// and memories ranked by relevance to the current scene. Measured 2026-10-14:
// someone recruited 166 game days before was first seen in the feed 0.13 days
// ago, and one person's oldest memory moved from one day to 240 between two
// reads an hour apart. SkyrimNet's database answers both exactly.
//
// Bound by GetProcAddress against SkyrimNet.dll on first use, so nothing here
// runs at load and a missing or older SkyrimNet just answers "".
namespace SNRom::SkyrimNetLink {

    // "KNOWNPROOF <api> <total> <in2d> <in7d> <in30d> <oldestMemory>", where
    // total is every event the player and this person share in SkyrimNet's
    // database, inXd how many of them fall within the last X game days, and
    // oldestMemory the game time (seconds) of this person's oldest memory of
    // any kind, active or not; 0 when they have none. "" when SkyrimNet is
    // missing, older than API 10, or its database is not ready. Thread-safe:
    // every SkyrimNet query it makes is documented thread-safe.
    std::string KnownProof(std::uint32_t a_formId);
}
