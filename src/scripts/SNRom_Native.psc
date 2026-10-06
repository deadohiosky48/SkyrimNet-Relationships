Scriptname SNRom_Native Hidden
{Natives provided by SkyrimNetRelationships.dll, the dashboard's host.

 THE DLL IS OPTIONAL. Call nothing here unless
 SKSE.GetPluginVersion("SkyrimNetRelationships") > 0 - see
 SNRom_Bridge.DashboardDllPresent. Papyrus cannot test whether a native exists:
 an unbound one logs an error and returns 0 or False, which reads exactly like
 a real answer.}

Int Function Version() Global Native
{Which natives the DLL offers. Raised whenever one is added or changes
 meaning.
   1  the three below, with SetDashboardHotkey taking the key alone
   2  SetDashboardHotkey takes the modifier as well
   3  the dashboard's read model and its actions, below SetDeveloperView
   4  SetDisplaySettings
   5  RecordChange and Announce
   6  ObserversNear
   7  AppendLog
   8  BioPlan
   9  UuidHex
  10  ApiLoaded; PutBondNumbers takes 25 numbers}

Bool Function SetDashboardHotkey(Int aiVirtualKey, Int aiModifierVirtualKey) Global Native
{Binds the dashboard key. aiVirtualKey is a Windows VIRTUAL-KEY code, which is
 what SkyrimNet's hotkey widget stores; the DLL converts it to the scan code
 keyboard input carries. 0 unbinds it.

 aiModifierVirtualKey is 0 for none, or the virtual key of one side of Shift,
 Ctrl or Alt (160 to 165), which must then be held when the key goes down. See
 SNRom_Bridge.DashboardModifierVK.

 False means the key has no keyboard scan code, or the modifier is not one of
 those six, and NOTHING was bound. The DLL refuses rather than guesses, because
 a key that silently fires on a different key is the bug this replaces.

 Version 2 and later: check Version() first.}

Function SetDeveloperView(Bool abOn) Global Native
{The dashboard's developer view (design 7.6): True shows what characters have
 not said, and the developer tools. Sent to the page as settings.developer.}

Bool Function SetDisplaySettings(String asScale, String asTextSize) Global Native
{The dashboard's size: the SkyrimNet selects dashboardScale (Auto, or 75% to
 200%) and dashboardTextSize (Normal, Large or Larger), passed as the option
 names the panel stores. The DLL reads them with the same table as its settings
 watcher (Settings::ScaleFromName and TextSizeFromName), so the names live once,
 there. Sent to the page as settings.scale and settings.textSize.

 False when either is not one of the options: that one stays as it was, and the
 DLL logs which. Version 4 and later.}

; ===========================================================================
; VERSION 3: THE DASHBOARD'S READ MODEL (design 7.3, the WP2 transport)
;
; Papyrus PUSHES what the dashboard shows into a model the DLL holds. The DLL
; never reads it back as truth, and clears it whenever a save loads. Check
; Version() >= 3 before calling any of these; SNRom_Bridge caches that answer
; in ArmDashboard.
;
; ONE CALL PER ACTOR PER PUSH: the values travel as one positional array. The
; field order is defined once in native/src/Model.h and once in
; SNRom_Bridge.DashboardNumbers and DashboardText, each citing the other.
;
; aiGeneration says what a push belongs to: the refresh numbered in the
; SNRom_DashboardRefresh event that asked for it (> 0), nothing (0, a writer
; or an LLM callback keeping an open dashboard current), or a page action (-1,
; answered by ActionDone, which sends the page its snapshot).
; ===========================================================================

Function PutBondNumbers(Int aiGeneration, Actor akActor, Int[] aiNumbers) Global Native
{One actor's numbers, SNRom_Bridge.DashboardNumbers. Pushed for every roster
 member on every refresh, because they change often.}

Function PutBondText(Int aiGeneration, Actor akActor, String[] asText) Global Native
{One actor's text, SNRom_Bridge.DashboardText: WHY, LIMIT, ADDRESS. Pushed on a
 full refresh, and by the functions that write the text after one. The DLL
 reads the name from the engine itself.}

Function DropBond(Actor akActor) Global Native
{They have left the roster. A refresh also drops anyone it did not push.}

Int Function FormIdOf(Actor akActor) Global Native
{akActor.GetFormID(), without waiting for a frame: the same signed value, read
 by the DLL on the calling thread. For the refresh's text push, which builds
 three store keys per actor (SNRom_Bridge.DashboardText). 0 for None.}

Function PutPlaythrough(Int aiGeneration, String asId, String asStore, Int aiDecision) Global Native
{Which store is live, for the playthrough repairs: the playthrough id, the
 store name and SNRom_SaveId (0 undecided, 1 legacy, 2 own). Once per full
 refresh.}

