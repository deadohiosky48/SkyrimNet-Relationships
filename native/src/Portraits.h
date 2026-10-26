#pragma once

#include <cstdint>
#include <string>

// 2.5 (wpm44): SeverActions' companion portraits, on our detail page too.
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
// the save id being SkyrimNet's (PublicGetSaveUniqueID). Only ever read: never
// written, moved or deleted. Without SeverActions, or before it has shot
// someone, there is simply no portrait.
namespace SNRom::Portraits {

    // The portrait as a data: URL ("data:image/png;base64,..."), or "" when
    // there is none. Main thread: it resolves the actor's plugin files.
    std::string DataUrlOf(std::uint32_t a_formId);
}
