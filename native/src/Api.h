#pragma once

#include <cstdint>

// WP-A (2.1): the read API for other SKSE plugins. Public header:
// include/SkyrimNetRelationships/SNRelationships_API.h, served by the export
// SNRelationships_RequestApi (Api.cpp).
//
// It reads the dashboard's read model (Model.h), which Papyrus keeps current
// from 2.1 even when nobody opens the dashboard: everyone once after a load,
// then each person as their values are written (SNRom_Bridge.ApiTouch). What
// the model does not hold - commitment, whether romance applies at all, the
// intimacy gate - is worked out here with the same display copies the
// dashboard uses (Display.h), which the developer view's "Check the display"
// compares against Papyrus in play.
//
// THREADS. Everything public is called from the game thread, by the contract
// in the header; Changed/ChangedAll/Loaded are called from a Papyrus VM thread
// and only post an SKSE task, so all state lives on the game thread.
namespace SNRom::Api {

    // A row was pushed or dropped (Dashboard::PushNumbers, DropBond).
    void Changed(std::int32_t a_formId);
    // The MARAS / SeverActions / kin-guard facts were pushed, or a dashboard
    // refresh finished: anyone's derived values may have moved.
    void ChangedAll();
    // Papyrus finished publishing everyone after a load (SNRom_Native.ApiLoaded).
    void Loaded(std::int32_t a_count);
    // kPreLoadGame / kNewGame: nothing is there until Loaded.
    void Reset();
    // The interface table for a version, or null (the export calls this).
    const void* Request(std::uint32_t a_version);
}
