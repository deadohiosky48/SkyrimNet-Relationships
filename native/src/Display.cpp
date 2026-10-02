#include "Display.h"

// Every function here is a copy, for display only, of a Papyrus function the
// gates keep calling. Each Papyrus line is quoted above the line that mirrors
// it; a change to either side is a change to both. See Display.h.

namespace SNRom::Display {

    bool Following(std::int32_t a_formId, const EngineFacts& a_engine, const BatchFacts& a_batch) {
        // SNRom_Bridge.IsFollowing(Actor akActor)
        //
        //   If akActor.IsPlayerTeammate()
        //       Return True
        //   EndIf
        if (a_engine.teammate) {
            return true;
        }
        //   If SeverActionsPresent() && SeverActionsNativeExt.Native_GetIsFollower(akActor)
        //       Return True
        //   EndIf
        if (a_batch.sever && a_batch.severFollowers.contains(a_formId)) {
            return true;
        }
        //   Faction cff = Game.GetFormFromFile(0x0005C84E, "Skyrim.esm") as Faction
        //   Return cff != None && akActor.IsInFaction(cff)
        return a_engine.followerFaction;
    }

    bool MarriedToPlayer(std::int32_t a_formId, const EngineFacts& a_engine, const BatchFacts& a_batch) {
        // SNRom_Bridge.IsMarriedToPlayer(Actor akActor)
        //
        //   Faction married = Game.GetFormFromFile(0x000C6472, "Skyrim.esm") as Faction   ; PlayerMarriedFaction
        //   If married != None && akActor.IsInFaction(married)
        //       Return True
        //   EndIf
        if (a_engine.marriedFaction) {
            return true;
        }
        //   If MarasPresent() && MARAS.IsNPCStatus(akActor, "married")
        //       Return True
        //   EndIf
        //   Return False
        return a_batch.maras && a_batch.married.contains(a_formId);
    }

    std::int32_t Commitment(std::int32_t a_formId, const EngineFacts& a_engine, const BatchFacts& a_batch) {
        // SNRom_Bridge.CommitmentState(Actor akActor)
        //
        //   If IsMarriedToPlayer(akActor)
        //       Return 3
        //   EndIf
        if (MarriedToPlayer(a_formId, a_engine, a_batch)) {
            return 3;
        }
        //   If MarasPresent()
        //       If MARAS.IsNPCStatus(akActor, "engaged")
        //           Return 2
        //       EndIf
        //       If MARAS.IsNPCStatus(akActor, "candidate")
        //           Return 1
        //       EndIf
        //   EndIf
        if (a_batch.maras) {
            if (a_batch.engaged.contains(a_formId)) {
                return 2;
            }
            if (a_batch.candidates.contains(a_formId)) {
                return 1;
            }
        }
        //   Return 0
        return 0;
    }

    std::int32_t Applicability(std::int32_t a_formId, const EngineFacts& a_engine, const BatchFacts& a_batch,
                               const StoredFacts& a_stored, std::int32_t a_playerSex) {
        // SNRom_Decorators.RomanceApplicability(Actor akActor, Int aiKinGuard)
        //
        //   If aiKinGuard < 0
        //       aiKinGuard = KinGuardOn() as Int
        //   EndIf
        //   If aiKinGuard > 0 && SNRom_Decorators.IsPlayerKin(akActor)
        //       Return 1
        //   EndIf
        if (a_batch.kinGuard && a_stored.playerKin) {
            return 1;
        }
        //   If akActor.IsChild()
        //       Return 2
        //   EndIf
        if (a_engine.child) {
            return 2;
        }
        //   If SNRom_Bridge.IsMarriedToPlayer(akActor)
        //       Return 0
        //   EndIf
        if (MarriedToPlayer(a_formId, a_engine, a_batch)) {
            return 0;
        }
        //   If StorageUtil.GetIntValue(akActor, "SNRom_OrientationKnown", 0) < 2
        //       Return 0
        //   EndIf
        if (a_stored.orientationKnown < 2) {
            return 0;
        }
        //   Int orient = StorageUtil.GetIntValue(akActor, "SNRom_Orientation", 3)
        //   If orient == 0
        //       Return 0
        //   EndIf
        const auto orient = a_stored.orientation;
        if (orient == 0) {
            return 0;
        }
        //   Int playerSex = Game.GetPlayer().GetActorBase().GetSex()
        //   If orient == 1 && playerSex != 0
        //       Return 3
        //   ElseIf orient == 2 && playerSex != 1
        //       Return 3
        //   EndIf
        if (orient == 1 && a_playerSex != 0) {
            return 3;
        }
        if (orient == 2 && a_playerSex != 1) {
            return 3;
        }
        //   Return 0
        return 0;
    }
}
