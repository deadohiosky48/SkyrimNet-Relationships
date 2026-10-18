#pragma once

#include <string>

// THE MARRIAGE RINGS IN PLAY (2.5). Two things the plugin's records cannot do
// on their own:
//
// - SNRom_SpouseHere, the global the wedding ring's "together" effect asks when
//   the player wears it (an NPC wearer is asked about the player's distance
//   directly). 1 while a spouse shares the player's location or stands within
//   2048 units. Kept on every change of the player's location (and again a few
//   seconds later, when followers have arrived), every change of a marriage,
//   and after a load. Never polled.
//
// - A ring that comes off. A betrothed or spouse wearing the ring the player
//   gave them puts it back on once, two seconds later. Outfit systems strip
//   what their outfit does not list (SeverActions applied a preset to Hroki
//   seventeen seconds after she took her ring, 2026-10-18); if the ring comes
//   off again within fifteen seconds of going back on, something is enforcing
//   an outfit, and the ring is left in their inventory and the conflict logged
//   rather than fought.
namespace SNRom::Rings {

    // kDataLoaded: the equip and location event sinks.
    void Register();

    // Recompute SNRom_SpouseHere now (main thread).
    void UpdateSpouseHere();

    // The same, from any thread: queued as a task.
    void UpdateSpouseHereSoon();

    // PUT A RING ON ONCE THE GAME RUNS, AND NAME IT. A ring is given in the gift
    // menu, during a conversation, with the game paused, and an NPC's
    // equipment does not change while it is: Hroki took hers and never wore it
    // (2026-10-18). This waits until nothing pauses the game, equips it, and
    // names the copy worn ("Hroki's Gold Engagement Ring"), which keeps the
    // name in the save. Any thread.
    void WearWhenResumed(RE::FormID a_actor, RE::FormID a_ring, std::string a_name);
}
