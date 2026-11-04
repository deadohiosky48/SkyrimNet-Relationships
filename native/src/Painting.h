#pragma once

#include <nlohmann/json.hpp>

#include <string>

// THE WEDDING PAINTING (2.6, feasibility test; the author, 2026-11-04). The
// couple stand where they are, the camera poses on them as a painter would see
// them, the frame is caught before anything is drawn over it, and a painting
// is made of it: PNGs to look at, and a DDS texture for an object in the world.
// This build proves the parts; the sitting at a wedding, and the painter, come
// once they hold.
namespace SNRom::Painting {

    // A sitting of the player and a_partner, begun once the game runs again
    // (the dashboard closes first). "" when it is under way, or why not.
    std::string Sit(RE::FormID a_partner);

    // The latest painting, put on a_ref's 3D in place of its own picture: the
    // test that a texture written during play is loaded. "" or why not.
    std::string ShowOn(RE::FormID a_ref);

    // The latest painting, for the card: { name, src, painted, shot }. src is
    // a PNG data URL, "" when there is none yet.
    nlohmann::json Latest();

}  // namespace SNRom::Painting
