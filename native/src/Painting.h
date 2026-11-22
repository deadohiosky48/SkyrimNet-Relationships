#pragma once

#include <nlohmann/json.hpp>

#include <string>

// THE PAINTING (2.6; the author, 2026-11-04). The couple stand where they
// are, or kiss, the camera poses on them as a painter would see them, the
// frame is caught before anything is drawn over it, and a painting is made of
// it: PNGs in the SKSE log folder's Relationships\Paintings, a record of whose
// it is beside them, and a description by SkyrimNet's vision model. Asked for
// from the card, and at a wedding as the kiss plays (Ceremony.cpp).
namespace SNRom::Painting {

    // A sitting of the player and a_partner, begun once the game runs again
    // (the dashboard closes first). a_wedding: the ceremony's kiss, waited for
    // until their heads meet. "" when it is under way, or why not.
    std::string Sit(RE::FormID a_partner, bool a_wedding = false);

    // The newest painting of the player and a_partner in this playthrough,
    // for the card: { formId, name, src, title, description, describing,
    // wedding }. src is a PNG data URL, "" when there is none.
    nlohmann::json Latest(RE::FormID a_partner);

}  // namespace SNRom::Painting
