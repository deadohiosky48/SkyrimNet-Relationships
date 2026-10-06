// SNRelationships_API.h - read SkyrimNet Relationships from another SKSE plugin.
//
// Copy this one header into your project. It needs nothing else from us: the
// interface is a versioned struct of C function pointers, served by the export
// SNRelationships_RequestApi(version) in SkyrimNetRelationships.dll and found
// at runtime with GetModuleHandle/GetProcAddress. Without our DLL every
// request returns null; treat that as "Relationships not installed".
//
// READ ONLY. Nothing here changes a bond; the values are what the mod itself
// decides and shows on its dashboard.
//
// VERSIONING. A version is never changed in place: new members are appended
// in a new struct with a higher number, and Values only ever grows at the end
// (set Values::size before each call, and fields past what you passed are not
// written). An unknown version returns null.
//
// THREADS. Call everything from the game thread (an SKSE task, a game event
// sink, a Papyrus native that waits for the main thread). Listeners are called
// there too.
//
// TIMING. A change reaches listeners about half a second after the mod writes
// it, batched per person. While the game is paused (a menu, the console) the
// batch waits and goes out when play resumes; several changes to one person in
// that time arrive as one, and a value changed and changed back arrives as
// nothing.
//
// WHEN VALUES ARE THERE. After a game loads, the mod publishes everyone once,
// a few seconds after the load, and calls every listener with formId 0 and
// kReloaded. Before that, IsReady() is false and GetValues finds nobody. A
// load or a new game calls listeners with formId 0 and kUnloaded first.
//
// KNOWN LIMIT. Marriages, engagements and candidacies made by another mod
// (M.A.R.A.S.) are noticed at the mod's next check, up to about two game hours
// later, unless they happen through the mod's own marriage events.
//
// THIS FILE ONLY may be copied into your own project, changed, and distributed
// with your plugin, free of charge. The rest of SkyrimNet Relationships stays
// under its own licence (LICENSE in the repository).

#pragma once

#include <cstdint>

#ifndef SNREL_API_NO_LOADER
    #include <windows.h>
#endif

namespace SNREL_API {

    inline constexpr std::uint32_t kApiVersion1 = 1;

    // One enrolled person, as the mod sees them now.
    struct Values {
        std::uint32_t size;             // = sizeof(Values), set by the caller
        std::uint32_t formId;           // the reference's FormID
        std::int32_t  tier;             // 0 Stranger, 1 Acquaintance, 2 Friend, 3 Confidant, 4 Lover, 5 Spouse
                                        // (also the rank in faction SNRom_Bond, SNRom_Integration.esl 0xD63)
        std::int32_t  points;           // the bond's points; a tier is 500
        std::int32_t  sparked;          // 1 on the romantic track, 0 platonic
        std::int32_t  stance;           // the player's answer when asked: -1 no, 0 not yet, 1 yes
        std::int32_t  romanceEnded;     // 1 when a romance between them has ended
        std::int32_t  endedAtMinutes;   // when it ended, in game minutes (game days x 1440); -1 never
        std::int32_t  commitment;       // 0 none, 1 marriage candidate, 2 engaged, 3 married to the player
        std::int32_t  orientation;      // who they are drawn to: 0 no one, 1 men, 2 women, 3 both
        std::int32_t  orientationBasis; // 0 not known, 1 implied, 2 stated
        std::int32_t  intimacyRank;     // their disposition: 0 casual, 1 romantic, 2 guarded, 3 never
        std::int32_t  intimacyGate;     // 1 when intimacy with the player is open now
        std::int32_t  followingSinceMinutes;  // first seen following, in game minutes; -1 never
    };

    // What changed, as bits, for a listener.
    enum Changed : std::uint32_t {
        kTier            = 1u << 0,
        kPoints          = 1u << 1,
        kSparked         = 1u << 2,
        kStance          = 1u << 3,
        kRomanceEnded    = 1u << 4,   // romanceEnded or endedAtMinutes
        kCommitment      = 1u << 5,
        kOrientation     = 1u << 6,   // orientation or orientationBasis
        kIntimacyRank    = 1u << 7,
        kIntimacyGate    = 1u << 8,
        kFollowingSince  = 1u << 9,
        kEnrolled        = 1u << 16,  // newly enrolled (every value bit is set as well)
        kUnenrolled      = 1u << 17,  // no longer enrolled; GetValues now finds nobody
        kReloaded        = 1u << 24,  // formId 0: everyone's values are there after a load
        kUnloaded        = 1u << 25,  // formId 0: a load or new game began; nothing is there
    };

    // Called on the game thread. Keep it short; do not call back into
    // RemoveListener from inside it.
    using ChangeFn = void (*)(std::uint32_t formId, std::uint32_t changed, void* user);

    struct Api1 {
        std::uint32_t apiVersion;  // = kApiVersion1

        // True once the values for this game are published (see above).
        bool (*IsReady)();

        // One person. False when they are not enrolled, or before IsReady.
        bool (*GetValues)(std::uint32_t formId, Values* out);

        // Everyone enrolled, as FormIDs. Writes up to `capacity` and returns
        // how many there are in all, so a first call with capacity 0 sizes it.
        std::uint32_t (*ListEnrolled)(std::uint32_t* out, std::uint32_t capacity);

        // A change callback, until removed. Returns a handle; 0 on failure.
        std::uint32_t (*AddListener)(ChangeFn fn, void* user);
        void (*RemoveListener)(std::uint32_t handle);
    };

#ifndef SNREL_API_NO_LOADER
    // Null when SkyrimNet Relationships is not installed, or older than 2.1.
    inline const Api1* RequestApi1() {
        const HMODULE mod = GetModuleHandleW(L"SkyrimNetRelationships.dll");
        if (!mod) return nullptr;
        using RequestFn = const void* (*)(std::uint32_t);
        const auto request = reinterpret_cast<RequestFn>(GetProcAddress(mod, "SNRelationships_RequestApi"));
        if (!request) return nullptr;
        return static_cast<const Api1*>(request(kApiVersion1));
    }
#endif
}
