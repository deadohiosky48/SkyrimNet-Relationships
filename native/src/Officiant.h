#pragma once

#include <cstdint>
#include <vector>

namespace RE {
    class Actor;
}

// WHO CAN MARRY THEM (2.5, Build A, M4e; spec 5.3). Any priest or priestess at
// any temple, or any jarl: vanilla's JobPriestFaction and JobJarlFaction.
// Recognised natively, so the eligibility of BlessUnion holds while dialogue
// pauses the game.
namespace SNRom::Officiant {

    // A living adult priest, priestess or jarl.
    bool Is(RE::Actor* a_actor);

    // Everyone engaged to the player who is here: loaded, alive, and within
    // a_range units of the player. Eloping needs both of them present.
    std::vector<RE::Actor*> BetrothedNear(float a_range);

    // How near counts as present for eloping: about a room's width.
    inline constexpr float kPresentRange = 1500.0f;

    // Whether a_actor may bless a marriage now: an officiant, not themselves
    // the betrothed, someone engaged to the player is here, and the household
    // rule allows one more spouse (spec 5.4).
    bool CanBless(RE::Actor* a_actor);
}
