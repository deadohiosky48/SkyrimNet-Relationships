#pragma once

// LOVER'S COMFORT FOR EVERY SPOUSE (2.6; the author, 2026-11-04).
//
// Vanilla grants it from PlayerSleepQuestScript.OnSleepStop, and only for the
// one spouse in RelationshipMarriageFIN's LoveInterest alias, which a
// Relationships wedding never fills. So after vanilla's own handler has run,
// if it gave the player ordinary Rested or Well Rested and one of their
// Relationships spouses is in the player's location (vanilla's own test), the
// DLL swaps it for vanilla's Lover's Comfort and shows vanilla's message.
//
// Vanilla still decides who may rest at all: beast blood removes every rested
// state and the Lover Stone keeps its own, and neither gets Rested or Well
// Rested, so neither is touched here. Nor is a vanilla spouse's Lover's Comfort,
// which is already in place. Rested and Well Rested are cleared as the player
// lies down (vanilla clears them on waking anyway), so one seen after waking is
// vanilla's, just given. The spells and the message are read from the sleep
// quest's own script properties, so a mod that changes them is followed.
namespace SNRom::LoversComfort {

    // kDataLoaded: the sleep-stop sink.
    void Register();
}
