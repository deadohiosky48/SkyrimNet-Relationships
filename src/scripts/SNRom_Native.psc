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
  10  ApiLoaded; PutBondNumbers takes 25 numbers
  11  Text (2.3)
  12  ActionText, AnnounceKey; PutBondText takes 4 strings (2.4)
  13  KnownProof (2.4)
  14  DecoratorsNative, SetDecoratorFacts, CheckDecorators; PutBondNumbers takes 27 (2.4)
  15  MarriageState, SetMarriageState, MarriageWithState, MaraException, SetMaraException (2.5)
  16  CanAcceptProposal, CanDeclineProposal, NoteProposalDeclined, SetMarriageFacts, MarriageRing,
      SetMarriageRing, RingsCarried, IsOfficiant, CanBless, BetrothedNear (2.5, Build A)}

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

Int Function MarriageState(Actor akActor) Global Native
{VERSION 15 (2.5). akActor's marriage to the player in Relationships' own record:
 0 none, 1 engaged, 2 married, 3 broken off, 4 divorced, 5 widowed, 6
 separated (SNRom_Bridge.MARRIAGE_*).}

Bool Function SetMarriageState(Actor akActor, Int aiState, String asWhy, Bool abForce, Actor akOfficiant, Bool abEloped) Global Native
{VERSION 15 (2.5). The record's one writer: refuses a step that is not a legal
 one unless abForce, stamps the game day, and fires SNRom_MarriageChanged.
 akOfficiant and abEloped are kept for a marriage. False if refused or
 unchanged. Call SNRom_Bridge.ChangeMarriage, which keeps the game in step.}

Actor[] Function MarriageWithState(Int aiState) Global Native
{VERSION 15 (2.5). Everyone in the record in aiState.}

Bool Function MaraException() Global Native
{VERSION 15 (2.5). Whether Mara has granted the player her exception: another
 marriage while already married.}

Function SetMaraException(Bool abGranted) Global Native
{VERSION 15 (2.5). Grants or withdraws it. Kept in the save.}

Bool Function CanAcceptProposal(Actor akActor) Global Native
{VERSION 16 (2.5). Whether akActor could say yes to a proposal now: Spouse and
 above, enrolled, romance applicable, not engaged or married to the player, not
 inside the wait after a no, and one more spouse allowed. The decorator
 marriage_can_accept gives the same answer.}

Bool Function CanDeclineProposal(Actor akActor) Global Native
{VERSION 16 (2.5). Enrolled, and not engaged or married to the player.}

