#pragma once

#include <cstdint>

namespace SNRom::Natives {

    // What SNRom_Native.Version() returns. Raise it when a native is added or
    // changes meaning, so Papyrus can tell which DLL it is talking to.
    //   1  Version, SetDashboardHotkey(key), SetDeveloperView
    //   2  SetDashboardHotkey(key, modifier)
    //   3  the read model: PutBondNumbers, PutBondText, DropBond, FormIdOf,
    //      PutPlaythrough, PutRefreshFacts, RefreshDone; the actions:
    //      ActionArgs, ActionDone, CheckBond
    //   4  SetDisplaySettings(scale, text size)
    //   5  RecordChange: what moved a bond, kept in the co-save (History.h);
    //      Announce: a tier change, shown when the player can see it (Notices.h)
    //   6  ObserversNear: the enrolled characters who can observe the player
    //   7  AppendLog: the mod's own log files, written natively and in order
    //   8  BioPlan: one person's Relationships bio blocks, decided natively
    //   9  UuidHex: a decimal SkyrimNet UUID as the hex GetActorByUUID wants
    //  10  ApiLoaded, and PutBondNumbers takes 25 numbers: the read API (Api.h)
    inline constexpr std::int32_t kVersion = 10;

    // Registers the natives declared in src/scripts/SNRom_Native.psc.
    void Register(const SKSE::PapyrusInterface* a_papyrus);
}