Function PutRefreshFacts(Int aiGeneration, Bool abKinGuard, Bool abMaras, Actor[] akMarried, Actor[] akEngaged, Actor[] akCandidates, Bool abSever, Actor[] akSeverActive, Actor[] akSeverDead) Global Native
{ONCE per refresh, not per bond: what other mods know, fetched with their batch
 calls, for the DLL's display copies of IsFollowing, CommitmentState and
 RomanceApplicability (native/src/Display.cpp). MARAS.GetNPCsByStatus for
 "married", "engaged" and "candidate" when TT_MARAS.esp is installed;
 SeverActions' Native_GetActiveFollowerRoster and Native_GetDeadTrackedFollowers
 when SeverActions.esp is; and KinGuardOn. See SNRom_Bridge.DashboardPutFacts.}

Function RefreshDone(Int aiGeneration, Int aiCount, String asStatus) Global Native
{The refresh numbered aiGeneration is finished: aiCount actors were pushed.
 asStatus is "ok", or "not ready: <why>", which the page shows instead of an
 empty roster. The DLL then sends the page the snapshot and logs how long it
 took.}

; ===========================================================================
; VERSION 3: THE DASHBOARD'S ACTIONS
;
; The page asks; the DLL checks the op against its fixed table and sends the
; SNRom_DashboardAction ModEvent (strArg the op, numArg the request id, sender
; the actor); SNRom_Bridge.OnDashboardAction does it and answers here.
; ===========================================================================

Int[] Function ActionArgs(Int aiRequestId) Global Native
{The Int arguments the page sent with request aiRequestId, in order: a trait
 and a value for SetCharacterField, a field for ForceDriftReview. Empty for
 any other op, or a request the DLL no longer holds.}

Function ActionDone(Int aiRequestId, Bool abOk, String asMessage) Global Native
{Papyrus's answer to request aiRequestId, which the page shows. Push the
 actor's row FIRST: this makes the DLL send the page a fresh snapshot. A
 long-running action answers "started", and the row its LLM callback pushes
 ends it.}

Int Function CheckBond(Actor akActor, Bool abFollowing, Int aiCommitment, Int aiApplicability) Global Native
{The developer check "Check the display against the rules", one bond: what the
 real IsFollowing, CommitmentState and RomanceApplicability answered. The DLL
 works out its display copy of the same three from fresh facts, logs every
 disagreement, and returns how many there were. Waits for the main thread, a
 frame per bond, which this slow tool pays on purpose. Push the bond's numbers
 first. See SNRom_Bridge.CheckDashboardDisplay.}

Function RecordChange(Actor akActor, String asKind, Int aiDelta, Int aiTotal, String asReason) Global Native
{VERSION 5. One change to a bond's depth, for the dashboard's history: kind
 (SNRom_Bridge.ApplyDepth's asKind), the change, the points after it, and the
 reason. The DLL keeps the last few per bond in the co-save, with the game
 time, so they roll back with the save. Called only by
 SNRom_Bridge.RecordHistory.}

Function Announce(String asText) Global Native
{VERSION 5. A tier change's notice, worded by SNRom_Bridge.AnnounceTier. The
 DLL holds it until the player is out of combat, out of an OStim or SexLab
 scene and not paused, then sends the ModEvent SNRom_ShowNotice with the
 text, which SNRom_Bridge.OnShowNotice shows.}

Actor[] Function ObserversNear(Float afRange) Global Native
{VERSION 6. Every enrolled character - in SNRom_Bond - whom the game keeps
 loaded near the player, alive and within afRange units: who can observe the
 player now. One call, and one frame, for what a roster walk asked a frame
 at a time. Called only by SNRom_Bridge.Observers.}

Bool Function AppendLog(String asFile, String asText) Global Native

; VERSION 8 (2.1, WP-B). One person's Relationships bio blocks: given their
; block titles (SeverActions) and stored values (SNRom_Bridge.BioState), the
; plan SNRom_Bridge.BioRun carries out. Layout in native/src/BioPlan.h.
Int[] Function BioPlan(Actor akActor, String[] asTitles, Int[] aiState) Global Native

; VERSION 9 (2.1, WP-B2). SkyrimNet's event record prints UUIDs in decimal;
; SkyrimNetApi.GetActorByUUID wants uppercase hex. "" for anything else.
String Function UuidHex(String asDecimal) Global Native

; VERSION 10 (2.1, WP-A). Everyone has been pushed after a load: the read API
; (native/include/SkyrimNetRelationships/SNRelationships_API.h) is ready, and
; tells its listeners once. aiCount is how many were pushed, for the log.
Function ApiLoaded(Int aiCount) Global Native

; VERSION 10. DEV TOOL: the DLL uses its own read API as another plugin would,
; logs what it reads to SkyrimNetRelationships.log, and logs every change after.
Function ApiSelfTest() Global Native
{VERSION 7. Appends asText to asFile - a bare name: snrom.log, ledger.jsonl
 or dispositions.jsonl - in the mod's logs folder, at once and in order.
 snrom.log lines get the wall clock in front. False when it could not be
 written. Called only by SNRom_Bridge.WriteLog.}