Function NoteProposalDeclined(Actor akActor) Global Native
{VERSION 16 (2.5). Starts the wait after a no (SetMarriageFacts' cooldown).}

Function SetMarriageFacts(Int aiSpouses, Float afCooldownDays) Global Native
{VERSION 16 (2.5). What the DLL cannot count itself: the player's spouses
 across every record (SNRom_Bridge.SpouseCount), and the wait after a no in
 game days.}

Form Function MarriageRing(Actor akActor, Bool abFromPlayer) Global Native
{VERSION 16 (2.5). The engagement ring the player gave akActor (abFromPlayer)
 or akActor gave the player; None if none.}

Bool Function SetMarriageRing(Actor akActor, Bool abFromPlayer, Form akItem) Global Native
{VERSION 16 (2.5). Records a ring. Refused unless akActor is engaged or married
 to the player.}

Form[] Function RingsCarried(Actor akActor) Global Native
{VERSION 16 (2.5). Every ring akActor carries that could change hands, worn
 ones included; never a quest item.}

Form Function RingNamed(Actor akOwner, String asName) Global Native
{VERSION 16 (2.5). The ring akOwner carries whose name contains asName or is
 contained in it, ignoring case; None if none.}

FormList Function RingGiftFilter() Global Native
{VERSION 16 (2.5). A list holding the ring keyword, for ShowGiftMenu: the gift
 menu then shows rings only, however many.}

Function SnapshotRings(Actor akOwner) Global Native
{VERSION 16 (2.5). Notes akOwner's rings and counts, before the gift menu.}

Form Function RingGivenSince(Actor akOwner) Global Native
{VERSION 16 (2.5). A ring that left akOwner's inventory since SnapshotRings;
 None if none did.}

Int Function SeverOutfitLockSetting() Global Native
{VERSION 16 (2.5). SeverActions' Outfit Lock setting, read from its script: 1
 on, 0 off, -1 unread.}

Bool Function IsOfficiant(Actor akActor) Global Native
{VERSION 16 (2.5). A living adult priest, priestess or jarl.}

Bool Function CanBless(Actor akActor) Global Native
{VERSION 16 (2.5). An officiant who could marry the player now: someone engaged
 to the player is here, and one more spouse is allowed.}

Actor[] Function BetrothedNear() Global Native
{VERSION 16 (2.5). Everyone engaged to the player who is here with them.}

Bool Function DecoratorsNative() Global Native
{VERSION 14 (2.4). True when the DLL answers get_romance and
 romance_physical_ok itself (registered with SkyrimNet at kDataLoaded): they
 then work while the game is paused, and SNRom_Bridge.RegisterDecorators does
 not register the Papyrus pair.}

Function SetDecoratorFacts(Int aiPartnerCount, Float afBypassRatio) Global Native
{VERSION 14 (2.4). The two facts the native decorators cannot read from the
 model: SNRom_PartnerCount and the attractionBypassRatio setting.}

Int Function CheckDecorators(Actor akActor, String asPapyrusRomance, String asPapyrusPhysical) Global Native
{VERSION 14 (2.4). Developer check: the native get_romance and
 romance_physical_ok for akActor against the Papyrus answers given, field by
 field. Logs each difference to SkyrimNetRelationships.log; returns how many.}

String Function KnownProof(Actor akActor) Global Native
{VERSION 13 (2.4). How long the player and akActor have known each other, from
 SkyrimNet's database rather than its live feed: "KNOWNPROOF api total in2d
 in7d in30d oldestMemory" - every event they share, how many fall within the
 last 2, 7 and 30 game days, and the game time in seconds of akActor's oldest
 memory (0 for none). Empty when SkyrimNet is missing, older than API 10, or
 its database is not ready. SNRom_Bridge.TimeKnown reads it.}

String Function ActionText(Int aiRequestId) Global Native
{VERSION 12 (2.4). The one String the page sent with request aiRequestId, for
 an op that takes one: the player's account for SetPlayerHistory. Empty for
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

; v11 (2.3, WP-L): the player's words in the player's language. asEnglish is
; the text when this language has none; {0} and {1} are filled from a0 and a1
; either way. Reached through SNRom_Bridge.Tr, which checks Version() first.
String Function Text(String asKey, String asEnglish, String a0, String a1) Global Native
{VERSION 5. A tier change's notice, worded by SNRom_Bridge.AnnounceTier. The
 DLL holds it until the player is out of combat, out of an OStim or SexLab
 scene and not paused, then sends the ModEvent SNRom_ShowNotice with the
 text, which SNRom_Bridge.OnShowNotice shows.}

Function AnnounceKey(String asKey, String asEnglish, String a0, String a1Key, String a1) Global Native
{VERSION 12 (2.4, WP-N). Announce, worded when SHOWN rather than when posted,
 so a notice held while the game is paused follows a change of language.
 asEnglish is the text when the language has none. The first placeholder is
 a0; the second is a1, or, when a1Key is set, that key's text (a tier's name)
 with a1 as its English.}

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

Int Function AskOpen(String asTitle, String asBody, String[] asButtons) Global Native
{VERSION 17 (2.5). A question for the player in our own UI: over the dashboard
 if it is open, otherwise the view opens with the question alone. Returns its
 id, or 0 when there is no dashboard view (no UI framework). Read the answer
 with AskAnswer.}

Int Function AskAnswer(Int aiId) Global Native
{VERSION 17 (2.5). -2 while unanswered; then, once (the answer is forgotten
 when read), the index of the button chosen, -1 dismissed (closed without a
 choice), or -3 never shown (another menu kept the screen for a minute).}

; VERSION 19 (2.5): THE WEDDING, SPOKEN AND DIRECTED (native/src/Ceremony.h).
; The DLL runs the ceremony as a script that moves on when it hears the right
; person speak; Papyrus begins it, cues speakers, and records the marriage.
Bool Function CeremonyBegin(Actor akOfficiant, Actor akBetrothed, String asVariant) Global Native
{Begins one. False when one is under way or SkyrimNet has no dialogue events. asVariant judges the answers.}

Int Function CeremonyStage() Global Native
{The step now, 1-8; 0 when none.}

Actor Function CeremonyOfficiant() Global Native
Actor Function CeremonyBetrothed() Global Native
Actor Function CeremonyLastOfficiant() Global Native
{The officiant of the last ceremony, for SNRom_CeremonyMarried.}

Actor Function CeremonyCueTarget(Int aiToken) Global Native
Bool Function CeremonyCueWanted(Int aiToken) Global Native
Float Function CeremonyCueDelay(Int aiToken) Global Native
Function CeremonyCueSent(Int aiToken) Global Native

Function CeremonyStop(String asWhy) Global Native
{Over, short of a marriage: SNRom_CeremonyEnded (strArg asWhy, sender the betrothed).}

; VERSION 22 (2.5): THE RING CATALOGUE (native/src/RingCatalog.h): four shapes
; (0 engagement ring, 1 wedding ring, 2 wedding band, 3 wide band) in three
; metals (0 gold, 1 silver, 2 ebony).
Form Function RingWeddingFor(Form akEngagement) Global Native
{The wedding ring an engagement ring of ours becomes, in its metal; None for any other ring.}

Form Function RingBand(Int aiMetal, Bool abWide) Global Native
{The wedding band in that metal: the wide band, or the braided one.}

Int Function RingKindOf(Form akRing) Global Native
{0-3 as above; -1 for a ring not ours.}

Int Function RingMetalOf(Form akRing) Global Native
{0 gold, 1 silver, 2 ebony; -1 for a ring not ours.}

Form[] Function RingAllOurs() Global Native
{Every ring of ours.}

Function ClearProposalDeclined(Actor akActor) Global Native
{VERSION 24 (2.5). Lifts akActor's last no to a proposal: their bond's tier has
 risen since, and the answer may be asked for again.}

Float Function ProposalDaysSinceDeclined(Actor akActor) Global Native
{VERSION 24 (2.5). Game days since akActor last said no to a proposal; -1 for never.}

Function NoteProposalDeclinedAt(Actor akActor, Int aiTier) Global Native
{VERSION 25 (2.5). A no to a proposal, at the bond's tier then: the wait after
 it lifts once the tier rises above that. A no repeated during the wait keeps
 the first one's day.}

Bool Function RemoveChange(Actor akActor, Int aiIndex, Int aiDelta, Int aiTotal) Global Native
{VERSION 27 (2.5). Takes one change out of akActor's history: the one at aiIndex
 (0 = newest), if its delta and total are still aiDelta and aiTotal and it moved
 points. The newer changes' totals lose its delta. False otherwise. The points
 are the caller's to move (SNRom_Bridge.UndoChange).}

Bool Function MarasPromote(Actor akActor, String asStatus) Global Native
{VERSION 28 (2.5, Build B). MARAS.PromoteNPCToStatus(akActor, asStatus), called
 with as many arguments as the installed MARAS declares (2.0 added sendEvent).
 True when sent; MARAS's own answer is logged in SkyrimNetRelationships.log.}

Int Function AskOpenEx(String asTitle, String asBody, String[] asButtons, Int aiDefault, Float afSeconds) Global Native
{VERSION 28 (2.5, Build B, M8c). AskOpen with a default and a timer: asked on its
 own, the question waits for a calm moment (out of combat, no menu, no wedding
 under way) and floats low on the screen over a game that keeps playing; when
 afSeconds run out the page chooses aiDefault (-1: none, so it is dismissed).
 0 seconds: no timer.}

Int Function AskPeek(Int aiId) Global Native
{VERSION 28. AskAnswer without forgetting the answer: -2 pending, -1 dismissed,
 -3 unshown, or the button's index.}

Function AskCancel(Int aiId) Global Native
{VERSION 28. Withdraws a question, waiting or on screen.}

; ---------------------------------------------------------------------------
; VERSION 28 (2.5, Build B, M4p and M4w): THE WEDDING PLAN (WeddingPlan.h).
; ---------------------------------------------------------------------------

Bool Function CeremonyBeginPlanned(Actor akOfficiant, Actor akBetrothed, String asVariant, Int aiParts) Global Native
{A planned wedding: CeremonyBegin with the plan's parts (1 the address, 2 a
 reading, 4 the rings, 8 the kiss) added to the minimum.}

Bool Function CeremonyPlanned() Global Native
{The wedding under way is a planned one, not an elopement.}

Bool Function IsWeddingPlanner(Actor akActor) Global Native
{One of the wedding planners (FACT SNRom_WeddingPlanner).}

Actor Function PersonNamed(String asName) Global Native
{Someone by name: anyone loaded, then anyone on the roster. None when no one.}

Actor Function BetrothedNamed(String asName) Global Native
{The one engaged to the player named asName; else the only one engaged, or the
 nearest loaded of several. None when nobody is engaged.}

Bool Function PlanExists(Actor akBetrothed) Global Native
Bool Function PlanHire(Actor akBetrothed, Actor akPlanner) Global Native
{A planner hired for this wedding: the plan gets every part of the ceremony.}

Bool Function PlanSetDay(Actor akBetrothed, Int aiDaysFromNow, String asTimeOfDay) Global Native
{The day, in whole days from today (0 today), and the hour from words
 ("morning", "noon", "evening") or digits; noon when the words mean nothing.}

Bool Function PlanSetPlace(Actor akBetrothed, String asPlace) Global Native
Bool Function PlanSetOfficiant(Actor akBetrothed, Actor akOfficiant) Global Native
Bool Function PlanGuest(Actor akBetrothed, Actor akGuest, Bool abAdd) Global Native
Bool Function PlanSetParts(Actor akBetrothed, Int aiParts) Global Native
Bool Function PlanSetRings(Actor akBetrothed, Int aiRingMetal, Int aiBandMetal, Int aiBandWide) Global Native
{Metals 0 gold, 1 silver, 2 ebony, -1 left as it is; aiBandWide 1 wide, 0
 braided, -1 as the player's sex has it.}

Bool Function PlanSetOutfit(Actor akBetrothed, Bool abSaved) Global Native
Bool Function PlanPostpone(Actor akBetrothed) Global Native
{The day cleared, the rest of the plan kept.}

Function PlanClear(Actor akBetrothed) Global Native
String Function PlanOpen(Actor akBetrothed) Global Native
{The required items still open, comma-separated: "day", "place", "officiant".}

Actor Function PlanOfficiant(Actor akBetrothed) Global Native
Actor Function PlanPlanner(Actor akBetrothed) Global Native
Actor[] Function PlanGuests(Actor akBetrothed) Global Native
String Function PlanPlace(Actor akBetrothed) Global Native
Bool Function PlanOutfit(Actor akBetrothed) Global Native
Int Function PlanParts(Actor akBetrothed) Global Native
Int Function PlanRing(Actor akBetrothed, Int aiWhich) Global Native
{aiWhich 0: the betrothed's wedding ring's metal; 1: the player's band's; 2:
 whether the band is wide. -1 when the plan leaves it.}

Form Function RingWeddingOfMetal(Int aiMetal) Global Native
{VERSION 28. Our wedding ring in a metal: 0 gold, 1 silver, 2 ebony; None
 otherwise.}
