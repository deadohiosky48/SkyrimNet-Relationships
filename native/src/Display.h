#pragma once

#include <cstdint>
#include <string>
#include <unordered_set>

// ---------------------------------------------------------------------------
// DISPLAY COPIES OF THREE PAPYRUS RULES, ON PROBATION (design 7.3, "Measured in
// play", 2026-09-29).
//
// The first refresh asked Papyrus for these per bond, and every one of those
// calls waited a frame: 55 seconds for 122 bonds. So the DLL now works out, FOR
// DISPLAY ONLY, what SNRom_Bridge.IsFollowing, SNRom_Bridge.CommitmentState
// (with IsMarriedToPlayer) and SNRom_Decorators.RomanceApplicability answer,
// from facts it reads from the engine itself and facts Papyrus fetches once
// per refresh with the batch APIs.
//
// THE GATES STILL CALL PAPYRUS. Nothing decides anything from these; they only
// draw the page. Each function below quotes its original line for line, and
// each original cites this file back. The developer tool "Check the display
// against the rules" runs the real functions for every bond and logs any bond
// where these disagree. They stay only while that check stays clean; in 2.0 the
// aim is one definition, with the gates calling the native (design 6.7).
//
// Free of game types, like Model.h, so the harness can test them.
// ---------------------------------------------------------------------------
namespace SNRom::Display {

    // What the DLL reads from the engine for one actor, on the main thread,
    // when it builds a snapshot (Dashboard.cpp, FactsOf). No Papyrus call.
    struct EngineFacts {
        bool        found = false;            // the form id resolved to an Actor
        std::string name;                     // GetDisplayFullName()
        bool        teammate = false;         // Actor::IsPlayerTeammate()
        bool        followerFaction = false;  // IsInFaction(CurrentFollowerFaction, Skyrim.esm 0x5C84E)
        bool        marriedFaction = false;   // IsInFaction(PlayerMarriedFaction, Skyrim.esm 0xC6472)
        bool        loaded = false;           // Is3DLoaded()
        bool        child = false;            // IsChild()
    };

    // What Papyrus fetches ONCE per refresh, with the batch APIs, and hands
    // over in one native (SNRom_Native.PutRefreshFacts).
    struct BatchFacts {
        bool                             maras = false;  // TT_MARAS.esp installed (SNRom_Bridge.MarasPresent)
        std::unordered_set<std::int32_t> married;        // MARAS.GetNPCsByStatus("married")
        std::unordered_set<std::int32_t> engaged;        // MARAS.GetNPCsByStatus("engaged")
        std::unordered_set<std::int32_t> candidates;     // MARAS.GetNPCsByStatus("candidate")
        bool                             sever = false;  // SeverActions.esp installed (SeverActionsPresent)
        // Native_GetActiveFollowerRoster() plus Native_GetDeadTrackedFollowers():
        // together, every tracked follower with isFollower set, which is what
        // Native_GetIsFollower reads (SeverActionsNativeExt.psc documents the
        // active roster as excluding the dead, and the other as exactly them).
        std::unordered_set<std::int32_t> severFollowers;
        bool                             kinGuard = true;  // SNRom_Decorators.KinGuardOn(), as ArmDashboard read it
    };

    // The per-bond StorageUtil values the copies read, from the numbers push.
    struct StoredFacts {
        std::int32_t orientation = 3;       // SNRom_Orientation (default 3)
        std::int32_t orientationKnown = 0;  // SNRom_OrientationKnown (default 0)
        bool         playerKin = false;     // SNRom_Decorators.IsPlayerKin
    };

    // SNRom_Bridge.IsFollowing.
    bool Following(std::int32_t a_formId, const EngineFacts& a_engine, const BatchFacts& a_batch);

    // SNRom_Bridge.IsMarriedToPlayer.
    bool MarriedToPlayer(std::int32_t a_formId, const EngineFacts& a_engine, const BatchFacts& a_batch);

    // SNRom_Bridge.CommitmentState: 0 none, 1 candidate, 2 engaged, 3 married.
    std::int32_t Commitment(std::int32_t a_formId, const EngineFacts& a_engine, const BatchFacts& a_batch);

    // SNRom_Decorators.RomanceApplicability: 0 applies, 1 kin, 2 minor,
    // 3 orientation. a_playerSex is the player's GetActorBase().GetSex().
    std::int32_t Applicability(std::int32_t a_formId, const EngineFacts& a_engine, const BatchFacts& a_batch,
                               const StoredFacts& a_stored, std::int32_t a_playerSex);
}
