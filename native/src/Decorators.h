#pragma once

#include <cstdint>
#include <string>

// 2.4: get_romance and romance_physical_ok, answered natively.
//
// THEY WERE PAPYRUS, AND PAPYRUS CANNOT RUN WHILE THE GAME IS PAUSED.
// SkyrimNet builds a dialogue prompt with the dialogue menu open; a Papyrus
// decorator it has not cached is a "cache miss ... returning empty", and an
// empty get_romance drops the whole "Your Bond With" section from the bio.
// Measured 2026-10-16 in the prompt logs: 5 of 45, 13 of 55 and 23 of 76
// conversations with enrolled people had no bond section at all; Beirand, given
// a history and seeded Friend, met the player as a stranger.
//
// A native decorator never waits on the VM. The answers are built from the read
// model (Model.h), which Papyrus keeps current on every change (ApiTouch) and
// after every load (ApiPublishAll), with the same display copies the read API
// uses (Display.h). The Papyrus functions stay: the developer view's display
// check compares the two for every bond (CheckDecorators), and Papyrus
// registers them itself only if these could not be.
namespace SNRom::Decorators {

    // kDataLoaded: binds SkyrimNet's PublicRegisterDecorator (API v5+) and
    // registers both. True if both registered.
    bool Register();

    // Whether the native pair is live (Papyrus then does not register its own).
    bool Active();

    // What the model has no per-person home for: the player's acknowledged
    // partners (SNRom_PartnerCount) and the attractionBypassRatio setting.
    void SetFacts(std::int32_t a_partnerCount, float a_bypassRatio);

    // The answers for one person, as the decorators give them.
    std::string Romance(std::int32_t a_formId);
    std::string PhysicalOk(std::int32_t a_formId);

    // Developer check: the native answers against Papyrus's for one person.
    // Logs each field that differs; returns how many.
    std::int32_t Check(std::int32_t a_formId, const std::string& a_papyrusRomance,
                       const std::string& a_papyrusPhysical);
}
