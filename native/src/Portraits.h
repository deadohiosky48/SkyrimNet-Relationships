#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

// 2.5 (wpm44): SeverActions' companion portraits, on our pages too.
//
// SeverActions 4.5 renders each companion as a transparent PNG cutout and
// keeps it in <Documents>/My Games/<game>/SKSE/SeverActions/Portraits. It has
// no API for them (its native API v1, 2026-10-26; one is asked for), so the
// file is found the way SeverActions names it:
//   - an actor from a plugin: "<plugin>_<local id, 6 hex>.cut.png", the local
//     id 12 bits for a light form (FE), 24 otherwise. The plugin is whichever
//     of the record's files SeverActions picked (vanilla actors appear under an
//     override's name), so each of them is tried, last first;
//   - an actor made at runtime (FF): "runtime_<save id>_<form id>.cut.png";
//   - the player: "player_<save id>.cut.png",
// the save id being SkyrimNet's (PublicGetSaveUniqueID). A portrait the player
// picked (SeverActions 4.6.0, for anyone) is "<key>.jpg" beside the cutout,
// and wins over it. Only ever read: never
// written, moved or deleted. Without SeverActions, or before it has shot
// someone, there is simply no portrait.
namespace SNRom::Portraits {

    // SeverActions' portrait folder exists and holds at least one cutout: the
    // roster then keeps room for a face on each row. Any thread.
    bool Available();

    // The files this actor's portrait could be, most likely first. Main
    // thread: it resolves the actor's plugin files.
    std::vector<std::filesystem::path> Candidates(std::uint32_t a_formId);

    // The portrait as a data: URL ("data:image/png;base64,..."), or "" when
    // there is none. Main thread, as Candidates.
    std::string DataUrlOf(std::uint32_t a_formId);

    // THE ROSTER'S THUMBNAIL (wpm45): the head, a square cut from the top of
    // the first candidate that exists, scaled to a_px by a_px with Windows'
    // own imaging (WIC) and encoded as a PNG data: URL; "" when none. A full
    // cutout is ~150 KB, a thumbnail a few: a roster of a hundred faces is
    // then well under a megabyte, and only the rows in view ask. Kept in
    // memory for the session by file, size and the file's last write, so a
    // portrait SeverActions shoots again is cut again. Any thread but the
    // main one: decoding takes a few milliseconds.
    std::string ThumbnailOf(const std::vector<std::filesystem::path>& a_candidates, std::uint32_t a_px);
}
