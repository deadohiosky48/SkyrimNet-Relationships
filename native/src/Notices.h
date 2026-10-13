#pragma once

#include <string>

// THE ANNOUNCEMENT OF A TIER CHANGE, HELD UNTIL THE PLAYER CAN SEE IT. The
// author's rule (2026-10-01, design question 4): a bond's tier change, up or
// down, is announced on screen, but never in combat, in an OStim or SexLab
// scene, or while the game is paused. The character's own awareness of it is
// a private thought Papyrus asks SkyrimNet for; nobody nearby hears anything.
//
// Papyrus words the notice (SNRom_Bridge.AnnounceTier) and posts it here. The
// DLL holds it, looks about once a second while anything waits - on the main
// thread, where the player's state can be read - and hands each one back with
// the ModEvent SNRom_ShowNotice, whose handler shows it with
// Debug.Notification. Nothing runs while nothing waits.
namespace SNRom::Notices {

    // kDataLoaded: resolve the scene factions and start the waiting thread.
    void Start();

    // kPreLoadGame and kNewGame: a notice belongs to the timeline it was
    // posted in, and is dropped with it.
    void Clear();

    // From the Announce native, on a VM thread.
    void Post(std::string a_text);

    // 2.4 (WP-N): worded when shown, through L10n, so a held notice follows a
    // language change. a_english is the text when the language has none;
    // {0} is a_arg0; {1} is a_arg1, or, when a_arg1Key is set, that key's
    // text (a tier's name) with a_arg1 as its English.
    void PostKeyed(std::string a_key, std::string a_english, std::string a_arg0, std::string a_arg1Key,
                   std::string a_arg1);

    // The player is in an OStim or SexLab scene (their scene factions).
    // Main thread. Also asked by the crosshair hotkeys (Hotkey.cpp).
    bool PlayerInScene();
}
