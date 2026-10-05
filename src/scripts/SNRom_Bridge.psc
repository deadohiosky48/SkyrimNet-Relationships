Scriptname SNRom_Bridge extends Quest
{ Relationships: SkyrimNet bonds, owned end to end.

  This script owns the bonds - points, tiers, enrollment, the consent gate -
  and everything SkyrimNet needs to read or move them, plus the disposition
  store the LLM authors into.

  ROMANTASY IS NOT A DEPENDENCY FROM 2.0 (design 8.1, 10). It is read once
  per save, if installed, by the points import (StartPointsImport), and never
  called otherwise: every Romantasy.* call in this file sits behind
  SNRom_RomantasyReadable, which is only ever set from Game.IsPluginInstalled.
  Papyrus cannot tell a missing native from a refusal, so an unguarded call
  would fail silently - grep for "Romantasy\." before adding one. }

; ---------------------------------------------------------------------------
; State
;
; DELIBERATELY ZERO PROPERTIES. Nothing here is ever set in the Creation Kit -
; SNRom_Bond is resolved at runtime from our own plugin, and the rest are
; constants. Declaring them as properties gave CK a property list to
; enumerate when saving the quest, for no benefit. A script with no properties
; is the least CK has to chew on, and there is nothing for a user to leave
; unfilled.
; ---------------------------------------------------------------------------
; SNRom_Bond, SNRom_Integration.esl 0xD63: membership is enrollment, the rank
; is the tier (0-5). The successor to ROM_RomanceLevel, for everything that
; reads bond state without Papyrus: action eligibility, the optional Baka
; tier gates, vanilla conditions and native plugins (design 6.6 a, 8.1).
Faction  _bond
; THE DASHBOARD'S VIEW OF THIS SESSION (SkyrimNetRelationships.dll, natives v3).
; Cached by ArmDashboard at every bootstrap, and the store pair again by the two
; store repairs, because the refresh handler must not call SkyrimNet's API: the
; dashboard pauses the game, and SkyrimNet has been seen refusing VM calls while
; it is paused. See OnDashboardRefresh.
Int      _dashNatives       ; SNRom_Native.Version(); 0 without the DLL, or one too old
String   _dashStore         ; StoreFile()
String   _dashPlaythrough   ; PlaythroughId()
Int      _dashKinGuard      ; SNRom_Decorators.KinGuardOn(), as 1 or 0
Bool     _dashMaras         ; MarasPresent(), for the refresh's batch fetch
Bool     _dashSever         ; SeverActionsPresent(), the same
; A FULL REFRESH HAS ANSWERED THIS SESSION, so the DLL holds everyone's text and
; the functions that write it push the change. Bootstrap clears it: the DLL
; clears its model whenever a save loads.
Bool     _dashText
; THE ONE-TIME POINTS IMPORT IS RUNNING (OnImportPoints). Not saved as True in
; any way that matters: a save made mid-import resumes it, and the per-actor
; stamps skip whoever is already done.
Bool     _importing
; WHO CAN OBSERVE THE PLAYER THIS TICK (Observers): the enrolled characters
; near them, taken once at the top of OnUpdateGameTime. The assessors and the
; per-actor housekeeping pick from these, not from the whole roster.
Actor[]  _observers
Int      _seq
; HAS OUR CONTENT LAYER LOADED? 0 not looked yet, 1 present, 2 missing. Reset to
; 0 by Bootstrap so the answer is reported once per session and again every load
; until it is fixed. See CheckContentLoaded.
Int      _contentSeen
Float    _lastBootstrap
String[] _ledgerBuf
Int      _ledgerCount
Bool     _ready

Int Function LOG_ERROR() Global
    Return 1
EndFunction
Int Function LOG_WARN() Global
    Return 2
EndFunction
Int Function LOG_INFO() Global
    Return 3
EndFunction
Int Function LOG_DEBUG() Global
    Return 4
EndFunction

Float Function PaceMultiplier() Global
    { The one lever, resolved from the named speed the player picked.

      THREE SPEEDS, NOT FIVE. A first cut deliberately: half, normal, double is
      easy to hold in your head and easy to judge from play. Finer strata are a
      later decision, and only worth making once these three have been felt.

      NAMED SPEEDS, NOT A NUMBER. Players understand "relationships take about
      twice as long"; nobody understands 0.5. The select carries the words and
      this maps them, so the mapping can be retuned without retraining anyone.

      Unknown or empty means Normal. A typo in a config file must not silently
      stop a relationship from moving. }
    String w = SNRom_Decorators.Upper(SNRom_Decorators.Trim( \
        SkyrimNetApi.GetConfigString(CFG(), "bondPace", "Normal")))
    If w == "SLOW"
        Return 0.5
    ElseIf w == "FAST"
        Return 2.0
    EndIf
    Return 1.0
EndFunction

Int Function ScaleAward(Int aiPoints) Global
    { THE ONLY PLACE THE PACE MULTIPLIER IS APPLIED. Points leave this mod
      through ten separate Romantasy calls and seven of them are earnings, so the
      arithmetic lives here once and each site says for itself whether it is an
      earning or a transfer. A wrapper around ModifyPoints was the other option
      and was rejected: it would need telling which kind it was anyway, and two
      near-identical wrappers hide the distinction that actually matters.

      NEVER CALL THIS ON A TRANSFER. HoldShortOfLover banks an award short of
      Lover; AcceptRomance returns the banked amount in full.
      Scale either and points evaporate - claw back 200, hand back 50 - and the
      player watched those points accrue and was promised them back. Seeding is
      excluded too: "Prior history together" describes a relationship that
      existed before this mod was installed, and a slow setting has no business
      retroactively shrinking someone's past.

      THE FLOOR IS THE WHOLE POINT AT THE SLOW END. Points are Ints, so at 0.25x
      a SMALL award of 10 becomes 2 and an award of 1 becomes 0 - the axis stops
      registering entirely and the player learns their behaviour does not matter.
      Any non-zero award stays non-zero and keeps its sign. Better to move the
      needle by one than not at all; that is the entire reason this exists. }
    If aiPoints == 0
        Return 0
    EndIf
    Float mult = PaceMultiplier()
    If mult == 1.0
        Return aiPoints
    EndIf
    Int scaled = (aiPoints * mult) as Int
    If scaled == 0
        If aiPoints > 0
            Return 1
        EndIf
        Return -1
    EndIf
    Return scaled
EndFunction
String Function CFG() Global
    { SkyrimNet namespaces plugin manifests as "Plugin_<plugin name>" - see
      /config?api=list, which shows "Plugin_SeverActions" and
      "Plugin_SkyrimNet Relationships". Reading from "game" silently returns the
      caller's default for every key, so the manifest renders in the dashboard
      and changes nothing. }
    Return "Plugin_SkyrimNet Relationships"
EndFunction

String Function LedgerPath() Global
    Return "Data/SKSE/Plugins/SkyrimNet Relationships/logs/ledger.jsonl"
EndFunction

String Function NL() Global
    { Papyrus string literals support no escape sequences - NL() is a
      literal backslash-n. Build the newline from its char code. }
    Return StringUtil.AsChar(10)
EndFunction

String Function DiagPath() Global
    Return "Data/SKSE/Plugins/SkyrimNet Relationships/logs/snrom.log"
EndFunction

; ===========================================================================
; Lifecycle
; ===========================================================================

Event OnInit()
    Bootstrap()
EndEvent

Function Bootstrap(Bool abForce = False)
    { Called from OnInit and from the player alias on every game load.
      Everything here MUST be idempotent - decorator and ModEvent
      registrations do not survive a save/load and must be re-established.

      Debounced: quest OnInit, alias OnInit and OnPlayerLoadGame all fire
      within moments of each other, so this ran four times per load and
      quadrupled every log line for no benefit.

      abForce bypasses the debounce entirely and is passed by
      OnPlayerLoadGame, the one event that unambiguously means "new session".
      The debounce is a REAL-TIME window compared against a value persisted in
      the save, and real time cannot tell sessions apart: load a save at a
      similar point in the launch as last time and the delta falls inside the
      window, skipping bootstrap on a fresh session. That silently cost an
      entire play session's spark timer - RegisterForSingleUpdateGameTime is
      inside the skipped region, and a single-update registration that is
      never made simply never fires. Nothing errored; the feature was just
      absent. }
    Float now = Utility.GetCurrentRealTime()
    If abForce
        _lastBootstrap = 0.0
    EndIf
    ; The `now >= _lastBootstrap` term is load-bearing, not defensive noise.
    ; GetCurrentRealTime counts from GAME LAUNCH and resets every restart, but
    ; _lastBootstrap is a script variable and PERSISTS in the save. Load a save
    ; faster than you did last session and the delta goes NEGATIVE, which
    ; satisfies "< 5.0" and silently skipped the whole bootstrap - no
    ; decorators, no ModEvents, no log line, on the one path that exists
    ; precisely because those do not survive a save/load. Intermittent and
    ; timing-dependent, so it looked like nothing at all. A negative delta
    ; means "new game session", which is exactly when we MUST run.
    If _lastBootstrap > 0.0 && now >= _lastBootstrap && (now - _lastBootstrap) < 5.0
        Return
    EndIf
    _lastBootstrap = now
    ; SESSION COUNTER, not a boolean. The marriage reconciliation needs to know
    ; whether it has checked a GIVEN ACTOR this session, and StorageUtil values
    ; persist in the save, so there is nothing per-actor that resets on its own.
    ; Incrementing one None-scoped Int here makes every actor's stored marker
    ; stale at once, which is the reset - and it costs one write per load rather
    ; than a walk over the roster clearing flags.
    StorageUtil.SetIntValue(None, "SNRom_SessionId", \
        StorageUtil.GetIntValue(None, "SNRom_SessionId", 0) + 1)
    _ledgerBuf = new String[32]
    _ledgerCount = 0

    ; Register FIRST, unconditionally. If our plugin is missing the decorators
    ; must still exist, or every prompt referencing them errors out instead of
    ; rendering "not enrolled". Degrade quietly, never disappear.
    ; BEFORE ANYTHING TOUCHES THE STORE. StoreFile() reads the save id, so a
    ; decorator or a sweep that ran first would read and write the previous
    ; playthrough's file. Same ordering constraint Kinship documents.
    EnsureSaveId()
    WriteStorePointer()

    RegisterDecorators()
    RegisterEvents()
    ; Same place, same reason: the dashboard needs nothing from the gate. Once
    ; per bootstrap; the DLL watches the saved settings itself after that.
    ; The DLL cleared its read model when this save began loading, so it holds
    ; no text until the next full refresh answers, and the writers stop pushing.
    _dashText = False
    ArmDashboard()

    ; OUR OWN PLUGIN'S BOND FACTION is the one thing the mod cannot run
    ; without; Romantasy is no longer required (design 8.1: "_ready must stop
    ; meaning 'Romantasy resolved'").
    _bond = ResolveBondFaction()
    If _bond == None
        _ready = False
        Diag(LOG_ERROR(), "SNRom_Bond unresolved - SNRom_Integration.esl is missing or older than " + \
            "these scripts. Integration inert.")
        Return
    EndIf

    _ready = True
    ; THE POINTS ARE OURS. A save that has not been brought over yet is, once,
    ; on its own stack: from Romantasy if it is installed, from nothing if it
    ; is not. Until someone is reached, PointsOf reads Romantasy's number for
    ; them where it can. Before anything below reads a point.
    ;
    ; _importing is cleared first: a save made mid-import carries it as True,
    ; and if that stack is not resumed the import would never run again. Two
    ; running at once is harmless - each actor's stamp is checked before it is
    ; written.
    _importing = False
    StartPointsImport()
    ; WHICH SKYRIMNET WE ARE RUNNING AGAINST, logged every session.
    ;
    ; Beta 25 moved content into a plugin library and stopped reading the old
    ; folders, so from here on there are two possible layouts and only one of
    ; them is live on any given install. This line plus the one from
    ; CheckContentLoaded is what turns "my companions have gone blank" into a
    ; readable bug report - without it, the two failures are indistinguishable.
    Diag(LOG_INFO(), "SkyrimNet build " + SkyrimNetApi.GetBuildVersion() + \
        " (" + SkyrimNetApi.GetBuildType() + ")")
    ; ASKED AGAIN THIS SESSION. Not a latch that outlives the problem: Bootstrap
    ; runs on every load, so a player who fixes their install is told it is fixed,
    ; and one who does not is reminded.
    _contentSeen = 0
    ; AND ASKED RIGHT NOW, not only on the tick. See CheckContentLoaded for why
    ; a "no" here is not yet an answer.
    CheckContentLoaded()
    ; ONE-TIME WARNING: SEVERACTIONS' INTIMACY & CONSENT SECTION.
    ;
    ; SeverActions 3.9.10 renders its own receptivity stance into every NPC bio
    ; from an assessor that states outright "Do NOT derive desire from
    ; friendship, trust, or relationship rank", where a single welcomed evening
    ; can reach "willing". This mod's model is earned tier. Two contradictory
    ; sets of instructions in one bio reads to the player as an NPC that cannot
    ; make up its mind.
    ;
    ; IT SHIPS ENABLED - IntimateHistoryEnabled defaults to true - and it does
    ; not skip followers, so anyone running both mods has the conflict and no
    ; reason to suspect it. That is the whole reason this is a MessageBox and
    ; not a Diag line: the people affected are exactly the people not reading
    ; the log.
    ;
    ; DELIBERATELY NOT READING THEIR SETTING, so this fires even for users who
    ; have already turned it off. Reading it means a compile-time reference to
    ; SeverActions_FollowerManager and a hard build coupling to their releases,
    ; to save one dismissible box once per save. Their toggle is also mirrored
    ; into a native settings store, so the Papyrus property is not reliably the
    ; live value anyway.
    ;
    ; Once per save, not once per install: a new playthrough is exactly when
    ; someone would want reminding, and the flag rolling back with a reload is
    ; the harmless direction for a warning.
    ; NO SEVERACTIONS WARNING HERE ANY MORE, and the reason is worth keeping.
    ; 1.0.4 popped a MessageBox telling the player to disable SeverActions'
    ; Intimacy & Consent section, because it shipped enabled and contradicted
    ; this mod's pacing. Sever fixed it at the source in 3.9.11:
    ; IntimacyGate::DetectExternalRomance looks for SNRom_Integration.esl by
    ; name and stands the whole layer down - blurb, stance decorator AND the
    ; assessments, so it stops spending LLM calls too. A player can revert that
    ; deliberately in his settings, and if they do, our bio block still
    ; countermands because it is gated on HIS intimacySurfaced flag rather than
    ; on the plugin being present. So the override survives and the nag does not.
    ;
    ; Warning about a conflict another author has already fixed is how a mod
    ; teaches players to dismiss its warnings.
    ; Arm the tick. Safe to call on every bootstrap - a single-update
    ; registration simply replaces any prior one rather than stacking.
    ;
    ; Armed on the ASSESSMENT cadence, which reads a follower count cached in the
    ; co-save, so the first tick of a session already knows how large the party
    ; was when it ended. SweepFollowers runs at the end of this function and
    ; refreshes it before the tick after that.
    RegisterForSingleUpdateGameTime(AssessIntervalHours())
    Diag(LOG_INFO(), "Bridge ready. SNRom_Bond resolved. Assessing every " + \
        AssessIntervalHours() + "h, housekeeping every " + SparkIntervalHours() + "h.")
    ; Catch up immediately rather than waiting a game hour or two. This is the
    ; path that finds followers SeverActions never announces.
    SweepFollowers()
    ; Our bio block libraries, and the player's blocks read back into the
    ; character (2.1, WP-B). Last, so nothing above waits on the roster walk.
    BioBlocksOnLoad()
EndFunction

Faction Function ResolveBondFaction() Global
    { SNRom_Bond, from our own ESL by its plugin-local FormID; SKSE handles
      the ESL indirection, as it did for ROM_RomanceLevel for a year. }
    Return Game.GetFormFromFile(0x00000D63, "SNRom_Integration.esl") as Faction
EndFunction

Faction Function RomantasyFaction() Global
    { ROM_RomanceLevel, or None when Romantasy is not installed or only a stub
      of its plugin is. Read by the release in MoveToBondFaction, and by
      StartPointsImport as the test that Romantasy is really there; nothing is
      put into it any more. }
    If !Game.IsPluginInstalled("CS_Romantasy.esp")
        Return None
    EndIf
    Return Game.GetFormFromFile(0x00000800, "CS_Romantasy.esp") as Faction
EndFunction

Function RegisterEvents()
    ; ROMANTASY'S EVENTS ARE NO LONGER HEARD (design 10, phase 3: "Stop
    ; subscribing to passive deeds. Stop listening to Romantasy_OnLevelChanged").
    ; Registrations are saved with the script, so a save from 1.x still holds
    ; them: unregistered explicitly, once per load, which is harmless when
    ; there is nothing to remove.
    UnregisterForModEvent("Romantasy_OnLevelChanged")
    UnregisterForModEvent("Romantasy_OnPreference")
    ; 1.x's re-read and re-author keys were RegisterForKey, saved with the
    ; script the same way; the DLL has the keys from 2.0.
    UnregisterForAllKeys()
    RegisterForModEvent("SNRom_Hotkey", "OnHotkey")
    ; SeverActions' native watcher fires this ~1s after ANY mod or vanilla
    ; dialogue calls SetPlayerTeammate(true) on an untracked actor - which is
    ; the only reliable "became a follower" signal available. Vanilla Skyrim
    ; has no such event and Papyrus cannot enumerate teammates.
    ;
    ; SOFT dependency: without SeverActions this simply never fires and
    ; nobody auto-enrolls. Nothing errors, and BeginSpark still works. See
    ; the note in AutoEnroll about what a standalone fallback would cost.
    RegisterForModEvent("SeverActions_NewTeammateDetected", "OnNewTeammate")
    ; MARAS owns the marriage state machine and ANNOUNCES changes. We read that
    ; state in six places and never listened for it changing, so a marriage that
    ; happened - or became visible - after an actor was seeded reached us never.
    ; The seed stamps SNRom_Seeded and the sweep then skips that actor forever,
    ; so a missed marriage was permanent rather than eventually-consistent.
    ; Signature is the standard SKSE shape, documented in MARAS.psc:585:
    ;   (String eventName, String status, Float statusEnum, Form npc)
    RegisterForModEvent("maras_status_changed", "OnMarasStatusChanged")
    ; SkyrimNetRelationships.dll asks for the roster every time the dashboard
    ; opens (OnDashboardRefresh). Without the DLL it never fires, and this costs
    ; nothing.
    RegisterForModEvent("SNRom_DashboardRefresh", "OnDashboardRefresh")
    ; And sends the page's actions here (OnDashboardAction), the same way.
    RegisterForModEvent("SNRom_DashboardAction", "OnDashboardAction")
    ; The one-time points import runs on its own stack (StartPointsImport).
    RegisterForModEvent("SNRom_ImportPoints", "OnImportPoints")
    ; A held tier notice the player can now see (AnnounceTier, Notices.h).
    RegisterForModEvent("SNRom_ShowNotice", "OnShowNotice")
EndFunction

; NOTE: there is deliberately no decorator self-test. Mod-added decorators
; only resolve for the current speaker or target, so calling one via
; ParseString from a quest script CANNOT work - it returns null and SkyrimNet
; throws "json.exception.type_error.302 type must be number, but is null".
; A diagnostic that always fails is worse than none. The real check is a
; rendered prompt in openrouter_input.log.
Function RegisterDecorators()
    { RegisterDecorator returns a status int. Ignoring it was how four silent
      registration failures went unnoticed - log every one. }
    ; ONLY WHAT A TEMPLATE READS. romance_is_enrolled and romance_can_begin
    ; were registered for the old RomanceBeginSpark gate, which moved to a
    ; background call and native eligibility rules long ago - nothing has read
    ; either since, yet SkyrimNet evaluated each ~327 times a session. Under
    ; Beta 25 every registered Papyrus decorator is also something the cache
    ; must warm, so dead ones compete with the two that matter. Unregistered
    ; 2026-09-27; IsEnrolled and CanBegin themselves stay, as plain functions.
    Int c = SkyrimNetApi.RegisterDecorator("romance_physical_ok", "SNRom_Decorators", "PhysicalOk")
    Int e = SkyrimNetApi.RegisterDecorator("get_romance",         "SNRom_Decorators", "GetRomance")
    Diag(LOG_INFO(), "RegisterDecorator rc: physical_ok=" + c + " get_romance=" + e)
EndFunction

; ===========================================================================
; Actions (called by SkyrimNet YAML via questEditorId/scriptName/function)
; ===========================================================================

Function BeginSpark(Actor akActor, String asReason)
    { RomanceBeginSpark. Enrollment. }
    If !_ready || akActor == None
        Return
    EndIf
    If IsEnrolled(akActor)
        Diag(LOG_WARN(), "BeginSpark on already-enrolled " + akActor.GetDisplayName())
        Return
    EndIf
    ; Eligibility YAML can only use NATIVE decorators (see the note in
    ; RomanceBeginSpark.yaml), so the real gate lives here. Belt and braces:
    ; the model cannot route past a Papyrus check.
    If SNRom_Decorators.CanBegin(akActor) != "true"
        Diag(LOG_INFO(), "BeginSpark declined for " + akActor.GetDisplayName() +             " - not receptive, orientation mismatch, or already enrolled.")
        Return
    EndIf

    StorageUtil.SetIntValue(akActor, "SNRom_Enrolled", 1)
    JoinBondFaction(akActor)
    StorageUtil.SetFloatValue(akActor, "SNRom_EnrolledAt", Utility.GetCurrentGameTime())
    ; BeginSpark IS the spark - this is what puts her on the romantic ladder in
    ; 0330_relationships_bond rather than the platonic one. Once followers
    ; auto-enroll, enrollment alone will stop meaning anything about romance
    ; and this flag becomes the only thing that does.
    StorageUtil.SetIntValue(akActor, "SNRom_Sparked", 1)
    ; Roster membership is what ResolveFromBase matches against, so an NPC
    ; enrolled through BeginSpark rather than AutoEnroll must be on it too -
    ; otherwise her passive scoring falls back to the fragile name lookup.
    StorageUtil.FormListAdd(None, "SNRom_Roster", akActor, False)

    ; Authored beats land immediately regardless of the load-time constraint,
    ; so the bond is never sitting at a bare zero after a real moment.
    ApplyDepth(akActor, ScaleAward(25), asReason, False, "began")

    SkyrimNetApi.RegisterPersistentEvent( \
        akActor.GetDisplayName() + " and " + Game.GetPlayer().GetDisplayName() + \
        " have reached an understanding neither has named. " + asReason, akActor, Game.GetPlayer())

    Ledger(akActor, "enroll", "", 25, 1, asReason)

    ; Enrollment is what makes a person's character matter, so enrollment is
    ; what authors it. Async - the callback lands whenever the LLM answers;
    ; nothing here waits on it.
    AuthorDisposition(akActor)
EndFunction

; ===========================================================================
; Auto-enrollment
;
; Enrollment stopped being the romance gate on 2026-07-28. It now means only
; "this person is being observed" - the bond starts accruing from shared
; experience, and whether it is a friendship or a romance is decided later by
; the spark, not here.
;
; So this deliberately does NOT do three things BeginSpark does:
;   - no opening points award
;   - no "an understanding neither has named" persistent event
;   - no SNRom_Sparked flag
; Asserting any of those for a mercenary who just took a contract would be a
; lie the LLM then has to live with.
; ===========================================================================

Function SweepFollowers()
    { Detection CANNOT be purely reactive, and believing otherwise cost a
      whole session.

      SeverActions_NewTeammateDetected only fires for actors SeverActions is
      not ALREADY tracking. A long-standing follower it already knows never
      generates an event at all, so we never hear about her: Hermir traveled
      for an entire session, was talked to at length, and was never enrolled.

      What disguised this is that save reverts also revert SeverActions' own
      tracking data, so after each revert everyone briefly looked new and the
      event fired for the whole party. It appeared to work; it was only
      working because the tracking had been thrown away.

      ScanCellNPCs returns Actor[] directly, so unlike ScanCellObjects there
      is no form-type enum to get silently wrong. Radius bounds the cost.
      Anyone further out is picked up the next time they share a cell, and
      the roster is persistent, so it only has to happen once per follower.

      IgnoreDead is passed FALSE, and the dead check moved into the loop below.
      A VR user crashed inside PapyrusUtil on 2026-08-19 in the cell walk this
      call drives: an access violation reading a byte at rdi+0x40 with rdi =
      0xFFFFFF01, which is a stale entry in the cell's object list rather than
      anything we passed - the only arguments crossing this boundary are the
      player and a float. They reported it "after two in-game hours", which is
      exactly SparkIntervalHours, so it was the first OnUpdateGameTime tick
      that happened to land in a heavily patched interior.

      IgnoreDead TRUE makes PapyrusUtil evaluate each actor's dead state during
      that native walk, so it must dereference every entry it finds. FALSE
      skips that, and a.IsDead() below asks the same question through a
      VM-validated handle, where a stale pointer cannot reach us. Whether that
      is sufficient is UNTESTED - none of this reproduces without a VR install -
      so cellScanEnabled is the off switch for anyone it still crashes. }
    If SkyrimNetApi.GetConfigBool(CFG(), "cellScanEnabled", True) == False
        Return
    EndIf
    Actor player = Game.GetPlayer()
    Actor[] near = MiscUtil.ScanCellNPCs(player, 6000.0, None, False)
    Int scanned = 0
    If near
        scanned = near.Length
    EndIf
    Int followers = 0
    Int i = 0
    While i < scanned
        Actor a = near[i]
        If a != None && a != player && !a.IsDead()
            If IsFollowing(a)
                followers += 1
                ; RECENCY STAMP, for BuildCircle's ordering. The author swaps party
                ; members regularly, so "who is relevant to compare against" is
                ; not "who enrolled first" - it is whoever has traveled with
                ; him most recently. Someone dismissed an hour ago after a week
                ; on the road matters more than an early enrollee who never
                ; left town.
                ;
                ; Stamped on every sweep rather than only on transitions: a
                ; transition hook cannot see someone who was ALREADY following
                ; when the feature shipped, which is the same trap that made
                ; enrollment need a catch-up sweep in the first place.
                StorageUtil.SetFloatValue(a, "SNRom_LastFollowingAt", Utility.GetCurrentGameTime())
                AutoEnroll(a)  ; handles dead/summon/already-enrolled and the roster add
            ElseIf StorageUtil.GetFloatValue(a, "SNRom_FirstSeenFollowing", 0.0) > 0.0 && \
                   StorageUtil.GetIntValue(a, "SNRom_Enrolled", 0) == 0
                ; They started the waiting period and did not finish it. Clearing
                ; the stamp is what makes the debounce mean "two CONTINUOUS
                ; hours" rather than "two hours, ever". Without this, an
                ; accidental recruit who is dismissed a minute later keeps a
                ; stamp that ages indefinitely, and enrolls INSTANTLY the next
                ; time anything makes them a follower again - which is precisely
                ; the case the debounce exists to catch.
                ;
                ; Guarded on SNRom_Enrolled because an enrolled follower who is
                ; dismissed must keep their stamp: AutoEnroll's already-enrolled
                ; branch returns before reaching the debounce, but a future
                ; reader moving that boundary should not silently reset people
                ; who are long past this gate.
                StorageUtil.UnsetFloatValue(a, "SNRom_FirstSeenFollowing")
                StorageUtil.FormListRemove(None, PENDING_LIST(), a, True)
                Diag(LOG_INFO(), a.GetDisplayName() + " is no longer following before enrollment - waiting period reset")
            EndIf
        EndIf
        i += 1
    EndWhile
    PurgeNonPersons()

    ; ALWAYS log the counts. The first version of this function was silent, ran
    ; twice on a load, found nothing, and left no way to tell whether the scan
    ; returned nothing or the follower test rejected everyone. Two completely
    ; different bugs, indistinguishable from outside. Never ship a sweep
    ; without its counts.
    ; Cached for AssessIntervalHours. The sweep already knows this number and it
    ; costs a walk of the roster to recompute, so it is stored rather than asked
    ; for again. Up to one housekeeping period stale, which is harmless for a
    ; pacing decision.
    StorageUtil.SetIntValue(None, "SNRom_FollowerCount", followers)
    Diag(LOG_INFO(), "Follower sweep: " + scanned + " actors in range, " + followers + \
        " following, roster now " + StorageUtil.FormListCount(None, "SNRom_Roster"))
EndFunction

String Function PENDING_LIST() Global
    { Everyone serving the enrollment waiting period: noticed following, not
      yet enrolled. }
    Return "SNRom_PendingEnroll"
EndFunction

Function CheckPendingEnrollments()
    { FINISHES THE WAITING PERIOD WHEREVER THEY ARE. The sweep notices a
      follower near the player; this asks each one waiting, directly, whether
      they are still following - IsFollowing reads flags and factions, which an
      unloaded character has too. So a new follower told to wait in a house
      while the player clears a dungeon is enrolled when the period is up, as
      the author asked (2026-10-01), not on the first sweep that finds them
      nearby again. Not following any more resets the period: "two CONTINUOUS
      hours", as the sweep's own reset has always meant.

      A short list, so a handful of reads a tick. Backwards, because entries
      are removed as it goes. }
    Int i = StorageUtil.FormListCount(None, PENDING_LIST()) - 1
    While i >= 0
        Actor a = StorageUtil.FormListGet(None, PENDING_LIST(), i) as Actor
        If a == None || a.IsDead() || IsEnrolled(a)
            StorageUtil.FormListRemoveAt(None, PENDING_LIST(), i)
        ElseIf IsFollowing(a)
            StorageUtil.SetFloatValue(a, "SNRom_LastFollowingAt", Utility.GetCurrentGameTime())
            AutoEnroll(a)
        Else
            StorageUtil.FormListRemoveAt(None, PENDING_LIST(), i)
            If StorageUtil.GetFloatValue(a, "SNRom_FirstSeenFollowing", 0.0) > 0.0
                StorageUtil.UnsetFloatValue(a, "SNRom_FirstSeenFollowing")
                Diag(LOG_INFO(), a.GetDisplayName() + " is no longer following before enrollment - waiting period reset")
            EndIf
        EndIf
        i -= 1
    EndWhile
EndFunction

Function PurgeNonPersons()
    { Self-healing cleanup for creatures already on the roster.

      Written instead of dispatching UnenrollActor on the two horses by hand,
      for two reasons: the game was stopped so nothing could be dispatched, and
      a hand-written list would have missed the House Cat - which was noticed
      separately and is exactly the kind of thing a manual fix forgets.

      Runs on the sweep rather than once at load, so anything that slipped in
      under an older build is removed the first time the player is near it, with
      no migration step and nothing for the player to remember to run.

      Walks BACKWARDS. FormListRemove shifts every later index down by one, so a
      forward loop skips the entry immediately after each removal - and with two
      horses adjacent on the roster that would have left one of them behind. }
    Int i = StorageUtil.FormListCount(None, "SNRom_Roster") - 1
    While i >= 0
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None && !IsPerson(a)
            Diag(LOG_WARN(), "Removing " + a.GetDisplayName() + " from the roster - not a person. " + \
                "Enrolled by a build that only asked whether they were following.")
            UnenrollActor(a)
        EndIf
        i -= 1
    EndWhile
EndFunction

Bool Function IsPerson(Actor akActor)
    { NOT Global, deliberately - unlike IsFollowing. A Global cannot call Diag,
      and the fail-open branch below is worthless without a log line: a filter
      that silently stops filtering looks exactly like the bug it replaced.
      Nothing outside this script needs it, so instance scope costs nothing.

      People only. Horses, cats and anything else on four legs are not romance
      candidates and were never meant to be.

      TWO HORSES AND A HOUSE CAT reached the roster before this existed - with
      recruit rows, LLM-authored dispositions, and a share of the one-assessment
      -per-tick budget. A Haflinger Horse had opinions about Barters, Locks
      Picked and Items Stolen. AutoEnroll filtered dead / commanded / player and
      then asked IsFollowing, and an owned horse passes IsPlayerTeammate, so
      nothing in the chain ever asked whether the candidate was a PERSON.

      ActorTypeNPC is the game's own answer to that question, which is why this
      uses it rather than a race list or a name test. It is also strictly better
      than the ActorBase.IsUnique() guard rejected on 2026-08-02: that would
      have excluded FMR-spawned children, who ARE people, while still letting a
      unique horse through. This does neither.

      FAILS OPEN, and loudly. If the keyword cannot be resolved the answer is
      "yes, a person" rather than blocking every enrollment in the mod - but it
      logs at ERROR, because a silent fail-open here would look exactly like the
      bug it was written to fix. }
    If akActor == None
        Return False
    EndIf
    Keyword kw = Game.GetFormFromFile(0x00013794, "Skyrim.esm") as Keyword   ; ActorTypeNPC
    If kw == None
        Diag(LOG_ERROR(), "ActorTypeNPC keyword did not resolve from Skyrim.esm - the humans-only " + \
            "filter is INERT this session and creatures can be enrolled again.")
        Return True
    EndIf
    Return akActor.HasKeyword(kw)
EndFunction

Bool Function SeverActionsPresent() Global
    { GLOBAL, and therefore NOT cached in a script variable the way MarasPresent
      is - a Global has no instance state to cache into. IsPluginInstalled is a
      cheap native lookup, so paying it per call is fine and is much better than
      the alternative of making IsFollowing non-Global again.

      Guards SA's native Papyrus surface. Calling a native whose DLL is absent
      does not CTD, but it logs a Papyrus error per call, and IsFollowing runs
      for every actor in every sweep. }
    Return Game.IsPluginInstalled("SeverActions.esp")
EndFunction

Bool Function IsFollowing(Actor akActor) Global
    { GLOBAL so SNRom_Decorators can reach it too - CanBegin was asking the same
      question with the bare vanilla flag, which is the identical bug. Touches no
      instance state, so Global is safe here. (The "never Global" rule applies to
      DECORATOR entry points, which SkyrimNet dispatches as instance methods;
      this is a plain helper.)

      THREE tests, because one is not enough and two were not either.

      IsPlayerTeammate is the vanilla flag and is what most followers set, but
      follower frameworks do not all use it consistently and it can be cleared
      while someone is still functionally traveling with you. Vanilla's
      CurrentFollowerFaction is the second opinion.

      The third is SeverActions' OWN follower flag, read straight out of
      StorageUtil. Found by reading the 3.9.0 source: SeverActions_FollowerManager
      documents its per-follower keys at :28-35 and defines KEY_IS_FOLLOWER at
      :433. It is an INT (see the UnsetIntValue at :2673), and ints survive a
      reload here where strings do not - so it is durable as well as
      authoritative. Preferred over the SeverActions_ActivelyFollowing FACTION:
      no Game.GetFormFromFile, no ESL indirection, no soft-dependency guard,
      and a missing key simply returns 0 when SeverActions is not installed.

      Written as OR deliberately: a false negative here means an NPC is never
      enrolled and never scored, silently, forever - which is exactly what
      happened to Hermir and then to Svana. A false positive costs one wasted
      enrollment, and the enrollment debounce now absorbs even that.

      THE DASHBOARD DRAWS A COPY OF THIS: Display::Following in
      native/src/Display.cpp, line for line, from facts the DLL reads itself.
      Change one, change both. The gates keep calling this function. }
    If akActor.IsPlayerTeammate()
        Return True
    EndIf
    ; SeverActions' NATIVE roster, not StorageUtil. This read used to be
    ; StorageUtil.GetIntValue(akActor, "SeverFollower_IsFollower", 0) - a key
    ; SA no longer writes. It still DECLARES the constant and still UNSETS it on
    ; dismissal (FollowerManager.psc:510, :3100), and its header comment block
    ; still documents the whole SeverFollower_* family as a live API, so the
    ; source reads exactly like a working integration. Nothing writes any of
    ; them: not one of the 38 Papyrus scripts, and the strings do not appear in
    ; either native DLL in any encoding. The give-away is the docstring on the
    ; replacement, SeverActionsNativeExt.psc:658 - "Replaces
    ; StorageUtil(KEY_IS_FOLLOWER)".
    ;
    ; LESSON, and it is the same one as llmVariant: a key that is only ever READ
    ; returns its default forever and looks exactly like a false answer. Before
    ; depending on another mod's data, find the WRITER, not the declaration.
    If SeverActionsPresent() && SeverActionsNativeExt.Native_GetIsFollower(akActor)
        Return True
    EndIf
    Faction cff = Game.GetFormFromFile(0x0005C84E, "Skyrim.esm") as Faction
    Return cff != None && akActor.IsInFaction(cff)
EndFunction

Float Function OBSERVE_RANGE() Global
    { How near the player an enrolled character must be to be observing them:
      the follower sweep's own scan radius, so "near enough to notice
      following" and "near enough to notice anything" are one distance. }
    Return 6000.0
EndFunction

Actor[] Function Observers()
    { FOLLOWING IS NOT A QUALIFIER (design 3.2): everyone enrolled who can
      observe the player - loaded, alive and within OBSERVE_RANGE - follower
      or not. The talk, spark and drift assessors, the attraction reading and
      the marriage check pick from these. Following decides one thing,
      automatic enrollment (SweepFollowers).

      THE ASSESSORS READ EVERYTHING SINCE THEIR LAST LOOK, so a conversation
      with someone you then walk away from is not lost: it is judged the next
      time a tick finds you near them. A spouse at home lives again when you
      visit; a shopkeeper you courted, when you go back.

      ONE NATIVE CALL with the DLL (natives v6), one frame. Without it, or with
      an older one, a roster walk that pays a frame per question per
      character - correct, and slow. }
    If _dashNatives >= 6
        Return SNRom_Native.ObserversNear(OBSERVE_RANGE())
    EndIf
    Actor player = Game.GetPlayer()
    Actor[] found = PapyrusUtil.ActorArray(0)
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int i = 0
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None && a.Is3DLoaded() && !a.IsDead() && a.GetDistance(player) <= OBSERVE_RANGE()
            found = PapyrusUtil.PushActor(found, a)
        EndIf
        i += 1
    EndWhile
    Return found
EndFunction

Event OnNewTeammate(String eventName, String strArg, Float numArg, Form sender)
    { Shape copied from SeverActions_FollowerManager.OnNativeTeammateDetected:
      sender is the Actor, with numArg as a FormID fallback. }
    Actor who = sender as Actor
    If who == None
        who = Game.GetFormEx(numArg as Int) as Actor
    EndIf
    AutoEnroll(who)
EndEvent

Function AutoEnroll(Actor akActor)
    If !_ready || akActor == None
        Return
    EndIf
    If SkyrimNetApi.GetConfigBool(CFG(), "enrollmentOrganic", True) == False
        Return
    EndIf
    ; Summons, corpses and the player are not romance candidates. IsCommandedActor
    ; catches conjured creatures, which SetPlayerTeammate also fires for.
    If akActor.IsDead() || akActor.IsCommandedActor() || akActor == Game.GetPlayer()
        Return
    EndIf
    ; People only. See IsPerson - a horse passes IsPlayerTeammate, so without
    ; this the only thing keeping livestock off the roster was luck.
    If !IsPerson(akActor)
        Diag(LOG_DEBUG(), "Not enrolling " + akActor.GetDisplayName() + " - not a person")
        Return
    EndIf

    ; Two enrollment tests, not one. Romantasy cannot see a runtime AddToFaction
    ; until the next load, so GetLevel() stays 0 for the rest of this session
    ; and IsEnrolled alone would let a second event enroll her all over again.
    If IsEnrolled(akActor) || StorageUtil.GetIntValue(akActor, "SNRom_Enrolled", 0) == 1
        ; Already enrolled - but STILL put her on the roster. The roster is our
        ; only way to enumerate followers, and it drifts out of sync with
        ; actual enrollment: it lives in StorageUtil and reverts with a save,
        ; while Romantasy's enrollment lives in faction membership and does
        ; not. Reload an older save and you get NPCs Romantasy is scoring that
        ; we cannot see at all.
        ;
        ; An empty roster silently disables three things at once - the circle
        ; passed to disposition authoring, ResolveFromBase (so passive points
        ; are dropped), and both background assessors. All three just quietly
        ; do nothing.
        ;
        ; SeverActions fires this event for every teammate on load, so adding
        ; here repairs the roster on the next game start without needing to
        ; enumerate anything.
        StorageUtil.FormListAdd(None, "SNRom_Roster", akActor, False)
        Return
    EndIf

    ; ---- ENROLLMENT DEBOUNCE -----------------------------------------------
    ; Enrollment is PERMANENT and the only undo is UnenrollActor, which the
    ; player has to know to reach for. So an accidental follower is close to a
    ; permanent passenger.
    ;
    ; And accidents are not rare, because SkyrimNet's LLM can make anyone a
    ; follower mid-scene. Twice in two days: a bandit highwayman recruited
    ; through dialogue, then Sibbi Black-Briar, who auto-joined from his JAIL
    ; CELL while the player was taunting him - apparently reacting to Threki's
    ; recruitment dialogue happening in the same scene. Neither was intended.
    ;
    ; Requiring the follower state to SURVIVE a waiting period filters both: a
    ; mistake is normally dismissed or killed long before it elapses, while a
    ; deliberate companion clears it without noticing. The stamp is a Float, and
    ; floats persist across reloads here where strings do not.
    ;
    ; THIS MUST STAY BELOW THE ALREADY-ENROLLED BRANCH. Above it, the delay also
    ; gated the roster rebuild - and the roster is empty on every load, so a
    ; party of established followers would have spent the first two game hours
    ; of every session invisible to both assessors, which is the exact silent
    ; do-nothing failure the roster comment above warns about.
    ;
    ; NOT ActorBase.IsUnique(). That was the earlier plan and it would have
    ; caught the bandit but NOT Sibbi, who is a unique NPC - and it would also
    ; have excluded FMR-spawned children, which is a behavior change nobody
    ; asked for. Tenure catches both cases without judging who deserves it.
    Float now = Utility.GetCurrentGameTime()
    Float firstSeen = StorageUtil.GetFloatValue(akActor, "SNRom_FirstSeenFollowing", 0.0)
    If firstSeen <= 0.0
        StorageUtil.SetFloatValue(akActor, "SNRom_FirstSeenFollowing", now)
        StorageUtil.FormListAdd(None, PENDING_LIST(), akActor, False)
        Diag(LOG_INFO(), "Noticed " + akActor.GetDisplayName() + \
            " following - enrollment held until they are still here in " + \
            SkyrimNetApi.GetConfigFloat(CFG(), "enrollmentDelayHours", 2.0) + " game hours")
        Return
    EndIf
    If (now - firstSeen) < (SkyrimNetApi.GetConfigFloat(CFG(), "enrollmentDelayHours", 2.0) / 24.0)
        Return                                  ; still serving the waiting period
    EndIf

    EnrollNow(akActor, "Auto-enrolled")
EndFunction

Function EnrollNow(Actor akActor, String asHow)
    { THE ENROLLMENT ITSELF, for both ways in: AutoEnroll once a follower's
      waiting period is up, and EnrollByHand. asHow opens the log line. }
    StorageUtil.SetIntValue(akActor, "SNRom_Enrolled", 1)
    JoinBondFaction(akActor)
    ; THE flag that keeps IsSparked honest. Faction membership used to imply a
    ; deliberate act; once anyone who signs on is enrolled it implies nothing,
    ; and this is what tells the platonic/romantic split which is which.
    StorageUtil.SetIntValue(akActor, "SNRom_AutoEnrolled", 1)
    StorageUtil.SetFloatValue(akActor, "SNRom_EnrolledAt", Utility.GetCurrentGameTime())
    StorageUtil.FormListRemove(None, PENDING_LIST(), akActor, True)

    ; ── STAMP BOTH ASSESSOR WATERMARKS AT ENROLLMENT ────────────────────────
    ; Without this a new enrollee has LastTalkCheck 0.0, which means TWO things
    ; at once and both are wrong:
    ;
    ;   1. Their wait is the entire game clock, so AssessNextTalk's most-overdue
    ;      pick chooses them FIRST, within seconds of joining.
    ;   2. The watermark passed to the prompt is 0, so the window is unbounded.
    ;
    ; For an NPC with history that over-scores. For one with none it is worse:
    ; the window renders empty and the model, asked to judge a conversation that
    ; does not exist, produces one. Bryling was enrolled at gd=130.506 and
    ; assessed at gd=130.507 - the same instant - and came back RUPTURE -350
    ; citing a moment of sexual intimacy that belonged to Sybille, who happened
    ; to be standing next to her. Romantasy rejected the award only because
    ; Bryling was not live yet; nothing in this mod stopped it.
    ;
    ; Stamping NOW means the first assessment sees only what has happened SINCE
    ; they joined - which for someone who just joined is nothing, so the honest
    ; answer NOTHING becomes the easy one instead of an empty page to fill.
    StorageUtil.SetFloatValue(akActor, "SNRom_LastTalkCheck", Utility.GetCurrentGameTime())
    StorageUtil.SetFloatValue(akActor, "SNRom_LastSparkCheck", Utility.GetCurrentGameTime())

    ; Channel is "recruit". It has been through two wrong names already:
    ;
    ;   "autoenroll" - a case-variant of the function name AutoEnroll, folded
    ;                  onto the identifier by the compiler's case-insensitive
    ;                  string interning (the LLMVariant bug again).
    ;   "auto"       - stored correctly as lowercase in the .pex string table,
    ;                  yet written to the ledger as "AUTO". `Auto` is a PAPYRUS
    ;                  KEYWORD; "moment"/"enroll"/"passive" are not and all
    ;                  round-trip fine. Mechanism unconfirmed, but the pattern
    ;                  is clear enough to avoid.
    ;
    ; RULE: a string literal must not be a case-variant of any identifier in
    ; the script, NOR of a Papyrus keyword. Verify by reading the value that
    ; actually lands in the file, never the source.
    ; Roster for the spark assessor. Papyrus cannot enumerate followers, so
    ; the only way to have a candidate list later is to build it at the moment
    ; we already have the actor in hand.
    StorageUtil.FormListAdd(None, "SNRom_Roster", akActor, False)

    Ledger(akActor, "recruit", "", 0, 1, "")
    Diag(LOG_INFO(), asHow + " " + akActor.GetDisplayName() + " at Stranger/0" + \
        " (platonic until sparked)")

    AuthorDisposition(akActor)
EndFunction

String Function EnrollByHand(Actor akActor)
    { WP7: THE PLAYER ENROLLS SOMEONE, following or not - the dashboard's
      crosshair target or the enroll hotkey. The only way a non-follower joins
      the roster: never automatic (design 3.2, the author 2026-09-28). No
      waiting period, because the player asked. "" when enrolled; otherwise
      why not, in words for the player. }
    If !_ready
        Return "Relationships has not started this session."
    EndIf
    If akActor == None
        Return "Point at someone first."
    EndIf
    String who = akActor.GetDisplayName()
    If akActor == Game.GetPlayer()
        Return "That is you."
    EndIf
    If akActor.IsDead()
        Return who + " is dead."
    EndIf
    If akActor.IsCommandedActor() || !IsPerson(akActor)
        Return who + " cannot be enrolled - only people can."
    EndIf
    If IsEnrolled(akActor)
        Return who + " is already enrolled."
    EndIf
    EnrollNow(akActor, "Enrolled by hand:")
    Return ""
EndFunction

; ---------------------------------------------------------------------------
; A MAGNITUDE THAT DID NOT SURVIVE COERCION, RECOVERED.
;
; Captured verbatim from openrouter_output on 2026-09-03, a live
; RomanceMarkMoment call - written as a line comment rather than a docstring
; because Papyrus docstrings are brace-delimited and the payload contains
; braces, which closes the docstring early and produces five errors on
; unrelated lines:
;
;   PARAMS: "aiMagnitude": "}35", "asActivity": "", "asReason": "He held me
;   so close in the quiet, making me feel like the only person in the world
;   who mattered."
;
; A stray closing brace glued to the number. SkyrimNet coerces the value to
; the Int the signature asks for, that coercion fails, and the action arrives
; with magnitude 0 - so the moment is discarded along with the reason the NPC
; wrote for it. Three of those in five game days: Fenja, Tormir, Kayla.
;
; Note the value is QUOTED even when well formed, so string-to-int coercion is
; the normal path and this only differs in tolerating debris around the digits.
; ---------------------------------------------------------------------------
Int Function DigitsToInt(String asText) Global
    { Pull a signed integer out of whatever the model actually sent.

      Deliberately strict about what it will invent: digits and one leading
      sign, nothing else. A stray brace before the digits gives the number,
      "-20" gives -20, "+35" gives 35, and "a lot" gives 0 - which the caller
      still treats as a damaged payload, because it is. }
    Int n = StringUtil.GetLength(asText)
    If n == 0
        Return 0
    EndIf
    Int i = 0
    Int val = 0
    Bool neg = False
    Bool seen = False
    While i < n
        String c = StringUtil.GetNthChar(asText, i)
        Int o = StringUtil.AsOrd(c)
        If o >= 48 && o <= 57
            val = (val * 10) + (o - 48)
            seen = True
        ElseIf c == "-" && !seen
            ; Only meaningful BEFORE any digit. A trailing dash is punctuation,
            ; and "35-40" is a range the model should not have sent - taking the
            ; first number is the least surprising reading.
            neg = True
        ElseIf seen
            ; Debris after the number ends it. Prevents "35 of 40" becoming 3540.
            i = n
        EndIf
        i += 1
    EndWhile
    If neg
        Return -val
    EndIf
    Return val
EndFunction

Function MarkMoment(Actor akActor, Int aiMagnitude, String asReason, String asActivity, String asMagnitude = "")
    { RomanceMarkMoment. The workhorse: an authored beat, in either
      direction, awarded flat through the consent gate. }
    If !_ready || akActor == None
        Return
    EndIf
    If !IsEnrolled(akActor)
        Diag(LOG_WARN(), "MarkMoment on unenrolled " + akActor.GetDisplayName())
        Return
    EndIf

    ; -- A MAGNITUDE OF ZERO IS A DAMAGED CALL, NOT A NEUTRAL ONE ------------
    ; SkyrimNet converts the model's parameter to an Int before it reaches us,
    ; so anything unparseable arrives here as 0 with no indication it was ever
    ; anything else. The model has no legitimate reason to author a zero: this
    ; action exists to record that something moved, and "nothing moved" is said
    ; by not calling it. Zero therefore always means the payload was damaged.
    ;
    ; Measured 2026-08-29 on Fenja Secret-Fire, two damaged payloads in eleven
    ; minutes. One collapsed to {"aiMagnitude": ", "} and was caught by
    ; SkyrimNet for its missing asReason - loudly, in its own log. The other
    ; arrived as "}35", a stray brace glued to the number, and was NOT caught:
    ; it dispatched, scored zero, and reached the line below that writes the
    ; player-visible journal row. That row would name a moment that mattered and
    ; award nothing for it - the same failure the refusal guard further down
    ; already exists to prevent, arriving by a different route.
    ; RECOVER BEFORE REFUSING. asMagnitude carries the same value as text, so a
    ; number SkyrimNet could not coerce is still readable here - see DigitsToInt
    ; for the captured payload this exists for. Prefer the Int when it survived:
    ; it is the value SkyrimNet already validated.
    Int mag = aiMagnitude
    If mag == 0 && asMagnitude != ""
        mag = DigitsToInt(asMagnitude)
        If mag != 0
            Diag(LOG_WARN(), "Recovered magnitude " + mag + " for " + \
                akActor.GetDisplayName() + " from a damaged parameter ('" + asMagnitude + \
                "'). The moment was kept.")
        EndIf
    EndIf
    ; -- STILL ZERO MEANS GENUINELY DAMAGED ---------------------------------
    ; SHORT ON PURPOSE. This is LOG_ERROR, and logNotifications mirrors every
    ; line to a corner toast - the previous version of this message ran to 307
    ; characters, which Skyrim renders by shrinking the font until it cannot be
    ; read. The reason text belongs in the log, not on screen.
    If mag == 0
        Diag(LOG_ERROR(), "MarkMoment for " + akActor.GetDisplayName() + \
            ": magnitude did not parse. Moment dropped.")
        Diag(LOG_INFO(), "  dropped reason was: " + asReason)
        Return
    EndIf

    ; FLAT, ALWAYS, from 2.0. Routing through Romantasy's likes and dislikes
    ; ended with Romantasy (it fired once in 180 awards, design 4.0); phase 5
    ; routes on our own vocabulary. asActivity is still accepted, and recorded
    ; in the ledger, until the action stops offering it.
    Int cap = SkyrimNetApi.GetConfigInt(CFG(), "awardMaxPoints", 75)
    Int clamped = mag
    If clamped > cap
        clamped = cap
    ElseIf clamped < -cap
        clamped = -cap
    EndIf
    Int magnitude = ScaleAward(clamped)

    ; EARNED: the consent gate inside ApplyDepth may withhold it.
    Int result = ApplyDepth(akActor, magnitude, asReason, True, "moment")
    If result == DEPTH_WITHHELD()
        Ledger(akActor, "withheld", asActivity, magnitude, 1, asReason)
        Return
    EndIf

    ; -- A REFUSED AWARD MUST NOT LEAVE A LEDGER ROW -------------------------
    ; The return value used to be discarded and the row written unconditionally,
    ; so when Romantasy declined (it moved points only for someone following),
    ; this function awarded nothing, said nothing, and then wrote the points
    ; into the journal anyway. The player reads that journal. The points are
    ; ours now and land wherever the companion is; the one refusal left is an
    ; actor whose Romantasy points could not be verified mid-copy
    ; (ImportPoints logs why).
    If result <= 0
        Diag(LOG_ERROR(), "Could not write " + magnitude + " pts for " + \
            akActor.GetDisplayName() + " - their points could not be brought over from Romantasy " + \
            "(see the line above). Award LOST, no ledger row written.")
        Return
    EndIf

    ; -- SAY WHAT LANDED --------------------------------------------------
    ; Until now this path logged only its failures, so a working award left no
    ; trace on our side at all and had to be reconstructed from SkyrimNet own
    ; log. That is backwards: the successes are what the tuning is judged on.
    ; Report the whole chain, because each step can change the number and the
    ; quadratic pace bug was invisible precisely while only one end was shown -
    ; what the model asked for, what the cap allowed, what the pace applied.
    String moved = ""
    If clamped != mag
        moved = " (model asked " + mag + ", capped at " + cap + ")"
    EndIf
    If magnitude != clamped
        moved = moved + " -> " + magnitude + " applied (Bond Pace: " + \
            SkyrimNetApi.GetConfigString(CFG(), "bondPace", "Normal") + ")"
    EndIf
    Diag(LOG_INFO(), "Moment for " + akActor.GetDisplayName() + ": " + \
        clamped + " pts" + moved + " - " + asReason)

    Ledger(akActor, "moment", asActivity, magnitude, 1, asReason)
EndFunction

Function UnsparkActor(Actor akActor)
    { Return someone to the PLATONIC ladder without touching bond depth.

      Written 2026-08-04 because five NPCs crossed into romance during the
      period when the first-ever spark assessment ran with an UNBOUNDED window
      - watermark 0.0 meant it judged an NPC's entire history at once, diary
      included, and almost always said yes. The tenure gate fixed that going
      forward; it could do nothing about the ones already across, and nothing
      in the mod could undo a spark at all.

      DEPTH IS DELIBERATELY UNTOUCHED. Points and tier are what they earned
      together and none of that is in question - what is being corrected is the
      KIND of bond, not its size. Dropping points here would punish the NPC for
      our scheduling bug and would also be the one direction that is hard to
      justify to the player, who watched those points accumulate.

      THE WATERMARK RESET IS THE POINT, not an extra. Clearing the flag alone
      just lets them re-cross on the very next assessment, judged once more on
      the same accumulated history that crossed them the first time. Stamping
      SNRom_LastSparkCheck to NOW means the next judgment sees only what
      happens from here - which is the question actually worth asking.

      Safe to call on someone who never sparked; it just resets their window. }
    If akActor == None || !_ready
        Return
    EndIf
    String who = akActor.GetDisplayName()
    Bool was = StorageUtil.GetIntValue(akActor, "SNRom_Sparked", 0) == 1
    StorageUtil.UnsetIntValue(akActor, "SNRom_Sparked")
    StorageUtil.UnsetFloatValue(akActor, "SNRom_SparkedAt")
    ; Also clear the seeding exemption, or they skip the tenure gate and are
    ; re-judged within one tick instead of after the wait everyone else serves.
    StorageUtil.UnsetIntValue(akActor, "SNRom_SeedRomantic")
    StorageUtil.SetFloatValue(akActor, "SNRom_LastSparkCheck", Utility.GetCurrentGameTime())
    ; Re-arm the tenure gate from now, so they must travel together again before
    ; romance can even be considered. Without this, EnrolledAt is months old and
    ; the gate is already satisfied.
    StorageUtil.SetFloatValue(akActor, "SNRom_EnrolledAt", Utility.GetCurrentGameTime())
    If was
        Diag(LOG_INFO(), "Un-sparked " + who + " - back on the platonic ladder at tier " + \
            TierOf(akActor) + " with points intact. Spark window reset to now; " + \
            "the tenure gate must be served again before romance can be judged.")
    Else
        Diag(LOG_INFO(), "Spark window reset for " + who + " (was not sparked)")
    EndIf
EndFunction

; ---------------------------------------------------------------------------
; The player's stance
;
; ENDING A ROMANCE CAN BE ONE-SIDED; STARTING ONE CANNOT. The author's rule, and it
; exposed a flaw that was already shipping: the spark assessor deliberately
; judges ONE side ("it does not matter whether the player feels anything -
; unrequited is a real answer"), which is correct. But the moment it said YES,
; the bond prompt switched her to the romantic ladder, and by tier 4 that ladder
; says "you love them, and it is not a secret between you - speak to them as a
; lover, with claim". Her one-sided feeling became a mutual relationship and
; nobody ever asked the player.
;
; The lower romantic rungs were always fine - tier 0 is "you have not named it,
; even to yourself; say nothing of it directly", which is exactly right for
; unrequited. It is the top of the ladder that assumed an answer.
;
; So the spark is not the wrong mechanism, it was missing its counterpart. This
; is that counterpart, and it gates tier 4+ the same way romanceOk already does
; for orientation - the difference being WHY the door does not open: not "the
; shape of who you are" but "you asked, and they answered".
; ---------------------------------------------------------------------------
Int Function STANCE_DECLINED() Global
    Return -1
EndFunction
Int Function STANCE_UNANSWERED() Global
    Return 0
EndFunction
Int Function STANCE_ACCEPTED() Global
    Return 1
EndFunction

; ===========================================================================
; Points - ours (design 6.4, 8.4, 9.1; WP4, and the cut in 2.0)
;
; A bond's depth lives in THIS mod's co-save: StorageUtil Int SNRom_Points
; per actor, which rolls back with the save the way players expect. Romantasy
; is read once per actor, by the import, and never written.
;
; THREE RULES, and a grep proves each:
;   - PointsOf is how anything reads depth. Only RomantasyPoints reads
;     Romantasy's number, and only the import and PointsOf's read-through
;     for someone not yet imported call it.
;   - ApplyDepth is how anything CHANGES depth, and the consent gate for
;     earned awards lives inside it (9.1).
;   - StorePoints is the only write to SNRom_Points; ApplyDepth and
;     ImportPoints are its only callers, and each keeps SNRom_Bond's rank in
;     step (SyncBondRank).
; ===========================================================================

Int Function DEPTH_WITHHELD() Global
    { What ApplyDepth returns when the consent gate held an earned award
      short of Lover instead of writing it. Written is 1, refused 0. }
    Return -1
EndFunction

Int Function TierForPoints(Int aiPoints) Global
    { The tier, 0 Stranger to 5 Spouse, from points. Romantasy's own level
      is exactly this plus one (LevelNumberForPoints in its
      RomanceManager.cpp: 500 points a rung), so every "GetLevel - 1" the
      mod used to write is this function now. }
    If aiPoints >= 2500
        Return 5
    ElseIf aiPoints >= 2000
        Return 4
    ElseIf aiPoints >= 1500
        Return 3
    ElseIf aiPoints >= 1000
        Return 2
    ElseIf aiPoints >= 500
        Return 1
    EndIf
    Return 0
EndFunction

String Function TierName(Int aiTier) Global
    { The rung's name, as Romantasy's GetLevelName spelled it for the same
      points (LevelNameForPoints). The platonic track's own names are the
      dashboard's; this is the ladder the prompts and the log have always
      used. }
    If aiTier >= 5
        Return "Spouse"
    ElseIf aiTier == 4
        Return "Lover"
    ElseIf aiTier == 3
        Return "Confidant"
    ElseIf aiTier == 2
        Return "Friend"
    ElseIf aiTier == 1
        Return "Acquaintance"
    EndIf
    Return "Stranger"
EndFunction

Int Function TierOf(Actor akActor) Global
    Return TierForPoints(PointsOf(akActor))
EndFunction

Bool Function RomantasyReadable() Global
    { Whether Romantasy may be called at all this session: StartPointsImport
      asked Game.IsPluginInstalled, which cannot fail the way a call to a
      missing native does. EVERY Romantasy call in this mod is behind it. }
    Return StorageUtil.GetIntValue(None, "SNRom_RomantasyReadable", 0) == 1
EndFunction

Int Function RomantasyPoints(Actor akActor) Global
    { THE ONE READ OF ROMANTASY'S NUMBER, for the import and for PointsOf's
      read-through before it. 0 when Romantasy is not installed, without
      calling it. }
    If !RomantasyReadable()
        Return 0
    EndIf
    Return Romantasy.GetPoints(akActor)
EndFunction

Bool Function PointsImported(Actor akActor) Global
    Return akActor != None && StorageUtil.GetIntValue(akActor, "SNRom_PointsImported", 0) == 1
EndFunction

Int Function PointsOf(Actor akActor) Global
    { A bond's depth. Ours once the actor is imported.

      BEFORE THE IMPORT, ROMANTASY'S NUMBER where it is installed, read
      through and never written here: until then Romantasy holds the only
      copy, and returning 0 would make every gate think a long bond had just
      begun. The one-time import, or the first change (ApplyDepth), brings
      them over. Without Romantasy, 0 - which the import then adopts. }
    If akActor == None
        Return 0
    EndIf
    If StorageUtil.GetIntValue(akActor, "SNRom_PointsImported", 0) == 1
        Return StorageUtil.GetIntValue(akActor, "SNRom_Points", 0)
    EndIf
    Return RomantasyPoints(akActor)
EndFunction

Function StorePoints(Actor akActor, Int aiPoints)
    { THE ONLY WRITE TO SNRom_Points. Callers: ApplyDepth and ImportPoints. }
    StorageUtil.SetIntValue(akActor, "SNRom_Points", aiPoints)
EndFunction

Function SyncBondRank(Actor akActor)
    { SNRom_Bond's rank IS the tier, for everything that reads bond state
      without Papyrus. Called after every write of the points, never between
      a write and its stamp (SetFactionRank waits a frame). Only for the
      enrolled: membership is enrollment, and SetFactionRank would add them. }
    If _bond != None && IsEnrolled(akActor)
        akActor.SetFactionRank(_bond, TierOf(akActor))
    EndIf
EndFunction

Function AnnounceTier(Actor akActor, Int aiFrom, Int aiTo, String asKind, String asReason)
    { A bond crossed a tier, up or down. The author's rule (2026-10-01,
      design question 4), in two halves:

      ON SCREEN, FOR THE PLAYER, up and down - but never in combat, in an
      OStim or SexLab scene, or while paused. Worded here and handed to the
      DLL, which holds it until the player can see it (native/src/Notices.h)
      and sends it back to OnShowNotice. Without the DLL, shown at once.

      IN THEIR HEAD, FOR THE CHARACTER ALONE: a private thought
      (SkyrimNetApi.GenerateNPCThought), which surfaces in their own later
      prompts. Nobody nearby hears anything - Romantasy's narration trigger
      is gone. ThoughtHint words it, and says nothing for the changes that
      are not a change of heart.

      The tier is named on the track the player is shown (ShownTierName), so
      a feeling nobody has spoken is not announced as one. }
    String name = akActor.GetDisplayName()
    String tier = ShownTierName(akActor, aiTo)
    String text = ""
    If asKind == "seed"
        text = "Your history with " + name + " reads as " + tier
    ElseIf aiTo > aiFrom
        text = "Your bond with " + name + " deepened: " + tier
    Else
        text = "Your bond with " + name + " cooled: " + tier
    EndIf
    If _dashNatives >= 5
        SNRom_Native.Announce(text)
    Else
        Debug.Notification(text)
    EndIf
    String hint = ThoughtHint(asKind, aiTo > aiFrom, asReason)
    If hint != ""
        Int rc = SkyrimNetApi.GenerateNPCThought(akActor, hint)
        If rc != 0
            Diag(LOG_WARN(), "Tier thought for " + name + " was not generated (rc=" + rc + \
                "); the change stands, only the private thought is missing.", True)
        EndIf
    EndIf
    ; QUIET: with logNotifications on, a loud line would put the notice on
    ; screen at once, through the mirror, and the hold would be for nothing.
    Diag(LOG_INFO(), "Tier " + aiFrom + " -> " + aiTo + " for " + name + " (" + asKind + "): '" + text + "'", True)
EndFunction

String Function ShownTierName(Actor akActor, Int aiTier)
    { The tier's name on the track the PLAYER is shown, by the dashboard's
      rule (native/src/Model.cpp, Track): the romantic ladder only for a
      mutual romance or a recorded engagement or marriage; the friendship
      ladder otherwise - including for a feeling nobody has spoken. Reads
      MARAS and the applicability, which wait for frames: only on a tier
      change. }
    Bool romantic = False
    If SNRom_Decorators.RomanceApplicability(akActor) == 0
        romantic = (SNRom_Decorators.IsSparked(akActor) && \
            StorageUtil.GetIntValue(akActor, "SNRom_PlayerStance", 0) == STANCE_ACCEPTED()) || \
            CommitmentState(akActor) >= 2
    EndIf
    If romantic
        Return TierName(aiTier)
    EndIf
    If aiTier >= 5
        Return "Best Friend"
    ElseIf aiTier == 4
        Return "Ally"
    EndIf
    Return TierName(aiTier)
EndFunction

String Function ThoughtHint(String asKind, Bool abUp, String asReason)
    { What the character privately notices when their bond crosses a tier, or
      "" for no thought: a seed or an import is a reading, not a change of
      heart; a spark has its own thought (ApplySpark); a marriage is its own
      event. No tier names - those are the player's bookkeeping, not how
      anyone thinks of someone. }
    If asKind == "seed" || asKind == "import" || asKind == "spark" || asKind == "married" || \
       asKind == "ceiling"
        Return ""
    EndIf
    String player = Game.GetPlayer().GetDisplayName()
    If asKind == "accepted"
        Return player + " has said yes to what is between you. Let it settle in: you are not only hoping now."
    ElseIf asKind == "declined"
        Return player + " has turned you down. It stings, and you hold yourself a little further off than you did."
    ElseIf asKind == "ended"
        Return "It is over between you and " + player + ". " + asReason
    ElseIf asKind == "released"
        If abUp
            Return "You realise " + player + " has come to matter more to you than before."
        EndIf
        Return ""
    EndIf
    If abUp
        Return "You realise " + player + " has come to matter more to you than before. What brought it home: " + asReason
    EndIf
    Return "Something has cooled between you and " + player + "; you hold them a little further off than you did. " + \
        "What did it: " + asReason
EndFunction

Event OnShowNotice(String asEventName, String asText, Float afNumArg, Form akSender)
    { The DLL's go-ahead for a held tier notice (AnnounceTier): the player is
      out of combat, out of a scene and not paused. }
    If asText != ""
        Debug.Notification(asText)
    EndIf
EndEvent

Function RecordHistory(Actor akActor, String asKind, Int aiDelta, Int aiTotal, String asReason)
    { One change to a bond, for the dashboard's history: kept by the DLL in
      the co-save, so it rolls back with the save (native/src/History.h).
      Called by ApplyDepth and ImportPoints only. One native, callable from
      tasklets, so it does not wait a frame. Without the DLL nothing is kept,
      and nothing else depends on it. }
    If _dashNatives >= 5 && akActor != None
        SNRom_Native.RecordChange(akActor, asKind, aiDelta, aiTotal, asReason)
    EndIf
EndFunction

Function JoinBondFaction(Actor akActor)
    { Enrollment's mark on the actor itself: into SNRom_Bond, at their tier.
      The caller sets SNRom_Enrolled, which is what the mod reads. }
    If _bond == None || akActor == None
        Return
    EndIf
    akActor.AddToFaction(_bond)
    akActor.SetFactionRank(_bond, TierOf(akActor))
EndFunction

Bool Function ImportPoints(Actor akActor, String asWhen)
    { Make one actor's points ours, and stamp them (design 8.4).

      WITH ROMANTASY: copied exactly. Verified before the stamp: ours read
      back, and Romantasy read again, must both equal what was copied. A
      mismatch is an ERROR and leaves them unstamped, still reading
      Romantasy's number, to be tried again.

      WITHOUT IT: adopted at 0, and unseeded, so the next seed reads them
      from their history instead (8.3: "the playthrough is simply un-migrated
      and everyone is seeded from the record"). For someone enrolled in 2.0,
      who never had Romantasy points, that is simply where a bond starts.

      Returns True when they are ours, including already. }
    If akActor == None
        Return False
    EndIf
    If PointsImported(akActor)
        Return True
    EndIf
    If !RomantasyReadable()
        StorePoints(akActor, 0)
        StorageUtil.SetIntValue(akActor, "SNRom_PointsImported", 1)
        StorageUtil.UnsetIntValue(akActor, "SNRom_Seeded")
        SyncBondRank(akActor)
        ; Lines only for someone the one-time import started over, whose
        ; history this explains. Anyone enrolled in 2.0 simply starts at 0, and
        ; an "import" row naming Romantasy would be wrong for every one of them.
        If asWhen == "in the one-time import"
            RecordHistory(akActor, "import", 0, 0, "Started over: Romantasy was not installed")
            Diag(LOG_INFO(), akActor.GetDisplayName() + "'s points start from 0 " + asWhen + \
                " (no Romantasy to bring them from); the next seed reads them from their history.", True)
            LedgerRow(akActor, "import", "", 0, 1, "Started from 0 without Romantasy")
        Else
            Diag(LOG_INFO(), akActor.GetDisplayName() + "'s bond starts at 0 pts.", True)
        EndIf
        Return True
    EndIf
    ; READ TWICE, THEN WRITE AND STAMP WITH NOTHING BETWEEN. Romantasy's read
    ; waits a frame, and while it waits another stack can run - an award whose
    ; ApplyDepth imports this same actor and writes. So the stamp is checked
    ; again after each read: if someone else brought them over, their write
    ; stands and this one does nothing. The write, the stamp and the
    ; read-back are StorageUtil calls, which do not wait, so no other stack can
    ; land between them.
    Int theirs = RomantasyPoints(akActor)
    Int again = RomantasyPoints(akActor)
    If PointsImported(akActor)
        Return True
    EndIf
    If again != theirs
        Diag(LOG_ERROR(), "Import of " + akActor.GetDisplayName() + " did not verify: Romantasy read " + \
            theirs + " then " + again + " while it was being copied. Left unstamped; tried again next time.")
        Return False
    EndIf
    StorePoints(akActor, theirs)
    StorageUtil.SetIntValue(akActor, "SNRom_PointsImported", 1)
    Int ours = StorageUtil.GetIntValue(akActor, "SNRom_Points", -1)
    If ours != theirs
        StorageUtil.UnsetIntValue(akActor, "SNRom_PointsImported")
        Diag(LOG_ERROR(), "Import of " + akActor.GetDisplayName() + " did not verify: wrote " + theirs + \
            ", read back " + ours + ". Left unstamped; tried again next time.")
        Return False
    EndIf
    SyncBondRank(akActor)
    ; Only when there was something to bring: Romantasy answers 0 for a new
    ; companion it never tracked, which is just where their bond starts.
    If theirs > 0
        RecordHistory(akActor, "import", theirs, theirs, "Brought over from Romantasy")
    EndIf
    ; Quiet: the one-time import writes this for every character, and the
    ; notification mirror would queue one toast each (reported on the first
    ; WP4 test). The pass's summary and its Say are what the player sees.
    Diag(LOG_INFO(), "Brought " + akActor.GetDisplayName() + " over " + asWhen + ": Romantasy " + \
        theirs + " -> ours " + ours + " pts.", True)
    LedgerRow(akActor, "import", "", theirs, 1, "Brought over from Romantasy")
    Return True
EndFunction

Int Function ApplyDepth(Actor akActor, Int aiDelta, String asReason, Bool abShowLevelUp, String asKind)
    { THE ONE PLACE A BOND'S DEPTH CHANGES (design 9.1). Every award, seed,
      release, setback and clamp comes through here, and nothing else
      writes SNRom_Points.

      THE CONSENT GATE LIVES HERE, FOR EVERY INCREASE (2.0, design 9.2):
      HoldShortOfLover withholds and banks anything that would carry an
      unanswered romance into Lover, and this returns DEPTH_WITHHELD instead
      of writing. In 1.x it guarded earned awards only, with a reactive
      ceiling behind it for the rest - Romantasy's own scoring among them -
      and that ceiling's clawbacks were the splashes and refusals 2.0 set out
      to end. With every write here, one preventive check covers them all.
      The single exception is a marriage ("married"): the proposal and its
      acceptance ARE the answer.

      abShowLevelUp: whether a tier this change crosses is announced - on
      screen when the player can see it, and to the character alone as a
      private thought (AnnounceTier).

      asKind: what happened, in one word ("moment", "talk", "seed"...), for
      the bond's history (RecordHistory): every change that lands, and every
      earned award the gate withholds, is recorded here, so the history can
      never miss one the way the ledger missed seeds and marriages.

      NEVER REFUSED FOR WHERE SOMEONE IS. The one refusal is an actor whose
      Romantasy points could not be verified mid-copy (ImportPoints), because
      writing 0 plus the change would lose what Romantasy holds.

      Returns 1 written, DEPTH_WITHHELD, or 0 refused. }
    If akActor == None
        Return 0
    EndIf
    If !PointsImported(akActor) && !ImportPoints(akActor, "at its first change")
        Return 0
    EndIf
    If asKind != "married" && HoldShortOfLover(akActor, aiDelta)
        RecordHistory(akActor, "withheld", aiDelta, StorageUtil.GetIntValue(akActor, "SNRom_Points", 0), asReason)
        Return DEPTH_WITHHELD()
    EndIf
    If aiDelta == 0
        Return 1
    EndIf
    ; Never below zero, as Romantasy clamped (max(0, points + delta)).
    Int was = StorageUtil.GetIntValue(akActor, "SNRom_Points", 0)
    Int now = was + aiDelta
    If now < 0
        now = 0
    EndIf
    StorePoints(akActor, now)
    SyncBondRank(akActor)
    If now != was
        RecordHistory(akActor, asKind, now - was, now, asReason)
        Int fromTier = TierForPoints(was)
        Int toTier = TierForPoints(now)
        If abShowLevelUp && fromTier != toTier
            AnnounceTier(akActor, fromTier, toTier, asKind, asReason)
        EndIf
    EndIf
    Return 1
EndFunction

Function StartPointsImport()
    { Bootstrap. The two one-time passes a save needs on its way to 2.0, on
      their own stack via a ModEvent, so a large roster never holds up the
      rest of the bootstrap (OnImportPoints). Also records whether Romantasy
      can be read at all this session (RomantasyReadable).

      POINTS ONLY. Romantasy's likes and dislikes are not brought over: they
      name game statistics ("Dungeons Cleared"), routing on them fired once in
      180 awards (design 4.0), and phase 5 re-authors everyone's preferences
      against our own vocabulary. The author decided 2026-09-30 that nothing
      of Romantasy's preferences carries into Relationships. }
    ; The faction FIRST: && short-circuits, so GetApiVersion is never called
    ; when Romantasy is absent - nor when a header-only stub of its plugin
    ; stands in so a save that needed it still loads. The stub has no records,
    ; and Romantasy's scripts are gone with the rest of it.
    Bool readable = RomantasyFaction() != None && Romantasy.GetApiVersion() > 0
    StorageUtil.SetIntValue(None, "SNRom_RomantasyReadable", readable as Int)
    If StorageUtil.GetIntValue(None, "SNRom_Migrated", 0) == 1 && \
       StorageUtil.GetIntValue(None, "SNRom_BondFactionPass", 0) == 1 && \
       StorageUtil.GetIntValue(None, "SNRom_AuthoredFlagPass", 0) == 1 && \
       StorageUtil.GetIntValue(None, "SNRom_LoverLinePass", 0) == 1
        Return
    EndIf
    SendModEvent("SNRom_ImportPoints")
EndFunction

Event OnImportPoints(String asEventName, String asStrArg, Float afNumArg, Form akSender)
    { The one-time passes, in order: the points import (ImportEveryone), the
      move into SNRom_Bond (MoveToBondFaction), and the repair of the
      authored flag (RepairAuthoredFlags). Each is stamped only when it
      finished, so an interrupted one resumes on the next load. }
    If _importing
        Return
    EndIf
    _importing = True
    If StorageUtil.GetIntValue(None, "SNRom_Migrated", 0) != 1
        ImportEveryone()
    EndIf
    If StorageUtil.GetIntValue(None, "SNRom_BondFactionPass", 0) != 1
        MoveToBondFaction()
    EndIf
    If StorageUtil.GetIntValue(None, "SNRom_AuthoredFlagPass", 0) != 1
        RepairAuthoredFlags()
    EndIf
    ; After the import, so the points it reads are ours.
    If StorageUtil.GetIntValue(None, "SNRom_LoverLinePass", 0) != 1 && \
       StorageUtil.GetIntValue(None, "SNRom_Migrated", 0) == 1
        RestoreLoverLine()
    EndIf
    _importing = False
EndEvent

Function ImportEveryone()
    { The one-time import itself (design 8.4). Resumable, never repeated:
      whoever is already stamped is skipped, and SNRom_Migrated - written
      only once every roster member is stamped and verified - stops
      it running on any save made afterwards.

      A save made BEFORE the import has no stamp and genuinely has not been
      brought over, so it is, once, from its own numbers. The playthrough's
      store remembers an import happened, which is how its notification says
      "an older save" rather than looking like a repeat.

      WITHOUT ROMANTASY everyone is adopted at 0 and re-read from their
      history as the seed reaches them (ImportPoints). Loud, because the only
      way back is a save from before it, loaded with Romantasy installed. }
    Bool readable = RomantasyReadable()
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int brought = 0
    Int already = 0
    Int failed = 0
    Int skipped = 0
    Int i = 0
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        ; THE DEAD ARE BROUGHT OVER TOO. Their points are the history the
        ; dashboard shows, and after the cut Romantasy's copy is gone. The
        ; first WP4 test build skipped them.
        If a == None
            skipped += 1
        ElseIf PointsImported(a)
            already += 1
        ElseIf ImportPoints(a, "in the one-time import")
            brought += 1
        Else
            failed += 1
        EndIf
        i += 1
    EndWhile
    If failed > 0
        Diag(LOG_ERROR(), "Import incomplete: " + failed + " did not verify and keep reading " + \
            "Romantasy's number until the next load tries again. " + brought + " brought over.")
        Return
    EndIf
    StorageUtil.SetIntValue(None, "SNRom_Migrated", 1)
    String store = StoreFile()
    Bool before = JsonUtil.GetIntValue(store, "SNRom_PointsImportedOnce", 0) == 1
    JsonUtil.SetIntValue(store, "SNRom_PointsImportedOnce", 1)
    JsonUtil.Save(store)
    Int total = brought + already
    If !readable
        Diag(LOG_WARN(), "Import done WITHOUT Romantasy: " + brought + " start from 0 and are re-read " + \
            "from their history as the seed reaches them; " + already + " were already ours, " + skipped + \
            " skipped (no longer in the game). To bring Romantasy's points over instead, load a save " + \
            "from before this one with Romantasy installed.")
        If brought > 0
            Say("Romantasy isn't installed, so " + brought + " companions start over and are re-read from their history.")
        EndIf
        Return
    EndIf
    Diag(LOG_INFO(), "Import done: " + brought + " brought over, " + already + " already ours, " + \
        skipped + " skipped (no longer in the game). Nobody brought over is read from Romantasy again; " + \
        "anyone enrolled later is brought over at their first change.")
    If brought > 0
        If before
            Say("An older save: brought " + total + " companions over from Romantasy, from this save's own points.")
        Else
            Say("Brought " + total + " companions over from Romantasy.")
        EndIf
    EndIf
EndFunction

Function RestoreLoverLine()
    { ONE-TIME (SNRom_LoverLinePass), for a save from 1.x: puts any
      unanswered romance standing above the Lover line back on it, holding
      the difference for the answer exactly as the gate does.

      1.x pulled such a bond back with a reactive ceiling after Romantasy's own
      scoring carried it over - and Romantasy refused the pull-back for anyone
      not following, hundreds of times for Iddra and Irgnir. So a 1.x save can
      arrive with an unanswered romance at Lover, the one crossing the
      question exists to govern. From 2.0 nothing can carry one over
      (ApplyDepth withholds), so once is enough.

      A declined companion past the line is reopened first, as the gate does,
      so the question comes back to them as it would have. }
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int restored = 0
    Int i = 0
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None && PointsOf(a) > UNANSWERED_MAX()
            ReopenIfClimbedBack(a, 0)
            Bool sparked = SNRom_Decorators.IsSparked(a)
            If StorageUtil.GetIntValue(a, "SNRom_PlayerStance", 0) == STANCE_UNANSWERED() && \
               (sparked || !SparkDecided(a))
                Int over = PointsOf(a) - UNANSWERED_MAX()
                ; A decrease, so the gate never holds it; recorded like any
                ; change, for the developer view (labels.js CHANGE.ceiling).
                If ApplyDepth(a, -over, "Held at the Lover line until you answer", False, "ceiling") > 0
                    StorageUtil.SetIntValue(a, "SNRom_BankedPoints", \
                        StorageUtil.GetIntValue(a, "SNRom_BankedPoints", 0) + over)
                    If sparked
                        StorageUtil.SetIntValue(a, "SNRom_AskPending", 1)
                    EndIf
                    restored += 1
                    Diag(LOG_INFO(), a.GetDisplayName() + " stood " + over + " pts past the Lover line " + \
                        "unanswered; put back at " + UNANSWERED_MAX() + " and the " + over + " held for the answer.", True)
                EndIf
            EndIf
        EndIf
        i += 1
    EndWhile
    StorageUtil.SetIntValue(None, "SNRom_LoverLinePass", 1)
    If restored > 0
        Diag(LOG_INFO(), restored + " unanswered romances were past the Lover line from 1.x and are back " + \
            "on it, their difference held for the answer.")
    EndIf
EndFunction

Function RepairAuthoredFlags()
    { ONE-TIME (SNRom_AuthoredFlagPass): marks as authored every companion
      whose character was written but whose SNRom_DispositionAuthored says
      otherwise. Found on the 2.0 dashboard, which drew 12 of 122 as
      "not authored yet" while their characters were plainly there.

      Two 1.x paths left it wrong:
      - the character-only re-author never set the flag, so a companion
        wiped with ClearDisposition during development (flag 0) and then
        re-authored that way kept 0 - ten of the twelve;
      - a failed re-author marked an intact character 2, "archetype" -
        fixed at the source in ApplyArchetype.

      THE FLAG IS NOT COSMETIC: the dashboard, BuildCircle and drift all read
      it, so those companions showed as defaults, were left out of the circle
      a new character is made distinct from, and never drifted.

      Evidence of a written character: any character field stored -
      ClearDisposition unsets every one of them, so one present means a
      character was written after it - or a WHY in the store, the evidence
      AuthorDisposition already trusts. StorageUtil and JsonUtil reads only,
      so the walk does not wait on frames. }
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int repaired = 0
    Int i = 0
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None && StorageUtil.GetIntValue(a, "SNRom_DispositionAuthored", 0) != 1
            Bool written = StorageUtil.HasIntValue(a, "SNRom_PhysMinTier") || \
                StorageUtil.HasIntValue(a, "SNRom_Ardor") || \
                StorageUtil.HasIntValue(a, "SNRom_Exclusivity") || \
                StorageUtil.HasIntValue(a, "SNRom_Orientation")
            If written || StoreGetText(a, "Why") != ""
                Int was = StorageUtil.GetIntValue(a, "SNRom_DispositionAuthored", 0)
                StorageUtil.SetIntValue(a, "SNRom_DispositionAuthored", 1)
                repaired += 1
                Diag(LOG_INFO(), a.GetDisplayName() + "'s character was written but marked " + was + \
                    "; marked authored.", True)
            EndIf
        EndIf
        i += 1
    EndWhile
    StorageUtil.SetIntValue(None, "SNRom_AuthoredFlagPass", 1)
    Diag(LOG_INFO(), "Authored flag repaired for " + repaired + " companions whose characters were " + \
        "written but not marked: the dashboard shows them as authored, and they can drift and be " + \
        "compared against again.")
EndFunction

Function MoveToBondFaction()
    { THE CUT'S LAST ACT FOR EACH COMPANION (design 8.1): into SNRom_Bond at
      their tier, and out of ROM_RomanceLevel, the faction 1.x put them in.
      Otherwise a Romantasy left installed keeps scoring them from its own
      economy and splashing its own tier names over a bond it no longer
      holds. That undoes our own enrollment; it writes nothing of Romantasy's.

      ONLY ONCE THEIR POINTS ARE OURS. Romantasy tracks by that faction, and
      nothing says what it does with a record it stops tracking, so anyone
      whose import has not verified keeps it, and the pass is not stamped
      until the next load finishes them.

      Also sets SNRom_Enrolled for the whole roster: that flag is what the
      mod reads for enrollment from 2.0 (IsEnrolled), and companions enrolled
      before it existed never had it. The roster is exactly the enrolled -
      UnenrollActor takes them off it. }
    Faction rom = RomantasyFaction()
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int moved = 0
    Int released = 0
    Int waiting = 0
    Int i = 0
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None
            StorageUtil.SetIntValue(a, "SNRom_Enrolled", 1)
            JoinBondFaction(a)
            moved += 1
            If rom != None && a.IsInFaction(rom)
                If PointsImported(a)
                    a.RemoveFromFaction(rom)
                    released += 1
                Else
                    waiting += 1
                EndIf
            EndIf
        EndIf
        i += 1
    EndWhile
    If waiting > 0
        Diag(LOG_WARN(), "Moved " + moved + " into SNRom_Bond; " + waiting + " stay in Romantasy's faction " + \
            "until their points are ours, and the pass runs again on the next load.")
        Return
    EndIf
    StorageUtil.SetIntValue(None, "SNRom_BondFactionPass", 1)
    Diag(LOG_INFO(), "Moved " + moved + " companions into SNRom_Bond at their tiers; " + released + \
        " released from Romantasy's faction, which no longer tracks them.")
EndFunction

Int Function UNANSWERED_MAX() Global
    { The most an UNANSWERED romance may hold: one point below Lover.

      CORRECTED 2026-09-01. This returned 2499 - one below SPOUSE - on the
      reasoning that the gate should bite where marriage becomes eligible. That
      was the wrong rung, and the author, who designed the ladder, restated it:

        1. Stranger to Confidant: natural progression, no gate.
        2. Crossing into LOVER pops the consent question. Yes -> Lover. No ->
           mid-Friend. Undecided -> held below Lover, asked again later.
        3. Lover to Spouse: natural progression, NO GATE. Crossing into Spouse
           is what makes a formal marriage proposal eligible.

      At 2499 an unanswered romance could occupy the whole of Lover, which is the
      one rung the answer is supposed to govern. The question fired at 2000 and
      then nothing stopped her sitting at 2400 unanswered - a realized romance in
      everything except the record of consent.

      AND THERE IS NO CONSENT GATE AT SPOUSE. A formal proposal and its
      acceptance ARE the consent to marry, and that proposal only becomes
      possible at Spouse. Gating Spouse as well asked the same question twice and
      made the second asking ours rather than the marriage system.

      NOTHING CROSSES IT UNANSWERED from 2.0: ApplyDepth withholds any
      increase that would (HoldShortOfLover), and CheckRomanceQuestion reads
      points PLUS the bank, so the question is owed the moment a withheld
      amount would have carried them over. }
    Return LOVER_MIN() - 1
EndFunction
Bool Function HoldShortOfLover(Actor akActor, Int aiDelta)
    { Should this increase be WITHHELD instead of written? Returns True when
      writing it would carry an unanswered romance from Confidant into Lover.

      FROM 2.0 IT GUARDS EVERY INCREASE, not only earned awards: ApplyDepth
      asks it for each one but a marriage. The 1.x rule below was the
      author's answer to Romantasy scoring on its own, and its reactive
      backstop is gone with Romantasy.

      WITHHELD, NOT WRITTEN-THEN-CORRECTED, and that is the whole point of this
      function. EnforceLoverCeiling has always clawed back after the fact, which
      was invisible while the ceiling sat at 2499 - nothing reached it. Moving the
      ceiling to just under Lover made the correction fire at the crossing for the
      first time and exposed what it costs: Romantasy received 2009, announced
      LOVER, then received -10 and announced Confidant again. The player watched a
      promotion appear and be revoked, and anything reacting to Romantasy's
      tier-change event saw the same false crossing.

      THE AUTHOR'S RULE, and it is deliberately narrow: there is exactly ONE
      moment in normal play where points should not reach Romantasy, and it is
      this one. Everything else - seeding, transfers, ruptures, the Spouse rung -
      writes normally. So this is a targeted check at the earning paths rather
      than a wrapper around every point change, and EnforceLoverCeiling stays
      behind it as a backstop for anything that slips past.

      WHAT HAPPENS TO THE WITHHELD AWARD depends on the answer, and two of the
      three throw it away:
        accepted - granted in full, so the wait costs nothing
        declined  - discarded, because they are dropping to mid-Friend anyway
        deferred  - discarded, and they stay exactly where they are

      Only bites while SPARKED and UNANSWERED, same as the ceiling: a platonic
      bond has no question to answer and must be free to reach Spouse-tier depth. }
    If akActor == None || !_ready || aiDelta <= 0
        Return False
    EndIf
    ; Before the stance test: a declined companion whose award would carry
    ; them back over the line becomes unanswered HERE, so this award is held
    ; and banked like the first time's rather than written and clawed back.
    ReopenIfClimbedBack(akActor, aiDelta)
    If StorageUtil.GetIntValue(akActor, "SNRom_PlayerStance", 0) != STANCE_UNANSWERED()
        Return False
    EndIf
    ; THREE STATES, NOT TWO, and this is the fix for Jarl Laila Law-Giver
    ; crossing into Lover unasked on 2026-09-05.
    ;
    ;   sparked + unanswered  -> hold, and ask the player
    ;   judged platonic       -> let it climb; a friendship owes no answer and
    ;                            must be free to reach Spouse-tier depth
    ;   NOT YET JUDGED        -> hold, and ask the ASSESSOR
    ;
    ; The third state used to fall through to "not sparked, so no question to
    ; answer" and wrote the points. That is right for a bond somebody looked at
    ; and called platonic, and wrong for one nobody has looked at yet. Laila was
    ; enrolled, seeded to 1999 from a diary describing physical intimacy, and
    ; given a 10-point talk award 0.2 game days later - all before the tenure
    ; gate would let the spark assessor near her. She arrived at Lover with the
    ; consent question never raised, which is the one crossing this mod exists
    ; to put a question in front of.
    Bool sparked = SNRom_Decorators.IsSparked(akActor)
    If !sparked && SparkDecided(akActor)
        Return False                            ; judged platonic; depth is free
    EndIf
    Int held = PointsOf(akActor)
    If held + aiDelta <= UNANSWERED_MAX()
        Return False                            ; does not reach the crossing
    EndIf
    ; Hold the withheld amount so acceptance can grant it. Accumulates across
    ; awards only if the player never answers, and both non-acceptance answers
    ; clear it.
    StorageUtil.SetIntValue(akActor, "SNRom_BankedPoints", \
        StorageUtil.GetIntValue(akActor, "SNRom_BankedPoints", 0) + aiDelta)
    If sparked
        ; Level-triggered, so it cannot be lost - but the crossing has not
        ; happened, so ask on the strength of what WOULD have landed rather than
        ; on the total.
        StorageUtil.SetIntValue(akActor, "SNRom_AskPending", 1)
        Diag(LOG_INFO(), "Held " + aiDelta + " pts short of Lover for " + \
            akActor.GetDisplayName() + " - " + held + " + " + aiDelta + " would cross " + \
            UNANSWERED_MAX() + " with the question unanswered. Held, so no tier change - " + \
            "granted in full on yes, discarded otherwise.")
    Else
        ; NO ASK PENDING HERE. The consent question presupposes a spark - asking
        ; "do you want this to become romantic" of a bond nobody has judged puts
        ; the second question first. Ask the assessor instead; whichever way it
        ; answers, ApplySpark or the NO branch settles what happens to the bank.
        Diag(LOG_INFO(), "Held " + aiDelta + " pts short of Lover for " + \
            akActor.GetDisplayName() + " - " + held + " + " + aiDelta + " would cross " + \
            UNANSWERED_MAX() + " and the spark has not been judged yet. Asking the " + \
            "assessor first; held, so no tier change.")
        RequestSparkNow(akActor)
    EndIf
    Return True
EndFunction



Function AcceptRomance(Actor akActor)
    { The player says yes. Only this opens tier 4+ as a realized romance. }
    SetStance(akActor, STANCE_ACCEPTED(), "accepted")
    If akActor == None || !_ready
        Return
    EndIf
    ; Release whatever the gate held back. Doing this AFTER the stance write
    ; matters: HoldShortOfLover reads the stance, and ApplyDepth asks it for
    ; every increase, so releasing first would be held straight back again.
    Int banked = StorageUtil.GetIntValue(akActor, "SNRom_BankedPoints", 0)
    If banked <= 0
        Return
    EndIf
    ; NOT ScaleAward: the other half of the ceiling round trip. The player watched
    ; these accrue and was promised them back, whole.
    ;
    ; THE BANK IS CLEARED ONLY ONCE THE RELEASE HAS LANDED. It used to be
    ; cleared first, so when Romantasy refused - anyone not following at the
    ; moment of the yes - the banked points were simply gone. Ours does not
    ; refuse for that; if the write fails at all, the bank stays for the next
    ; acceptance path to try.
    If ApplyDepth(akActor, banked, "What was held while the question waited", True, "accepted") > 0
        StorageUtil.UnsetIntValue(akActor, "SNRom_BankedPoints")
        Ledger(akActor, "unbank", "", banked, 1, "Released on acceptance")
        Diag(LOG_INFO(), "Released " + banked + " banked pts to " + akActor.GetDisplayName() + \
            " on acceptance -> " + PointsOf(akActor) + " pts, tier " + \
            TierOf(akActor) + ". The waiting cost her nothing.")
    Else
        Diag(LOG_ERROR(), "Could not release " + banked + " banked pts to " + akActor.GetDisplayName() + \
            " - their points are not ours yet. The bank is kept.")
    EndIf
EndFunction

Int Function FRIEND_MID() Global
    { Middle of tier 2, "Friend", which spans 1000-1499.

      Where a declined romance lands. From the 2000 crossing that is a 750
      point setback - about nineteen talk awards at the REAL 40 these have been
      scoring - so working back to the question takes real shared road rather
      than an evening. The author's call, and deliberately harsher than the
      Confidant cap an ENDED romance gets: being turned down when you asked is
      not the same as a relationship running its course. }
    Return 1250
EndFunction

Function DeclineRomance(Actor akActor)
    { The player says no, kindly or otherwise.

      DOES NOT CLEAR HER FEELINGS. The spark stays, the disposition stays, and
      the question comes back by itself: ReopenIfClimbedBack makes it live
      again when she climbs back to Lover, exactly as the first time (1.8.1).
      A no is an answer for now, not forever - people reconsider.

      IT DOES LOWER THE BOND, and that is a deliberate reversal of the original
      design (2026-08-08). The first version left depth untouched on the
      reasoning that "she still feels what she feels and they are still as
      close as they were". True of the feeling, false of the relationship: a
      follower who is turned down and stays one award short of asking again
      makes the refusal weightless, and the player would be asked again almost
      immediately. Dropping to the middle of Friend puts real distance back and
      gives the climb somewhere to go.

      Rejection is the one place lowering depth is justifiable to the player,
      because they caused it and they watched it happen. Contrast EndRomance,
      which only CAPS at Confidant - that path can fire from an assessment the
      player did not choose. }
    SetStance(akActor, STANCE_DECLINED(), "declined")
    If !_ready || akActor == None
        Return
    EndIf
    ; The bank dies with the refusal. It represents closeness that was heading
    ; somewhere, and it is not heading there now - releasing it would undo most
    ; of the setback below and put her back at the question within an evening,
    ; which is the opposite of what a refusal should cost.
    StorageUtil.UnsetIntValue(akActor, "SNRom_BankedPoints")
    String who = akActor.GetDisplayName()
    Int had = PointsOf(akActor)
    Int drop = FRIEND_MID() - had
    If drop >= 0
        Diag(LOG_INFO(), who + " was turned down at " + had + " pts - already at or below " + \
            FRIEND_MID() + ", so depth is unchanged.")
        Return
    EndIf
    If ApplyDepth(akActor, ScaleAward(drop), "Turned down", True, "declined") > 0
        Ledger(akActor, "declined", "", drop, 1, "Turned down")
        Diag(LOG_INFO(), "Turned down " + who + ": " + had + " -> " + PointsOf(akActor) + \
            " pts, tier " + TierOf(akActor) + ". She keeps the spark and everything " + \
            "she believes; what she loses is the closeness that got her to the question.")
    Else
        Diag(LOG_ERROR(), "Could not apply the decline setback for " + who + " - stance is set but depth is unchanged")
    EndIf
EndFunction

Function ReopenRomance(Actor akActor)
    { Back to unanswered, so the question is live again. For the case the author
      described: turning someone down early and coming to feel differently
      after enough shared road. }
    SetStance(akActor, STANCE_UNANSWERED(), "reopened")
    ; Re-arm at once rather than waiting for the next point change to notice.
    ; Someone who is already deep and already sparked should have the question
    ; live again the moment it is reopened, not after the next award lands.
    CheckRomanceQuestion(akActor)
EndFunction

Bool Function ReopenIfClimbedBack(Actor akActor, Int aiIncoming)
    { A declined companion who climbs back to Lover is asked again, exactly as
      the first time. Returns True if it reopened them.

      THE AUTHOR'S RULE, 2026-09-28: "After decline, the question should simply
      be raised again once they progress back to the threshold of Lover. No
      reason for it to be different than the first time." Until 1.8.1 nothing
      did: CheckRomanceQuestion arms only an UNANSWERED stance, ReopenRomance
      had no caller anywhere, and HoldShortOfLover and EnforceLoverCeiling both
      stand down for DECLINED - so a declined companion climbed through Lover
      and Spouse depth unasked while 0330 told them never to raise it.

      SO THE STANCE GOES BACK TO UNANSWERED AT THE LINE, and every existing
      mechanism then does what it does the first time: the hold withholds and
      banks, the question is owed, the sweep raises it in their own words, and
      a second no drops them to mid-Friend again. No second code path, and
      nothing that can disagree with the first one.

      THE LINE IS THE SAME ONE both gates already use. HoldShortOfLover fires
      when held + incoming passes UNANSWERED_MAX; CheckRomanceQuestion when
      earned reaches LOVER_MIN, one point higher. Banked is zero for a declined
      companion (DeclineRomance discards it) and counted anyway, so this cannot
      drift from CheckRomanceQuestion if that ever changes.

      An old save already carrying a declined companion ABOVE Lover is reopened
      on its next point change or sweep, clamped like any unanswered romance,
      and asked. That is the first time's behaviour too, applied late. }
    If akActor == None || !_ready
        Return False
    EndIf
    If StorageUtil.GetIntValue(akActor, "SNRom_PlayerStance", 0) != STANCE_DECLINED()
        Return False
    EndIf
    If !SNRom_Decorators.IsSparked(akActor)
        Return False
    EndIf
    Int earned = PointsOf(akActor) + StorageUtil.GetIntValue(akActor, "SNRom_BankedPoints", 0)
    If earned + aiIncoming <= UNANSWERED_MAX()
        Return False
    EndIf
    Diag(LOG_INFO(), akActor.GetDisplayName() + " climbed back to Lover after being turned down (" + \
        earned + " + " + aiIncoming + " pts) - the question is live again, as the first time.")
    SetStance(akActor, STANCE_UNANSWERED(), "reopened on climbing back")
    Return True
EndFunction

Function SetStance(Actor akActor, Int aiStance, String asWord)
    If akActor == None || !_ready
        Return
    EndIf
    StorageUtil.SetIntValue(akActor, "SNRom_PlayerStance", aiStance)
    ; Any stance write settles the outstanding question, including a reopen -
    ; ReopenRomance re-arms it immediately afterwards via CheckRomanceQuestion,
    ; which is the same path a fresh crossing takes. Leaving it set here would
    ; have the sweep keep asking someone who has already answered.
    StorageUtil.UnsetIntValue(akActor, "SNRom_AskPending")
    Diag(LOG_INFO(), "Player stance toward " + akActor.GetDisplayName() + ": " + asWord + \
        " (tier " + TierOf(akActor) + ", sparked=" + \
        SNRom_Decorators.IsSparked(akActor) + "). Bond depth unchanged.")
EndFunction

Function AskTheQuestion(Actor akActor)
    { Puts the decision in front of the player and applies their answer.

      STEP 1 OF THE CONSENT LOOP, and deliberately the only part built so far.
      Dispatch it by hand via execute-quest-script-function with questEditorId
      SNRom_Quest, scriptName SNRom_Bridge, functionName AskTheQuestion and one
      hex FormID argument. (The JSON body is not written out here: a literal
      brace inside a Papyrus docstring CLOSES it, and the rest of the comment
      is then parsed as code. That is what "no viable alternative at character
      ':'" means, and it cost a build.)

      What it proves before anything is built on top: that SkyMessage's natives
      link at all, that a box reaches the screen, and that the chosen index
      comes back and moves the stance. Everything else in the loop - crossing
      detection, the trigger that has her raise it in her own voice, the retry
      timer, the decline penalty - hangs off this working.

      BLOCKING here, non-blocking later. AskNow parks this dispatched thread
      until the player answers or 60s passes, which is fine for a hand-fired
      test and wrong for the sweep. When this moves onto the follower sweep it
      switches to Open()/IsAnswered()/Take() so a menu left open cannot hold a
      script thread.

      BODY TEXT IS DIEGETIC ON PURPOSE. SkyrimNet captures message boxes as
      events - iActions' "<name> is asking for a drink..." box is in
      openrouter_input.log with its full button list and has_callback:true, and
      those events are read back by every NPC in scene. So this reads as
      something that happened between two people, not as UI addressed to a
      player. Nothing here mentions tiers, points, or stances. }
    If akActor == None || !_ready
        Return
    EndIf
    String who = akActor.GetDisplayName()
    ; ONE PARAGRAPH, NO FORCED BREAKS. The two newlines here used to split this
    ; into two blocks, and Skyrim's message box wrapped each of them on its own
    ; while most of the box width sat unused - it read as cramped text in a wide
    ; frame. The engine wraps well enough on its own; let it.
    String body = who + " has asked where the two of you stand. " + \
        "Whatever you answer, you will have answered it plainly."

    Int answer = SNRom_Choice.AskNow(body, \
        "Tell them you feel the same", \
        "Tell them you do not feel that way", \
        "Say nothing of it for now")

    If answer == SNRom_Choice.ANSWER_ACCEPT()
        AcceptRomance(akActor)
    ElseIf answer == SNRom_Choice.ANSWER_DECLINE()
        DeclineRomance(akActor)
    ElseIf answer == SNRom_Choice.ANSWER_DEFER()
        ; Left UNANSWERED on purpose - the question stays live and the retry
        ; timer will raise it again. Logged so a deferral is distinguishable
        ; from a box that never opened, which look identical from outside.
        ; DISCARD THE WITHHELD AWARD. The author's rule: on "unsure" the points
        ; that would have been awarded are dropped and the follower stays exactly
        ; where they are until the next opportunity. Only acceptance grants them.
        ; Without this the held amount accumulates across deferrals and a late yes
        ; pays out for every conversation the player declined to answer about.
        StorageUtil.UnsetIntValue(akActor, "SNRom_BankedPoints")
        Diag(LOG_INFO(), "Question deferred for " + who + " - stance left unanswered, still open.")
    Else
        ; ANSWER_NONE covers BOTH "timed out" and "the box never opened because
        ; SkyrimScripting.MessageBox.dll is missing". Those need telling apart,
        ; so say so rather than logging a bare failure.
        Diag(LOG_WARN(), "No answer captured for " + who + \
            " - the box timed out, or Papyrus MessageBox (Nexus 83578) is not installed. " + \
            "MARAS bundles it; check SkyrimScripting.MessageBox.dll is in SKSE\\Plugins.")
    EndIf
EndFunction

Int Function ENDED_CAP() Global
    { Confidant. Romantasy's own tier NAMES are what the player sees in its UI,
      and tier 3 is the deepest one that is not called "Lover". }
    Return 1500
EndFunction

Function EndRomance(Actor akActor, String asReason)
    { Ending a romance, for real this time.

      THE OLD VERSION DID NOT END A ROMANCE. It cleared SNRom_Enrolled and
      subtracted 250, and that was all. Three things wrong with it:

        - It never touched SNRom_Sparked, so the bond prompt kept selecting the
          ROMANTIC ladder and she carried on speaking as a lover. The one thing
          the function is named for did not happen.
        - -250 from Spouse (2500) or Lover (2000) leaves them still Spouse or
          still Lover. Romantasy's own UI would go on calling them that.
        - Clearing SNRom_Enrolled is actively harmful: AutoEnroll treats them as
          new on the next sweep and re-enrols them, writing a duplicate recruit
          row. Enrollment means "we are tracking this bond", which is still true
          after a breakup. It is the ROMANCE that ended, not the relationship.

      CAP, DO NOT ERASE. A divorced couple who traveled together for a year are
      not strangers. Depth is what they earned and it happened; the romantic
      designation is what is being withdrawn. Anyone already below the cap keeps
      exactly what they have - this can only ever lower, never raise.

      RE-STARTABLE BY DESIGN (the author's call). Stance returns to UNANSWERED rather
      than DECLINED, and the spark flag is cleared rather than blocked, so the
      assessor may cross them again after the tenure gate. People reconcile. }
    If !_ready || akActor == None
        Return
    EndIf
    String who = akActor.GetDisplayName()

    ; Back to the platonic ladder. This is the part the old version omitted and
    ; it is the part that actually changes how she speaks.
    StorageUtil.UnsetIntValue(akActor, "SNRom_Sparked")
    StorageUtil.UnsetFloatValue(akActor, "SNRom_SparkedAt")
    StorageUtil.UnsetIntValue(akActor, "SNRom_SeedRomantic")
    StorageUtil.SetIntValue(akActor, "SNRom_PlayerStance", STANCE_UNANSWERED())
    ; Direct write, so it bypasses SetStance and its pending-flag clear. Clear it
    ; here too: an ended romance must not leave a question hanging that the sweep
    ; would keep raising. The spark flag above is already gone, so nothing will
    ; re-arm it until the assessor crosses them again.
    StorageUtil.UnsetIntValue(akActor, "SNRom_AskPending")
    StorageUtil.SetFloatValue(akActor, "SNRom_EndedAt", Utility.GetCurrentGameTime())
    ; Re-arm both gates from now, exactly as UnsparkActor does - otherwise the
    ; next tick re-judges them on the history that just ended.
    StorageUtil.SetFloatValue(akActor, "SNRom_LastSparkCheck", Utility.GetCurrentGameTime())
    StorageUtil.SetFloatValue(akActor, "SNRom_EnrolledAt", Utility.GetCurrentGameTime())

    Int had = PointsOf(akActor)
    Int drop = ENDED_CAP() - had
    If drop < 0
        If ApplyDepth(akActor, ScaleAward(drop), asReason, True, "ended") > 0
            Ledger(akActor, "end", "", drop, 1, asReason)
            Diag(LOG_INFO(), "Romance ended for " + who + ": " + had + " -> " + \
                PointsOf(akActor) + " pts, tier " + TierOf(akActor) + \
                " (" + TierName(TierOf(akActor)) + "). Back on the platonic ladder; " + \
                "romance can be judged again after the tenure gate. " + asReason)
        Else
            Diag(LOG_ERROR(), "Romance ended for " + who + " but the " + drop + \
                " pt cap could not be written - the ladder reverted, the tier did not.")
        EndIf
    Else
        Diag(LOG_INFO(), "Romance ended for " + who + " at " + had + " pts - already at or below " + \
            ENDED_CAP() + ", so depth is unchanged. Back on the platonic ladder. " + asReason)
    EndIf
EndFunction

; ===========================================================================
; Decorators (JSON out, consumed by prompts and eligibility rules)
; ===========================================================================


; ===========================================================================
; Helpers
; ===========================================================================

Bool Function IsEnrolled(Actor akActor) Global
    { ENROLLMENT, NOT DEPTH: SNRom_Enrolled, set by both ways in (BeginSpark,
      AutoEnroll) and cleared by UnenrollActor, which also takes them off the
      roster. From 2.0 it replaces "Romantasy has a level for them". Their
      depth is PointsOf.

      OR ON THE ROSTER, because the roster is exactly the enrolled and some
      companions were enrolled before the flag existed. MoveToBondFaction sets
      it for them, but on its own stack, while Bootstrap's SweepFollowers runs
      at once - and a flag-only test there would re-enroll an old companion as
      new, restarting their enrollment clock and assessor watermarks.

      StorageUtil reads only, so it answers for someone unloaded and never
      waits a frame; the roster search runs only when the flag is missing. }
    If akActor == None
        Return False
    EndIf
    Return StorageUtil.GetIntValue(akActor, "SNRom_Enrolled", 0) == 1 || \
        StorageUtil.FormListFind(None, "SNRom_Roster", akActor) >= 0
EndFunction

Actor Function ResolveFromBase(ActorBase akBase)
    { The roster member built from this ActorBase. The obvious resolution -
      FindActorByName(base.GetName()) - is WRONG for anyone whose display name
      differs from their base name.

      Nicollette is the case that exposed it (1.x, when Romantasy's events
      carried only the base). Born through Fertility Mode Reloaded, her
      ActorBase is still named "Player's Nord Mage Daughter" while the
      reference displays as "Nicollette". The name lookup found nothing, and
      every passive point she earned was discarded.

      Matching the roster by ActorBase is name-independent and exact, so it
      survives renames, titles, and any mod that builds an actor from a
      generic base. The name lookup stays as a fallback. }
    If akBase == None
        Return None
    EndIf
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int i = 0
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None && a.GetActorBase() == akBase
            Return a
        EndIf
        i += 1
    EndWhile
    Return SkyrimNetApi.FindActorByName(akBase.GetName())
EndFunction


Bool Function OrientationExcludesPlayer(Int aiOrient) Global
    { Would this orientation rule the player out as a partner?

      Codes are SNRom_Decorators.OrientationToInt's: 0 none, 1 men, 2 women,
      3 any. GetSex is 0 male, 1 female. Deliberately the SAME test RomanceOk
      applies on read, kept as one function so the two can never drift - a
      write-time guard that disagreed with the read-time gate would be worse
      than neither.

      NONE counts as excluding. A married NPC authored "not drawn to anyone
      that way" contradicts the marriage just as squarely as a wrong gender. }
    If aiOrient == 0
        Return True
    EndIf
    Int playerSex = Game.GetPlayer().GetActorBase().GetSex()
    If aiOrient == 1 && playerSex != 0
        Return True
    ElseIf aiOrient == 2 && playerSex != 1
        Return True
    EndIf
    Return False
EndFunction

Int Function CONFIDANT_MIN() Global
    { Points at which Romantasy calls someone "Confidant" - tier 3, the rung
      below Lover. 500 per tier, same arithmetic as LOVER_MIN.

      Used as the "deep enough that the spark question is now urgent" line: a
      seed landing here puts someone within one ordinary award of the Lover
      floor, so the assessor is asked immediately rather than in two game days.
      See the seed hook in OnSeedAssessed. }
    Return 1500
EndFunction

Int Function LOVER_MIN() Global
    { Points at which Romantasy calls someone "Lover".

      500 per tier, so tier = points / 500 and Lover is tier 4. Read off the
      artifact rather than the documentation: ledger.jsonl has Jordis at
      "tot":2011 with "ta":4, and Sybille at 1689 with "ta":3. }
    Return 2000
EndFunction

Function CheckRomanceQuestion(Actor akActor)
    { Flag that the player owes this person an answer.

      LEVEL-TRIGGERED, NOT EDGE-TRIGGERED, and that is the whole design. It
      tests current state instead of watching for the instant of crossing,
      because an edge here is unreliable in three separate ways: an award can
      land while the NPC is unloaded, seeding can drop someone above the line in
      a single step, and the obvious hook was dead: 1.x's Romantasy event
      handler returned on its self-award flag BEFORE its tier-change branch,
      so "crossed a tier" appeared zero times in a log where Jordis sat at
      2011 points. Anything built on an edge would silently never fire.

      Idempotent. The pending flag is what stops it re-asking, so clearing that
      flag is also what makes the question live again after a deferral.

      DOES NOT ask anything by itself. It only records that the question is
      owed; raising it is the sweep's job, so this stays cheap enough to run on
      every point change.

      RomanceOk is checked because asking is worse than staying silent when her
      orientation already rules it out - the bond prompt has prose for that case
      and it is not a question anyone should be posed. }
    If akActor == None || !_ready
        Return
    EndIf
    ; Before the stance test below, which is what used to make a refusal
    ; permanent. Reopening clears SNRom_AskPending (SetStance), so the check
    ; that follows it cannot short-circuit a question that has just come back.
    ReopenIfClimbedBack(akActor, 0)
    If StorageUtil.GetIntValue(akActor, "SNRom_AskPending", 0) == 1
        Return
    EndIf
    If !IsEnrolled(akActor) || !SNRom_Decorators.IsSparked(akActor)
        Return
    EndIf
    If StorageUtil.GetIntValue(akActor, "SNRom_PlayerStance", 0) != STANCE_UNANSWERED()
        Return
    EndIf
    If !SNRom_Decorators.RomanceOk(akActor)
        Return
    EndIf
    ; EARNED, NOT STORED - points plus whatever the gate is holding back. (The
    ; history below names 1.x's reactive ceiling; the gate in ApplyDepth holds
    ; the same bank today, and the reasoning is unchanged.)
    ;
    ; THIS WAS A DEADLOCK, and it defeated the mod's central feature. The
    ; sequence: a sparked, unanswered romance reaches Lover, EnforceLoverCeiling
    ; claws the overflow into SNRom_BankedPoints to stop an unasked promotion,
    ; and then this test - reading the STORED points it just reduced - never sees
    ; tier 4 and never marks the question owed. Points are withheld because the
    ; question is unanswered; the question is never asked because the points were
    ; withheld. Nothing breaks the loop.
    ;
    ; It was survivable by accident until 1.6.0. The rest point was 1999, one
    ; under Lover, so any award at all from ROMANTASY'S own economy - the path
    ; this mod cannot intercept - pushed the stored value over 2000 for the
    ; instant before the clawback, and this test happened to run first. Every
    ; "Question owed" line in the log reads 2003-2084 for exactly that reason:
    ; not one of them was triggered by an award we wrote. Adding the 250-point
    ; buffer raised the escape to a single 251+ award and shut the door.
    ;
    ; Sybille Stentor, 2026-09-15. Sparked since gd 133, made a companion
    ; deliberately so she would cross and be asked, re-authored, re-seeded to
    ; DEVOTED. Held at 1749 with 483 banked - 2232 earned, comfortably past Lover
    ; - and the question was never once owed to her. Awards of 30, 25 and 35
    ; could not clear a 251-point gap.
    ;
    ; SAME BUG SHAPE AS PhysicalOk, FIXED 2026-09-07 AND NOT GENERALISED: compare
    ; what she has EARNED, never the value the ceiling suppressed. Both gates
    ; read a number that another subsystem deliberately holds down. Any future
    ; test against a points threshold belongs on this side of that line too.
    If (PointsOf(akActor) + StorageUtil.GetIntValue(akActor, "SNRom_BankedPoints", 0)) < LOVER_MIN()
        Return
    EndIf

    StorageUtil.SetIntValue(akActor, "SNRom_AskPending", 1)
    ; Zero rather than now, so the sweep raises it at the first opportunity
    ; instead of serving a retry interval before anyone has been asked once.
    StorageUtil.SetFloatValue(akActor, "SNRom_LastAskAttempt", 0.0)
    ; REPORTS BOTH NUMBERS. The stored value is what the player sees on
    ; Romantasy's panel and the earned one is why the question is being asked;
    ; a line carrying only one of them reads as a contradiction of the other.
    Diag(LOG_INFO(), "Question owed to " + akActor.GetDisplayName() + " at " + \
        (PointsOf(akActor) + StorageUtil.GetIntValue(akActor, "SNRom_BankedPoints", 0)) + \
        " pts earned (" + PointsOf(akActor) + " held + " + \
        StorageUtil.GetIntValue(akActor, "SNRom_BankedPoints", 0) + " banked, tier " + \
        TierOf(akActor) + \
        ") - sparked, orientation permits, and the player has never answered.")

    ; RAISE IT NOW, not on the next tick. Waiting for the game-time sweep put up
    ; to two game hours between crossing into Lover and her asking about it -
    ; Vivienne Onis crossed on the back of a MAJOR intimacy award and the
    ; question arrived long after the moment that earned it, which reads as the
    ; game noticing late rather than as her deciding to speak.
    ;
    ; PumpAskQueue rather than OpenAsk directly, so this goes through exactly
    ; the same gates as the sweep - not in combat, she is present and within
    ; range, no other box already up. If any of them fail, nothing happens here
    ; and the sweep raises it later exactly as before; this only removes the
    ; wait when the conditions are ALREADY right, which at the moment of
    ; crossing they usually are.
    ;
    ; Cost is bounded: the debt transitions to pending once per NPC ever, so
    ; this roster walk happens once per person and never on a busy path.
    PumpAskQueue()
EndFunction

Function Ledger(Actor akActor, String asChannel, String asActivity, Int aiDelta, Int aiCount, String asReason)
    { One JSON object per point change. Buffered - OnPreference fires on every
      matching statistic increment for every enrolled follower, so a native
      write per event is not acceptable in a busy fight. }
    ; BEFORE the logLedgerEnabled gate, deliberately. Ledger is the only place
    ; every point change passes through - enroll, recruit, moment, end, passive,
    ; seed, talk and spark all call it - which makes it the one hook that cannot
    ; be missed when a ninth award path is added later. But it is also a LOGGING
    ; function with a config switch, and a player turning the ledger off must
    ; not silently disable romance questions. Running first is what keeps a
    ; logging preference from becoming a gameplay one.
    CheckRomanceQuestion(akActor)
    ; And the marriage gate, in the same place and for the same reason: this is
    ; the one hook every point change passes through, so it is the only place a
    ; crossing into Spouse cannot be missed. One HasKeyword read in the steady
    ; state, and it writes only when the answer actually changes.
    MaintainProposalGate(akActor)

    ; And for the third time, same reason: this is the one place every point
    ; change passes through, so it is the only honest place to count how much
    ; has actually HAPPENED to someone. Disposition drift refuses to look at an
    ; NPC until this counter is high enough, which is what turns "a new pattern
    ; of behavior has been established" into something Papyrus can enforce
    ; rather than something a prompt is asked to feel. Above the ledger gate,
    ; because turning off logging must not freeze everyone's personality.
    StorageUtil.SetIntValue(akActor, "SNRom_EventsSinceDrift", \
        StorageUtil.GetIntValue(akActor, "SNRom_EventsSinceDrift", 0) + 1)
    ; ---- AND WHEN those events happened, not just how many -----------------
    ; Six events in one evening is one occasion, and a review asked about it
    ; cannot be answered honestly - there is no pattern to find, only a moment.
    ; Five forced reviews on exactly that material produced five manufactured
    ; YES verdicts, escalating from undated phrasings to invented timestamps as
    ; each guard closed. The lesson is the spark tenure gate's: do not ask a
    ; question the material cannot answer.
    ;
    ; Only the FIRST and LAST day are kept. Distinct-day counting would be
    ; better and needs a set Papyrus does not have; first-to-last span is one
    ; subtraction and answers the question that matters - has anything happened
    ; on a different day from the first thing.
    Float today = Utility.GetCurrentGameTime()
    If StorageUtil.GetFloatValue(akActor, "SNRom_DriftFirstDay", -1.0) < 0.0
        StorageUtil.SetFloatValue(akActor, "SNRom_DriftFirstDay", today)
    EndIf
    StorageUtil.SetFloatValue(akActor, "SNRom_DriftLastDay", today)

    LedgerRow(akActor, asChannel, asActivity, aiDelta, aiCount, asReason)
EndFunction

String Function LedgerChannelJson(String asChannel) Global
    { The row's channel field, from literals no other string in the game can
      share. Papyrus keeps one copy of each string whatever its case, so a
      bare "talk" was written as "Talk" in play (2026-10-01). Comparison
      ignores case, so each known channel is matched and written whole. }
    If asChannel == "talk"
        Return ",\"ch\":\"talk\""
    ElseIf asChannel == "moment"
        Return ",\"ch\":\"moment\""
    ElseIf asChannel == "seed"
        Return ",\"ch\":\"seed\""
    ElseIf asChannel == "spark"
        Return ",\"ch\":\"spark\""
    ElseIf asChannel == "import"
        Return ",\"ch\":\"import\""
    ElseIf asChannel == "recruit"
        Return ",\"ch\":\"recruit\""
    ElseIf asChannel == "enroll"
        Return ",\"ch\":\"enroll\""
    ElseIf asChannel == "declined"
        Return ",\"ch\":\"declined\""
    ElseIf asChannel == "end"
        Return ",\"ch\":\"end\""
    ElseIf asChannel == "unbank"
        Return ",\"ch\":\"unbank\""
    ElseIf asChannel == "withheld"
        Return ",\"ch\":\"withheld\""
    EndIf
    Return ",\"ch\":\"" + asChannel + "\""
EndFunction

Function LedgerRow(Actor akActor, String asChannel, String asActivity, Int aiDelta, Int aiCount, String asReason)
    { The row alone, without Ledger's reactions (the question, the ceiling,
      the proposal gate, drift's counters). For the one-time import, which
      records where a bond already stood rather than a change to it. }
    If SkyrimNetApi.GetConfigBool(CFG(), "logLedgerEnabled", True) == False
        Return
    EndIf
    Int pts = PointsOf(akActor)
    String row = "{\"gd\":" + Utility.GetCurrentGameTime() + \
        ",\"npc\":\"" + Escape(akActor.GetDisplayName()) + "\"" + \
        LedgerChannelJson(asChannel) + \
        ",\"act\":\"" + asActivity + "\"" + \
        ",\"d\":" + aiDelta + ",\"n\":" + aiCount + \
        ",\"tot\":" + pts + \
        ",\"ta\":" + TierForPoints(pts) + \
        ",\"why\":\"" + Escape(asReason) + "\"}"

    If _ledgerCount >= _ledgerBuf.Length
        FlushLedger()
    EndIf
    _ledgerBuf[_ledgerCount] = row
    _ledgerCount += 1

    ; Buffering exists ONLY to survive the passive channel, which fires on
    ; every matching statistic increment for every enrolled follower. Every
    ; other channel is rare and important, so flush it immediately - otherwise
    ; an authored beat sits in memory and is lost on a crash or a quit, which
    ; is exactly the data you most wanted to keep.
    If asChannel != "passive"
        FlushLedger()
        Return
    EndIf

    Int flushEvery = SkyrimNetApi.GetConfigInt(CFG(), "logFlushEvery", 25)
    If _ledgerCount >= flushEvery
        FlushLedger()
    EndIf
EndFunction

Function FlushLedger()
    If _ledgerCount <= 0
        Return
    EndIf
    Int i = 0
    String blob = ""
    While i < _ledgerCount
        blob += _ledgerBuf[i] + "\n"
        i += 1
    EndWhile
    WriteLog("ledger.jsonl", LedgerPath(), blob)
    _ledgerCount = 0
EndFunction

String Function Escape(String asText) Global
    { Reason strings are LLM-authored free text and land inside JSON.

      IT DID NOT ESCAPE ANYTHING until 2026-08-08 - it only truncated, while
      its own docstring said what it was for. Any reason containing a quote
      wrote a broken row, and ledger.jsonl is the analysis file, so the damage
      was silent until something tried to parse it. Found when a Sybille row
      carrying `to bear your "storm" within me` threw on ConvertFrom-Json and
      took every row after it down with the parse.

      TRUNCATE FIRST, THEN ESCAPE. The other order can cut a two-character
      escape in half and leave a trailing backslash, which is worse than the
      bug being fixed - the row stays invalid AND the reason is unreadable. }
    Return SNRom_Decorators.JsonEscape(StringUtil.Substring(asText, 0, 300))
EndFunction

Function WriteLog(String asName, String asPath, String asText)
    { One write to one of the mod's log files: through the DLL (natives v7),
      at once and in order, or through MiscUtil without it - which groups
      lines by call site and delivers them late (see Diag). }
    If _dashNatives >= 7 && SNRom_Native.AppendLog(asName, asText)
        Return
    EndIf
    MiscUtil.WriteToFile(asPath, asText, True, False)
EndFunction

Function Diag(Int aiLevel, String asText, Bool abQuiet = False)
    { Every line carries its own sequence number and game time.

      MiscUtil.WriteToFile does NOT guarantee ordering - entries arrive in
      blocks, grouped by call site rather than chronologically, and recent
      writes can lag behind by minutes. Reading position in the file as
      "when it happened" is wrong, and reading absence as "it did not run" is
      worse. Self-stamping every line is the only way to reconstruct order.

      abQuiet WRITES THE FILE AND SKIPS THE NOTIFICATION MIRROR, for the one
      shape of line the mirror cannot carry: a forensic record of arbitrary
      length, containing authored PROSE.

      Notifications are a single line of fixed width. Skyrim shrinks the font
      to fit and then clips, so a long one arrives unreadable AND pushes the
      short useful ones out of the queue - which is how a player with
      logNotifications on ends up seeing less than one with it off. Reported
      2026-09-05 on the parse-failure notification: "the notification text is
      so long that it shrinks the font to where I can't read it."

      The same goes for a line written once per character by a pass over the
      whole roster (the WP4 import): a hundred toasts drain for minutes and
      bury the one summary worth reading.

      This is the emission-point rule again: the constraint belongs on the line
      that emits, not on a caller who has to remember it. Anything the player
      should actually READ goes through Say, which is one short sentence by
      construction and does not depend on a log setting at all. }
    Int configured = SkyrimNetApi.GetConfigInt(CFG(), "logLevel", 3)
    If aiLevel > configured
        Return
    EndIf
    _seq += 1
    String line = "[" + _seq + "] gd=" + Utility.GetCurrentGameTime() + " L" + aiLevel + " " + asText
    WriteLog("snrom.log", DiagPath(), line + NL())
    If !abQuiet && SkyrimNetApi.GetConfigBool(CFG(), "logNotifications", False)
        Debug.Notification("[SNRom] " + asText)
    EndIf
EndFunction

; ===========================================================================
; Phase 3 - LLM-authored dispositions
;
; The distinctive part of the mod: each follower's likes and dislikes are
; derived from who they actually are, not from a class archetype table.
;
; Only ONE authoring call can be in flight at a time - SendCustomPromptToLLM's
; callback signature carries no actor, so the subject is held in _pendingActor.
; A second request while one is pending is dropped rather than queued; these
; fire once per NPC in a lifetime, so contention is not worth the complexity.
; ===========================================================================

Actor  _pendingActor
String _pendingName

; Spark assessment keeps its OWN pending slot. It shares nothing with
; disposition authoring: the two run on different callbacks and either may be
; in flight while the other is, and reusing _pendingActor would silently make
; one overwrite the other's subject.
Actor  _sparkActor
String _sparkName
Float  _sparkPendingAt

; ---------------------------------------------------------------------------
; Pending-slot watchdog.
;
; SendCustomPromptToLLM returns rc=1 for a template that FAILS TO RENDER. The
; callback then never fires, so a slot only cleared on `rc != 1` stays occupied
; forever and the scheduled path is silently dead until a game restart. Hit for
; real on 2026-07-30: an Inja parse error in snrom_talk_assess wedged _talkActor
; while Papyrus logged two clean sends.
;
; REAL time, not game time. Game time does not advance while paused, and a
; debugging session is mostly paused - a game-time watchdog would never fire in
; exactly the situation that needs it.
; ---------------------------------------------------------------------------
Float Function PendingTimeoutSeconds() Global
    { Raised 120 -> 300 on 2026-08-04 so the LLM request timeout can go above
      120s without the watchdog racing it.

      THE TWO NUMBERS ARE COUPLED AND NOTHING ENFORCES IT. If a variant's
      request_timeout exceeds this, the watchdog frees the pending slot while
      the request is still in flight, a second assessment starts, and the late
      response then lands against a slot that no longer belongs to it - a double
      award, or one attributed to the wrong follower. Keep this comfortably
      ABOVE the largest request_timeout in OpenRouter.yaml. }
    Return 300.0
EndFunction

; ---------------------------------------------------------------------------
; Durable text store
;
; StorageUtil STRINGS DO NOT SURVIVE A RELOAD. Ints and Floats on the same
; actor do. Proven 2026-08-02 with a clean experiment: Haelga's ARDOR (Int) and
; her WHY (String) were written milliseconds apart in the same response handler;
; after a reload the Int rendered and the String was gone. Svana repeated it.
;
; That silently killed circle differentiation for this mod's entire history -
; BuildCircle reads OTHER roster members' WHYs, which are by definition values
; written in EARLIER sessions, which are exactly the ones lost. It worked
; within a session and never across one, which is why it read as "it reverted
; with the save" for two sessions running.
;
; JsonUtil is FILE-backed (data/skse/plugins/StorageUtilData/), not co-save, so
; it survives reloads, and - just as valuable - the result can be READ FROM
; DISK to confirm a write actually landed. Co-save contents are invisible from
; outside the game, which is why this bug took so long to pin down. Prefer a
; store you can verify over one you have to trust.
; ---------------------------------------------------------------------------


String Function LegacyStoreFile() Global
    { The one file every install had before playthroughs were separated. Still
      the live store for whichever save claims it - see EnsureSaveId. }
    Return "SNRom_Dispositions"
EndFunction

String Function PlaythroughId() Global
    { Which playthrough this save belongs to, as SkyrimNet knows it.

      THE PROBLEM THIS SOLVES. Everything our store keys on is written by us,
      so it only exists in saves made AFTER we first wrote it - which makes an
      older save of the same playthrough indistinguishable from a different one.
      Two earlier attempts failed on exactly that: a `claimedBy` boolean divorced
      a 205-day playthrough from a 19,780-byte store, and the character name that
      replaced it is not unique across playthroughs.

      Skyrim itself does carry a real per-playthrough id - the second field of a
      save filename, e.g. 3D42EC5C, constant across 390 saves spanning weeks on
      this install and distinct for each of six other characters in the same
      folder. Papyrus cannot read it, and po3's extender does not expose it.

      SKYRIMNET ALREADY SOLVED THIS AND PUBLISHES THE ANSWER. It keeps one
      SQLite database per playthrough (data/SkyrimNet-<id>.db, eleven of them
      here) and exposes the id natively. Being an SKSE plugin it can read the
      save itself, so the value is stable for every save of a playthrough
      including ones made long before this mod was installed - which is the
      property nothing we write can have.

      SkyrimNet is already a hard dependency, so this costs nothing. We are the
      first Papyrus caller of it, so treat an empty return as normal rather than
      as impossible.

      SANITISED, because it becomes a filename. A JsonUtil write to a bad path
      is the silent failure this whole store exists to avoid, and a format change
      upstream must not be able to cause one. }
    String raw = SkyrimNetApi.GetSaveUniqueID()
    Int n = StringUtil.GetLength(raw)
    If n == 0
        Return ""
    EndIf
    String out = ""
    Int i = 0
    While i < n
        String c = StringUtil.GetNthChar(raw, i)
        Int o = StringUtil.AsOrd(c)
        If (o >= 48 && o <= 57) || (o >= 65 && o <= 90) || (o >= 97 && o <= 122) || c == "-" || c == "_"
            out = out + c
        EndIf
        i += 1
    EndWhile
    Return out
EndFunction

String Function StoreFile() Global
    { The disposition store FOR THIS PLAYTHROUGH.

      Flat filename, no subfolder. JsonUtil accepts a path here, but whether it
      CREATES a missing directory is undocumented, and a silent write failure is
      the one outcome this whole store exists to avoid.

      WHY THIS IS NOT A CONSTANT. JsonUtil writes one file per INSTALL, not per
      save, and dispositions are keyed on reference FormID - stable for every
      vanilla NPC. So a second playthrough read the FIRST one's authored WHY,
      LIMIT and ADDRESS for everyone, AND the authoring guard then found those
      values and refused to write new ones. The two halves hid each other,
      because a stale disposition looks like a working one.

      SNRom_SaveId is a cached DECISION, not an identity: 1 means this
      playthrough owns the legacy file, 2 means it uses its own. Ints survive a
      reload; strings do not, which is why the id itself is re-read from
      SkyrimNet rather than stored. }
    If StorageUtil.GetIntValue(None, "SNRom_SaveId", 0) == 1
        Return LegacyStoreFile()
    EndIf
    String id = PlaythroughId()
    If id == ""
        ; SkyrimNet has not answered yet. Share rather than invent a file:
        ; sharing is visible and recoverable, a wrong new file looks like the
        ; mod forgetting everyone.
        Return LegacyStoreFile()
    EndIf
    Return LegacyStoreFile() + "_" + id
EndFunction

Function EnsureSaveId()
    { Decides, once per playthrough, whether this save owns the original
      disposition file or gets its own.

      THE FIRST PLAYTHROUGH TO RUN THIS INHERITS THE EXISTING DATA, deliberately.
      On an install that has only ever had one character - the overwhelming
      majority, and every current user - it is silently correct and nobody loses
      the characters they have authored.

      The claim is recorded INSIDE the legacy file, because the question "who
      owns this" has to be answerable from a save that has never seen our
      co-save state.

      SNRom_SaveId IS A DECISION, AND ONLY 0, 1 AND 2 ARE VALID. 0 undecided,
      1 owns the legacy file, 2 has its own. Any other value is a leftover from
      the short-lived scheme that stored a RANDOM id there, and it must be
      re-decided rather than trusted - under the current reading a stale random
      id silently means "not 1", so a save carrying one would quietly use a
      per-playthrough file it never chose. Measured 2026-09-05: a save holding
      1350563096 from an earlier build skipped the decision entirely and went on
      reading the wrong store with nothing logged. }
    Int decided = StorageUtil.GetIntValue(None, "SNRom_SaveId", 0)
    If decided == 1 || decided == 2
        Return
    EndIf
    If decided != 0
        Diag(LOG_INFO(), "Save id " + decided + " is from the earlier random-id scheme. " + \
            "Re-deciding which disposition store this playthrough owns.")
    EndIf

    String id = PlaythroughId()
    If id == ""
        ; Undecided rather than wrong. StoreFile falls back to the legacy file
        ; meanwhile, and the next bootstrap asks again.
        Diag(LOG_WARN(), "SkyrimNet returned no save id, so the disposition store " + \
            "cannot be assigned to a playthrough yet. Using the shared file for now.")
        Return
    EndIf

    String owner = JsonUtil.GetStringValue(LegacyStoreFile(), "claimedById", "")
    ; A NEW GAME MUST NOT INHERIT AN UNCLAIMED STORE, 2026-09-28. "The first
    ; playthrough to run this inherits" was right for the playthrough that WROTE
    ; the file and wrong for a fresh game that merely got here first - a player
    ; who played before 1.4.1 and then started over. The new game took the old
    ; characters' WHY, LIMIT and ADDRESS, and AuthorDisposition, finding a WHY
    ; already stored, skipped authoring them at all ("authored before a save
    ; reload rolled the flag back"), so they kept the old prose over default
    ; numbers forever. Reported by a player 2026-09-28 as relationships that
    ; "carry over through different saves".
    ;
    ; The roster tells the two apart, because it lives in the co-save: the
    ; playthrough that wrote the file has enrolled people in it; a new game has
    ; enrolled nobody yet. An empty roster meeting an existing file takes a
    ; store of its own and leaves the file unclaimed for its real owner, who
    ; still claims it the next time that playthrough loads.
    If owner == "" && StorageUtil.FormListCount(None, "SNRom_Roster") == 0 && \
            JsonUtil.JsonExists(LegacyStoreFile())
        StorageUtil.SetIntValue(None, "SNRom_SaveId", 2)
        Diag(LOG_INFO(), "A new playthrough (" + id + ") found characters in the unclaimed " + \
            "disposition store from an earlier one and left them there. This one uses " + \
            LegacyStoreFile() + "_" + id + ".json and everyone begins as a stranger.")
    ElseIf owner == ""
        JsonUtil.SetStringValue(LegacyStoreFile(), "claimedById", id)
        JsonUtil.Save(LegacyStoreFile())
        StorageUtil.SetIntValue(None, "SNRom_SaveId", 1)
        Diag(LOG_INFO(), "This playthrough (" + id + ") now owns the existing disposition " + \
            "store. Everyone already authored keeps their character.")
    ElseIf owner == id
        StorageUtil.SetIntValue(None, "SNRom_SaveId", 1)
        Diag(LOG_INFO(), "Rejoined the main disposition store - same playthrough (" + id + \
            "), just a save made before it was claimed.")
    Else
        StorageUtil.SetIntValue(None, "SNRom_SaveId", 2)
        Diag(LOG_INFO(), "A different playthrough (" + id + "; the main store belongs to " + \
            owner + "). This one uses " + LegacyStoreFile() + "_" + id + ".json and " + \
            "everyone begins as a stranger, which is what a new game should mean.")
    EndIf
EndFunction

Function StartFreshStore()
    { Give THIS playthrough its own disposition store, leaving the legacy one to
      whoever claimed it. Takes no arguments, so it dispatches from the web API.

      Nothing is deleted: the store it leaves is untouched on disk, and
      AdoptLegacyStore returns to it. }
    If !_ready
        Return
    EndIf
    StorageUtil.SetIntValue(None, "SNRom_SaveId", 2)
    WriteStorePointer()
    DashboardCacheStore()
    If _dashText
        PushAllBondText()
    EndIf
    Diag(LOG_INFO(), "This playthrough now has its own disposition store: " + StoreFile() + \
        ".json. Nothing was deleted - the previous store is untouched, and " + \
        "AdoptLegacyStore returns to it.")
EndFunction

Function AdoptLegacyStore()
    { Reattach THIS playthrough to the main disposition store, taking ownership
      of it. For a save that was separated by an earlier version of this logic.

      Takes no arguments, so it dispatches from the web API. Safe and
      reversible: it moves which file this save READS and deletes nothing. }
    If !_ready
        Return
    EndIf
    String id = PlaythroughId()
    StorageUtil.SetIntValue(None, "SNRom_SaveId", 1)
    If id != ""
        JsonUtil.SetStringValue(LegacyStoreFile(), "claimedById", id)
        JsonUtil.Save(LegacyStoreFile())
    EndIf
    WriteStorePointer()
    DashboardCacheStore()
    If _dashText
        PushAllBondText()
    EndIf
    Diag(LOG_INFO(), "Adopted the main disposition store, now claimed by playthrough '" + \
        id + "'. Reading " + StoreFile() + ".json - authored characters are visible again.")
EndFunction


Function WriteStorePointer() Global
    { Publishes which disposition file is live, for anything reading from
      outside the game - our own log analysis included.

      The store name is derived from a co-save Int, so nothing outside Skyrim
      can work it out. One key, rewritten every bootstrap so it can never go
      stale. This is also why the store is JsonUtil rather than the co-save at
      all: prefer a store you can verify over one you have to trust. }
    JsonUtil.SetStringValue("SNRom_Current", "store", StoreFile())
    JsonUtil.Save("SNRom_Current")
EndFunction

String Function StoreKey(Actor akActor, String asField) Global
    { Keyed on the reference FormID, not the name and not the ActorBase.

      Not the name: renamed and mod-spawned followers break it, which is the
      trap that dropped every event for an FMR child whose base name differed
      from her display name.

      Not the ActorBase: leveled generics share one base, so several NPCs would
      collide on a single key and overwrite each other's authored line.

      A dynamic reference FormID (FF...) is not guaranteed stable across load
      order changes. If one shifts, that NPC's stored text is orphaned and reads
      as blank - which is exactly the behavior we have today, so the failure
      mode is no worse than the bug this replaces. }
    Return akActor.GetFormID() + "." + asField
EndFunction

Function StoreSetText(Actor akActor, String asField, String asValue) Global
    { Writes AND saves. JsonUtil holds the file in memory until Save() is
      called, so skipping it means the value survives exactly until the game
      exits - reintroducing the bug in a different disguise. }
    If akActor == None || asValue == ""
        Return
    EndIf
    JsonUtil.SetStringValue(StoreFile(), StoreKey(akActor, asField), asValue)
    JsonUtil.Save(StoreFile())
EndFunction

String Function StoreGetText(Actor akActor, String asField, String asStoreName = "", Int aiFormId = 0) Global
    { Falls back to the old StorageUtil location so NPCs authored before this
      change keep working for the rest of the current session. Their value is
      still lost on the next load - nothing can recover a string the co-save
      never kept - but they degrade to blank rather than breaking.

      asStoreName names the store to read, for the one caller that must not
      ask SkyrimNet which store is live: the dashboard's refresh, which runs
      while the game is paused (OnDashboardRefresh). Empty, as every other
      caller leaves it, means StoreFile().

      aiFormId is akActor's form id when the caller already has it: the
      dashboard's text push, which gets it from SNRom_Native.FormIdOf once per
      actor instead of three GetFormID calls, each of which may wait a frame.
      0, as every other caller leaves it, means StoreKey() asks the actor. The
      key is the same either way. }
    If akActor == None
        Return ""
    EndIf
    String fromStore = asStoreName
    If fromStore == ""
        fromStore = StoreFile()
    EndIf
    ; jsonKey, NOT key: Key is a Papyrus type, and names ignore case.
    String jsonKey
    If aiFormId != 0
        jsonKey = aiFormId + "." + asField   ; StoreKey's shape, without the GetFormID call
    Else
        jsonKey = StoreKey(akActor, asField)
    EndIf
    String v = JsonUtil.GetStringValue(fromStore, jsonKey, "")
    If v != ""
        Return v
    EndIf
    ; Legacy fallback, spelled out rather than built by concatenation.
    ;
    ; Why only: LIMIT is new in this build, so there is no old value of it to
    ; find, and "SNRom_Disposition" + asField would have invented a key name
    ; that never existed. It also hid the real key from check.ps1, whose regex
    ; can only see the literal part before a concatenation - it reported
    ; "SNRom_Disposition is READ but never written", which was true of a string
    ; that is not actually a key.
    If asField == "Why"
        Return StorageUtil.GetStringValue(akActor, "SNRom_DispositionWhy", "")
    EndIf
    Return ""
EndFunction

Bool Function SlotStale(Float afPendingAt) Global
    If afPendingAt <= 0.0
        Return True
    EndIf
    Return (Utility.GetCurrentRealTime() - afPendingAt) > PendingTimeoutSeconds()
EndFunction

String Function VariantName() Global
    { SendCustomPromptToLLM's "variant" names a variant configured in
      OpenRouter.yaml.

      THIS FUNCTION MUST NOT BE NAMED LLMVariant - or any other case-variant
      of the "llmVariant" config key. The Papyrus compiler interns strings
      CASE-INSENSITIVELY, first spelling wins, and identifiers enter the table
      before literals. A function named LLMVariant claims the slot, the
      literal "llmVariant" below folds onto it, and the compiled pex asks
      SkyrimNet for "LLMVariant" - which fails the case-sensitive YAML lookup
      and silently returns the default. Proven by pex disassembly 2026-07-27;
      cost a full diagnostic cycle. The same applies to EVERY identifier vs
      EVERY config-key literal in a script: keep key names and identifiers
      spelled apart.

      DO NOT read "LLM returned empty response" as a variant fault. That
      message is what Papyrus receives for BOTH a genuine provider failure and
      the entirely unrelated case of a prompt with no [ system ]/[ user ]
      section markers, which produces an empty messages array and never
      reaches a provider at all. Chasing it through four variants cost most of
      a day; the marker bug was the real one. SkyrimNet.log names the
      difference - "Messages array is empty" - and Papyrus never sees it.

      What matters is the PROVIDER, not the model_name: KoboldCPP-style
      backends ignore the requested model and serve whatever is loaded, so a
      variant's model_name can disagree with reality without any error.

      Pick a variant whose provider runs your strongest instruction-following
      model, with generous max_tokens and structured output OFF - structured
      output forces a JSON schema that fights our labeled-line format.

      Prefer a LOW temperature. Every prompt this variant serves emits labeled
      lines that get parsed, not prose, and creative sampling is how those come
      back malformed. A variant tuned for diary or dialogue writing - warm, long,
      high temperature - is the wrong shape for this work even on a large model.
      Model capability scales up safely; sampling settings do not travel.

      Avoid naming a variant another subsystem owns. This defaulted to
      DiaryGeneration until 2026-08-19, which meant anyone who made their diary
      entries warmer or longer silently retuned every assessment this mod makes,
      with nothing on screen to connect cause to effect. It then briefly defaulted
      to CharacterProfileGeneration, which was the same mistake with a politer
      name - still somebody else's variant.

      The default is snrom_background: the variant this mod DECLARES in its
      manifest. Declaring it is what puts it on the Models page and what carries
      it into model presets, so it is the only name that is guaranteed to still
      exist after a user applies a preset - and the only one whose settings
      nobody else will retune underneath us.

      Deliberately configurable. Variant names, their providers, token limits
      and flags are entirely user-defined, and setups range from OpenRouter to
      several local endpoints on a LAN. There is no value that is right for
      everyone. }
    Return SkyrimNetApi.GetConfigString(CFG(), "llmVariant", "snrom_background")
EndFunction

Function ClearDisposition(Actor akActor)
    { Wipes every authored character field back to unset, so the next
      authoring starts from nothing.

      1.x also removed the Romantasy preference factions here. From 2.0 this
      mod writes no preferences, and leaves Romantasy's data alone (design 10,
      phase 5: "Do not clear another mod's data on the way out"). }
    If akActor == None
        Return
    EndIf
    StorageUtil.UnsetIntValue(akActor, "SNRom_Orientation")
    StorageUtil.UnsetIntValue(akActor, "SNRom_OrientationKnown")
    StorageUtil.UnsetIntValue(akActor, "SNRom_PhysMinTier")
    StorageUtil.UnsetIntValue(akActor, "SNRom_PhysAttrBypass")
    StorageUtil.UnsetIntValue(akActor, "SNRom_Ardor")
    StorageUtil.UnsetIntValue(akActor, "SNRom_Exclusivity")
    StorageUtil.SetIntValue(akActor, "SNRom_DispositionAuthored", 0)
    Diag(LOG_INFO(), "Cleared disposition for " + akActor.GetDisplayName() + \
        " - character fields unset")
EndFunction

String Function BuildCircle(Actor akExclude)
    { The authored ENUM PROFILE of everyone else already traveling with the
      player, so a new disposition is made distinct from the ACTUAL CAST
      rather than from an abstraction.

      IT USED TO PASS THEIR WHY SENTENCES, AND THAT CAUSED THE SAMENESS IT
      EXISTS TO PREVENT. Elisif was handed "Bryling: She finds a profound,
      almost addictive sanctuary in the total surrender of her will and the
      physical dismantling of her composure" and answered "She finds a profound
      sanctuary in the total surrender of Haruk's will and the physical
      dismantling of his composure" - the same sentence with the pronouns
      swapped, which inverts the dynamic and is nonsense for her. The author spotted
      it in play on 2026-08-07.

      This is the oldest rule in snrom-prompt-lessons, broken by our own code:
      never put a valid, well-formed answer where the model is about to answer.
      The instruction beside it literally read "must not read as a variation on
      one of the others" and lost to proximity, as instructions always do here.

      Enums cannot be pasted back as a WHY - different field, wrong shape - and
      they are the BETTER comparison anyway: WHY resisted repetition across ~15
      authorings while every enum clustered, so the enums are where sameness
      actually shows up.

      Scope is what makes this tractable. We are not trying to be distinct
      across every NPC in Skyrim - only across the handful the player actually
      travels with and sees side by side.

      The prompt has always said "two different people must not come out the
      same", but it had no idea who the others were, so it was differentiating
      against nothing. This is the difference between "be varied" and "do not
      be another Kayla".

      Scope is what makes this tractable. We are not trying to be distinct
      across every NPC in Skyrim - only across the handful the player actually
      travels with and sees side by side, which is where sameness is
      perceptible at all. Two companions in the same room must not read alike;
      two strangers in opposite holds may be identical and nobody will ever
      know.

      Capped at five. Beyond that it is prompt weight for a comparison the
      player is not making, and the response cap punishes length. }
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    Actor[] picked = new Actor[5]
    Float[] ranks = new Float[5]
    Int shown = 0
    Float now = Utility.GetCurrentGameTime()

    ; ONE PASS, keeping the best five in order as it goes. This was a selection
    ; sort - five passes, each asking every companion IsFollowing - written for
    ; a roster of about 20. At 122 that is some 600 follower checks, each
    ; waiting for a frame, and a re-author from the dashboard took 39 seconds
    ; to answer (2026-10-01).
    Int i = 0
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        ; Only someone actually authored. An unauthored NPC carries nothing
        ; but mapper defaults, and listing those differentiates against a
        ; fiction.
        If a != None && a != akExclude && \
           StorageUtil.GetIntValue(a, "SNRom_DispositionAuthored", 0) == 1
            ; Rank = when they last traveled with the player, with current
            ; followers lifted above every former one. Game time is days
            ; since game start and will not approach the offset in any
            ; playthrough, so the two bands cannot overlap.
            ;
            ; IsFollowing waits for a frame, so it is asked only of someone
            ; stamped in the last day: the follower sweep stamps everyone
            ; following on every pass, so nobody older can be following now.
            Float rank = StorageUtil.GetFloatValue(a, "SNRom_LastFollowingAt", 0.0)
            If rank > 0.0 && now - rank < 1.0 && IsFollowing(a)
                rank += 1000000.0
            EndIf
            ; Into the five, highest first. A tie keeps the one met first, as
            ; the old sort did.
            Int slot = -1
            If shown < 5
                slot = shown
                shown += 1
            ElseIf rank > ranks[4]
                slot = 4
            EndIf
            If slot >= 0
                While slot > 0 && rank > ranks[slot - 1]
                    picked[slot] = picked[slot - 1]
                    ranks[slot] = ranks[slot - 1]
                    slot -= 1
                EndWhile
                picked[slot] = a
                ranks[slot] = rank
            EndIf
        EndIf
        i += 1
    EndWhile

    String out = ""
    Int k = 0
    While k < shown
        Actor best = picked[k]
        If out != ""
            out += "   "
        EndIf
        out += "- " + best.GetDisplayName() + ": " + \
            SNRom_Decorators.IntimacyWordFromTier( \
                StorageUtil.GetIntValue(best, "SNRom_PhysMinTier", 4)) + \
            ", " + SNRom_Decorators.ArdorWord( \
                StorageUtil.GetIntValue(best, "SNRom_Ardor", 2)) + \
            ", exclusivity " + StorageUtil.GetIntValue(best, "SNRom_Exclusivity", 50)
        k += 1
    EndWhile
    Return out
EndFunction

Function UnenrollByName(String asName)
    { Un-enroll someone who is nowhere near the player.

      WHY THIS EXISTS. UnenrollActor needs an Actor, and the web API can only
      supply one as a FormID or a SkyrimNet UUID. Both are easy to obtain for
      someone standing in front of the player - nearby-actors lists them - and
      genuinely hard to obtain for anyone else. Sibbi Black-Briar is the case
      that forced it: accidentally recruited before the two-hour release window
      existed, sitting in Riften jail, and with no row in the disposition store
      to recover a FormID from because he was authored before WHY was written
      to JsonUtil at all. Nothing available could name him.

      THE ROSTER IS THE ANSWER, and it is better than FindActorByName. It is a
      FormList of the exact Actors we enrolled, held whether or not their 3D is
      loaded, so a name lookup against it reaches anyone we are tracking no
      matter where they are. FindActorByName is the fallback for the one case
      the roster cannot serve - an actor Romantasy knows and we never enrolled -
      and it carries the Nicollette hazard documented on ResolveFromBase, where
      a display name and a base name disagree.

      Matching is on the DISPLAY name, because that is what the player and
      every log line calls them. Papyrus compares strings case-insensitively,
      so the caller does not have to match capitalisation. }
    If !_ready || asName == ""
        Return
    EndIf
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int i = 0
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None && a.GetDisplayName() == asName
            UnenrollActor(a)
            Return
        EndIf
        i += 1
    EndWhile

    Actor found = SkyrimNetApi.FindActorByName(asName)
    If found != None
        Diag(LOG_WARN(), "'" + asName + "' was not on the roster - un-enrolling the " + \
            "actor SkyrimNet resolved by that name instead. Verify this was the " + \
            "person meant; display and base names can disagree.")
        UnenrollActor(found)
        Return
    EndIf
    Diag(LOG_ERROR(), "Cannot un-enroll '" + asName + "' - nobody by that name is on " + \
        "the roster and SkyrimNet could not resolve them. Check the spelling against " + \
        "a log line; the display name is what is matched.")
EndFunction

Function UnenrollActor(Actor akActor)
    { Undo an accidental enrollment. Dispatch via the web API:
        functionName UnenrollActor, arguments ["0x0001B136"]

      NOT A RESET. Their points, character and prose stay stored; what this
      does is stop us ever acting on them again: off the roster, so neither
      assessor can enumerate them and BuildCircle cannot cite them; out of
      SNRom_Bond and SNRom_Enrolled cleared, so nothing reads them as enrolled
      and AutoEnroll treats them as new; and the debounce stamp cleared, so
      re-adding them deliberately still serves the full waiting period rather
      than enrolling instantly on the old stamp. }
    If akActor == None
        Return
    EndIf
    String who = akActor.GetDisplayName()
    StorageUtil.FormListRemove(None, "SNRom_Roster", akActor, True)
    StorageUtil.UnsetIntValue(akActor, "SNRom_Enrolled")
    StorageUtil.UnsetIntValue(akActor, "SNRom_AutoEnrolled")
    If _bond != None
        akActor.RemoveFromFaction(_bond)
    EndIf
    StorageUtil.UnsetFloatValue(akActor, "SNRom_FirstSeenFollowing")
    StorageUtil.FormListRemove(None, PENDING_LIST(), akActor, True)
    StorageUtil.UnsetFloatValue(akActor, "SNRom_LastTalkCheck")
    StorageUtil.UnsetFloatValue(akActor, "SNRom_LastSparkCheck")
    ; Drift state too, for the same reason as the two above: if they are ever
    ; deliberately re-added, a stale review clock and a half-full evidence
    ; counter would let their personality move on the strength of a life they
    ; lived before we stopped watching.
    StorageUtil.UnsetFloatValue(akActor, "SNRom_LastDriftCheck")
    StorageUtil.UnsetIntValue(akActor, "SNRom_EventsSinceDrift")
    StorageUtil.UnsetFloatValue(akActor, "SNRom_DriftFirstDay")
    StorageUtil.UnsetFloatValue(akActor, "SNRom_DriftLastDay")
    Diag(LOG_INFO(), "Un-enrolled " + who + " - off the roster and out of SNRom_Bond, no longer " + \
        "assessed. Roster now " + StorageUtil.FormListCount(None, "SNRom_Roster"))
EndFunction

Function ReauthorCharacter(Actor akActor)
    { Re-author the character block - orientation, intimacy, ardor,
      exclusivity, WHY, LIMIT, ADDRESS - from the record.

      Dispatch by hand with execute-quest-script-function, questEditorId
      SNRom_Quest, scriptName SNRom_Bridge, functionName ReauthorCharacter, one
      hex FormID argument.

      THE SAME AS ReauthorDisposition FROM 2.0. In 1.x that one also added
      Romantasy preferences, permanently, and this was the character-only
      path; with no preferences there is only the character. Both names are
      kept because the dashboard and every note on dispatching them use them. }
    If akActor == None
        Return
    EndIf
    ReauthorDisposition(akActor)
EndFunction


Function ReauthorDisposition(Actor akActor)
    { Bypasses the once-only guard. Needed for two real cases:

      1. NPCs authored before a schema change. Jordis and Kayla were authored
         when the prompt only produced likes and dislikes, so their
         orientation, intimacy, ardor and exclusivity were never written -
         the two most developed relationships in the save were the only two
         with no authored character.
      2. A player who has pre-seeded facts (a SeverActions custom bio block,
         say) and wants them picked up now rather than never.

      NOT SAFE TO REPEAT CASUALLY: it rewrites the character fields from a
      fresh response, discarding any drift they have accumulated. }
    If akActor == None
        Return
    EndIf
    Diag(LOG_INFO(), "Re-authoring disposition for " + akActor.GetDisplayName())
    ; DELIBERATELY NOT ZEROING SNRom_DispositionAuthored.
    ;
    ; It used to be zeroed here to get past AuthorDisposition's once-only check,
    ; and SNRom_ForceAuthor below has been the real bypass since the on-disk
    ; store started being consulted. The zero was legacy - and once
    ; PreferencesAreForeign started reading that same flag as the ours/theirs
    ; marker, it became actively harmful: zeroing it made this mod's OWN
    ; preferences look like another author's, so the guard refused to touch them
    ; and re-authoring silently stopped replacing anything.
    ;
    ; That defeated the whole point of API 3's replaceable preferences. Observed
    ; on Endarie 2026-08-22: "already holds preferences this mod did not write
    ; (2 of them)" - both of them ours.
    ; Zeroing the Int is no longer sufficient on its own - AuthorDisposition
    ; also consults the on-disk store, which does not roll back and would
    ; refuse. This says "yes, I mean it", and AuthorDisposition consumes it.
    StorageUtil.SetIntValue(akActor, "SNRom_ForceAuthor", 1)
    ; Our own blocks come off first, or the prompt would read our last guess
    ; as the player's direct answer and copy it back. Put back (or replaced)
    ; when the authoring call answers, whatever it answers.
    LiftOurBlocks(akActor)
    AuthorDisposition(akActor)
EndFunction

Function AuthorDisposition(Actor akActor)
    If !_ready || akActor == None
        Return
    EndIf
    ; 1 = LLM-authored: never redo - her opinions are her personality now, and
    ; a re-enrollment after EndRomance must not reroll who she is.
    ; 2 = archetype fallback: DO retry - the fallback was a stopgap, and a
    ; fresh enrollment is the natural moment to upgrade it to the real thing.
    ;
    ; SNRom_ForceAuthor BYPASSES THIS GUARD TOO, and leaving it out of the
    ; condition made ReauthorDisposition a silent no-op for exactly the actors
    ; it exists to serve.
    ;
    ; ReauthorDisposition used to zero the flag above, which got it past this
    ; line. 1.0.2 stopped doing that - correctly, because zeroing it made this
    ; mod's own preferences look foreign to PreferencesAreForeign - and set
    ; SNRom_ForceAuthor instead, on the understanding that the force flag was
    ; "the real bypass". It was only ever the bypass for the ON-DISK guard
    ; below. This one still tested the Int alone, hit Return before the force
    ; flag was ever read, and returned WITHOUT LOGGING ANYTHING.
    ;
    ; Caught on Silana and Lisette 2026-08-24: both logged "Re-authoring
    ; disposition", neither ever dispatched, and nothing said why. Fastred in
    ; the same batch worked, which is what made it look like an LLM problem
    ; rather than a gate - her flag was 0, so she sailed past a guard the other
    ; two hit. A silent Return that only fires for SOME actors is the worst
    ; possible shape for this bug, hence the log line.
    If StorageUtil.GetIntValue(akActor, "SNRom_DispositionAuthored", 0) == 1 &&        StorageUtil.GetIntValue(akActor, "SNRom_ForceAuthor", 0) == 0
        Diag(LOG_INFO(), "Not authoring " + akActor.GetDisplayName() +             " - already LLM-authored. ReauthorDisposition forces a redo.")
        SyncAfterAuthoring(akActor, "?")   ; re-enrolled: blocks from the character they already have
        Return
    EndIf
    ; SECOND GUARD, ON DISK RATHER THAN IN THE SAVE.
    ;
    ; The flag above lives in StorageUtil and ROLLS BACK WITH A SAVE RELOAD.
    ; Romantasy's preferences do not - it keeps its own persistent copy and
    ; restores it - so reloading past an authoring forgets that it happened
    ; while leaving everything it granted in place. The next enrollment would
    ; then stack a whole fresh set on top, permanently, and preference removal
    ; cannot survive a reload either.
    ;
    ; StoreGetText reads the disposition JSON, a FILE - not save data, so it
    ; does not roll back. A stored WHY is durable evidence that this person was
    ; authored, whatever the save believes. Checked second because it is a
    ; string read and the Int above answers the common case.
    ;
    ; THE FILE IS NOW PER-PLAYTHROUGH, and this guard is the reason that matters
    ; more than the prose inheritance. Before StoreFile() was split by save id,
    ; a SECOND playthrough read the FIRST one's file - so this check found a WHY
    ; for every vanilla NPC and refused to author them. A new game therefore
    ; kept the old character AND could never write a new one; the two halves of
    ; the bug hid each other, because the stale disposition looked like a
    ; working one. Scoped to the playthrough, "does not roll back" is true where
    ; it needs to be and false where it must be.
    ;
    ; THE HAZARD IS REAL BUT UNPROVEN. It was added believing Karita had been
    ; double-authored, 4 likes then 7. She had not: there are TWO NPCs named
    ; Karita in Skyrim - 0x01A6C7 and 0x0BC07E - and each was authored once,
    ; correctly. The author caught it. The guard is kept because the rollback
    ; asymmetry is independently documented and the cost is one string read,
    ; not because that incident demonstrated it.
    ;
    ; EXPLICIT RE-AUTHORING MUST STILL WORK. ReauthorDisposition forces a rerun
    ; by zeroing the Int above - but the store still holds the WHY, so this
    ; check would block every ReauthorCharacter and ReauthorDisposition on
    ; anyone ever authored. That is the entire dev workflow. The force flag is
    ; what distinguishes "the save forgot" from "I asked for this".
    If StoreGetText(akActor, "Why") != "" && \
       StorageUtil.GetIntValue(akActor, "SNRom_ForceAuthor", 0) == 0
        Diag(LOG_INFO(), "Not authoring " + akActor.GetDisplayName() + \
            " - the disposition store still holds their WHY, so they were authored before " + \
            "a save reload rolled the flag back. Repairing the flag instead.")
        StorageUtil.SetIntValue(akActor, "SNRom_DispositionAuthored", 1)
        SyncAfterAuthoring(akActor, "?")
        Return
    EndIf
    If _pendingActor != None
        ; QUEUED, not dropped. Dropping was acceptable while authoring only
        ; happened on a deliberate one-at-a-time BeginSpark; with auto-enroll,
        ; hiring two mercenaries in the same breath would have silently left
        ; the second one with no personality forever.
        ;
        ; SNRom_ForceAuthor IS DELIBERATELY STILL SET WHEN THIS RETURNS. Being
        ; queued is not being authored - the dequeue calls this function again
        ; from the top, and the flag has to survive that round trip or the
        ; second pass refuses the very work the first pass accepted.
        ;
        ; It used to be consumed ABOVE this block, so a forced re-author lost
        ; its force the moment anything else was already in flight. Invisible
        ; until the guard at the top learned to read the flag: re-authoring
        ; three followers at once, the first was authored and the other two
        ; were refused on dequeue (Silana yes, Lisette and Fastred no,
        ; 2026-08-24).
        StorageUtil.FormListAdd(None, "SNRom_AuthorQueue", akActor, False)
        Diag(LOG_INFO(), "Authoring busy; queued " + akActor.GetDisplayName() + \
            " (queue depth " + StorageUtil.FormListCount(None, "SNRom_AuthorQueue") + ")")
        Return
    EndIf
    ; Consumed here - past every early return that could still need it, and
    ; before anything that actually authors, so a forced run cannot leak into
    ; the next enrollment.
    StorageUtil.UnsetIntValue(akActor, "SNRom_ForceAuthor")
    If SkyrimNetApi.GetConfigBool(CFG(), "enrollmentLlmPreferences", True) == False
        ApplyArchetype(akActor)
        Return
    EndIf

    _pendingActor = akActor
    _pendingName  = akActor.GetDisplayName()

    ; npc_uuid lets the prompt call render_character_profile, which is the
    ; ONLY way this call sees who the NPC actually is. The old hand-built
    ; npc_bio was twelve words - race, sex, level, "traveling companion" -
    ; and the model was being asked to author a sexual orientation from it.
    ; It invented one for Lynea and hard-blocked her romance. The stub is kept
    ; as a fallback ONLY, for when the profile fails to render.
    ;
    ; IT DOES NOT PICK UP SeverActions' custom bio blocks. This comment used to
    ; claim it did - that they rendered into the character profile, so anything
    ; pre-seeded in PrismaUI arrived as established fact for free. It was never
    ; true under either of SeverActions' designs: the old bioslot submodules and
    ; the revived 0040_severactions_bio_blocks both gate on full/thoughts/
    ; transform, and the profile is assembled from six bio_* modes. The prompt
    ; now calls custom_bio_blocks(npc_uuid) itself, guarded on SeverActions.esp.
    ; A comment asserting a thing works is not evidence that it does; this one
    ; sat here unexamined while the feature it described was removed entirely
    ; and then rebuilt differently.
    ; npc_formid is an INTEGER and the template derives the UUID from it with
    ; formid_to_uuid(). Passing GetEntityUUID's STRING instead looks obviously
    ; right and silently fails: render_character_profile returns "" with NO
    ; error logged, the {% else %} fallback fires, and the model authors from
    ; the twelve-word stub exactly as before - a fix that changes nothing and
    ; reports success. Copied from sever_relationship_assess.prompt:4, which
    ; is the shape known to work on this setup.
    ; ── npc_married: STATE THE FACT, DO NOT HOPE THE BIO CARRIES IT ──────────
    ; Jarl Elisif the Fair is married to the player through MARAS, and was
    ; authored ORIENTATION: WOMEN / BASIS: STATED twice out of three attempts -
    ; STATED being the one confidence level allowed to refuse a romance. The
    ; model was not being perverse: with dynamic bio updates turned off, the
    ; static bio is everything it sees, and the static bio says nothing about
    ; who she married. It was asked to infer an orientation with no evidence
    ; and it obliged, which is the failure mode this prompt already warns about.
    ;
    ; Papyrus KNOWS. IsMarriedToPlayer reads the vanilla faction and MARAS
    ; directly, so the fact can be asserted rather than inferred - and it works
    ; for every NPC automatically, with no per-character bio editing and no
    ; dependency on dynamic bios being enabled.
    ;
    ; This is the general lesson, not an Elisif patch: anything Papyrus can
    ; establish should be STATED in the context, never left for the model to
    ; deduce from prose that may not mention it.
    ; ── KEEP ctx SHORT. A malformed or over-long payload loses EVERYTHING ────
    ;
    ; 2026-08-06: authoring broke completely for every NPC. The template
    ; rendered - catalogue, rules, answer form all present - but npc_name,
    ; npc_bio, npc_formid and cat_seed were ALL undefined, so the model was sent
    ; literal "{{ npc_name }}" and replied "Please provide the details". Two
    ; NPCs, identical failure, so not data-dependent.
    ;
    ; The context is one JSON string. If it is truncated or malformed anywhere,
    ; the WHOLE object is rejected and every field silently becomes undefined -
    ; there is no partial parse and no error. So ctx size is a correctness
    ; concern, not a performance one, and `circle` is the dangerous field: five
    ; roster members' full WHY sentences, unbounded.
    ;
    ; player_name and player_sex are REMOVED rather than shortened. SkyrimNet
    ; already supplies player.name and player.gender as globals to every
    ; prompt - passing our own copies was duplicating data we get for free and
    ; spending payload on it. Check what the engine already gives you before
    ; adding a field.
    ActorBase b = akActor.GetActorBase()
    String circleText = SNRom_Decorators.JsonEscape(BuildCircle(akActor))
    ; Hard cap. BuildCircle is already limited to 5 entries, but each carries a
    ; free-text WHY of unbounded length, so the entry count bounds nothing.
    If StringUtil.GetLength(circleText) > 600
        circleText = StringUtil.Substring(circleText, 0, 600)
        Diag(LOG_WARN(), "Circle text truncated to 600 chars for " + _pendingName + \
            " - it is the only unbounded field in the authoring context, and an over-long " + \
            "context makes EVERY variable undefined rather than just this one.")
    EndIf
    ; ── BUILD THE BOOLEAN LITERAL EXPLICITLY. Never inline it. ──────────────
    ; The context dump caught this red-handed on 2026-08-06:
    ;
    ;     {"npc_name":"Sybille Stentor",...,"npc_married":False,...}
    ;
    ; Capital F. JSON has no such token, so the WHOLE object failed to parse and
    ; every variable - npc_name, npc_formid, cat_seed, circle, npc_bio - came
    ; through undefined. The model received a prompt full of literal
    ; "{{ npc_name }}" and replied "Please provide the details".
    ;
    ; That is Papyrus's implicit Bool->String conversion, which yields
    ; "True"/"False", not JsonBool's lowercase output - even though the source
    ; called JsonBool and the compiled artifact contains only lowercase
    ; literals. I could not reconcile that by inspection, so this stops relying
    ; on the conversion behaving: the string is built by an If, and what goes
    ; into ctx is unambiguously a String.
    ;
    ; THE REAL LESSON IS THE DUMP. Three fixes were shipped for this from
    ; hypotheses - the template, ctx length, JsonEscape - and each cost a
    ; restart. Writing the actual string to a file answered it in one attempt.
    ; When a payload crosses a boundary, log the payload.
    ; ── REVERTED TO THE LAST SHAPE KNOWN TO WORK, 2026-08-06 ────────────────
    ; The four-field shape below is what was in ctx when authoring last
    ; succeeded (Elisif, gd=128.684708, "6 likes (4 new), 4 dislikes (4 new)"),
    ; established as a baseline after a wholesale revert and then PROVEN in
    ; play on 2026-08-07 across Sybille, Bryling and Elisif.
    ;
    ; cat_seed is the FIRST field re-added on the way back up, because Elisif
    ; came back that same session with a verbatim catalogue transcription -
    ; positions 3..N copied straight down the list. Still stripped and awaiting
    ; their own turn: npc_married, player_name, player_sex, the SeverActions
    ; slot block and ADDRESS. One at a time, with a test between each.
    ;
    ; WHY A WHOLESALE REVERT RATHER THAN MORE BISECTING. Four hypothesis-driven
    ; fixes were shipped for this failure - the render mode, ctx length, the
    ; JsonEscape hardening, the False literal - and every one was wrong; one of
    ; them froze the game with an infinite loop. Prompt-side bisecting then
    ; eliminated the CAT array, the SeverActions slot calls and the married
    ; block without finding it either.
    ;
    ; At that point the base itself is no longer trustworthy, and stacking a
    ; sixth guess on top of it is how this went from a one-line feature to two
    ; hours. Go back to a state that demonstrably worked, PROVE it works, then
    ; re-add ONE field at a time with a test between each.
    ;
    ; npc_name is deliberately NOT JsonEscape'd here, matching the working
    ; version exactly. That is a real latent bug for a name containing a quote,
    ; and it gets fixed on the way back up - not now, while establishing a
    ; baseline.
    ; AN INT, NOT A JSON BOOLEAN, AND NOT A STRING LITERAL EITHER.
    ;
    ; JSON has no True/False, so a Papyrus Bool rendered into the context makes
    ; the WHOLE object unparseable and every variable in it - npc_name, npc_bio,
    ; cat_seed, all of them - comes back undefined. Not just this field.
    ;
    ; The obvious fix, assigning the lowercase string "true", DOES NOT WORK and
    ; wasted two attempts before the artifact was checked. Papyrus interns
    ; strings CASE-INSENSITIVELY, so a literal "true" collapses into the
    ; capitalised True already present in the script: source says "true",
    ; SNRom_Bridge.pex's string table says True x6 / False x6, and the context
    ; ships invalid. Same compiler case-fold bug that hid the plugin config.
    ;
    ; An Int cannot be case-folded. The prompt tests `npc_married == 1`.
    ; Verify this one in the .pex, never in the .psc.
    Int marriedFlag = 0
    If IsMarriedToPlayer(akActor)
        marriedFlag = 1
    EndIf

    ; MarasContext, not just marriedFlag. Authoring reads the same six bio_*
    ; modes the seed read does, and SkyrimNet's Dynamic Bio writes into them -
    ; it called Olfina Gray-Mane and Fastred the fiancee of the player while
    ; MARAS recorded ZERO engagements on the save. Without npc_engaged and
    ; npc_candidate the prompt cannot contradict that, so it was believing a
    ; peer system about a fact that system does not own. One extra call on a
    ; path that runs once per character, not per tick.
    String ctx = "{\"npc_name\":\"" + _pendingName + "\"" + \
        ",\"npc_formid\":" + akActor.GetFormID() + \
\
        ",\"npc_married\":" + marriedFlag + MarasContext(akActor) + \
        ",\"circle\":\"" + circleText + "\"" + \
        ",\"npc_bio\":\"" + b.GetRace().GetName() + ", " + \
        SNRom_Decorators.SexWord(b.GetSex()) + ", level " + akActor.GetLevel() + \
        ". Known to the Dragonborn.\"}"

    Int rc = SkyrimNetApi.SendCustomPromptToLLM("snrom_author_disposition", VariantName(), ctx, \
        Self, "SNRom_Bridge", "OnDispositionAuthored")   ; this script IS the quest
    Diag(LOG_INFO(), "Disposition authoring requested for " + _pendingName + " variant='" + VariantName() + "' (rc=" + rc + ")")
    If rc != 1
        Diag(LOG_ERROR(), "SendCustomPromptToLLM failed (rc=" + rc + ") - falling back to archetype")
        ApplyArchetype(_pendingActor)
        _pendingActor = None
    EndIf
EndFunction

Event OnUpdate()
    PumpAuthoringQueue()
    OpenPendingBox()
    CollectAskAnswer()
EndEvent

; ===========================================================================
; The consent loop - raising the question and collecting the answer
;
; CheckRomanceQuestion sets SNRom_AskPending when someone reaches Lover while
; sparked, orientation-permitted and never answered. That flag is a debt: the
; player owes this person an answer and does not yet know it. Everything below
; is about collecting that answer without nagging and without ever deciding on
; the player's behalf.
;
; TWO CLOCKS, ON PURPOSE.
;   - ASKING runs on the GAME-TIME sweep, because the retry interval is in game
;     hours and should pass while traveling or sleeping, not while the player
;     stands still.
;   - COLLECTING runs on the REAL-TIME OnUpdate, because a message box is a UI
;     element and the player answers it in seconds.
; ===========================================================================

Actor _boxActor
Int   _boxId
Float _boxOpenedAt

; SHE SPEAKS FIRST, THEN THE BOX APPEARS.
;
; A message box that materialises with no warning reads as the game asking on
; her behalf, which is exactly the register this loop must avoid. So OpenAsk no
; longer opens anything: it fires a mod event, a trigger voices her raising it
; in her own words, and the box follows a few seconds later carrying only the
; player's half of the exchange.
;
; The delay is REAL time, not game time. It is covering an LLM round trip and a
; line of narration appearing on screen, both of which happen in seconds and
; neither of which should pass while the player sleeps.
;
; Nothing waits on the LLM. If the trigger is disabled, the model is slow, or
; the narration never lands, the box still opens on schedule - the voice is an
; enrichment, never a dependency. That is why this is a plain timer and not a
; callback.
Actor _boxPending
Float _boxVoicedAt

Float Function VoiceLeadSeconds() Global
    { How long her line gets to land before the box interrupts it.

      DO NOT RENAME THIS TO MATCH ITS CONFIG PATH, and do not spell that path
      anywhere in this comment either. Papyrus interns strings
      case-insensitively AND docstrings are embedded in the .pex, so a function
      name - or a stray mention in documentation - that differs from the config
      literal only by case collides with it in the string table. The identifier
      wins, the literal is stored folded to it, and GetConfigFloat is handed a
      path that does not exist: it returns the default forever and the manifest
      setting silently does nothing.

      Caught here only by grepping the .pex. The source looks perfect and the
      compiler says OK. This is the same failure that made the whole plugin
      config inert once already. }
    Return SkyrimNetApi.GetConfigFloat(CFG(), "askVoiceSeconds", 6.0)
EndFunction

Float Function AskRetryHours(Int aiAttempts) Global
    { Backoff, so an unanswered question does not become nagging.

      First attempt is immediate - CheckRomanceQuestion stamps LastAskAttempt
      to 0.0 precisely so the debt is raised at the first good moment rather
      than after serving an interval nobody has earned.

      After that it widens: a player who deferred once was busy, a player who
      has deferred three times is telling you something. }
    If aiAttempts <= 0
        Return 0.0
    ElseIf aiAttempts == 1
        Return 2.0
    ElseIf aiAttempts == 2
        Return 6.0
    EndIf
    Return 24.0
EndFunction

Function PumpAskQueue()
    { Raise the outstanding question with ONE person, if conditions allow.

      Conditions are all cheap and local - no LLM call, no allocation - because
      this runs on every sweep whether or not anyone is owed an answer.

      ONE BOX AT A TIME, globally. Two questions on screen at once would be
      unanswerable in any sensible order.

      TWO FLAGS GUARD THAT, NOT ONE. _boxId covers a box already on screen;
      _boxPending covers the window between her being asked to speak and the
      box appearing. Checking only _boxId would let a second follower start
      raising the same question during that gap, and both boxes would then
      queue up behind each other. }
    If !_ready || _boxId != 0 || _boxPending != None
        Return
    EndIf
    Actor player = Game.GetPlayer()
    If player == None || player.IsInCombat()
        Return
    EndIf
    Float now = Utility.GetCurrentGameTime()
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int i = 0
    While i < n && _boxId == 0 && _boxPending == None
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None && StorageUtil.GetIntValue(a, "SNRom_AskPending", 0) == 1 && !a.IsDead()
            Int attempts = StorageUtil.GetIntValue(a, "SNRom_AskAttempts", 0)
            Float last = StorageUtil.GetFloatValue(a, "SNRom_LastAskAttempt", 0.0)
            ; Game time is DAYS. Multiply to compare against an hours interval.
            Float waitedH = (now - last) * 24.0
            ; She has to be present. Asking on behalf of someone standing in
            ; another hold reads as the game talking, not as her asking.
            If waitedH >= AskRetryHours(attempts) && a.Is3DLoaded() && a.GetDistance(player) < 600.0
                OpenAsk(a)
            EndIf
        EndIf
        i += 1
    EndWhile
EndFunction

Function OpenAsk(Actor akActor)
    { Have her raise it in her own words. The box follows on a timer.

      This function no longer puts anything on screen. It fires
      SNRom_QuestionRaised, the trigger of the same name voices her asking, and
      OpenPendingBox opens the box once that line has had its moment.

      WHY A MOD EVENT AND NOT THE BOX ITSELF. SkyrimNet does capture message
      boxes into prompt context - iActions' fast-travel box is in
      openrouter_input.log with its full button list and has_callback true - but
      capture is not the same as a trigger-matchable event, and there is no
      message-box event type in WORKFLOW_TRIGGERS.md. A mod event is documented,
      fires exactly when we choose, and carries her identity.

      HER NAME TRAVELS IN str_arg. Sent from the actor, sender_form_id resolves
      to her too, but the existing tier trigger already documents that
      sender_form_id is an ActorBase and awkward to resolve back to a reference.
      str_arg sidesteps that entirely and renders the same either way. }
    String who = akActor.GetDisplayName()

    Int attempts = StorageUtil.GetIntValue(akActor, "SNRom_AskAttempts", 0) + 1
    ; Stamped BEFORE anything can fail. A question that never reaches the screen
    ; must still consume its retry slot, or a missing DLL turns into an attempt
    ; every single sweep forever.
    StorageUtil.SetFloatValue(akActor, "SNRom_LastAskAttempt", Utility.GetCurrentGameTime())
    StorageUtil.SetIntValue(akActor, "SNRom_AskAttempts", attempts)

    akActor.SendModEvent("SNRom_QuestionRaised", who, 0.0)

    _boxPending = akActor
    _boxVoicedAt = Utility.GetCurrentRealTime()
    RegisterForSingleUpdate(1.0)
    Diag(LOG_INFO(), who + " is raising the question in her own words (attempt " + attempts + \
        "); the box follows in " + VoiceLeadSeconds() + "s, next retry in " + \
        AskRetryHours(attempts) + "h if unanswered")
EndFunction

Function OpenPendingBox()
    { Puts the question on screen once her line has had its moment.

      DIEGETIC BODY TEXT. SkyrimNet reads message boxes back to every NPC in
      scene, so this reads as something that happened between two people, never
      as UI addressed to a player. Nothing here names a tier, a point or a
      stance.

      SHE HAS TO STILL BE THERE. The gap is only seconds, but a follower can
      die, be dismissed or walk out of range inside it, and a box asking where
      you stand with someone who just left the room is worse than no box. The
      pending slot clears and the retry timer takes it from the top. }
    If _boxPending == None || _boxId != 0
        Return
    EndIf
    If (Utility.GetCurrentRealTime() - _boxVoicedAt) < VoiceLeadSeconds()
        RegisterForSingleUpdate(1.0)
        Return
    EndIf

    Actor akActor = _boxPending
    String who = akActor.GetDisplayName()
    Actor player = Game.GetPlayer()
    If akActor.IsDead() || !akActor.Is3DLoaded() || player == None || \
       akActor.GetDistance(player) >= 600.0
        _boxPending = None
        Diag(LOG_INFO(), "Dropped the question for " + who + \
            " - they are no longer present. It stays owed and will be raised again.")
        Return
    EndIf

    ; ONE PARAGRAPH, NO FORCED BREAKS. The two newlines here used to split this
    ; into two blocks, and Skyrim's message box wrapped each of them on its own
    ; while most of the box width sat unused - it read as cramped text in a wide
    ; frame. The engine wraps well enough on its own; let it.
    String body = who + " has asked where the two of you stand. " + \
        "Whatever you answer, you will have answered it plainly."

    Int id = SNRom_Choice.Open(body, \
        "Tell them you feel the same", \
        "Tell them you do not feel that way", \
        "Say nothing of it for now")
    If id == 0
        _boxPending = None
        Diag(LOG_WARN(), "Could not open the question for " + who + \
            " - Papyrus MessageBox (Nexus 83578) is missing. MARAS bundles it; " + \
            "check SkyrimScripting.MessageBox.dll is in SKSE\\Plugins. Retrying on a later sweep.")
        Return
    EndIf
    _boxPending = None
    _boxActor = akActor
    _boxId = id
    _boxOpenedAt = Utility.GetCurrentRealTime()
    RegisterForSingleUpdate(2.0)
    Diag(LOG_INFO(), "Question on screen for " + who)
EndFunction

Function CollectAskAnswer()
    { Poll the open box and apply whatever the player chose.

      TIMEOUT, because the poll re-registers itself. A player who walks away
      from the box would otherwise leave this ticking for the rest of the
      session. Discarding leaves SNRom_AskPending SET, so the backoff simply
      raises it again later - which is the correct reading of "did not
      answer". }
    If _boxId == 0
        Return
    EndIf
    If !SNRom_Choice.IsAnswered(_boxId)
        If (Utility.GetCurrentRealTime() - _boxOpenedAt) > 180.0
            SNRom_Choice.Discard(_boxId)
            Diag(LOG_INFO(), "Question for " + _boxActor.GetDisplayName() + \
                " went unanswered and was withdrawn - it stays owed and will be raised again.")
            _boxId = 0
            _boxActor = None
            Return
        EndIf
        RegisterForSingleUpdate(2.0)
        Return
    EndIf

    Int answer = SNRom_Choice.Take(_boxId)
    Actor who = _boxActor
    _boxId = 0
    _boxActor = None
    If who == None
        Return
    EndIf

    If answer == SNRom_Choice.ANSWER_ACCEPT()
        ; Clears SNRom_AskPending via SetStance, and the attempt counter with
        ; it - so a later ReopenRomance starts the backoff fresh rather than
        ; inheriting a stale count that would delay the first new ask by a day.
        StorageUtil.UnsetIntValue(who, "SNRom_AskAttempts")
        AcceptRomance(who)
    ElseIf answer == SNRom_Choice.ANSWER_DECLINE()
        StorageUtil.UnsetIntValue(who, "SNRom_AskAttempts")
        DeclineRomance(who)
    ElseIf answer == SNRom_Choice.ANSWER_DEFER()
        ; DISCARD THE WITHHELD AWARD. The author's rule: on "unsure" the points
        ; that would have been awarded are dropped and the follower stays exactly
        ; where they are until the next opportunity. Only acceptance grants them.
        ; Without this the held amount accumulates across deferrals and a late yes
        ; pays out for every conversation the player declined to answer about.
        StorageUtil.UnsetIntValue(who, "SNRom_BankedPoints")
        Diag(LOG_INFO(), "Question deferred for " + who.GetDisplayName() + \
            " - still owed, raised again after backoff.")
    Else
        Diag(LOG_WARN(), "No usable answer for " + who.GetDisplayName() + " - still owed.")
    EndIf
EndFunction

; ===========================================================================
; Attraction feed
;
; SNRom_AttractionRatio was the last gate in this mod that something READ and
; nothing WROTE - PhysicalOk consulted it, so the CASUAL bypass could never
; fire and casual intimacy still effectively required tier 2. Several NPCs are
; authored CASUAL, so an inert key was silently overriding the character the
; LLM wrote for them.
;
; SOURCE IS OSTIM COMMUNITY RESOURCE, NOT A FORMULA OF OURS. OCR already models
; this per-NPC - the answer varies with the NPC's race preference, their social
; class, their sex, and a per-NPC "enthusiast" trait - which is exactly the
; per-character variation this project wants, and a second competing notion of
; attractiveness in the same load order is worse than having no second opinion.
;
; SOFT DEPENDENCY, and the degraded path is the SAFE one: with OCR absent
; GetFormFromFile returns None, the ratio stays 0.0, and PhysicalOk falls back
; to gating on tier alone. The bypass simply never fires, which is what it did
; for this mod's whole history.
; ===========================================================================

; OCR's plugin is a plain ESP (TES4 flags 0x0 - NOT ESL), so these are ordinary
; plugin-local FormIDs read out of the record headers in
; OStimCommunityResource.esp. Verify with the EDID scan in the session notes if
; OCR ever renumbers; a wrong ID here returns None and looks exactly like "OCR
; is not installed", which is the one confusion worth logging apart.
Int Function OCR_ATTRACTION_QUEST() Global
    Return 0x0001710B                           ; OCR_AttractionUtilQST
EndFunction
Int Function OCR_ATTRACTIVENESS_BASE() Global
    Return 0x000170FB                           ; OCR_AttractivenessBase (GLOB)
EndFunction
String Function OCR_PLUGIN() Global
    Return "OStimCommunityResource.esp"
EndFunction

; Set once an unavailability reason has been logged, cleared the moment the
; source resolves again. Purely a log latch - it never suppresses a RETRY.
;
; It exists because the unavailable paths cannot stamp SNRom_LastAttrCheck:
; stamping would mean "checked", and an actor who was skipped because the
; player had not yet answered OCR's questionnaire must be picked up promptly
; once they do, not a game day later. Unstamped, though, the same most-overdue
; actor is re-picked on EVERY tick - so without this latch a missing optional
; dependency would print the same line every two game hours for the rest of the
; playthrough and bury everything worth reading.
;
; A plain script variable is right here rather than StorageUtil: it resets each
; session, which is exactly the cadence a "here is why this feature is idle"
; message wants.
Bool _attrQuiet

OCR_AttractionUtil Function AttractionSource()
    { Resolve OCR's attraction calculator, or None with the reason logged once.

      Order matters. The plugin check comes first because "OCR is not installed"
      is the overwhelmingly common answer and must stay cheap and quiet; the
      questionnaire check comes before the cast because it is the one condition
      where CALLING the calculator would do something the player did not ask
      for. See RefreshAttraction's docstring. }
    Form qf = Game.GetFormFromFile(OCR_ATTRACTION_QUEST(), OCR_PLUGIN())
    If qf == None
        ; DEBUG, not WARN. OCR is optional and most load orders will not have
        ; it; a warning about a dependency the player never chose to install is
        ; noise that trains people to ignore the log.
        If !_attrQuiet
            Diag(LOG_DEBUG(), "Attraction: OStim Community Resource not present - ratio stays 0.0 and the physical gate runs on tier alone")
            _attrQuiet = True
        EndIf
        Return None
    EndIf

    GlobalVariable gv = Game.GetFormFromFile(OCR_ATTRACTIVENESS_BASE(), OCR_PLUGIN()) as GlobalVariable
    If gv == None
        If !_attrQuiet
            Diag(LOG_WARN(), "Attraction: OCR is loaded but OCR_AttractivenessBase did not resolve - its FormIDs may have moved in an OCR update")
            _attrQuiet = True
        EndIf
        Return None
    EndIf
    If gv.GetValue() == 0.0
        ; NEVER let this become "call it anyway and let OCR ask". See below.
        If !_attrQuiet
            Diag(LOG_INFO(), "Attraction: OCR's attractiveness questionnaire is unanswered, so there is no baseline to read. " + \
                "Answer it through OStim and this starts working on its own - we will not raise that prompt from a background sweep.")
            _attrQuiet = True
        EndIf
        Return None
    EndIf

    OCR_AttractionUtil util = qf as OCR_AttractionUtil
    If util == None
        If !_attrQuiet
            Diag(LOG_WARN(), "Attraction: resolved OCR_AttractionUtilQST but its script did not cast - OCR install may be partial")
            _attrQuiet = True
        EndIf
        Return None
    EndIf
    _attrQuiet = False                          ; a later failure is news again
    Return util
EndFunction

Function RefreshAttraction(Actor akActor)
    { Recompute and store one NPC's attraction ratio. ONE argument, so it is
      dispatchable from the web API for probing; it deliberately re-resolves
      the source and clears the log latch so a manual probe always says why it
      did nothing.

      THIS CALL IS NEITHER FREE NOR PURE, and both facts shape everything else
      in this section.

      Not free: CalculateNPCAttraction runs roughly forty GetActorValue calls,
      ten quest-completion checks and up to thirty GetFactionRank calls, and
      prints ten lines to the console, every time. That is why only ONE actor
      is refreshed per tick and why the interval is a game DAY rather than
      hours - its inputs are player skills, fame and main-quest progress, none
      of which move fast enough to care.

      Not pure: it ADDS THE NPC TO FACTIONS. An OCR social class if they have
      none, and a RANDOMLY CHOSEN "enthusiast" trait if they have none. Both
      are OCR's own bookkeeping and OCR would write exactly the same thing the
      first time it evaluated the NPC itself - we only make it happen sooner -
      but a mod that quietly mutates another mod's data should say so in its
      log and should be switchable off. Hence attractionEnabled.

      THE ONE SIDE EFFECT WE MUST NOT CAUSE: if the player has never answered
      OCR's attractiveness questionnaire, CalculateNPCAttraction SHOWS IT -
      three modal message boxes, raised from a background game-time timer, at
      whatever moment our tick happened to land. Read OCR_AttractivenessBase
      first and refuse to proceed while it is 0. The player answers that
      through OStim, on their own terms; we consume the answer and never
      provoke the question.

      Deliberately calls CalculateNPCAttraction rather than GetAttraction. The
      latter is the same computation plus a write to OCR's OCR_CurrentAttraction
      global, which belongs to whatever scene OStim is running. Reading another
      mod's number is fair; overwriting it from a background sweep is not. }
    If akActor == None || !_ready
        Return
    EndIf
    If SkyrimNetApi.GetConfigBool(CFG(), "attractionEnabled", True) == False
        Return
    EndIf
    _attrQuiet = False                          ; a probe always states its reason
    OCR_AttractionUtil util = AttractionSource()
    If util == None
        Return
    EndIf
    ApplyAttraction(util, akActor)
EndFunction

Function ApplyAttraction(OCR_AttractionUtil akSource, Actor akActor)
    { The reading itself, split out so the scheduled path can resolve the
      source ONCE per tick instead of once per actor. }
    Float ratio = akSource.CalculateNPCAttraction(akActor)
    StorageUtil.SetFloatValue(akActor, "SNRom_AttractionRatio", ratio)
    StorageUtil.SetFloatValue(akActor, "SNRom_LastAttrCheck", Utility.GetCurrentGameTime())
    ; Log the THRESHOLD alongside the ratio. On its own "1.83" is unreadable -
    ; the only question anyone asks of this line is whether it cleared the bar,
    ; and the bar is a config value that may not be 1.5 any more.
    Float bar = SkyrimNetApi.GetConfigFloat(CFG(), "attractionBypassRatio", 1.5)
    Diag(LOG_INFO(), "Attraction: " + akActor.GetDisplayName() + " ratio=" + ratio + \
        " bar=" + bar + " (" + AttrVerdict(ratio >= bar) + "). OCR may have assigned them a social class " + \
        "and an enthusiast trait as a side effect of this reading.")
EndFunction

String Function AttrVerdict(Bool abClears) Global
    { Exists only so the log line above reads as a sentence. Inline string
      literals in a Diag concatenation are fine; a bare "true"/"false" next to
      two floats is not. }
    If abClears
        Return "clears the bypass bar"
    EndIf
    Return "below the bypass bar"
EndFunction

Function RefreshNextAttraction()
    { ONE actor per tick, most overdue wins - the same shape as AssessNextTalk
      and AssessNextSpark, for a harder reason than either.

      Those two are bounded naturally: each holds a pending slot until an LLM
      round trip returns, so at most one is ever in flight. This has no round
      trip and would happily run the whole roster inside a single frame, which
      on a ten-follower party is roughly four hundred GetActorValue calls and a
      hundred faction lookups in one Papyrus slice. That is a visible hitch. }
    If !_ready
        Return
    EndIf
    If SkyrimNetApi.GetConfigBool(CFG(), "attractionEnabled", True) == False
        Return
    EndIf
    Float now = Utility.GetCurrentGameTime()
    Float interval = SkyrimNetApi.GetConfigFloat(CFG(), "attractionRefreshHours", 24.0) / 24.0
    Int n = 0
    If _observers
        n = _observers.Length
    EndIf
    Int i = 0
    Actor pick = None
    Float bestWait = -1.0
    While i < n
        Actor a = _observers[i]
        ; IsFollowing, matching every other candidate test in this script. The
        ; ratio only matters while they are with the player, and refreshing it
        ; for someone dismissed to Whiterun spends the budget on a number
        ; nothing will read.
        If a != None
            Float last = StorageUtil.GetFloatValue(a, "SNRom_LastAttrCheck", 0.0)
            If (now - last) >= interval && (now - last) > bestWait
                bestWait = now - last
                pick     = a
            EndIf
        EndIf
        i += 1
    EndWhile
    If pick == None
        Return                                  ; whole party is current - cost so far is a roster walk
    EndIf
    ; Resolve AFTER choosing, not before. With everyone up to date this function
    ; is then just StorageUtil reads, and the two GetFormFromFile calls are only
    ; paid on a tick that is actually going to do something.
    OCR_AttractionUtil util = AttractionSource()
    If util == None
        Return                                  ; reason already logged, once
    EndIf
    ApplyAttraction(util, pick)
EndFunction

; ===========================================================================
; Tier seeding - reconstructing history that already happened
;
; Without it an NPC the game already records as the player's SPOUSE starts at
; Stranger/0 and has to climb the whole ladder as if they had just met.
;
; THE GOVERNING ASYMMETRY: BOND DEPTH IS REVERSIBLE, THE SPARK IS NOT.
; ModifyPoints accepts negatives, so a points seed that lands wrong is a number
; you can walk back. SNRom_Sparked is once-per-NPC-ever and rewrites how they
; speak to the player for the rest of the game. So the two axes are seeded from
; DIFFERENT evidence and only one of them is seeded at all:
;
;   Bond depth (points)          <- objective history, seeded here
;   Romantic track               <- NOT set here. Seeding only sets
;                                   SNRom_SeedRomantic, which EXEMPTS them from
;                                   the tenure gate so the spark assessor may
;                                   judge them now instead of in two game days.
;                                   The assessor still decides. Its prompt
;                                   already says an established fact in the
;                                   profile settles the question, so a spouse
;                                   crosses on the first look - through the
;                                   normal path, on evidence, rather than by us
;                                   inferring a spark from a faction.
;
; A child appears nowhere in the romantic column, which is why the Sapphire case
; - one night, a child, no commitment - falls out with NO special-case logic:
; real bond depth, no romance, and she can still want the player through the
; separately authored INTIMACY axis.
; ===========================================================================

; Evaluated once per session. MARAS is a soft dependency and its Papyrus
; surface is entirely native, so every call is a no-op-with-an-error-line when
; the DLL is absent - cheap individually, but this runs per follower per seed.

String Function MarasStateLine(Actor akActor) Global
    { What MARAS believes about this person, for the log only.

      Added after an afternoon spent reconstructing one companion's marital
      state from a crash log, an OpenRouter transcript and the MARAS source.
      All of it was one native call away the whole time. Nothing reads this - it
      exists so the next question of this shape is a grep. }
    If !MarasPresent() || akActor == None
        Return ""
    EndIf
    String status = "none"
    If MARAS.IsNPCStatus(akActor, "married")
        status = "married"
    ElseIf MARAS.IsNPCStatus(akActor, "engaged")
        status = "engaged"
    ElseIf MARAS.IsNPCStatus(akActor, "candidate")
        status = "candidate"
    EndIf
    Return " marasStatus=" + status + " playerSpouses=" + MARAS.GetStatusCount("married")
EndFunction

String Function MarasContext(Actor akActor) Global
    { The marriage facts, stated rather than inferred, for the three assessors.

      This is the npc_married lesson generalised. Elisif was authored
      ORIENTATION: WOMEN / BASIS: STATED - the one confidence level allowed to
      refuse - because the static bio says nothing about who she married, so the
      model was asked to infer with no evidence and obliged. Papyrus knew all
      along. The same was true of the talk assessor, which had no marriage
      vocabulary at all and paid a LANDMARK award for a wedding that had not
      happened and, with the polygamy quest incomplete, could not happen.

      INTS, NOT STRINGS, for the booleans. A context boolean fed by a String is
      the case-fold trap in another coat, and check.ps1 fails the build over it.

      npc_married sits OUTSIDE the MARAS guard on purpose: IsMarriedToPlayer
      reads the vanilla PlayerMarriedFaction first, so a vanilla marriage is
      still a fact when MARAS is absent.

      WE DO NOT GATE ON ANY OF THIS. Spouse tier is DEPTH, and a shield-sister
      who will never be a lover has to be able to reach it - gating it on a
      marriage system would collapse the two tracks back into one ladder. These
      are facts for the NPC to judge, which is the whole design. }
    Int present   = 0
    Int married   = 0
    Int engaged   = 0
    Int candidate = 0
    Int spouses   = 0
    If IsMarriedToPlayer(akActor)
        married = 1
    EndIf
    If MarasPresent()
        present = 1
        If MARAS.IsNPCStatus(akActor, "engaged")
            engaged = 1
        EndIf
        If MARAS.IsNPCStatus(akActor, "candidate")
            candidate = 1
        EndIf
        spouses = MARAS.GetStatusCount("married")
    EndIf
    Return ",\"maras_present\":" + present +            ",\"npc_married\":" + married +            ",\"npc_engaged\":" + engaged +            ",\"npc_candidate\":" + candidate +            ",\"player_spouse_count\":" + spouses
EndFunction

Bool Function MarasPresent() Global
    { GLOBAL and uncached, same reasoning as SeverActionsPresent: a Global has
      no instance state to cache into, and IsPluginInstalled is a cheap native
      lookup. Made Global when IsMarriedToPlayer had to be reachable from
      SNRom_Decorators. The previous version cached into _marasState and logged
      once on absence; the log line is the only thing lost, and it was DEBUG. }
    Return Game.IsPluginInstalled("TT_MARAS.esp")
EndFunction

Int Function SeedTarget(Actor akActor)
    { The point total this NPC's ALREADY-LIVED history justifies.

      Three signals, deliberately chosen because their ranges are KNOWN. This
      project has been burned repeatedly by calibrating against a scale nobody
      verified, so anything whose range I could not confirm from source is read
      and LOGGED but not allowed to move the number:

        SeverFollower_Rapport   -100..100  documented at
                                SeverActions_FollowerManager.psc:30
        GetRelationshipRank     -4..4      vanilla, 4 = Lover
        MARAS married/engaged   boolean

        MARAS GetPermanentAffection - range is UNDOCUMENTED and configurable at
        runtime via SetAffectionMinMax, so it contributes NOTHING and is only
        logged. Give it a ratio once a real save shows what values it takes.

      Rapport is the primary signal and replaces the LLM read of her diary that
      the original design called for: it is a persisted number expressing how
      she actually feels, earned in real play, for anyone who has ever traveled
      with the player. Deterministic beats judged, when the deterministic thing
      is measuring the right quantity.

      A tier is exactly 500. Confirmed by ColdSun directly on 2026-08-20, after
      two independent observations had already agreed: Romantasy's own UI on
      2026-08-03, and Kayla's seed landing precisely on tier 1. This was carried
      as an inference for weeks and this docstring outlived the evidence that
      settled it. The ratios below are still expressed against 500 and the caller
      still logs the tier that actually landed rather than trusting the
      arithmetic, which is worth keeping regardless. }
    ; THE HIGHEST ESTIMATE WINS - these are not contributions to be summed.
    ;
    ; Each signal is a COMPLETE estimate of one quantity (how deep is this bond)
    ; expressed on its own scale, and they overlap almost entirely: a married
    ; companion has rank 4 AND MARAS married AND high rapport, three readings of
    ; the same fact. Adding them paid for that history three times and pinned
    ; every long-standing follower to the cap regardless of who they were, which
    ; flattens exactly the per-character variation this mod exists to produce.
    Int best = 0

    ; ---- Vanilla relationship rank ----------------------------------------
    ; Not a ratio. Vanilla's rank NAMES are Romantasy's tier names - Acquaintance,
    ; Friend, Confidant, then Ally, then Lover - because both are modeling the
    ; same ladder, so this reads the game's own answer rather than inventing a
    ; conversion. Shifted down one deliberately: a vanilla Lover seeds to
    ; Confidant, not Lover, so the romance still has somewhere to go afterwards.
    ; Tiers are exactly 500 apart, 2500 at Spouse - confirmed by ColdSun on
    ; 2026-08-20, and before that by Romantasy's UI on 2026-08-03 and by Kayla's
    ; seed landing exactly on tier 1.
    ; ---- RANK 3 IS CONTAMINATED, AND EVERYTHING BELOW LOVER WITH IT --------
    ; Measured over 34 live seeds on 2026-08-10: THIRTY-ONE came back rank 3,
    ; including Alva and Jonna, both recruited the day before and neither
    ; previously known to the player. Follower frameworks set the vanilla rank
    ; to Ally on recruitment, so rank 3 does not mean "we are close" - it means
    ; "this person is a follower", which is already the precondition for being
    ; seeded at all. It was worth 1250, i.e. tier 2, which is exactly the gate
    ; a CASUAL disposition (72% of authored NPCs) needs for physical intimacy.
    ; Every new companion therefore arrived with that gate already open, which
    ; is the day-one problem re-entering through the seed rather than through
    ; an award.
    ;
    ; The sub-Lover rungs are scaled down together rather than rank 3 alone -
    ; vanilla rank 3 (Ally) outranks rank 2 (Confidant), so moving one without
    ; the others would invert the ladder and seed a Confidant ABOVE an Ally.
    ;
    ; Rank 4 is left alone. Vanilla only reaches it through marriage or a
    ; specific quest, never through recruitment, so it is the one rung that
    ; still means what it says.
    ; SCALED DOWN A SECOND TIME, 2026-08-24. 750 shut the intimacy gate but
    ; still landed a brand-new companion at tier 1 and halfway through it -
    ; Senna, Orla and Hamal all seeded at exactly 750 two game hours after
    ; being met, having done nothing together but talk. Clearing the whole of
    ; Stranger on the strength of recruitment is the same error the 1250 cut
    ; addressed, one rung down: rank 3 carries no information about closeness,
    ; so it must not buy a tier.
    ;
    ; Ratios between the sub-Lover rungs are preserved exactly (5:4:2:1), so
    ; the ladder still cannot invert.
    ;
    ; This also hands the axis back to rapport, the signal that means
    ; something: at 15 points per rapport it overtakes rank 3 from about 14
    ; rapport rather than 50, so someone who has genuinely travelled with the
    ; player now outranks someone hired this morning by a wide margin.
    Int rank = akActor.GetRelationshipRank(Game.GetPlayer())
    Int byRank = 0
    If rank >= 4                                ; Lover - uncontaminated
        byRank = 1500                           ; -> Confidant
    ElseIf rank == 3                            ; Ally - set by recruitment
        byRank = 200                            ; -> Stranger, and only part way
    ElseIf rank == 2                            ; Confidant
        byRank = 160
    ElseIf rank == 1                            ; Friend
        byRank = 80
    ElseIf rank == 0                            ; Acquaintance
        byRank = 40
    EndIf                                       ; hostile ranks estimate nothing
    If byRank > best
        best = byRank
    EndIf

    ; ---- SeverActions rapport ---------------------------------------------
    ; NATIVE, not StorageUtil. SeverFollower_Rapport is a dead key - see the
    ; long note in IsFollowing. Reading it returned 0.0 for everyone, silently,
    ; and the first live seed (Kayla, rapport=0.000000 rank=4) is what exposed
    ; it. Range is -100..100; only the positive half can estimate depth.
    ;
    ; THE MULTIPLIER HAS TO BE ABLE TO BEAT THE RANK BRANCH, or this signal is
    ; decorative. At 10.0 the ceiling was 100 * 10 = 1000, below the old rank-3
    ; constant of 1250, so across 31 seeded NPCs with rapport ranging from 0 to
    ; 100 the rank branch won every single time and all 31 landed on the same
    ; number. A "primary signal" that cannot change the answer is not one.
    ; At 15.0 the ceiling is 1500 and rapport overtakes rank 3 from about 50,
    ; which is the point of this whole function: someone who has actually
    ; traveled with the player outranks someone hired yesterday.
    If SeverActionsPresent()
        Float rapport = SeverActionsNative.Native_GetRapport(akActor)
        Int byRapport = (rapport * SkyrimNetApi.GetConfigFloat(CFG(), "seedPointsPerRapport", 15.0)) as Int
        If byRapport > best
            best = byRapport
        EndIf
    EndIf

    ; ---- Marriage: THE EXCEPTION TO THE SHIFT-DOWN RULE ---------------------
    ;
    ; Everything above deliberately seeds one tier BELOW what the evidence
    ; names, so a romance still has somewhere to go. Marriage is exempt, by
    ; The author's call on 2026-08-04: they should not have to earn the right to be a
    ; Spouse when they are literally already a spouse. A completed ceremony is
    ; not evidence pointing at a relationship, it IS the relationship, and it is
    ; the one piece of state the game records with no ambiguity at all.
    ;
    ; This was previously 1500, on the reasoning that a MARAS marriage and a
    ; vanilla rank-4 Lover were "the same claim by another route". Watching it
    ; apply to an actual spouse showed that was wrong: a relationship STATE and
    ; a completed CEREMONY are not equivalent evidence.
    ;
    ; Engagement raised 1000 -> 2000 to keep the ladder coherent. An engagement
    ; is an explicit mutual commitment to marry; leaving it at Friend while
    ; marriage sits at Spouse put four tiers between two adjacent states. It
    ; stays inside seedMaxPoints, so it is still capped like everything else.
    If IsMarriedToPlayer(akActor)
        best = 2500                             ; Spouse - see the cap exemption
    ElseIf MarasPresent() && MARAS.IsNPCStatus(akActor, "engaged")
        If 2000 > best
            best = 2000                         ; Lover
        EndIf
    EndIf

    Return best
EndFunction

Int Function CommitmentState(Actor akActor) Global
    { How far this person has formally committed: 0 nothing, 1 candidate,
      2 engaged, 3 married. Ordered on purpose, so a rising number is a real
      step forward and a falling one is a real step back.

      READ, NEVER RECORDED. MARAS already owns this state machine -
      candidate, engaged, married, divorced, jilted - and vanilla owns
      PlayerMarriedFaction. Keeping our own copy would mean two records that
      can disagree, and the one that disagrees is always ours, because a
      marriage or a divorce can happen entirely through their dialogue while
      nothing tells us about it.

      Married is checked FIRST and by IsMarriedToPlayer, which accepts either
      the vanilla faction or MARAS, because a completed marriage outranks any
      earlier rung regardless of which mod recorded it. Without MARAS the
      middle two rungs simply do not exist and this collapses to 0 or 3, which
      is the correct answer for a game that only models the wedding.

      THE DASHBOARD DRAWS A COPY OF THIS: Display::Commitment in
      native/src/Display.cpp, line for line. Change one, change both. }
    If akActor == None
        Return 0
    EndIf
    If IsMarriedToPlayer(akActor)
        Return 3
    EndIf
    If MarasPresent()
        If MARAS.IsNPCStatus(akActor, "engaged")
            Return 2
        EndIf
        If MARAS.IsNPCStatus(akActor, "candidate")
            Return 1
        EndIf
    EndIf
    Return 0
EndFunction
Bool Function IsMarriedToPlayer(Actor akActor) Global
    { Married, by whichever system the player actually uses. Vanilla and MARAS
      both count and neither is preferred - the question is whether the game
      records a completed marriage, not which mod recorded it.

      GLOBAL so SNRom_Decorators.RomanceOk can reach it. That gate runs on
      authored orientation, and an authored trait must never be able to
      contradict a recorded marriage - see the note there.

      THE DASHBOARD DRAWS A COPY OF THIS: Display::MarriedToPlayer in
      native/src/Display.cpp, line for line. Change one, change both. }
    If akActor == None
        Return False
    EndIf
    Faction married = Game.GetFormFromFile(0x000C6472, "Skyrim.esm") as Faction   ; PlayerMarriedFaction
    If married != None && akActor.IsInFaction(married)
        Return True
    EndIf
    If MarasPresent() && MARAS.IsNPCStatus(akActor, "married")
        Return True
    EndIf
    Return False
EndFunction

Bool Function SeedRomanticEvidence(Actor akActor)
    { EXPLICIT DECLARATIONS ONLY. Not points, not tier, not rapport, not
      affection - none of those say two people are together, they say the
      relationship has depth, and depth is exactly what a close platonic
      companion of many years also has.

      NOT RELATIONSHIP RANK 4 EITHER, which this used to accept.

      That was the same conflation the seeding table exists to undo. Vanilla has
      exactly one axis and calls its top of it "Lover", so rank 4 has to carry
      both "we are extremely close" and "we are together" at once. This mod
      splits those deliberately - THE SAPPHIRE CASE IS THE WHOLE POINT: a
      Confidant, or even a Friend, may well go to bed with the player for its
      own sake while wanting none of the commitment that Lover implies. Vanilla
      cannot express that; we can, through the authored INTIMACY axis and the
      attraction bypass, and rank 4 must not quietly overrule it.

      So rank 4 seeds DEPTH (1500, Confidant - see SeedTarget) and says nothing
      here. What counts is an actual ceremony: PlayerMarriedFaction, or MARAS
      reporting married/engaged. Those are declarations; a rank is a summary.

      This gates nothing on its own; it only lets the spark assessor look early.
      Someone at rank 4 who really is in love simply reaches that verdict the
      ordinary way, on evidence, after the tenure gate - which costs two game
      days and is exactly the wait the gate was built to impose. }
    Faction married = Game.GetFormFromFile(0x000C6472, "Skyrim.esm") as Faction   ; PlayerMarriedFaction
    If married != None && akActor.IsInFaction(married)
        Return True
    EndIf
    If MarasPresent()
        If MARAS.IsNPCStatus(akActor, "married") || MARAS.IsNPCStatus(akActor, "engaged")
            Return True
        EndIf
    EndIf
    Return False
EndFunction

Bool Function SeedActor(Actor akActor)
    { Seed ONE follower, once ever. Safe to call repeatedly - it is a no-op
      after it succeeds, and a rejected attempt changes nothing at all.

      RETURNS whether the seed is now SETTLED for this actor, which is not the
      same as "points were awarded": needing none is just as settled as being
      given some. Only a REJECTION is unsettled. SeedNextActor spends its
      one-per-tick budget on that distinction. }
    If akActor == None || !_ready
        Return False
    EndIf
    If SkyrimNetApi.GetConfigBool(CFG(), "seedEnabled", True) == False
        Return False
    EndIf
    If StorageUtil.GetIntValue(akActor, "SNRom_Seeded", 0) == 1
        Return True
    EndIf

    Int target = SeedTarget(akActor)
    Int cap = SkyrimNetApi.GetConfigInt(CFG(), "seedMaxPoints", 2000)
    ; MARRIAGE IS EXEMPT FROM THE CAP, not merely valued highly by it.
    ;
    ; The cap exists so that no amount of accumulated HISTORY can hand out the
    ; top of the ladder. A completed marriage is not accumulated history - it is
    ; a stated fact, and it is the single case the ladder's top rung describes.
    ; Left capped at the default 2000 this whole change would have been inert:
    ; the 2500 would have been clipped straight back to Lover.
    If IsMarriedToPlayer(akActor)
        cap = 2500
    EndIf
    If target > cap
        Diag(LOG_INFO(), "Seeding: " + akActor.GetDisplayName() + " computed " + target + \
            " but the cap is " + cap + " - seeding must never hand out the top of the ladder")
        target = cap
    EndIf

    ; SEED TO A FLOOR, never add on top. Two reasons, and the second is the one
    ; that actually bites: the attempt below is normally REJECTED the first few
    ; times (see the note in ApplyTalkAward - Romantasy snapshots its roster at
    ; load, so an NPC enrolled this session is invisible to it until the next
    ; one), and we retry every tick until it lands. Between the first attempt
    ; and the successful one they may have earned real points from conversation.
    ; Adding a fixed delta would then count that history twice.
    ;
    ; It also makes backfilling the existing roster safe: someone who has
    ; already earned MORE than their history justifies gets nothing rather than
    ; a windfall.
    Int current = PointsOf(akActor)
    Int delta = target - current
    If delta <= 0
        StorageUtil.SetIntValue(akActor, "SNRom_Seeded", 1)
        Diag(LOG_INFO(), "Seeding: " + akActor.GetDisplayName() + " needs none - history justifies " + \
            target + " and they already have " + current)
        SeedRomanticFlag(akActor)
        Return True
    EndIf

    ; NOT ScaleAward: seeding describes a relationship that existed before this mod
    ; was installed. A slow setting must not retroactively shrink someone's past.
    ; From 1.9 the points are ours and this is not refused for being newly
    ; enrolled; the branch below is left for the one refusal that remains
    ; (their points could not be brought over from Romantasy yet).
    Bool applied = ApplyDepth(akActor, delta, "Prior history together", True, "seed") > 0
    If !applied
        ; Not stamped, so the next tick tries again: never seeding someone at
        ; all, silently, is the worse failure.
        Diag(LOG_DEBUG(), "Seeding: the seed for " + akActor.GetDisplayName() + \
            " did not land - will retry on the next check.")
        Return False
    EndIf

    StorageUtil.SetIntValue(akActor, "SNRom_Seeded", 1)
    Diag(LOG_INFO(), "Seeding: " + akActor.GetDisplayName() + " granted " + delta + \
        " pts of prior history, now at " + target + ". Deliberately not pace-scaled.")
    ; Record the rapport this seed CONSUMED. The SeverActions rapport bridge was
    ; designed but never built; if it ever is, it must convert deltas measured
    ; from here rather than from zero, or every point of rapport already spent
    ; on this seed gets paid out a second time.
    Float rapportNow = 0.0
    If SeverActionsPresent()
        rapportNow = SeverActionsNative.Native_GetRapport(akActor)
    EndIf
    StorageUtil.SetFloatValue(akActor, "SNRom_SeedRapportAt", rapportNow)
    Ledger(akActor, "seed", "", delta, 1, "Prior history together")

    ; READ BACK the tier rather than computing it. "500 per tier" is inference
    ; from "2500 to Spouse" and has never been confirmed against Romantasy's
    ; native code. Logging what actually landed is how that finally gets
    ; verified, from real saves, without hardcoding the guess anywhere.
    Int affection = -1
    If MarasPresent()
        affection = MARAS.GetPermanentAffection(akActor)
    EndIf
    Diag(LOG_INFO(), "Seeded " + akActor.GetDisplayName() + " +" + delta + " -> " + \
        PointsOf(akActor) + " pts, tier " + TierOf(akActor) + \
        " (" + TierName(TierOf(akActor)) + "). rapport=" + rapportNow + \
        " rank=" + akActor.GetRelationshipRank(Game.GetPlayer()) + \
        " marasAffection=" + affection + " (logged for calibration only, unused)" +         MarasStateLine(akActor))

    SeedRomanticFlag(akActor)
    Return True
EndFunction

Function SeedRomanticFlag(Actor akActor)
    { Separate from the points seed because it must survive the points seed
      being rejected, capped, or already satisfied - none of which say anything
      about whether the game records these two as together. }
    If SeedRomanticEvidence(akActor)
        If StorageUtil.GetIntValue(akActor, "SNRom_SeedRomantic", 0) != 1
            StorageUtil.SetIntValue(akActor, "SNRom_SeedRomantic", 1)
            Diag(LOG_INFO(), "Seeding: the game already records " + akActor.GetDisplayName() + \
                " and the player as together, so they skip the wait before romance can be judged. " + \
                "This does NOT set the spark - the assessor still decides.")
        EndIf
    EndIf

    ; A MARRIAGE SETS THE SPARK DIRECTLY. Everything else leaves it to the
    ; assessor, and that distinction is the whole point of the rule.
    ;
    ; This is NOT the LLM-judged spark seeding the design forbids. That rule
    ; exists because SNRom_Sparked was once-per-NPC-ever and a wrong YES could
    ; not be undone; the evidence here is a completed ceremony the game records,
    ; not a model's reading of a diary. UnsparkActor also exists now, so it is
    ; no longer irreversible.
    ;
    ; And without it the seed is INCOHERENT. Seeding a spouse to 2500 puts them
    ; on tier 5 - which on the platonic ladder reads "some bonds are not
    ; romances and are no smaller for it". That is a fine line for a lifelong
    ; friend and an absurd one for the person you are married to.
    ;
    ; Stance is ACCEPTED for the same reason: the top of the romantic ladder is
    ; gated on the player having agreed, and a wedding is that agreement. Left
    ; UNANSWERED, a spouse would have rendered "what you feel has outgrown
    ; anything you have said aloud, and you have not said it."
    If IsMarriedToPlayer(akActor)
        Bool changed = StorageUtil.GetIntValue(akActor, "SNRom_Sparked", 0) != 1 || \
                       StorageUtil.GetIntValue(akActor, "SNRom_PlayerStance", 0) != STANCE_ACCEPTED()
        StorageUtil.SetIntValue(akActor, "SNRom_Sparked", 1)
        If StorageUtil.GetFloatValue(akActor, "SNRom_SparkedAt", 0.0) <= 0.0
            StorageUtil.SetFloatValue(akActor, "SNRom_SparkedAt", Utility.GetCurrentGameTime())
        EndIf
        StorageUtil.SetIntValue(akActor, "SNRom_PlayerStance", STANCE_ACCEPTED())
        If changed
            Diag(LOG_INFO(), "Seeding: " + akActor.GetDisplayName() + " is MARRIED to the player - " + \
                "romantic ladder and player stance set directly from the ceremony, not judged. " + \
                "No spark assessment needed; there is nothing left to decide.")
        EndIf
    EndIf
EndFunction

Int Function SPOUSE_MIN() Global
    { Points at which Romantasy calls someone "Spouse", and the rung the author's
      ladder makes a formal marriage proposal eligible at.

      Stranger to Confidant is free. Crossing into Lover pops the consent
      question. Lover to Spouse is free. Crossing Spouse is what earns the right
      to be asked - and the proposal and its acceptance ARE the consent to marry,
      which is why there is no second question here. }
    Return 2500
EndFunction

Keyword Function IgnoreProposalKeyword() Global
    { MARAS's own exclusion keyword, resolved by editor ID.

      LOGS LOUDLY ON None RATHER THAN RETURNING QUIETLY. MARAS resolves this
      through its own getter (GetIgnoreProposeKeyword), so if they ever rename the
      record our hardcoded string stops matching, Keyword.GetKeyword returns None,
      and a gate that silently stops gating is worse than no gate at all. }
    Return Keyword.GetKeyword("TTM_IgnoreProposal")
EndFunction

Function MaintainProposalGate(Actor akActor)
    { Keep MARAS's proposal exclusion in step with the ladder: present below
      Spouse, absent at or above it.

      THIS IS THE SECONDARY GATE, NOT THE PRIMARY ONE, and that is worth saying
      plainly. MARAS consults the keyword in two places - a CK condition on its
      vanilla dialogue topic, and AcceptProposalIsElgigible for the SkyrimNet
      action. On a SkyrimNet setup NEITHER runs:

        - the vanilla topic is suppressed while TTM_MCM_AllowAIDial is on, which
          is why no proposal option appears in her dialogue at all
        - the action's eligibility is a Papyrus call, and SkyrimNet refuses
          Papyrus calls while the game is paused - which it always is during
          dialogue. Measured 2026-08-31: "CheckActionEligibility: Blocking VM
          call for action ACCEPTMARRIAGEPROPOSAL because game is paused", 40
          times in one session, and the action is then offered ANYWAY. Eligibility
          fails OPEN.

      So this is maintained for the setups where it does bite, and because it
      costs almost nothing. The gate that actually holds is the event handler.

      CHEAP BY CONSTRUCTION. One HasKeyword native, and it only writes when the
      desired state differs from the current one - so the steady state is a single
      read per point change and nothing else. }
    If akActor == None || !_ready
        Return
    EndIf
    Keyword kw = IgnoreProposalKeyword()
    If kw == None
        ; Once per session is enough; this is a broken-integration warning, not a
        ; per-award one.
        If StorageUtil.GetIntValue(None, "SNRom_WarnedNoProposalKw", 0) != \
           StorageUtil.GetIntValue(None, "SNRom_SessionId", 0)
            StorageUtil.SetIntValue(None, "SNRom_WarnedNoProposalKw", \
                StorageUtil.GetIntValue(None, "SNRom_SessionId", 0))
            Diag(LOG_ERROR(), "TTM_IgnoreProposal did not resolve, so the marriage " + \
                "gate cannot be applied. Either MARAS is absent - in which case this " + \
                "is harmless - or the keyword has been renamed and the gate is now " + \
                "silently inert.")
        EndIf
        Return
    EndIf
    Bool shouldBlock = PointsOf(akActor) < SPOUSE_MIN()
    Bool isBlocked   = akActor.HasKeyword(kw)
    If shouldBlock == isBlocked
        Return                                  ; already correct - the common case
    EndIf
    If shouldBlock
        PO3_SKSEFunctions.AddKeywordToRef(akActor, kw)
        Diag(LOG_INFO(), "Marriage gate closed for " + akActor.GetDisplayName() + \
            " - below Spouse at " + PointsOf(akActor) + " pts.")
    Else
        PO3_SKSEFunctions.RemoveKeywordFromRef(akActor, kw)
        PO3_SKSEFunctions.RemoveKeywordOnForm(akActor.GetActorBase(), kw)
        Diag(LOG_INFO(), "Marriage gate OPEN for " + akActor.GetDisplayName() + \
            " - reached Spouse at " + PointsOf(akActor) + " pts. A formal " + \
            "proposal is now earned.")
    EndIf
EndFunction

Event OnMarasStatusChanged(String asEventName, String asStatus, Float afStatusEnum, Form akSender)
    { MARAS announced a relationship change. TWO statuses matter, and the second
      one was added later - this docstring said "other statuses are ignored:
      engagement is already read at seed time" while the code below had stopped
      ignoring it, which is the sort of comment that gets believed.

      ENGAGED is the marriage gate, and it is the one that actually holds. See
      the note at the branch for why enforcement has to happen on an event rather
      than through eligibility, and why engagement rather than marriage is the
      intercept.

      MARRIED re-seeds rather than topping up, because ReseedActor clears the
      stamp and re-runs the whole computation, which will now see the marriage and
      land on Spouse. That re-seed is ASYNCHRONOUS since it became a record read,
      so it can be deferred behind a pending one - which is why ReconcileMarriages
      and not this is what guarantees a spouse reaches the Spouse floor.

      A DIVORCE MUST NOT CLAW POINTS BACK - those were earned, and Romantasy owns
      what a break-up costs. Candidate and jilted are genuinely ignored. }
    Actor who = akSender as Actor
    If who == None || !_ready
        Return
    EndIf
    If !IsEnrolled(who)
        Return
    EndIf
    String st = SNRom_Decorators.Upper(SNRom_Decorators.Trim(asStatus))

    ; -- THE MARRIAGE GATE THAT ACTUALLY HOLDS ------------------------------
    ; The author designed the ladder so a formal proposal is only possible once
    ; the follower has crossed into Spouse. The keyword MaintainProposalGate
    ; sets is the polite version of that, and on a SkyrimNet setup it never
    ; fires: the vanilla topic is suppressed by AllowAIDial, and the action's
    ; Papyrus eligibility is SKIPPED while the game is paused, which it always
    ; is during dialogue. Eligibility fails open. So the enforcement has to
    ; happen after the fact, on an event, which runs unpaused.
    ;
    ; ENGAGEMENT IS THE INTERCEPT, not marriage. MARAS goes candidate ->
    ; engaged -> married, and CANCELWEDDINGENGAGEMENT exists as a separate
    ; action, so engagement is a real distinct step. Reversing it costs a
    ; status field. Reversing a COMPLETED marriage would mean unpicking spouse
    ; assets, hierarchy rank and house tenancy across 13 registered homes, and
    ; a mod that quietly dissolves marriages is worse than one that leaks.
    If st == "ENGAGED"
        Int held = PointsOf(who)
        If held < SPOUSE_MIN()
            If MARAS.PromoteNPCToStatus(who, "candidate")
                Diag(LOG_INFO(), "Engagement reversed for " + who.GetDisplayName() + \
                    " - they hold " + held + " pts and Spouse begins at " + SPOUSE_MIN() + \
                    ". A formal proposal is not earned yet, so they are back to candidate. " + \
                    "Nothing else changes and nothing is lost." + MarasStateLine(who))
            Else
                Diag(LOG_ERROR(), "MARAS refused to demote " + who.GetDisplayName() + \
                    " from engaged, so the marriage gate has leaked. They hold " + held + \
                    " pts against a Spouse floor of " + SPOUSE_MIN() + "." + MarasStateLine(who))
            EndIf
            Return
        EndIf
        Diag(LOG_INFO(), "Engagement allowed for " + who.GetDisplayName() + " - " + \
            held + " pts is at or past Spouse." + MarasStateLine(who))
        Return
    EndIf

    If st != "MARRIED"
        Return
    EndIf
    ; A marriage below Spouse means the gate was bypassed - almost certainly a
    ; proposal accepted during paused dialogue, where eligibility never ran.
    ; SAID LOUDLY AND NOT UNDONE: see the note above on what unpicking a
    ; marriage would cost. ReconcileMarriages will still put them at Spouse,
    ; because a recorded marriage outranks the ladder once it exists.
    If PointsOf(who) < SPOUSE_MIN()
        Diag(LOG_ERROR(), "MARRIED BELOW SPOUSE: " + who.GetDisplayName() + " holds " + \
            PointsOf(who) + " pts against a floor of " + SPOUSE_MIN() + \
            ". The proposal gate was bypassed - most likely accepted during paused " + \
            "dialogue, where SkyrimNet skips Papyrus eligibility. Not undone: a " + \
            "recorded marriage is left standing." + MarasStateLine(who))
    EndIf
    Diag(LOG_INFO(), "MARAS reports " + who.GetDisplayName() + \
        " is now married - re-seeding so the Spouse ceiling applies." + MarasStateLine(who))
    ReseedActor(who)
EndEvent

Function RefreshPartnerCount()
    { How many people the player has an ACKNOWLEDGED romance with, cached for
      the bio prompt.

      WHY THE BOND PROMPT NEEDS THIS. The exclusivity block describes what
      another partner WOULD cost - "if they take another partner that is not a
      disappointment to absorb, it is the end of what you have". For a player who
      already has two, that is not a hypothetical, it is a description of the
      present, and the character is being told to defend a line that was crossed
      long ago and survived. Observed 2026-09-06 on Iddra: she agreed to bear the
      player's child knowing there were others, then refused to share him on the
      grounds of a rule she had already been living under.

      ACKNOWLEDGED, NOT MERELY DEEP. Sparked AND the player answered yes. A
      companion nobody has said anything to is not a rival, and counting depth
      alone would make every close friend one.

      ON THE HOUSEKEEPING TICK, NOT PER RENDER. GetRomance is called on every bio
      render; walking a 71-entry roster there would be a per-prompt cost for a
      number that changes a handful of times per playthrough. }
    If !_ready
        Return
    EndIf
    Int n = 0
    Int i = 0
    Int total = StorageUtil.FormListCount(None, "SNRom_Roster")
    While i < total
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None && !a.IsDead() && SNRom_Decorators.IsSparked(a) && \
           StorageUtil.GetIntValue(a, "SNRom_PlayerStance", 0) == STANCE_ACCEPTED()
            n += 1
        EndIf
        i += 1
    EndWhile
    If StorageUtil.GetIntValue(None, "SNRom_PartnerCount", -1) != n
        Diag(LOG_INFO(), "Acknowledged partners: " + n + ". The bond prompt uses this " + \
            "so an exclusivity boundary is not described as hypothetical to someone " + \
            "already living with the answer.")
    EndIf
    StorageUtil.SetIntValue(None, "SNRom_PartnerCount", n)
EndFunction

Int Function EXCL_MIGRATION_VERSION() Global
    { Bump this ONLY to run a NEW migration. Changing it re-runs the sweep on
      every existing save, which is a data mutation - so it is a deliberate act,
      not a version number that tracks the mod's. }
    Return 1
EndFunction

Int Function CONSUMING_MIN() Global
    { Where the bond prompt's "you cannot share them" band begins. Duplicated
      from the prompt on purpose and flagged here: if that boundary moves, this
      constant and the migration below both have to move with it, and a silent
      divergence would sweep the wrong people. }
    Return 88
EndFunction

Function MigrateLegacyExclusivity()
    { ONE-SHOT. Pulls every roster member at CONSUMING down into POSSESSIVE,
      because values written at that extreme predate the scale being anchored and
      are not trustworthy.

      WHY THIS IS NOT COSMETIC, and it is the whole reason it exists. 1.5.0 gives
      the >= 88 band an "and there are already N others" continuation, and that
      text says the relationship ENDS rather than gets negotiated. Correct for
      someone deliberately authored that way. But measured 2026-09-06: 29 roster
      members sat at 88+, 27 of them at exactly 100, and every single one was
      authored before the calibration landed - while the block that would justify
      it, `Attachment: Cannot Share at All`, had never been applied to anybody.
      Shipping the continuation without this sweep would hand 29 relationships a
      script for ending, on the strength of a number nobody chose. That is worse
      than the version it replaces, which stated the condition abstractly and let
      it lie.

      UNCONDITIONAL, AND THAT IS THE HONEST FORM. The tempting version exempts
      anyone carrying the Cannot-Share block - but Papyrus cannot see bio blocks
      at all (`custom_bio_blocks` is a prompt decorator, not a native), and it
      does not need to: re-authoring reads that block correctly now and restores
      100 for anyone who genuinely holds it. So this claims only what it can
      support - "the old scale's extreme is not evidence" - and leaves the actual
      judgment to a re-author.

      75 IS THE TARGET because it is mid-POSSESSIVE, so it cannot be mistaken for
      a boundary value, and because that band's own others-continuation is the
      MOVABLE one - a real refusal that can still be brought round at a cost.
      Verified in play on Jora at 75 on 2026-09-06, which is the arc these
      characters should have been getting all along.

      RUNS FROM HOUSEKEEPING, NOT BOOTSTRAP, so SweepFollowers has already had a
      pass and the roster is settled before anything is rewritten. Once the stamp
      is set the steady cost is one Int read per housekeeping tick.

      EVERY CHANGE IS LOGGED WITH ITS OLD VALUE, quietly. Quietly because 29
      notifications would be a toast storm that buries the one line worth reading
      - and with the old numbers in the log, a character who should have stayed at
      100 is restored with SetCharacterField rather than guessed at. }
    If StorageUtil.GetIntValue(None, "SNRom_ExclMigration", 0) >= EXCL_MIGRATION_VERSION()
        Return
    EndIf
    ; STAMPED BEFORE THE WORK, not after. A mid-sweep interruption - a load, a
    ; crash, a script lag spike - must not leave this eligible to run again on a
    ; roster it has already half-rewritten, because the second pass would read
    ; the values the first pass wrote and could not tell them apart from
    ; originals. Missing a few actors is recoverable by hand; a partial re-run is
    ; not distinguishable from a correct one.
    StorageUtil.SetIntValue(None, "SNRom_ExclMigration", EXCL_MIGRATION_VERSION())
    Int moved = 0
    Int i = 0
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None
            ; NO IsDead OR IsFollowing FILTER, deliberately, unlike the other
            ; roster sweeps. Those gate live behaviour; this repairs stored data,
            ; and a dismissed companion is exactly who this is for - they are the
            ; ones nobody has got around to re-authoring. A dead one costs a
            ; single Int read.
            ; DEFAULT -1, A SENTINEL, NOT 50. Elsewhere in this script 50 is
            ; the right default to READ for an unauthored actor - it is the
            ; sensible middle. Here it would be a value this function COMPARES,
            ; and a migration that cannot tell "never authored" from "authored
            ; to the middle" is one bump away from rewriting people who have no
            ; stored opinion at all. Read a sentinel, write nothing.
            Int had = StorageUtil.GetIntValue(a, "SNRom_Exclusivity", -1)
            If had >= CONSUMING_MIN()
                StorageUtil.SetIntValue(a, "SNRom_Exclusivity", 75)
                moved += 1
                Diag(LOG_WARN(), "Recalibrated " + a.GetDisplayName() + \
                    " exclusivity " + had + " -> 75. Written under the old " + \
                    "unanchored scale; re-author to restore " + had + \
                    " if it was genuinely meant.", True)
            EndIf
        EndIf
        i += 1
    EndWhile
    Diag(LOG_INFO(), "Exclusivity migration " + EXCL_MIGRATION_VERSION() + \
        " complete: " + moved + " of " + n + " roster members recalibrated.")
    If moved > 0
        Say(moved + " companions had their limits on sharing you re-read - the old readings were unreliable at the extreme.")
    EndIf
EndFunction

Function CheckContentLoaded(Bool abSettled = False)
    { Did SkyrimNet actually load this mod's prompts, triggers and actions?

      THE FAILURE THIS EXISTS FOR IS COMPLETELY SILENT. SkyrimNet Beta 25 stopped
      reading `prompts/`, `config/triggers/` and `config/actions/` and reads a
      plugin library instead - old files are "ignored, not deleted". Install it
      over a mod that only ships the old layout and every line of Papyrus here
      still runs: decorators register, the tick fires, the roster sweeps, the
      hotkeys arm. What is gone is every prompt, so SendCustomPromptToLLM returns
      rc=1 - ACCEPTED, never executed - the callbacks never land, the assessors
      hold their slots until the 90-second timeout, and the bond submodule renders
      nothing at all. Nothing throws. The log looks healthy.

      IsActionRegistered TESTS THE OUTCOME, NOT A PROXY FOR IT, which is why this
      does not sniff the build version. A version test only catches the one cause
      we predicted. Asking whether the action is actually registered catches all
      of them: the wrong layout, a plugin folder rejected because its name does
      not match the manifest id, a single file skipped for a bad extension, a
      manifest that failed validation, a player who deleted something. If the
      answer is no, nothing this mod does will work, whatever the reason.

      ONE ACTION STANDS FOR THE LAYER. RomanceMarkMoment is the workhorse and
      ships in the same folder as the rest; if the layer loaded at all it is
      registered. This is deliberately a coarse test - it answers "is our content
      there", not "is every file there", and the log warns about the latter.

      ASKED AT BOOTSTRAP AND AGAIN ON THE TICK, and only YES latches. The first
      two attempts at this got the cadence wrong in the same direction:
      housekeeping is gated on two GAME HOURS, and even the fast tick needs the
      game unpaused for half a game hour. Both left a player who had just
      installed staring at a log that said nothing at all - which is the silence
      this check exists to end, reproduced faithfully. Measured twice on
      2026-09-11.

      So Bootstrap asks immediately, because the answer is almost always
      available: SKSE plugins load their content long before a quest script
      bootstraps on a game load. The remaining worry was a race against
      SkyrimNet still building its action registry - and the fix for that is not
      to delay the question, it is to not believe a NO. A yes is conclusive and
      latches. A no leaves the state unknown so the next tick asks again, and
      only the tick announces a failure to the player.

      That way the common case reports instantly and the rare race costs one
      extra call, instead of every player paying for a hazard almost none of
      them have.

      PLAYER-FACING, NOT JUST LOGGED. Every other diagnostic here can wait for
      someone to open a file. This one means the mod they installed is doing
      nothing, and they would otherwise play for hours before suspecting it. }
    If _contentSeen != 0
        Return
    EndIf
    If SkyrimNetApi.IsActionRegistered("RomanceMarkMoment")
        _contentSeen = 1
        Diag(LOG_INFO(), "Content layer loaded - RomanceMarkMoment is registered. " + \
            "SkyrimNet build " + SkyrimNetApi.GetBuildVersion() + ".")
        Return
    EndIf
    If !abSettled
        ; NOT AN ANSWER YET. Bootstrap may simply have asked before SkyrimNet
        ; finished registering. Say nothing, change nothing, let the tick decide.
        Return
    EndIf
    _contentSeen = 2
    Diag(LOG_ERROR(), "CONTENT NOT LOADED. SkyrimNet has not registered " + \
        "RomanceMarkMoment, so this mod's prompts, triggers and actions are not " + \
        "reaching it. Everything else will appear to run and nothing will work: " + \
        "LLM calls are accepted and never answered, and companion bios lose their " + \
        "relationship section entirely. SkyrimNet build " + \
        SkyrimNetApi.GetBuildVersion() + ". Relationships 2.0 needs SkyrimNet 0.25.0 " + \
        "(Beta 25) or newer, which reads it from SkyrimNet's external plugin folder; " + \
        "older builds cannot see it at all. On 0.25.0 or newer, reinstalling this mod " + \
        "is the usual fix.")
    Say("SkyrimNet is not loading Relationships' content - it needs SkyrimNet Beta 25 or newer. See the log.")
EndFunction

Function SweepLoverCeiling()
    { The consent question across the whole roster, not just on whoever
      earned something recently: CheckRomanceQuestion is level-triggered, and
      a romance held short of Lover earns nothing while it waits, so the one
      state the question exists to resolve never reaches Ledger by itself.

      1.x also pulled back here anyone Romantasy's own scoring had carried
      over the line (EnforceLoverCeiling). From 2.0 nothing can carry them
      over - ApplyDepth withholds - so only the question is left. }
    Int i = 0
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None && !a.IsDead()
            ; NO IsFollowing OR Is3DLoaded FILTER: the question can be owed to
            ; someone nobody is looking at, and that is who this exists for.
            ;
            ; THIRD TIME THIS EXACT GAP HAS APPEARED IN THIS FILE, which is what
            ; makes it worth stating rather than just fixing. CheckRomanceQuestion
            ; is called only from Ledger, Ledger fires only on a POINT CHANGE, and
            ; a romance held at the rest point earns nothing while it waits - so
            ; the one state the question exists to resolve is the one state that
            ; never re-evaluates it. MaintainProposalGate had it and got
            ; SweepProposalGates; the 1.x Lover ceiling had it and got this
            ; sweep; its neighbour had it all along and I did not look.
            ;
            ; Sybille Stentor, 2026-09-15: 1749 held, 483 banked, 2232 earned,
            ; idle. The corrected test was installed and could not run for her.
            ;
            ; THE RULE, for anything added here later: a gate reached only from
            ; Ledger is a gate that only fires for whoever recently earned
            ; something. If the state it judges can be REACHED BY STANDING STILL,
            ; it needs a place in this walk too.
            CheckRomanceQuestion(a)
        EndIf
        i += 1
    EndWhile
EndFunction

Function SweepProposalGates()
    { Establish the marriage gate across the whole roster, not just on whoever
      happened to earn points recently.

      WHY THIS IS NEEDED. MaintainProposalGate is called from Ledger, which fires
      only on a POINT CHANGE. So the gate was lazily established: measured
      2026-09-01, only one of five tested followers had ever had it evaluated, and
      Camilla Valerius was sitting as a MARAS candidate at 1999 pts with an
      acceptance chance of 0.993 and no keyword on her at all. A gate that exists
      only for whoever recently earned something is not a gate.

      This runs on the housekeeping tick and closes that hole. It also covers the
      case Ledger structurally cannot: a follower who is simply idle, and anyone
      enrolled before this feature existed.

      CHEAP, AND DELIBERATELY SO. MaintainProposalGate reads HasKeyword and
      returns immediately when the state is already correct, so the steady cost is
      one native read per roster entry per housekeeping tick - no writes, no
      GetPoints beyond the one comparison, and nothing at all once every follower
      is settled. The keyword is resolved ONCE here rather than per actor, because
      Keyword.GetKeyword is the only part of this that is not trivially cheap.

      NOT GATED ON FOLLOWING. Unlike ReconcileMarriages, which needs Romantasy to
      accept a point change, this only adds or removes a keyword - so it works for
      anyone on the roster whether or not they are travelling. A spouse waiting at
      home should still not be proposable at 900 points. }
    If !_ready
        Return
    EndIf
    If IgnoreProposalKeyword() == None
        Return                                  ; MaintainProposalGate logs this once
    EndIf
    Int i = 0
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None && !a.IsDead()
            MaintainProposalGate(a)
        EndIf
        i += 1
    EndWhile
EndFunction

Function ReconcileMarriages()
    { Heal a spouse who was seeded before MARAS could say they were married.
      ONE CHECK PER CHARACTER PER SAVE LOAD.

      THIS IS THE ONE THAT FIXES AN ALREADY-BROKEN SAVE, and the obvious
      alternative does not. Declining to stamp SNRom_Seeded when a marriage is
      missed cannot work: in the race IsMarriedToPlayer returns FALSE at seed
      time, so there is no fact for such a guard to notice. It cannot detect
      what it cannot see. Only a later re-read can.

      WHY NOT IN Bootstrap. MARAS initialises on load exactly as we do, and
      IsNPCStatus reads its native state. Checking at load would race the same
      way the original seed did and reach the same wrong answer. This runs on the
      housekeeping tick, after the sweep has refreshed follower states.

      THE MARKER IS PER ACTOR AND PER SESSION, not one flag for the whole pass.
      A single flag meant a spouse recruited later in the same session waited for
      the next load. Keyed this way, someone who becomes a follower mid-session
      is checked on the next tick instead.

      AND IT IS CHEAP, because the ordering does the work. An actor already
      checked this session costs one StorageUtil Int read and nothing else - no
      faction lookup, no MARAS call, no GetPoints. Only an unchecked FOLLOWER
      pays for those, at most once per load each.

      FROM 2.0, ANYONE NEAR THE PLAYER (Observers), following or not. The
      follower test was Romantasy's: it refused points to anyone not
      following. Ours land, so a spouse waiting at home is checked when the
      player is home. }
    If !_ready
        Return
    EndIf
    If SkyrimNetApi.GetConfigBool(CFG(), "seedEnabled", True) == False
        Return
    EndIf
    Int session      = StorageUtil.GetIntValue(None, "SNRom_SessionId", 0)
    Int spouseFloor  = 2500
    Int i = 0
    Int n = 0
    If _observers
        n = _observers.Length
    EndIf
    While i < n
        Actor a = _observers[i]
        ; Cheapest test first: everyone settled this session stops here.
        ; Alive and near the player already (Observers): following stopped
        ; mattering with Romantasy, which refused points to anyone not following.
        If a != None && StorageUtil.GetIntValue(a, "SNRom_MarriageChecked", -1) != session
            StorageUtil.SetIntValue(a, "SNRom_MarriageChecked", session)
            If IsMarriedToPlayer(a)
                Int have = PointsOf(a)
                If have < spouseFloor
                    ; NOT ScaleAward: a correction to prior history, the same
                    ; exemption seeding has. Bond Pace must not shrink a
                    ; marriage that already happened.
                    If ApplyDepth(a, spouseFloor - have, "Married to you", True, "married") > 0
                        Diag(LOG_INFO(), "Marriage reconcile: " + a.GetDisplayName() + \
                            " is married but held only " + have + " pts - raised to " + \
                            spouseFloor + "." + MarasStateLine(a))
                    Else
                        ; Unstamp so the next tick tries again.
                        StorageUtil.SetIntValue(a, "SNRom_MarriageChecked", -1)
                        Diag(LOG_WARN(), "Marriage reconcile: the top-up for " + \
                            a.GetDisplayName() + " did not land. Will retry.")
                    EndIf
                EndIf
            EndIf
        EndIf
        i += 1
    EndWhile
EndFunction
Actor  _seedActor
String _seedName
; WHEN THE PENDING READ WAS DISPATCHED, in real seconds, so a callback that
; never arrives cannot wedge seeding for the rest of the session. See
; SeedReadInFlight.
Float  _seedSentAt
; HAND-REQUESTED, so the answer is announced on screen instead of only in the
; log. An automatic seed is silent by design - it fires on a housekeeping tick
; the player did not ask for and must not interrupt them. A seed they pressed a
; key for is the opposite: they are standing there waiting for it.
Bool   _seedByHand

Int Function StandingToPoints(String asWord) Global
    { A tier WORD, not a number, for the same reason ArdorWord exists: a judge
      calibrates far better against "confidant" than against 1750.

      FIVE WORDS, NOT FOUR, AND `DEVOTED` IS WHY. The first version stopped at
      CONFIDANT and mapped it to the ceiling, so every strong read landed on the
      same 1999 - "deep and mutual" and "married in all but name" collapsed into
      one answer. That is the bimodal failure this project has already measured
      twice: EXCLUSIVITY offered only endpoints and came back 22-of-55 at the
      top, and INTIMACY skipped its middle value entirely, 1 in 55. A word doing
      double duty is how a scale loses its middle.

      So the top of the range is split. `CONFIDANT` sits mid-rung and `DEVOTED`
      takes the ceiling, which means the judge has to actually decide whether
      this is a deep bond or a love affair in everything but the saying of it.

      THE CEILING IS UNANSWERED_MAX BY DESIGN. The author asked for the seeding
      ceiling to sit just under the Lover floor, so overwhelming evidence lands
      one conversation away from the consent question rather than through it.
      Seeding must never answer, on the player behalf, a question the player is
      supposed to be asked. }
    String w = SNRom_Decorators.Upper(SNRom_Decorators.Trim(asWord))
    If w == "DEVOTED"
        Return UNANSWERED_MAX()                 ; 1999 - one point short of Lover
    ElseIf w == "CONFIDANT"
        Return 1650                             ; mid Confidant (1500-1999)
    ElseIf w == "FRIEND"
        Return 1250                             ; mid Friend (1000-1499)
    ElseIf w == "ACQUAINTANCE"
        Return 750                              ; mid Acquaintance (500-999)
    ElseIf w == "STRANGER"
        Return 200
    EndIf
    Return 0                                    ; unreadable - contributes nothing
EndFunction

Int Function KnownCap(String asKnown) Global
    { The most a seed may credit for how long two people have known each other.

      THE SEED HAD NO CLOCK. Live play does: talk moves a bond at most
      talkDailyCap (200) a game day, one landmark per talkLandmarkDays. The seed
      read what had happened and never when, so an eventful first day scored as
      a deep bond - Sosia Tremellia, 2026-09-21, seeded 1250 (mid Friend) about
      five game hours after she first followed the player, and Daighre 750 a day
      in. The author's rule: someone met less than a day ago is a stranger
      however much happened, and time known has to be a factor at every stage.

      The prompt computes the span from the oldest OWN memory on record and has
      the judge copy it back; this caps only the READ. The rank/rapport floor is
      never capped (it is the game's own record of history), nor is a marriage.
      Each cap is the top of its tier, so a stronger read still lands higher in
      the band than a weaker one instead of both collapsing to the same floor.

      0 means no time limit: MONTHS_OR_MORE, UNKNOWN, or anything unreadable.
      Unreadable must not mean strict - that would under-seed long-known
      characters whenever a response is malformed. The caller logs it. }
    String k = SNRom_Decorators.Upper(SNRom_Decorators.Trim(asKnown))
    If k == "NO_RECORD"
        ; NOTHING RECORDED BETWEEN THEM AT ALL - not even a first meeting. The
        ; author's call, 2026-09-22: take the smallest value rather than the top
        ; of the band, because there is no evidence to place them anywhere
        ; inside it, and the re-read hotkey can lift them later once there is.
        Return 200                              ; the Stranger seed value itself
    ElseIf k == "TODAY_OR_YESTERDAY"
        Return 499                              ; top of Stranger
    ElseIf k == "DAYS"
        Return 999                              ; top of Acquaintance
    ElseIf k == "WEEKS"
        Return 1499                             ; top of Friend
    EndIf
    Return 0
EndFunction

String Function KnownPhrase(String asKnown) Global
    { Why the read was held back, as a clause a player reads in a toast. }
    String k = SNRom_Decorators.Upper(SNRom_Decorators.Trim(asKnown))
    If k == "NO_RECORD"
        Return "nothing is recorded between you yet"
    ElseIf k == "TODAY_OR_YESTERDAY"
        Return "you met today or yesterday"
    ElseIf k == "DAYS"
        Return "you have known each other a few days"
    ElseIf k == "WEEKS"
        Return "you have known each other a few weeks"
    EndIf
    Return "you have not known each other long"
EndFunction
Function AssessSeed(Actor akActor)
    { Read the record and say where this relationship already stands.

      WHY THIS EXISTS. Measured 2026-09-01 across 63 seeded followers: rapport
      was exactly 5.0 for 57% of them and rank was 3 for 61 of 63, so SeedTarget
      returned about 200 for almost everyone whatever had happened between them.
      Its docstring called rapport "a persisted number expressing how she
      actually feels, earned in real play" - it was not being earned at all.

      The original design wanted an LLM read of the diary and was talked out of
      it on the grounds that deterministic beats judged WHEN THE DETERMINISTIC
      THING MEASURES THE RIGHT QUANTITY. It did not. This is that read restored,
      against a far richer store than existed when it was dropped.

      ONE PENDING AT A TIME, same discipline as the other three assessors. }
    If akActor == None || !_ready
        Return
    EndIf
    ; SeedReadInFlight, NOT a bare `_seedActor != None`. The slot is released by
    ; the callback, so a read that never came back held it for the whole session
    ; and this - the AUTOMATIC path - would have declined every follower forever
    ; while logging one line per tick. The timeout lives in that function.
    If SeedReadInFlight()
        ; SAY SO. Lisbet was requested while Silana was still pending and this
        ; returned in silence, so the test looked like a failed call rather than
        ; a queue doing its job. One line is the difference.
        Diag(LOG_WARN(), "Seed assessment for " + akActor.GetDisplayName() + \
            " skipped - a read for " + _seedName + " is still pending. Ask again.")
        Return
    EndIf
    _seedActor  = akActor
    _seedName   = akActor.GetDisplayName()
    _seedSentAt = Utility.GetCurrentRealTime()
    String prior = "vanilla relationship rank " + akActor.GetRelationshipRank(Game.GetPlayer())
    If SeverActionsPresent()
        prior = prior + ", SeverActions rapport " + SeverActionsNative.Native_GetRapport(akActor)
    EndIf
    String ctx = "{\"npc_name\":\"" + _seedName + "\"" + \
        ",\"npc_formid\":" + akActor.GetFormID() + \
        ",\"npc_bio\":\"" + Escape(akActor.GetActorBase().GetRace().GetName()) + ", known to the Dragonborn\"" + \
        ",\"npc_prior\":\"" + Escape(prior) + "\"" + MarasContext(akActor) + "}"
    Int rc = SkyrimNetApi.SendCustomPromptToLLM("snrom_seed_assess", VariantName(), ctx, \
        Self, "SNRom_Bridge", "OnSeedAssessed")
    Diag(LOG_INFO(), "Seed assessment sent for " + _seedName + " (rc=" + rc + ")")
    If rc != 1
        ; SAY SO WHEN SOMEONE IS WAITING ON IT. On the housekeeping path a
        ; refused dispatch is a log line and the next tick tries again. On the
        ; hotkey path the player pressed a key and would otherwise be told
        ; nothing at all, which is indistinguishable from a dead keybind.
        If _seedByHand
            Say("Could not reach the model to re-read " + _seedName + ".")
            _seedByHand = False
        EndIf
        _seedActor = None
    EndIf
EndFunction

Bool Function SeedReadInFlight()
    { Is a seed read already out?

      Checked BEFORE dispatching a hand-requested one, because AssessSeed holds
      a single pending slot and declines a second request with nothing but a log
      line - and a hotkey that silently does nothing reads as a broken hotkey
      rather than as a queue doing its job.

      TIMES THE SLOT OUT, and that is not defensive noise. The slot is released
      by the callback, so a response that never arrives - a dropped LLM call, a
      backend that died mid-request - held it for the rest of the session, and
      SeedNextActor would then never seed anyone again. Nothing surfaced that,
      because the automatic path fails quietly by design. The hotkey would have
      turned it into "still reading the record for Lydia" forever.

      NINETY REAL SECONDS is far longer than a read takes and far shorter than a
      play session. Releasing the slot early costs at worst one duplicate read,
      which is harmless: seeding tops up and cannot pay twice. }
    If _seedActor == None
        Return False
    EndIf
    Float waited = Utility.GetCurrentRealTime() - _seedSentAt
    ; Negative means the save was made in a previous launch, since real time
    ; counts from game start - so the pending actor is a stale save value and
    ; there is no read out at all. Same trap as Bootstrap's debounce.
    If waited < 0.0 || waited > 90.0
        Diag(LOG_WARN(), "Seed read for " + _seedName + " never came back (" + waited + \
            "s) - releasing the slot so seeding is not stuck for the session.")
        _seedActor = None
        _seedByHand = False
        Return False
    EndIf
    Return True
EndFunction

Event OnSeedAssessed(String asResponse, Int aiSuccess)
    { SkyrimNet's callback for AssessSeed, named in its dispatch. A thin
      wrapper since WP2: the read itself is SeedAssessed, below, which has many
      exits, and an open dashboard wants the row pushed after whichever one
      runs - a re-read started from the dashboard ends here. }
    Actor who = _seedActor
    SeedAssessed(asResponse, aiSuccess)
    If _dashText
        PushBond(who, 0)
    EndIf
EndEvent

Function SeedAssessed(String asResponse, Int aiSuccess)
    { The read comes back as a tier word. Papyrus decides what it is worth.

      TOPS UP, NEVER CLAWS BACK. The author's call, and it is the rule seeding has
      had: if the read lands at or below what they already hold, do nothing.
      Taking points off an established relationship on the strength of one LLM
      call is the one direction that cannot be justified.

      RANK AND RAPPORT SURVIVE AS A FLOOR. SeedTarget still runs and still wins
      where it is higher, so a cautious read cannot lower a Hroki whose rapport
      of 65 already justifies 975. They were only ever meant to be one input
      among several rather than the signal. }
    Actor  who   = _seedActor
    String asked = _seedName
    ; CAPTURED AND CLEARED TOGETHER with the pending actor. Every return path
    ; below reads `announce` rather than the member, so a read that lands while
    ; a second one is being dispatched cannot announce against the wrong name.
    Bool   announce = _seedByHand
    _seedActor = None
    _seedByHand = False
    If who == None || aiSuccess != 1
        ; FALL BACK TO THE DETERMINISTIC SEED rather than leaving them at zero.
        ; Without this, a player whose LLM endpoint is down or rate-limited gets
        ; no seeding at all and every follower sits at Stranger - worse than the
        ; rank-and-rapport table this replaced, which at least answered something.
        Diag(LOG_WARN(), "Seed assessment for " + asked + " failed or returned " + \
            "nothing - falling back to rank and rapport alone.")
        If announce
            Say("The re-read of " + asked + " came back empty. Fell back to rank and rapport.")
        EndIf
        If who != None
            SeedActor(who)
        EndIf
        Return
    EndIf
    String echoed = SNRom_Decorators.NameCore(SNRom_Decorators.FieldValue(asResponse, "NAME:"))
    If echoed != "" && echoed != SNRom_Decorators.NameCore(asked)
        Diag(LOG_ERROR(), "Seed echo mismatch: asked about " + asked + ", answered as " + \
            echoed + ". Discarded.")
        If announce
            Say("The answer for " + asked + " came back about " + echoed + " - discarded.")
        EndIf
        Return
    EndIf
    String standing = SNRom_Decorators.FieldValue(asResponse, "STANDING:")
    String because  = SNRom_Decorators.FieldValue(asResponse, "BECAUSE:")
    Int byRead = StandingToPoints(standing)
    If byRead == 0
        Diag(LOG_WARN(), "Seed read for " + asked + " returned an unreadable standing: '" + \
            standing + "'. Falling back to rank and rapport alone.")
    EndIf
    ; TIME KNOWN CAPS THE READ - see KnownCap. Before the floor comparison on
    ; purpose: the rank/rapport floor records history the game itself kept and
    ; must stay able to lift someone past a cautious or time-limited read.
    Int readRaw = byRead
    String known = SNRom_Decorators.Upper(SNRom_Decorators.Trim(SNRom_Decorators.FieldValue(asResponse, "KNOWN:")))
    Bool married = IsMarriedToPlayer(who)
    Int timeCap = 0
    If !married && SkyrimNetApi.GetConfigBool(CFG(), "seedTimeLimit", True)
        timeCap = KnownCap(known)
        If timeCap == 0 && known != "MONTHS_OR_MORE"
            Diag(LOG_WARN(), "Seed read for " + asked + " carried no usable time known (KNOWN: '" + \
                known + "') - no time limit applied.")
        EndIf
    EndIf
    If timeCap > 0 && byRead > timeCap
        byRead = timeCap
    EndIf
    ; What a toast calls the standing. A limited read still names the judge's
    ; word, so "reads as FRIEND" arriving with a Stranger's points is explained
    ; rather than looking like the read was ignored.
    String shown = standing
    If byRead < readRaw
        shown = standing + ", held back - " + KnownPhrase(known)
    EndIf
    Int byOld  = SeedTarget(who)
    Int target = byRead
    If byOld > target
        target = byOld
    EndIf
    Int cap = UNANSWERED_MAX()
    If married
        cap = 2500
    EndIf
    If target > cap
        target = cap
    EndIf
    Int held = PointsOf(who)
    String timeNote = ", known " + known
    If byRead < readRaw
        timeNote = timeNote + " - read " + readRaw + " held to " + byRead + " by time known"
    EndIf
    Diag(LOG_INFO(), "Seed read for " + asked + ": " + standing + " -> " + byRead + \
        " pts" + timeNote + " (rank/rapport floor " + byOld + ", cap " + cap + ", holds " + held + \
        "). Because: " + because)
    If target <= held
        Diag(LOG_INFO(), "Seed read for " + asked + " is at or below what they hold - nothing " + \
            "added. Seeding tops up and never claws back.")
        ; NAMES THE STANDING ANYWAY. "Nothing changed" on its own reads as a
        ; failed keypress; "read as CONFIDANT, already at or above that" is the
        ; same outcome and is obviously an answer.
        If announce
            Say(asked + " reads as " + shown + " - already at or above that, so nothing added.")
        EndIf
        StorageUtil.SetIntValue(who, "SNRom_Seeded", 1)
        SeedRomanticFlag(who)
        Return
    EndIf
    ; NOT ScaleAward: prior history predates this mod, and Bond Pace has no
    ; business retroactively shrinking someone's past. Same exemption SeedActor
    ; carries for the same reason.
    ;
    ; FROM 1.9 NOT REFUSED FOR SOMEONE WHO ISN'T FOLLOWING. Romantasy dropped
    ; these ("skipped Prior history together point adjustment ... not actively
    ; following"): a dashboard re-read of Erdi read DEVOTED three times and
    ; changed nothing. Ours lands wherever they are.
    ; THE JUDGE'S OWN REASON for the history, where it gave one: "Prior
    ; history together" says nothing a dashboard reader could not guess. It
    ; can name feelings nobody has said aloud, so the page shows it in the
    ; developer view only (labels.js, CHANGE.seed).
    String seedWhy = because
    If seedWhy == ""
        seedWhy = "Prior history together"
    EndIf
    If ApplyDepth(who, target - held, seedWhy, True, "seed") > 0
        StorageUtil.SetIntValue(who, "SNRom_Seeded", 1)
        SeedRomanticFlag(who)
        Diag(LOG_INFO(), "Seeded " + asked + " from the record: " + held + " -> " + \
            PointsOf(who) + " pts." + MarasStateLine(who))
        If announce
            Say(asked + " reads as " + shown + ".")
        EndIf
        ; SEEDING DEEP AND SAYING NOTHING ABOUT THE SPARK IS THE HOLE LAILA FELL
        ; THROUGH. A seed of CONFIDANT or above puts someone within one ordinary
        ; award of the Lover floor, and the tick will not look at their spark for
        ; two game days. Ask now.
        ;
        ; The threshold is the Confidant floor rather than the exact exposure
        ; (UNANSWERED_MAX minus awardMaxPoints), because the cost of asking early
        ; is one LLM call and the cost of asking late is a crossing nobody was
        ; offered. Generous on purpose.
        ;
        ; NOT the same as setting SNRom_SeedRomantic. That flag waives the
        ; probation permanently and is reserved for a romance the game records;
        ; this only changes WHEN the question is put. The assessor still decides,
        ; and it is free to answer no.
        If PointsOf(who) >= CONFIDANT_MIN()
            RequestSparkNow(who)
        EndIf
    Else
        Diag(LOG_WARN(), "The seed read for " + asked + " could not be written yet - their " + \
            "Romantasy points did not verify while being brought over (see the line above). " + \
            "It will be reapplied.")
        ; THE ONE OUTCOME A PLAYER CANNOT DIAGNOSE, so it is named rather than
        ; left as silence - the read was correct, it simply could not be written.
        ; From 2.0 the only way here is ImportPoints failing to verify a copy
        ; from Romantasy. What happens is a retry: SNRom_Seeded is still unset,
        ; so the housekeeping tick picks them up again on its own.
        If announce
            Say(asked + " reads as " + standing + ", but it could not be written yet. " + \
                "It will be retried automatically.")
        EndIf
    EndIf
EndFunction

Function ReseedActor(Actor akActor)
    { Clear the once-ever stamp and seed again. ONE argument, so it dispatches
      from the web API.

      Safe by construction rather than by care: SeedActor seeds to a FLOOR, so a
      re-seed can only ever raise someone to what their history justifies. It
      cannot take points away, and it cannot pay twice for the same history -
      whatever they already have is subtracted first.

      Written for the Kayla case. She was seeded on 2026-08-03 by a build whose
      rapport read was against a dead SeverActions key, so her entire target came
      from relationship rank and the rapport half of the estimate was silently
      zero. Anyone seeded by that build deserves the same second look.

      GOES THROUGH THE RECORD READ, not SeedTarget, and that correction is the
      whole point of the function now. This called SeedActor directly, which is
      the rank-and-rapport path - so the one repair a player reaches for after
      fixing someone's bio was the one path that could not see the fix. Rapport
      was 5.0 for 57% of 63 followers and rank was 3 for 61 of them, so a
      re-seed would have recomputed about 200, found it below what they held,
      and reported success having read nothing that was written.

      AssessSeed keeps SeedActor as its own failure fallback, so an endpoint
      that is down still answers something rather than nothing. }
    If akActor == None || !_ready
        Return
    EndIf
    Int had = PointsOf(akActor)
    StorageUtil.UnsetIntValue(akActor, "SNRom_Seeded")
    Diag(LOG_INFO(), "Re-seeding " + akActor.GetDisplayName() + " (currently " + had +         " pts) - reading the record again")
    AssessSeed(akActor)
EndFunction

; ===========================================================================
; The crosshair hotkeys - re-read, re-author, enroll - live in the DLL from 2.0
;
; RegisterForKey takes a SCAN code and SkyrimNet's hotkey widget stores a
; VIRTUAL key, so the re-read key set to End (VK 35) armed H (scan 35). The
; DLL converts, takes a modifier for each key, and follows the settings within
; seconds (native/src/Hotkey.h, WP8). On a press it sends SNRom_Hotkey with the
; key's name and the actor under the crosshair; OnHotkey routes it here.
;
; The re-read needs no confirmation: a seed only ever raises someone to what
; their history justifies. The re-author rewrites who someone is and discards
; their drift, and its confirmation is moved to BIND time: reauthorKey ships
; unbound, so a destructive press needs a key bound on purpose. Enrolling is
; what the player asked for, and is undone from the dashboard.
; ===========================================================================

Event OnHotkey(String asEventName, String asKey, Float afNumArg, Form akSender)
    { The DLL's crosshair keys. akSender is whoever was under the crosshair at
      the press, or None. }
    Actor who = akSender as Actor
    If asKey == "reread"
        ReseedUnderCrosshair(who)
    ElseIf asKey == "reauthor"
        ; ONE A MINUTE PER CHARACTER. A press re-rolls a whole character, and a
        ; key shared with something else - a scene menu, once - repeats it at
        ; every press. A second press inside the minute is refused, out loud.
        If who != None && Utility.GetCurrentRealTime() - StorageUtil.GetFloatValue(who, "SNRom_ReauthorKeyAt", -1000.0) < 60.0 && \
           Utility.GetCurrentRealTime() >= StorageUtil.GetFloatValue(who, "SNRom_ReauthorKeyAt", -1000.0)
            Say(who.GetDisplayName() + " was re-authored less than a minute ago. Press again later if you mean it.")
            Return
        EndIf
        If who != None
            StorageUtil.SetFloatValue(who, "SNRom_ReauthorKeyAt", Utility.GetCurrentRealTime())
        EndIf
        ReauthorUnderCrosshair(who)
    ElseIf asKey == "enroll"
        String refused = EnrollByHand(who)
        If refused != ""
            Say(refused)
        Else
            Say(who.GetDisplayName() + " is enrolled. Their character is being written.")
        EndIf
    EndIf
EndEvent

; ===========================================================================
; The dashboard - SkyrimNetRelationships.dll, optional
;
; The DLL hosts the dashboard page in Meridian UI and owns its hotkey (design
; 6.5, 7.1). Papyrus only hands it the dashboard settings, once per bootstrap;
; the DLL keeps them current itself by watching the settings file SkyrimNet
; saves (native/src/Settings.cpp), so nothing here polls for them. Nothing else
; here calls it, and nothing here may come to need it.
; ===========================================================================

Bool Function DashboardDllPresent() Global
    { PAPYRUS CANNOT TEST WHETHER A NATIVE EXISTS. Calling SNRom_Native without
      the DLL logs a Papyrus error and returns 0 or False, which looks exactly
      like a real refusal - so every call is gated on this first.

      Global, uncached, like SeverActionsPresent: it runs once per bootstrap,
      never per actor. }
    Return SKSE.GetPluginVersion("SkyrimNetRelationships") > 0
EndFunction

Int Function DashboardKeyWanted() Global
    { A VIRTUAL-KEY code, unlike the two keys above: the setting is SkyrimNet's
      hotkey widget, which captures a keypress and stores it as VK, and the DLL
      converts it natively - the job HotkeyCode's note says Papyrus should never
      attempt. 0, the shipped value, is unbound: the author's call, because the
      keys free in vanilla are the ones other mods have already taken. }
    Return SkyrimNetApi.GetConfigInt(CFG(), "dashboardHotkey", 0)
EndFunction

Bool Function DeveloperViewWanted() Global
    { The dashboard's developer view (design 7.6): off, the page shows only what
      the player could know. }
    Return SkyrimNetApi.GetConfigBool(CFG(), "dashboardDeveloperView", False)
EndFunction

String Function DashboardScaleWanted() Global
    { The dashboard's scale as the settings panel names it: Auto, or 75% to
      200%. Handed to the DLL by name; see SNRom_Native.SetDisplaySettings. }
    Return SkyrimNetApi.GetConfigString(CFG(), "dashboardScale", "Auto")
EndFunction

String Function DashboardTextSizeWanted() Global
    { The dashboard's text size as the settings panel names it: Normal, Large or
      Larger. On top of the scale. }
    Return SkyrimNetApi.GetConfigString(CFG(), "dashboardTextSize", "Normal")
EndFunction

String Function DashboardModifierWanted() Global
    { The dashboard key's modifier as the settings panel names it: None, Left
      Shift, Right Shift, Left Ctrl, Right Ctrl, Left Alt or Right Alt. A select,
      so it arrives as the option's name; DashboardModifierVK turns it into what
      the DLL takes. }
    Return SkyrimNetApi.GetConfigString(CFG(), "dashboardHotkeyModifier", "None")
EndFunction

Int Function DashboardModifierVK(String asName) Global
    { A dashboardHotkeyModifier option as the VIRTUAL KEY of that side of the
      keyboard, which is what SNRom_Native.SetDashboardHotkey takes: 0 for None,
      160 to 165 for the six others. The same table as kModifiers in the DLL's
      Hotkey.cpp, which the DLL's settings watcher uses; the two and the
      manifest's options must agree.

      -1 for anything else, which the DLL refuses rather than binding the bare
      key: a key that opens without the modifier the player chose is a guess.
      Papyrus string comparison ignores case, and so does the DLL's. }
    If asName == "" || asName == "None"
        Return 0
    ElseIf asName == "Left Shift"
        Return 160
    ElseIf asName == "Right Shift"
        Return 161
    ElseIf asName == "Left Ctrl"
        Return 162
    ElseIf asName == "Right Ctrl"
        Return 163
    ElseIf asName == "Left Alt"
        Return 164
    ElseIf asName == "Right Alt"
        Return 165
    EndIf
    Return -1
EndFunction

Function ArmDashboard()
    { Hands the dashboard settings to the DLL, once per bootstrap, so they hold
      from the first load even if the DLL cannot read the settings file.

      NOT FROM THE TICK. The DLL watches the file SkyrimNet rewrites whenever
      its panel saves, and applies a change within seconds - see Settings.cpp
      in native/src. Re-arming from OnUpdateGameTime took minutes to notice a
      change, and put more Papyrus on the tick, where the aim is less. The
      re-read and re-author keys are different, because Papyrus registers
      those itself - see OnHotkey. }
    ; Zeroed first, so every call site's gate reads "no" until the checks below
    ; say otherwise - including in a save made with a DLL that is gone now.
    _dashNatives = 0
    ; THE DLL IS REQUIRED FROM 2.0 (design 6.7): the dashboard, the hotkeys,
    ; the held tier notices, the bond history and who-is-near all live in it.
    ; Without it the mod still scores and gates - every native has a Papyrus
    ; fallback or is skipped - but the player must be told, once a load, in
    ; words that say what to check.
    If !DashboardDllPresent()
        Diag(LOG_ERROR(), "SkyrimNetRelationships.dll did not load. Relationships 2.0 needs it: " + \
            "check that it is installed, with SKSE and Address Library for this game version.", True)
        Say("SkyrimNetRelationships.dll did not load - no dashboard, hotkeys or bond history. " + \
            "Check SKSE and Address Library for this game version.")
        Return
    EndIf
    ; OLDER DLL, NEWER SCRIPTS. Version 1's SetDashboardHotkey took the key
    ; alone and these scripts pass two; version 2 has no read model, so the
    ; dashboard would open on an empty roster forever; version 3 has no
    ; SetDisplaySettings, so the dashboard's size could not be set. Each failure
    ; would read like something else. The gates below that ask for 3 still
    ; hold: _dashNatives is 0 or at least 4.
    Int natives = SNRom_Native.Version()
    If natives < 7
        Diag(LOG_ERROR(), "SkyrimNetRelationships.dll is older than these scripts (natives v" + natives + \
            ", these need v7). Install the DLL from the same release.", True)
        Say("SkyrimNetRelationships.dll is older than the scripts - install both from the same release.")
    EndIf
    If natives < 5
        Return
    EndIf
    _dashNatives = natives
    ; READ NOW, WHILE SKYRIMNET ANSWERS. The refresh runs while the dashboard
    ; has the game paused and may not ask it anything; see OnDashboardRefresh.
    ; A kin-guard setting changed mid-session reaches the dashboard's
    ; foreclosure at the next load - display only, the gate itself reads it live.
    DashboardCacheStore()
    _dashKinGuard = SNRom_Decorators.KinGuardOn() as Int
    ; Plugin presence cannot change mid-session, and asking per refresh is a
    ; frame each (Game.IsPluginInstalled).
    _dashMaras = MarasPresent()
    _dashSever = SeverActionsPresent()
    Int vk = DashboardKeyWanted()
    String modName = DashboardModifierWanted()
    Int modVK = DashboardModifierVK(modName)
    Bool dev = DeveloperViewWanted()
    SNRom_Native.SetDeveloperView(dev)
    ; The dashboard's size, by the options' names. A name the DLL
    ; does not know leaves that setting as it was, and the DLL logs which.
    String scaleName = DashboardScaleWanted()
    String textName = DashboardTextSizeWanted()
    If !SNRom_Native.SetDisplaySettings(scaleName, textName)
        Diag(LOG_WARN(), "Dashboard scale '" + scaleName + "' or text size '" + textName + \
            "' is not one of the options; see SkyrimNetRelationships.log.")
    EndIf
    If SNRom_Native.SetDashboardHotkey(vk, modVK)
        If vk > 0
            Diag(LOG_INFO(), "Dashboard hotkey armed on virtual key " + vk + ", modifier " + modName + \
                " (natives v" + natives + ", developer view " + dev + ").")
        Else
            Diag(LOG_INFO(), "Dashboard hotkey not set (dashboardHotkey = 0) - choose one under " + \
                "Dashboard in the settings panel.")
        EndIf
    ElseIf modVK < 0
        ; REFUSED, NOT GUESSED, the modifier this time: binding the bare key
        ; would open the dashboard without the modifier the player chose.
        Diag(LOG_WARN(), "Dashboard hotkey NOT bound: modifier '" + modName + "' is not one of the " + \
            "options. Choose one under Dashboard in the settings panel.")
        Say("That dashboard modifier can't be used - choose another in the settings.")
    Else
        ; REFUSED, NOT GUESSED. The DLL found no keyboard scan code for this key
        ; and bound nothing; binding the nearest number is how End became H.
        Diag(LOG_WARN(), "Dashboard hotkey NOT bound: virtual key " + vk + " has no keyboard " + \
            "scan code. Choose another key under Dashboard in the settings panel.")
        ; AND SAID ON SCREEN, because the player chose that key and is about to
        ; press it; a refusal only in the log reads as a key that does nothing.
        ; Every bootstrap while it stays set, which is the same as saying it
        ; still does not work.
        Say("That dashboard key can't be used - choose another in the settings.")
    EndIf
EndFunction

Function DashboardCacheStore()
    { The live store and the playthrough id, as the dashboard's refresh reads
      them. Both come from SkyrimNet, which the refresh may not ask (see
      OnDashboardRefresh), so they are read here: at every bootstrap, and by
      StartFreshStore and AdoptLegacyStore, the only things that move the store
      mid-session. EnsureSaveId decides the store once per bootstrap, before
      ArmDashboard runs. }
    _dashPlaythrough = PlaythroughId()
    _dashStore = StoreFile()
EndFunction

Int[] Function DashboardPoints(Actor akActor) Global
    { THE ONE PLACE THE DASHBOARD READS POINTS: [0] points held, [1] the tier
      0-5 (DashboardTier), [2] points banked by the consent gate while the
      question waits.

      OURS FROM 1.9 (WP4): PointsOf is a StorageUtil read, so a refresh no
      longer makes Romantasy's frame-waiting GetPoints call once per bond -
      that call was nearly all of the 2.5-3 s a refresh took. An actor the
      one-time import has not reached yet still reads Romantasy's number
      through PointsOf. It only reads: nothing on the dashboard's path writes
      a point. }
    Int[] pts = new Int[3]
    pts[0] = PointsOf(akActor)
    pts[1] = DashboardTier(pts[0])
    pts[2] = StorageUtil.GetIntValue(akActor, "SNRom_BankedPoints", 0)
    Return pts
EndFunction

Int Function DashboardTier(Int aiPoints) Global
    { The tier, 0-5, from points on the ladder the snapshot sends (thresholds
      500 apart). Romantasy's own level is exactly this: GetLevel is
      LevelNumberForPoints(points), 1-6, in its RomanceManager.cpp. Worked out
      here instead of asking GetLevel because that native waits a frame, and a
      refresh may not make a per-bond call that waits a frame (design 7.3,
      "Measured in play"). Nobody Romantasy tracks has 0 points, which is tier
      0 either way. }
    If aiPoints >= 2500
        Return 5
    ElseIf aiPoints >= 2000
        Return 4
    ElseIf aiPoints >= 1500
        Return 3
    ElseIf aiPoints >= 1000
        Return 2
    ElseIf aiPoints >= 500
        Return 1
    EndIf
    Return 0
EndFunction

Int Function DashMinutes(Float afGameTime) Global
    { A game time as whole game minutes, for the dashboard's Int array; -1 for
      never, which is how every one of these keys reads when unset (0.0). }
    If afGameTime <= 0.0
        Return -1
    EndIf
    Return (afGameTime * 1440.0) as Int
EndFunction

Int[] Function DashboardNumbers(Actor akActor) Global
    { ONE ACTOR'S NUMBERS, as SNRom_Native.PutBondNumbers takes them.

      THE ORDER IS enum Number IN native/src/Model.h, which cites this function.
      Change one, change both: the DLL refuses an array of the wrong length, and
      a reordering it cannot see would put one value in another's place.

      STORAGEUTIL READS ONLY - points included, since WP4 made them ours
      (PointsOf; until the import reaches someone, their number is still read
      from Romantasy). The first
      version asked the engine, MARAS and SeverActions here too, about twenty
      calls per bond that each waited a frame: 55 seconds for 122 bonds
      (design 7.3, "Measured in play"). Now the DLL reads the engine itself, and
      OnDashboardRefresh fetches MARAS and SeverActions once per refresh.
      Following, commitment and foreclosure are worked out by display copies in
      the DLL (native/src/Display.cpp); the gates keep calling Papyrus.

      NO SKYRIMNET CALL, NO DIAG, NO JSONUTIL: it runs inside
      OnDashboardRefresh, while the dashboard has the game paused. }
    Int[] n = new Int[21]
    Int[] pts = DashboardPoints(akActor)
    n[0] = pts[0]                                                                       ; kPoints
    n[1] = pts[1]                                                                       ; kTier
    n[2] = pts[2]                                                                       ; kBanked
    n[3] = DashMinutes(StorageUtil.GetFloatValue(akActor, "SNRom_LastFollowingAt", 0.0)) ; kLastFollowingAt
    n[4] = StorageUtil.GetIntValue(akActor, "SNRom_AutoEnrolled", 0)                    ; kAutoEnrolled
    n[5] = StorageUtil.GetIntValue(akActor, "SNRom_Enrolled", 0)                        ; kEnrolledFlag
    n[6] = StorageUtil.GetIntValue(akActor, "SNRom_PlayerStance", 0)                    ; kStance
    n[7] = StorageUtil.GetIntValue(akActor, "SNRom_AskPending", 0)                      ; kAskPending
    n[8] = StorageUtil.GetIntValue(akActor, "SNRom_Sparked", 0)                         ; kSparked
    n[9] = SparkDecided(akActor) as Int                                                 ; kSparkDecided
    n[10] = DashMinutes(StorageUtil.GetFloatValue(akActor, "SNRom_SparkedAt", 0.0))     ; kSparkedAt
    n[11] = DashMinutes(StorageUtil.GetFloatValue(akActor, "SNRom_LastSparkCheck", 0.0)) ; kLastSparkCheck
    n[12] = DashMinutes(StorageUtil.GetFloatValue(akActor, "SNRom_EndedAt", 0.0))       ; kEndedAt
    n[13] = StorageUtil.GetIntValue(akActor, "SNRom_Seeded", 0)                         ; kSeeded
    n[14] = StorageUtil.GetIntValue(akActor, "SNRom_DispositionAuthored", 0)            ; kAuthored
    n[15] = SNRom_Decorators.IntimacyRank(StorageUtil.GetIntValue(akActor, "SNRom_PhysMinTier", 4)) ; kIntimacy
    n[16] = StorageUtil.GetIntValue(akActor, "SNRom_Ardor", 2)                          ; kArdor
    n[17] = StorageUtil.GetIntValue(akActor, "SNRom_Exclusivity", 50)                   ; kExclusivity
    n[18] = StorageUtil.GetIntValue(akActor, "SNRom_Orientation", 3)                    ; kOrientation
    n[19] = StorageUtil.GetIntValue(akActor, "SNRom_OrientationKnown", 0)               ; kOrientationBasis
    n[20] = SNRom_Decorators.IsPlayerKin(akActor) as Int                                ; kPlayerKin
    Return n
EndFunction

String[] Function DashboardText(Actor akActor, String asStoreName) Global
    { ONE ACTOR'S TEXT, as SNRom_Native.PutBondText takes it: [0] WHY, [1] LIMIT,
      [2] ADDRESS. THE ORDER IS enum Text IN native/src/Model.h, which cites
      this function. No name: GetDisplayName waits a frame, and the DLL reads
      the name from the engine itself.

      asStoreName is the store ArmDashboard cached, because StoreFile() asks
      SkyrimNet for the playthrough id and this runs while the game is paused.

      The form id comes from SNRom_Native.FormIdOf, which answers without
      waiting for a frame, rather than akActor.GetFormID(), which StoreKey
      would otherwise call once per field: a full refresh reads 122 bonds.

      NO LIKES OR DISLIKES. Romantasy's name game statistics and do not carry
      into Relationships (the author, 2026-09-30); phase 5's own preferences,
      against our vocabulary, are the ones the dashboard will show. }
    Int id = SNRom_Native.FormIdOf(akActor)
    String[] t = new String[3]
    t[0] = StoreGetText(akActor, "Why", asStoreName, id)
    t[1] = StoreGetText(akActor, "Limit", asStoreName, id)
    t[2] = StoreGetText(akActor, "Address", asStoreName, id)
    Return t
EndFunction

Function PushBondText(Actor akActor)
    { A TEXT WRITER'S PUSH. Once a full refresh has answered this session
      (_dashText), the DLL holds everyone's name, WHY, LIMIT and ADDRESS, and it
      never asks for them again until the next load - every later open refreshes
      only the numbers. So each function that writes that text pushes the actor
      it wrote, here: one native call, as generation 0, which the DLL shows at
      once if the dashboard is open.

      CALLERS CHECK _dashText FIRST, so the only cost when nobody opens the
      dashboard is that Bool (kickoff WP2, e). This checks the version gate as
      well, like every native call site.

      The writers, and the grep that finds them, are listed in the WP2 pull
      request: every StoreSetText of Why, Limit or Address, and the two store
      repairs, which change which store all of it is read from. }
    If _dashNatives >= 3 && akActor != None
        SNRom_Native.PutBondText(0, akActor, DashboardText(akActor, _dashStore))
    EndIf
EndFunction

Function DashboardPutFacts(Int aiGeneration)
    { What the DLL's display copies need from other mods, fetched ONCE per
      refresh with their batch calls and handed over in one native
      (SNRom_Native.PutRefreshFacts). Asking per bond was IsNPCStatus three
      times and Native_GetIsFollower once, each waiting a frame.

      - MARAS.GetNPCsByStatus for "married", "engaged" and "candidate". Each is
        exactly the set its IsNPCStatus tests (both read the same set in MARAS's
        NPCRelationshipManager), less forms that are not loaded, which a
        roster member always is.
      - SeverActions' Native_GetActiveFollowerRoster and
        Native_GetDeadTrackedFollowers. Native_GetIsFollower, which IsFollowing
        asks, reads isFollower in SeverActions' store; the active roster is
        that minus the dead (its own docstring), and the other is exactly the
        dead. Together they answer as it does.
      - The kin guard ArmDashboard read. }
    Actor[] married
    Actor[] engaged
    Actor[] candidates
    If _dashMaras
        married = MARAS.GetNPCsByStatus("married")
        engaged = MARAS.GetNPCsByStatus("engaged")
        candidates = MARAS.GetNPCsByStatus("candidate")
    EndIf
    Actor[] severActive
    Actor[] severDead
    If _dashSever
        severActive = SeverActionsNativeExt.Native_GetActiveFollowerRoster()
        severDead = SeverActionsNativeExt.Native_GetDeadTrackedFollowers()
    EndIf
    SNRom_Native.PutRefreshFacts(aiGeneration, _dashKinGuard > 0, _dashMaras, married, engaged, candidates, \
        _dashSever, severActive, severDead)
EndFunction

Function PushAllBondText()
    { Everyone's text again, and the playthrough: for StartFreshStore and
      AdoptLegacyStore, which switch the store every line is read from. One call
      per roster member, like a full refresh, but only when a player runs one of
      those repairs with the dashboard live. }
    If _dashNatives < 3
        Return
    EndIf
    Int count = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int i = 0
    While i < count
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None
            SNRom_Native.PutBondText(0, a, DashboardText(a, _dashStore))
        EndIf
        i += 1
    EndWhile
    SNRom_Native.PutPlaythrough(0, _dashPlaythrough, _dashStore, StorageUtil.GetIntValue(None, "SNRom_SaveId", 0))
EndFunction

Function PushBond(Actor akActor, Int aiGeneration)
    { One actor's whole row, numbers and text. For a page action (generation
      -1, answered by ActionDone, which sends the snapshot) and for the LLM
      callbacks a long-running action ends in (generation 0, shown at once if
      the dashboard is open). Not for the refresh, which pushes its own. }
    If _dashNatives < 3 || akActor == None
        Return
    EndIf
    SNRom_Native.PutBondNumbers(aiGeneration, akActor, DashboardNumbers(akActor))
    SNRom_Native.PutBondText(aiGeneration, akActor, DashboardText(akActor, _dashStore))
EndFunction

Bool Function DashboardDeveloperOp(String asOp) Global
    { The developer tools in ui/relationships/actions.js (developer: true), and
      in the DLL's op table. Each bypasses a gate that is the design, so both
      sides refuse them unless the developer view is on. }
    Return asOp == "RequestSparkNow" || asOp == "UnsparkActor" || asOp == "ForceDriftReview" || \
        asOp == "CheckDisplay"
EndFunction

String Function CheckDashboardDisplay()
    { DEVELOPER TOOL: "Check the display against the rules". Runs the REAL
      IsFollowing, CommitmentState and RomanceApplicability for every bond and
      hands each answer to the DLL, which works out its display copy of the same
      three (native/src/Display.cpp) at the same moment and logs every
      disagreement to SkyrimNetRelationships.log, with the name, the field and
      both values. Returns the line the page shows.

      WHY IT EXISTS. The dashboard draws following, commitment and foreclosure
      from those copies, because asking Papyrus per bond cost 55 seconds for
      122 bonds (design 7.3, "Measured in play"). The author wants to see in
      play that the copies agree before trusting them; this is that evidence.

      LIKE FOR LIKE. The batch sets are fetched fresh first, as a refresh
      fetches them, and each bond's StorageUtil values are pushed just before
      its answer, so the copy and the rules see the same facts. The kin guard
      is read once and handed to both.

      SLOW ON PURPOSE: it pays the old per-bond cost, about a minute with 120
      bonds. It runs only when asked from the dashboard; nothing runs it
      automatically. }
    _dashKinGuard = SNRom_Decorators.KinGuardOn() as Int
    DashboardPutFacts(-1)
    Int checked = 0
    Int disagreements = 0
    Int count = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int i = 0
    While i < count
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None
            SNRom_Native.PutBondNumbers(-1, a, DashboardNumbers(a))
            disagreements += SNRom_Native.CheckBond(a, IsFollowing(a), CommitmentState(a), \
                SNRom_Decorators.RomanceApplicability(a, _dashKinGuard))
            checked += 1
        EndIf
        i += 1
    EndWhile
    ; A String on the left, so the rest concatenates rather than adds.
    Return (checked as String) + " bonds checked, " + disagreements + \
        " disagreements (see SkyrimNetRelationships.log)."
EndFunction

Event OnDashboardAction(String asEventName, String asOp, Float afRequestId, Form akSender)
    { A page action, from SkyrimNetRelationships.dll (kickoff WP2, d). The DLL
      has already checked asOp against its own fixed table; this maps it again,
      through this one, to the function actions.js names beside it. The page
      is data and never names a function.

      akSender is the actor, as a form: never a form id in a string. The Int
      arguments come from SNRom_Native.ActionArgs, never parsed from text.

      THE ROW, THEN THE ANSWER. The actor's row is pushed first (generation -1)
      and ActionDone second, because ActionDone is what makes the DLL send the
      page its result and a fresh snapshot.

      LONG-RUNNING ACTIONS SAY "STARTED". The re-read, re-author and preference
      repair finish in an LLM callback; their wrappers push the row when it
      lands (OnSeedAssessed, OnDispositionAuthored), and the DLL tells the page.

      Calls each function as it is. None of them changes the consent gate, and
      none is changed here (brief 2; design 13.4). }
    If _dashNatives < 3
        Return
    EndIf
    Int requestId = afRequestId as Int
    Actor who = akSender as Actor
    If !_ready
        SNRom_Native.ActionDone(requestId, False, "Relationships has not started, so nothing was done.")
        Return
    EndIf
    ; THE SECOND LOCK on the developer tools. The DLL refused them already
    ; unless the developer view is on; this reads the setting itself, because a
    ; page can be edited.
    If DashboardDeveloperOp(asOp) && !DeveloperViewWanted()
        SNRom_Native.ActionDone(requestId, False, "That is a developer tool, and the developer view is off.")
        Return
    EndIf
    Bool forPlaythrough = asOp == "StartFreshStore" || asOp == "AdoptLegacyStore" || asOp == "CheckDisplay"
    If !forPlaythrough && who == None
        SNRom_Native.ActionDone(requestId, False, "They could not be found in the game right now.")
        Return
    EndIf
    String whoName = ""
    If who != None
        whoName = who.GetDisplayName()
    EndIf
    String answer = ""
    If asOp == "ReseedActor"
        ; NO FOLLOW REQUIREMENT FROM 1.9. Until WP4 this was refused for anyone
        ; not following: Romantasy moved points only for an active follower, so
        ; a re-read of Erdi (2026-09-29) read DEVOTED three times and changed
        ; nothing. The points are ours now and land wherever they are.
        ;
        ; AssessSeed holds one read at a time and turns a second away with only
        ; a log line; say so here instead of "started".
        If SeedReadInFlight()
            SNRom_Native.ActionDone(requestId, False, "A read for " + _seedName + \
                " is still out. Try again when it comes back.")
            Return
        EndIf
        ReseedActor(who)
        answer = "Reading " + whoName + "'s record again. This updates when the answer comes back."
    ElseIf asOp == "ReauthorCharacter"
        ReauthorCharacter(who)
        answer = "Writing " + whoName + "'s character again. This updates when the answer comes back."
    ElseIf asOp == "SetCharacterField"
        Int[] fieldArgs = SNRom_Native.ActionArgs(requestId)
        If fieldArgs.Length < 2
            SNRom_Native.ActionDone(requestId, False, "Correct one trait needs a trait and a value.")
            Return
        EndIf
        SetCharacterField(who, fieldArgs[0], fieldArgs[1])
        answer = "Corrected one of " + whoName + "'s traits."
    ElseIf asOp == "EnrollActor"
        String refused = EnrollByHand(who)
        If refused != ""
            SNRom_Native.ActionDone(requestId, False, refused)
            Return
        EndIf
        answer = whoName + " is enrolled. Their character is being written, and their record read, " + \
            "in the next few minutes."
    ElseIf asOp == "UnenrollActor"
        UnenrollActor(who)
        SNRom_Native.DropBond(who)
        SNRom_Native.ActionDone(requestId, True, whoName + " is off the roster and no longer observed.")
        Return
    ElseIf asOp == "StartFreshStore"
        StartFreshStore()
        answer = "This playthrough now has its own store. Nothing was deleted."
    ElseIf asOp == "AdoptLegacyStore"
        AdoptLegacyStore()
        answer = "This playthrough is back on the main store."
    ElseIf asOp == "RequestSparkNow"
        RequestSparkNow(who)
        answer = "Asked the spark assessor about " + whoName + ". It declines on its own if they " + \
            "already have a verdict or are not loaded; the next open shows the result."
    ElseIf asOp == "UnsparkActor"
        UnsparkActor(who)
        answer = whoName + " is back on the platonic ladder, with every point kept."
    ElseIf asOp == "ForceDriftReview"
        ; No field from the page keeps the rotation, as ForceDriftReview documents.
        Int[] driftArgs = SNRom_Native.ActionArgs(requestId)
        Int field = -1
        If driftArgs.Length > 0
            field = driftArgs[0]
        EndIf
        ForceDriftReview(who, field)
        answer = "Asked for a drift review of " + whoName + ". The next open shows the result."
    ElseIf asOp == "CheckDisplay"
        answer = CheckDashboardDisplay()
    Else
        SNRom_Native.ActionDone(requestId, False, "This version of the scripts has no operation " + asOp + ".")
        Return
    EndIf
    If who != None
        PushBond(who, -1)
    EndIf
    SNRom_Native.ActionDone(requestId, True, answer)
EndEvent

Event OnDashboardRefresh(String asEventName, String asScope, Float afGeneration, Form akSender)
    { SkyrimNetRelationships.dll asks for the roster: every time the dashboard
      opens (design 7.3, the WP2 transport). The page is already showing what
      the DLL held; this pushes one call per roster member into its read model,
      then says RefreshDone, and the DLL sends the page the result.

      asScope "full" (the first open after a load) also pushes everyone's text
      and the playthrough; "numbers" pushes only the numbers, which every open
      refreshes. afGeneration numbers this refresh, so the DLL can drop an
      answer to one it has stopped waiting for.

      THREE THINGS IT MUST NOT DO, because the dashboard has the game paused:
      - Utility.Wait, which does not return while the game is paused;
      - write to JsonUtil;
      - call SkyrimNet's API, which SkyrimNet has been seen refusing while the
        game is paused. That rules out Diag too, since every Diag line reads the
        log level from SkyrimNet. The DLL logs the outcome and how long it took.

      "NOT READY" IS AN ANSWER. Said instead of an empty roster, so the page
      can tell the player the mod has not started rather than that nobody is
      on it. }
    ; Not armed this session (no DLL, or too old): nothing to answer. The DLL
    ; tells the page it heard nothing.
    If _dashNatives < 3
        Return
    EndIf
    Int generation = afGeneration as Int
    If !_ready
        SNRom_Native.RefreshDone(generation, 0, "not ready: Relationships has not started. " + \
            "SNRom_Integration.esl is missing or out of date (see snrom.log).")
        Return
    EndIf
    Bool withText = asScope == "full"
    String fromStore = _dashStore
    ; ONCE PER REFRESH, NOT PER BOND: what MARAS and SeverActions know, with
    ; their batch calls, for the DLL's display copies.
    DashboardPutFacts(generation)
    Int pushed = 0
    Int count = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int i = 0
    While i < count
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None
            SNRom_Native.PutBondNumbers(generation, a, DashboardNumbers(a))
            If withText
                SNRom_Native.PutBondText(generation, a, DashboardText(a, fromStore))
            EndIf
            pushed += 1
        EndIf
        i += 1
    EndWhile
    If withText
        SNRom_Native.PutPlaythrough(generation, _dashPlaythrough, fromStore, \
            StorageUtil.GetIntValue(None, "SNRom_SaveId", 0))
        _dashText = True
    EndIf
    SNRom_Native.RefreshDone(generation, pushed, "ok")
EndEvent

String Function EnrollmentPendingReason(Actor akActor)
    { Why this person is not being observed YET, in words that match what the
      player can see. Returns "" when they are fully enrolled and scoreable.

      WHY THIS EXISTS. Both hotkeys said "X is not being observed - only
      followers are" for every unenrolled actor, which is true of the mod and
      false to the player: they are pointing at a companion who is plainly
      following them, so the sentence reads as a bug. Reported 2026-09-07 on
      Irgnir, who was genuinely not enrolled - noticed following at gd 153.45,
      stopped following at gd 163.10 which reset her waiting period, and never
      noticed again in the 44 game days since. The refusal was correct. The
      explanation was not, and there was nothing in it to act on.

      FOUR STATES, NOT ONE, and this is the same mistake this project keeps
      making: a gate that cannot tell "no" from "not yet" tells the player
      neither. Enrolled-and-scoreable; enrolled but invisible to Romantasy until
      a reload; following and serving the waiting period; not noticed at all.
      Every one of them has a different thing for the player to do, and three of
      the four are just waiting.

      ONE HELPER FOR BOTH KEYS so the wording cannot drift apart, and the tenure
      numbers are read live from the same config the gate itself reads - a
      hardcoded "2 hours" here would quietly lie the moment anyone tuned it. }
    If akActor == None
        Return "Point at someone first."
    EndIf
    If IsEnrolled(akActor)
        Return ""
    EndIf
    Bool ours = StorageUtil.GetIntValue(akActor, "SNRom_Enrolled", 0) == 1
    If ours
        ; ENROLLED BY US, INVISIBLE TO ROMANTASY. Documented at the enrollment
        ; site: a runtime AddToFaction is not seen until the next load, so
        ; GetLevel stays 0 for the rest of the session. Nothing is wrong and
        ; nothing needs fixing - it needs a reload, which is worth saying rather
        ; than leaving as an apparent refusal.
        Return akActor.GetDisplayName() + " was enrolled this session - reload before their standing can be scored."
    EndIf
    If !IsFollowing(akActor)
        Return akActor.GetDisplayName() + " is not enrolled - only followers are enrolled, once they have followed you a while."
    EndIf
    Float firstSeen = StorageUtil.GetFloatValue(akActor, "SNRom_FirstSeenFollowing", 0.0)
    Float wait = SkyrimNetApi.GetConfigFloat(CFG(), "enrollmentDelayHours", 2.0)
    If firstSeen <= 0.0
        Return akActor.GetDisplayName() + " has not been noticed following yet - they are picked up on the next check."
    EndIf
    Float left = wait - ((Utility.GetCurrentGameTime() - firstSeen) * 24.0)
    If left < 0.0
        ; A NEGATIVE REMAINDER means the clock ran backwards - an older save
        ; loaded - and the sweep will settle it on its own pass. Do not report a
        ; negative wait, and do not claim they are ready either.
        Return akActor.GetDisplayName() + " is waiting to be enrolled - the next check will settle it."
    EndIf
    Return akActor.GetDisplayName() + " is still new - enrolled once they have been with you " + wait + " game hours, about " + left + " to go."
EndFunction

Function Say(String asText)
    { One player-facing line. Distinct from Diag's optional notification, which
      mirrors the LOG and is off by default: these are answers to a keypress and
      must appear whatever the log settings say. }
    Debug.Notification("[Relationships] " + asText)
EndFunction

Function ReseedUnderCrosshair(Actor akTarget)
    { Point at anyone enrolled, press the key, and their standing is read again from
      the record as it now stands.

      WHY THIS EXISTS. Fixing the material is the advice this mod gives - correct
      the bio, write the missing diary entry, apply a block - and none of it
      moves a standing that was already written down. The re-read was reachable
      only by hand-assembling a POST to SkyrimNet's web API with the actor's
      FormID, which is not a repair a player will perform.

      EVERY REFUSAL BELOW SAYS WHY. A hotkey that declines in silence is
      indistinguishable from one that is not bound, and the player has no log
      open. The asynchronous answer arrives in OnSeedAssessed, which announces
      all four of its outcomes when the request came from here. }
    If !_ready
        Say("Not ready - Relationships has not started this session.")
        Return
    EndIf
    Actor who = akTarget
    If who == None
        Say("Point at someone first.")
        Return
    EndIf
    If who == Game.GetPlayer()
        Say("That is you.")
        Return
    EndIf
    If who.IsDead()
        Say(who.GetDisplayName() + " is dead.")
        Return
    EndIf
    If !IsEnrolled(who)
        ; NOT ENROLLED IS NOT AN ERROR, and saying "no" without saying "yet"
        ; invites a second and third press. The reason is deferred to
        ; EnrollmentPendingReason because there are four of them and the flat
        ; version contradicted what the player could see.
        ;
        ; THIS KEY KEEPS THE STRICT TEST. A re-read writes POINTS, and Romantasy
        ; cannot receive them for someone it has not seen since the last load -
        ; so "enrolled by us this session" is genuinely not good enough here,
        ; and the reason string says so in those words.
        Say(EnrollmentPendingReason(who))
        Return
    EndIf
    If SeedReadInFlight()
        Say("Still reading the record for " + _seedName + " - try again in a moment.")
        Return
    EndIf
    ; SET BEFORE THE DISPATCH, because AssessSeed reports its own refusal and
    ; reads this to decide whether to announce it. Cleared on every path out of
    ; OnSeedAssessed and on a refused dispatch, so it cannot leak into the next
    ; automatic seed and make it noisy.
    _seedByHand = True
    Say("Re-reading the record for " + who.GetDisplayName() + "...")
    ReseedActor(who)
EndFunction

Function ReauthorUnderCrosshair(Actor akTarget)
    { Point at someone, press the OTHER key, and their character is written
      again from scratch - orientation, intimacy, ardor, exclusivity, WHY, LIMIT
      and ADDRESS.

      WHY THIS EXISTS, and it is a different need from the re-read. The re-read
      fixes a STANDING that was scored before the material improved. This fixes
      a CHARACTER that was authored before the material improved - and no amount
      of re-reading touches it, because points and personality are written by
      two different calls. Measured 2026-09-05: 45 of 136 authored characters
      hold exclusivity 100, nearly all of them from before the axis was
      anchored to named bands, and every one of them will keep refusing to share
      the player forever unless something rewrites the number. Reaching that
      repair meant hand-assembling a POST with a hex FormID, which is not
      something a player does.

      ROUTES TO ReauthorCharacter, NOT ReauthorDisposition, and that choice is
      load-bearing rather than incidental. ReauthorDisposition ADDS preferences
      on every run and they cannot be removed across a reload, so a player who
      pressed this a few times on the same companion would inflate what she
      cares about until nothing about her stood out - the tool would degrade
      exactly the characters it was reached for. Character-only re-authoring is
      idempotent in the way that matters: press it twice and you get one
      character, not one character and six new hobbies.

      NO IsFollowing GUARD, unlike ReseedUnderCrosshair, and the difference is
      real rather than an oversight. The re-read must refuse a dismissed
      follower because Romantasy scores active followers only and will reject
      the points write. Authoring writes this mod's own fields plus preference
      factions, and enrollment - not travelling - is what those need. A roster of
      companions waiting at home is the population this exists for, so refusing
      them would refuse the actual case.

      IT LOGS WHAT IT IS ABOUT TO OVERWRITE. There is no undo, and a mistaken
      press with the crosshair a few degrees off would otherwise be silent and
      permanent - the wrong companion quietly rerolled, discovered weeks later
      as "she has not felt like herself". The old values in the log will not
      restore her, but they name what was lost and they can be typed back in by
      hand, which is the difference between a bad afternoon and a lost
      character. }
    If !_ready
        Say("Not ready - Relationships has not started this session.")
        Return
    EndIf
    Actor who = akTarget
    If who == None
        Say("Point at someone first.")
        Return
    EndIf
    If who == Game.GetPlayer()
        Say("That is you.")
        Return
    EndIf
    If who.IsDead()
        Say(who.GetDisplayName() + " is dead.")
        Return
    EndIf
    ; ACCEPTS OURS-THIS-SESSION, unlike the re-read above, and the asymmetry is
    ; the same one as the IsFollowing difference: this writes THIS MOD's fields
    ; and preference factions, none of which route through Romantasy's scoring,
    ; so an enrollment Romantasy cannot see yet is no obstacle at all. Refusing
    ; here would block re-authoring a companion for a whole session over a
    ; limitation that has nothing to do with authoring.
    If !IsEnrolled(who) && StorageUtil.GetIntValue(who, "SNRom_Enrolled", 0) != 1
        Say(EnrollmentPendingReason(who))
        Return
    EndIf
    ; ALREADY IN FLIGHT OR ALREADY QUEUED, and this refusal is about waste
    ; rather than safety. AuthorDisposition queues rather than drops, so a
    ; second press would not be lost - it would be honoured, spending a second
    ; LLM call to overwrite the answer the first one is still fetching. The
    ; player pressing twice means "did that work?", not "do it twice".
    If _pendingActor == who
        Say("Already re-authoring " + who.GetDisplayName() + " - the answer takes a few seconds.")
        Return
    EndIf
    If StorageUtil.FormListFind(None, "SNRom_AuthorQueue", who) >= 0
        Say(who.GetDisplayName() + " is already queued for re-authoring.")
        Return
    EndIf
    ; LLM AUTHORING TURNED OFF MAKES THIS KEY MEANINGLESS, and caught here
    ; rather than downstream for a specific reason: AuthorDisposition answers
    ; that setting by calling ApplyArchetype, which is also the failure funnel -
    ; so letting it through would announce "the read failed" for a read nobody
    ; ever attempted, and send the player looking for a network problem they do
    ; not have. Refusing up front names the actual cause, which is a setting
    ; they can change.
    If SkyrimNetApi.GetConfigBool(CFG(), "enrollmentLlmPreferences", True) == False
        Say("LLM-authored personalities are switched off in the settings - there is nothing to re-author with.")
        Return
    EndIf
    ; THE RECORD OF WHAT IS BEING DISCARDED, written before the dispatch so it
    ; is in the log even if the call fails or the game ends in the next second.
    Int minTier = StorageUtil.GetIntValue(who, "SNRom_PhysMinTier", 4)
    String orient = SNRom_Decorators.OrientationWord(who)
    If orient == ""
        orient = "unknown"
    EndIf
    ; FILE ONLY, both of these. The player already gets a short Say below; this
    ; is the record for afterwards, and pushing it through the notification
    ; mirror would clip it into uselessness and bury the Say behind it.
    Diag(LOG_WARN(), "Re-authoring " + who.GetDisplayName() + " BY HOTKEY. Overwriting" + \
        " orientation=" + orient + \
        ", intimacy=" + SNRom_Decorators.IntimacyWordFromTier(minTier) + \
        ", ardor=" + StorageUtil.GetIntValue(who, "SNRom_Ardor", 2) + \
        " (" + SNRom_Decorators.ArdorWord(StorageUtil.GetIntValue(who, "SNRom_Ardor", 2)) + ")" + \
        ", exclusivity=" + StorageUtil.GetIntValue(who, "SNRom_Exclusivity", 50) + \
        ". There is no undo.", True)
    ; The WHY on its own line - it is prose, it is the part with no numeric
    ; equivalent to type back in, and it is what identifies the character that
    ; was here if the press was a mistake.
    String oldWhy = StoreGetText(who, "Why")
    If oldWhy != ""
        Diag(LOG_WARN(), "Discarded WHY for " + who.GetDisplayName() + ": " + oldWhy, True)
    EndIf
    ; NEVER AUTHORED IS NOT A RE-AUTHOR, and saying so matters: nothing is being
    ; lost, so the player can press this freely on a companion the automatic
    ; pass never reached. The two cases are indistinguishable from the outside
    ; otherwise, and the destructive-sounding one is the one people hesitate on.
    If oldWhy == "" && StorageUtil.GetIntValue(who, "SNRom_DispositionAuthored", 0) != 1
        Say("Authoring " + who.GetDisplayName() + " for the first time...")
    Else
        Say("Re-authoring " + who.GetDisplayName() + " - old character discarded...")
    EndIf
    ; PER-ACTOR, NOT A SCRIPT VARIABLE, for the reason ReauthorCharacter states
    ; about its own flag: authoring QUEUES, so a single Bool would be read by
    ; whichever response happened to come back next and announce the wrong
    ; person's answer. Consumed by AnnounceAuthored, on both the success and the
    ; failure path.
    StorageUtil.SetIntValue(who, "SNRom_AuthorByHand", 1)
    ReauthorCharacter(who)
EndFunction

Function AnnounceAuthored(Actor akActor, String asText)
    { Tells the player how a HAND-REQUESTED authoring turned out, once, and only
      if they asked for it.

      WITHOUT THIS THE KEY IS HALF A TOOL. The press says "re-authoring..." and
      then nothing ever says whether it landed - so the only way to find out is
      to open the log, which is the exact thing the hotkey exists to avoid. The
      re-read has had this from the start via _seedByHand; this is the same
      contract for the other key.

      CHECK-AND-CLEAR IN ONE PLACE, because OnDispositionAuthored has six early
      exits and anything that has to be remembered at each of them will be
      missed when a seventh is added. There are only two places a request can
      actually settle - ApplyCharacter when a character was written, and
      ApplyArchetype which every failure path already funnels through - so the
      announcement lives at those two and nowhere else.

      Clearing on ANY settle, success or fallback, is what stops a stale marker
      announcing an automatic authoring weeks later as though the player had
      just asked for it. }
    If akActor == None || StorageUtil.GetIntValue(akActor, "SNRom_AuthorByHand", 0) != 1
        Return
    EndIf
    StorageUtil.UnsetIntValue(akActor, "SNRom_AuthorByHand")
    Say(asText)
EndFunction

Function SeedNextActor()
    { One SETTLED seed per tick, walking the roster in order.

      Two things here are load-bearing and both are the same bug this project
      already fixed once in AssessNextTalk:

      1. Anyone enrolled, following or not, from 2.0: the follower test was
         Romantasy's rule, and the points are ours (design 3.2). The seed reads
         the record, which needs nobody nearby. The cheap seeded test first:
         IsDead waits for a frame.

      2. Do not stop on a rejection, only on a settled seed. Stopping on the
         first ATTEMPT means one permanently un-seedable actor at the front of
         the roster blocks everyone behind them forever, and the roster is in
         permanent first-enrollment order so "the front" never changes. A
         rejection costs a GetPoints and a native call that returns False, so
         walking past it is cheap; starving on it is not.

      No most-overdue ordering, unlike the assessors - this is once-per-NPC
      rather than recurring, so once the roster drains it costs a walk and
      nothing else.

      Backfills the EXISTING roster by design. Every follower enrolled before
      seeding existed is sitting at a tier their history does not match, which
      is the whole problem this was written to fix. The floor semantic in
      SeedActor is what makes that safe on an established save: it can only
      ever raise someone to what their history justifies, never lower anyone,
      and never pay someone who has already earned more. }
    If !_ready
        Return
    EndIf
    If SkyrimNetApi.GetConfigBool(CFG(), "seedEnabled", True) == False
        Return
    EndIf
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int i = 0
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None && StorageUtil.GetIntValue(a, "SNRom_Seeded", 0) != 1 && !a.IsDead()
            ; THE RECORD READ, not the old rank-and-rapport table. Measured
            ; 2026-09-01 across 63 seeded followers: rapport was exactly 5.0 for
            ; 57% and rank was 3 for 61 of 63, so SeedTarget returned about 200
            ; for almost everyone whatever had happened between them. AssessSeed
            ; reads the diary, the memories and the bio instead; SeedTarget
            ; survives inside it as a floor.
            ;
            ; ONE DISPATCH PER TICK, and the stamp is set by the callback rather
            ; than here - so a read that fails leaves the actor unseeded and they
            ; come round again next tick. AssessSeed holds a single pending slot,
            ; so a tick during an outstanding read simply does nothing.
            AssessSeed(a)
            Return
        EndIf
        i += 1
    EndWhile
EndFunction

; ===========================================================================
; Spark assessment - the platonic/romantic track selector
;
; Runs on GAME time, deliberately on a different event from the authoring
; queue's real-time OnUpdate. Papyrus gives one OnUpdate and one
; OnUpdateGameTime per script; using both is the only way to have two
; independent timers without them stepping on each other.
; ===========================================================================

Float Function AssessIntervalHours() Global
    { How long until the next ASSESSMENT tick. Housekeeping keeps its own,
      slower schedule - see OnUpdateGameTime.

      THE QUEUE WAS THE BOTTLENECK, NOT THE COOLDOWN. Each AssessNext* serves
      exactly one actor and holds a single pending slot until the answer lands,
      so a fixed two-hour tick meant a party of seven waited fourteen game hours
      between assessments each - while talkCooldownHours, the setting that is
      supposed to govern the rate, is 3.0 and never came close to binding.

      Dividing the window by the party size hands the cooldown back its job: the
      roster drains in roughly one window and each follower is then limited by
      their own cooldown, which is what it was written for.

      FLOORED AT HALF AN HOUR. Every tick is an LLM call for anyone eligible, and
      at a default timescale half a game hour is about ninety real seconds - fast
      enough that a large party still drains, slow enough not to hammer a local
      model. A party of eight drains in four hours, just past the cooldown, which
      is the right side of it.

      Count comes from the sweep rather than a fresh walk, so it can be one
      housekeeping period stale. That is fine: dismissing someone should not
      change the tick rate the instant it happens. }
    Int followers = StorageUtil.GetIntValue(None, "SNRom_FollowerCount", 1)
    If followers < 1
        followers = 1
    EndIf
    Float every = 2.0 / (followers as Float)
    If every < 0.5
        every = 0.5
    ElseIf every > 2.0
        every = 2.0
    EndIf
    Return every
EndFunction

Float Function SparkIntervalHours() Global
    { THE HOUSEKEEPING WINDOW, despite the name - kept because it is referenced
      in comments and in the 0.9.2 crash notes, and renaming it would orphan
      those. It bounds the sweep, the attraction refresh and seeding.

      It is also the numerator AssessIntervalHours divides by party size, so the
      roster is meant to drain in about one of these. }
    Return 2.0
EndFunction

Event OnUpdateGameTime()
    { TWO CADENCES, ONE TIMER. Papyrus gives a script one game-time update, so
      the FAST one drives the event and the slow work is gated on elapsed time
      inside it rather than getting a registration of its own.

      WHY NOT SIMPLY TICK EVERYTHING FASTER. SweepFollowers calls
      MiscUtil.ScanCellNPCs, which is the call a VR user crashed inside on a
      heavily patched cell in 0.9.2. Running that scan four times as often to
      make conversation scoring keep up would be paying for the fix with the
      bug. RefreshNextAttraction and SeedNextActor are both once-per-actor work
      with nothing to gain from hurrying.

      The three assessors and the ask queue run every tick. Each assessor serves
      one actor, holds a single pending slot until the answer lands, and obeys
      its own per-actor cooldown - so a faster tick drains the roster without
      assessing anyone more often than their cooldown already allows. That was
      the whole problem: at a fixed two hours a party of seven waited fourteen
      game hours apiece while talkCooldownHours sat at 3.0 and never bound. }
    ; ON THE FAST TICK, NOT INSIDE HOUSEKEEPING. It was in the housekeeping block
    ; first, which is gated on two GAME HOURS - so a player whose content had not
    ; loaded would play most of an in-game morning before the mod admitted it,
    ; which is most of the silence this check exists to end. Measured 2026-09-11:
    ; bootstrap logged the build version and nothing else for the rest of the
    ; session, because housekeeping had not come round yet.
    ;
    ; Still not in Bootstrap, for the original reason - SkyrimNet builds its
    ; action registry while it loads content, and asking at quest-start would
    ; report a missing layer that arrives a second later. The first tick is late
    ; enough to be true and early enough to be useful.
    ;
    ; Costs one Int compare per tick once it has answered. True = by now the
    ; registry has certainly finished loading, so a NO is a real no.
    CheckContentLoaded(True)
    _observers = Observers()
    Float now = Utility.GetCurrentGameTime()
    Float sinceKeep = now - StorageUtil.GetFloatValue(None, "SNRom_LastHousekeep", 0.0)
    ; A negative delta means the clock moved backwards - a load of an older save.
    ; Run housekeeping rather than wait out a window that will never elapse.
    If sinceKeep >= (SparkIntervalHours() / 24.0) || sinceKeep < 0.0
        StorageUtil.SetFloatValue(None, "SNRom_LastHousekeep", now)
        ; Sweep FIRST. All three assessors iterate the roster, so a follower who
        ; is not on it is invisible to them - and the event we used to rely on
        ; never fires for anyone SeverActions already knows.
        SweepFollowers()
        ; Wherever they are: a follower told to wait out of range still enrolls.
        CheckPendingEnrollments()
        ; Attraction BEFORE the assessors. It is the cheap deterministic one and
        ; it feeds a gate the spark assessment's outcome is read against.
        RefreshNextAttraction()
        ; Seeding BEFORE the assessors, and before the spark one in particular:
        ; it sets SNRom_SeedRomantic, which is what lets an established spouse be
        ; spark-assessed without serving the tenure gate.
        SeedNextActor()
        ; AFTER the sweep, so follower states are current, and after seeding so a
        ; first-time seed is not immediately topped up twice. Runs on EVERY tick
        ; by design and costs one Int read per roster entry once everyone present
        ; has been checked - that is what lets a follower recruited mid-session be
        ; picked up on the next tick rather than on the next load.
        ReconcileMarriages()
        ; Alongside it, and for the same reason: Ledger only sees actors whose
        ; points moved, so the marriage gate has to be established here to exist
        ; for an idle follower at all. One HasKeyword read per roster entry once
        ; everyone is settled.
        SweepProposalGates()
        ; The Lover question, for anyone owed it whether or not they have earned
        ; anything lately.
        SweepLoverCeiling()
        ; AFTER SweepFollowers above, so the roster is settled, and BEFORE
        ; RefreshPartnerCount so the partner count is taken from post-migration
        ; values on the very first tick rather than one cycle later.
        MigrateLegacyExclusivity()
        RefreshPartnerCount()
        If _bioWalkPending
            BioBlocksOnLoad()       ; the load-time walk was held back; see BioStoreLooksLoaded
        EndIf
    EndIf

    ; The outstanding question goes BEFORE the assessors. It is cheap, local and
    ; spends no LLM budget, and if a tick runs short of Papyrus time the thing
    ; the player is owed should not be what gets dropped. On the fast tick now,
    ; because a question waiting to be asked is the most latency-sensitive thing
    ; here and it was previously waiting up to two game hours for no reason.
    PumpAskQueue()
    AssessNextTalk()
    AssessNextSpark()
    ; Drift LAST of the three, deliberately. It is the rarest and least urgent -
    ; its own gates are measured in game weeks - so if a tick runs short of
    ; Papyrus budget this is the right thing to lose. It also reads values the
    ; other two write, and reading them one tick stale would mean judging her
    ; against who she was before tonight.
    AssessNextDrift()
    ; Re-arm unconditionally, including on every early return inside the
    ; assessors. A timer that stops when there is nothing to do never starts
    ; again when there is.
    RegisterForSingleUpdateGameTime(AssessIntervalHours())
EndEvent

; ===========================================================================
; Conversational scoring
;
; The core value-add, and it did not exist until 2026-07-30. The only
; dialogue->points path was MarkMoment, an action under the `romance`
; category, and the model never enters that category - zero `moment` rows
; were ever written. Talking to someone for an hour moved nothing.
;
; Same shape as the spark assessor because that shape works: background call,
; own pending slot, cheap local filters before any LLM spend, guards in
; Papyrus rather than in prose.
; ===========================================================================

Actor  _talkActor
String _talkName
Float  _talkPendingAt

Function AssessNextTalk()
    If !_ready
        Return
    EndIf
    If SkyrimNetApi.GetConfigBool(CFG(), "talkEnabled", True) == False
        Return
    EndIf
    If _talkActor != None
        If SlotStale(_talkPendingAt)
            Diag(LOG_WARN(), "Talk slot held by " + _talkName + \
                " with no callback for " + PendingTimeoutSeconds() + \
                "s - releasing. Two causes look identical from here: the prompt failed to " + \
                    "render, or the LLM call timed out. SkyrimNet.log tells them apart - a " + \
                    "template error names the file, while Request timeout, Transferred a " + \
                    "partial file or a JSON parse error means the backend, not us.")
            _talkActor = None
        Else
            Return                              ; one assessment genuinely in flight
        EndIf
    EndIf

    ; MOST OVERDUE WINS, not first-eligible.
    ;
    ; This loop used to Return on the first candidate, which starved everyone
    ; past the front of the roster - and the roster is permanent first-enrollment
    ; order, never re-sorted. Work it through with the shipped 2h timer and 3h
    ; cooldown and it converges to indices 0 and 1 alternating FOREVER:
    ;
    ;   t=0  both eligible          -> 0   (0 blocked until t=3)
    ;   t=2  0 blocked, 1 eligible  -> 1   (1 blocked until t=5)
    ;   t=4  0 eligible again       -> 0
    ;   t=6  0 blocked, 1 eligible  -> 1
    ;
    ; Index 2 onward is never assessed at all - not late, NEVER. Observed in
    ; play 2026-07-31: Nicollette and Kayla (early enrollments) were scored
    ; repeatedly while Hermir, enrolled twelfth, was never picked once by the
    ; scheduled path. The only thing that ever let anyone else through was an
    ; early NPC failing Is3DLoaded/IsPlayerTeammate by being dismissed or out
    ; of cell.
    ;
    ; Picking the largest wait is self-balancing and needs no persisted cursor.
    ; A never-assessed NPC has lastCheck 0.0, so her wait is the whole game
    ; clock and she is picked first - correct, and it self-corrects the moment
    ; she is stamped. Ties break on the order the scan found them in, which
    ; then rotates on the next tick because the winner has just been stamped.
    ;
    ; FROM WHO CAN OBSERVE THE PLAYER, not the roster (Observers): following
    ; is not a qualifier (design 3.2).
    Float now = Utility.GetCurrentGameTime()
    Float cooldown = SkyrimNetApi.GetConfigFloat(CFG(), "talkCooldownHours", 3.0) / 24.0
    Int n = 0
    If _observers
        n = _observers.Length
    EndIf
    Int i = 0
    Actor pick = None
    Float pickSince = 0.0
    Float bestWait = -1.0
    While i < n
        Actor a = _observers[i]
        If a != None && TalkCandidate(a, now, cooldown)
            Float last = StorageUtil.GetFloatValue(a, "SNRom_LastTalkCheck", 0.0)
            If (now - last) > bestWait
                bestWait  = now - last
                pick      = a
                pickSince = last
            EndIf
        EndIf
        i += 1
    EndWhile

    If pick == None
        Return
    EndIf
    ; Read the PRIOR watermark before overwriting it. The prompt window and this
    ; poll are two different clocks and nothing used to tie them together:
    ; Papyrus gated on "every talkCooldownHours" while the prompt showed "the
    ; last N events". A quiet stretch re-scored the same conversation; a busy
    ; one dropped it entirely.
    StorageUtil.SetFloatValue(pick, "SNRom_LastTalkCheck", now)
    Diag(LOG_DEBUG(), "Talk queue: picked " + pick.GetDisplayName() + \
        " after " + (bestWait * 24.0) + " game hours waiting")
    AssessTalk(pick, pickSince)
EndFunction

Bool Function TalkCandidate(Actor akActor, Float afNow, Float afCooldown)
    ; Alive, loaded and near the player already: akActor comes from Observers.
    ; This asked IsFollowing until 2.0 - a gate that was only ever Romantasy's
    ; (design 3.2), and that left a non-follower's conversations unscored.
    Return (afNow - StorageUtil.GetFloatValue(akActor, "SNRom_LastTalkCheck", 0.0)) >= afCooldown
EndFunction

Function AssessTalk(Actor akActor, Float afSince = 0.0)
    { afSince is the game time of the PREVIOUS assessment, in days, or 0.0 for
      "look at everything". Defaulted so the manual API dispatch
      (execute-quest-script-function -> AssessTalk) still takes one argument and
      still gets the full window, which is what you want when testing.

      NOTE FOR MANUAL DISPATCH: this takes TWO arguments from the web API.
      Papyrus default parameter values do NOT apply through
      execute-quest-script-function - the argument count must match the
      signature exactly or the call dies with "Argument count mismatch",
      visible only in SkyrimNet.log while the HTTP response still says 200.
      Pass `["0x0001B136", 0.0]` for a full-history window. An earlier comment
      here claimed the default made one argument sufficient; that was wrong.

      TWO forms go to the prompt, because the two sources measure time
      differently and neither conversion is safe to guess:

        npc_since_sec   - ABSOLUTE game-seconds, for filtering events. Events
                          carry ev.gameTime in seconds; the stock
                          components/event_history.prompt compares it against
                          604800 for "over a week ago", which pins the unit.
                          This assumes ev.gameTime shares an epoch with
                          GetCurrentGameTime(). PLAUSIBLE, NOT VERIFIED - the
                          prompt therefore falls back to the unfiltered window
                          if this filter empties a non-empty list.

        npc_since_hours - RELATIVE hours elapsed, for filtering diary entries.
                          Diary entries expose age_hours, which is relative, so
                          comparing two relative numbers needs no epoch
                          assumption at all. This is the safer of the two and
                          is why the diary filter is not built on entry_date.

      Both are 0.0 when there is no previous assessment, which every consumer
      reads as "no watermark, show everything". }
    Float sinceSec   = 0.0
    Float sinceHours = 0.0
    If afSince > 0.0
        sinceSec   = afSince * 86400.0
        sinceHours = (Utility.GetCurrentGameTime() - afSince) * 24.0
        If sinceHours < 0.0
            sinceHours = 0.0                    ; clock went backwards; show all
        EndIf
    EndIf
    _talkActor = akActor
    _talkName  = akActor.GetDisplayName()
    _talkPendingAt = Utility.GetCurrentRealTime()
    ; Her ardor and her authored WHY both go in, because the judgment is
    ; explicitly "how far did this move HER" rather than "was this a nice
    ; conversation". Without them the same exchange scores identically for
    ; everyone, which is the failure this whole mod exists to avoid.
    String ctx = "{\"npc_name\":\"" + _talkName + "\"" + \
        ",\"npc_formid\":" + akActor.GetFormID() + \
        ",\"npc_ardor\":\"" + SNRom_Decorators.ArdorWord(StorageUtil.GetIntValue(akActor, "SNRom_Ardor", 2)) + "\"" + \
        ",\"npc_why\":\"" + SNRom_Decorators.JsonEscape(StoreGetText(akActor, "Why")) + "\"" + \
        ",\"npc_since_sec\":" + sinceSec + \
        ",\"npc_since_hours\":" + sinceHours + MarasContext(akActor) + "}"
    Int rc = SkyrimNetApi.SendCustomPromptToLLM("snrom_talk_assess", VariantName(), ctx, \
        Self, "SNRom_Bridge", "OnTalkAssessed")
    ; Log the SEND, not just the failure. Logging only failures made a
    ; successful assessment that answered NOTHING indistinguishable from "no
    ; candidate was found" and from "the callback never fired" - three
    ; different states, all silent. Third time in this project.
    Diag(LOG_INFO(), "Talk assessment sent for " + _talkName + " (rc=" + rc + ")")
    If rc != 1
        _talkActor = None
    EndIf
EndFunction

Event OnTalkAssessed(String asResponse, Int aiSuccess)
    Actor who = _talkActor
    String asked = _talkName
    _talkActor = None

    If who == None || aiSuccess != 1
        Return
    EndIf
    String echoed = SNRom_Decorators.NameCore(SNRom_Decorators.FieldValue(asResponse, "NAME:"))
    If echoed != "" && echoed != SNRom_Decorators.NameCore(asked)
        Diag(LOG_ERROR(), "Talk echo mismatch: asked about '" + asked + "', answered as '" + echoed + "'. Discarded.")
        Return
    EndIf

    String weightWord = SNRom_Decorators.FieldValue(asResponse, "WEIGHT:")
    Int points = SNRom_Decorators.WeightToPoints(weightWord)
    If points == 0
        ; NOTHING is the expected answer most of the time, and it still gets a
        ; line. A verdict that leaves no trace cannot be distinguished from an
        ; assessor that never ran.
        Diag(LOG_INFO(), "Talk verdict for " + asked + ": '" + weightWord + "' - no award")
        Return
    EndIf

    ; WHAT is the last field, so its absence is also the truncation guard. An
    ; award with nothing to point at is exactly the one not to make.
    String what = SNRom_Decorators.FieldValue(asResponse, "WHAT:")
    If what == "" || SNRom_Decorators.Upper(what) == "NONE"
        Diag(LOG_WARN(), "Talk award for " + asked + " named no exchange - discarded")
        Return
    EndIf

    ; ── ADDRESS may be RE-ESTABLISHED in conversation ───────────────────────
    ; The author's case: the player told Sybille, explicitly, to call him "Daddy"
    ; from then on. That is a real event in the fiction and it should stick
    ; without anyone editing a file - which is precisely what SeverActions'
    ; custom bio blocks cannot do, since they are writable only from PrismaUI.
    ;
    ; Read BEFORE the weight gates below. A conversation can change what someone
    ; is called without moving the bond at all - "call me Daddy" may well score
    ; NOTHING - so this must not be gated on an award being made.
    ;
    ; The prompt only emits this when a form of address is EXPLICITLY set or
    ; changed, so an absent field means "unchanged", never "cleared".
    String newAddress = SNRom_Decorators.FieldValue(asResponse, "ADDRESS:")
    If newAddress != "" && SNRom_Decorators.Upper(newAddress) != "NONE"
        String oldAddress = StoreGetText(who, "Address")
        If oldAddress != newAddress
            StoreSetText(who, "Address", newAddress)
            ; The dashboard holds ADDRESS too; see PushBondText.
            If _dashText
                PushBondText(who)
            EndIf
            Diag(LOG_INFO(), asked + " now calls " + Game.GetPlayer().GetDisplayName() + \
                ": " + newAddress + (" (was: " + oldAddress + ")"))
        EndIf
    EndIf

    ; DIRECTION negates only weights that are POSITIVE to begin with.
    ;
    ; SETBACK and RUPTURE already carry their sign in the weight itself, and
    ; applying AWAY to them would flip a -40 into a +40 - rewarding the model
    ; for correctly identifying that something went wrong. Two fields that must
    ; agree is exactly the shape that fails on a small model, so the signed
    ; weights are deliberately immune to the second field.
    ;
    ; The old path still works: REAL/AWAY is -40, LANDMARK/AWAY is -350. Both
    ; vocabularies reach the same place, which matters because the model may
    ; reasonably reach for either.
    If points > 0
        If SNRom_Decorators.Upper(SNRom_Decorators.FieldValue(asResponse, "DIRECTION:")) == "AWAY"
            points = -points
        EndIf
    EndIf
    ; -- A COMMITMENT TO MARRY IS THE LARGEST BEAT THERE IS. IT ALSO HAS A FLOOR.
    ; The author's reasoning, not mine: two people saying aloud that they want to
    ; marry each other is a bigger step than becoming partners was, not a
    ; formality on the way to one. So this does NOT forbid the landmark, and an
    ; earlier version of this fix did - wrongly.
    ;
    ; WHAT IT FORBIDS IS REACHING IT FROM NOWHERE. Fenja Secret-Fire was paid
    ; LANDMARK 350 for "sealing our bond as husband and wife" while sitting at
    ; tier 2, unmarried, with an authored INTIMACY of ROMANTIC that will not even
    ; let her be touched until tier 4. The prompt had already told the judge she
    ; was not married and that a wedding is not a conversation; it obeyed the
    ; nearer, absolute rule instead. That is the whole reason this mod exists: an
    ; agreeable model will let you talk a stranger into marrying you inside a day.
    ;
    ; THE MODEL CLASSIFIES, PAPYRUS GATES. LANDMARK_KIND is a fact about what was
    ; said and the judge is good at it; whether that fact may pay 350 is a rule,
    ; and rules do not belong anywhere the model can reason past them. Same
    ; division as the eligibility gates in the action configs.
    ;
    ; Downgraded to MAJOR rather than discarded, because the moment DID happen and
    ; refusing it outright would teach the player their evening did not count.
    ; They can reach Lover and mean it again; the second time it pays in full.
    String landKind = SNRom_Decorators.Upper(SNRom_Decorators.Trim(\
        SNRom_Decorators.FieldValue(asResponse, "LANDMARK_KIND:")))
    If SNRom_Decorators.Upper(weightWord) == "LANDMARK" && landKind == "MARRIAGE"
        Int held = PointsOf(who)
        If held < LOVER_MIN()
            Diag(LOG_INFO(), "Talk landmark for " + asked + " was a commitment to " + \
                "marry, and they hold " + held + " pts - below Lover at " + LOVER_MIN() + \
                ". Downgraded to MAJOR: the moment counts, but marrying is not a step " + \
                "you take from here. It pays in full once they are actually lovers.")
            weightWord = "MAJOR"
            points     = SNRom_Decorators.WeightToPoints("MAJOR")
        EndIf
    EndIf

    ApplyTalkAward(who, points, weightWord, what)
EndEvent

Function ApplyTalkAward(Actor akActor, Int aiPoints, String asWeight, String asWhat)
    { Pacing lives HERE, not in the prompt. The model judges what happened;
      Papyrus decides how fast a relationship is allowed to move. }
    Int points = aiPoints
    String w = SNRom_Decorators.Upper(SNRom_Decorators.Trim(asWeight))
    ; RUPTURE shares every piece of LANDMARK's machinery - the same rarity
    ; cooldown, the same daily-cap exemption, a persistent event - because it is
    ; the same KIND of event pointing the other way. The day two people stop
    ; being what they were is exactly as defining as the day they started, and
    ; should be no easier to do twice in a week.
    ;
    ; TWO ROUTES REACH IT, and both must be caught: the explicit RUPTURE weight,
    ; and the older LANDMARK + DIRECTION:AWAY combination that has always been
    ; possible. Checking the sign rather than the word catches both, and catches
    ; any future signed weight for free.
    Bool rupture  = (w == "RUPTURE") || (w == "LANDMARK" && points < 0)
    Bool landmark = (w == "LANDMARK") && !rupture
    Bool defining = landmark || rupture
    Float now = Utility.GetCurrentGameTime()

    ; -- A STATE CANNOT BE ENTERED TWICE -------------------------------------
    ; Lisette was paid a landmark 350 for agreeing to marry, and 350 again 6.9
    ; game days later for agreeing to marry a second time. Neither award broke a
    ; rule: talkLandmarkDays is 3.0, and the gate limits how OFTEN a bond may be
    ; redefined, not what the redefinition is about.
    ;
    ; That is the right shape for most beats - "we grew closer than we were" can
    ; honestly happen more than once, so a generic landmark stays repeatable and
    ; is guarded only by the cooldown below. What cannot honestly happen twice is
    ; ENTERING A STATE YOU ARE ALREADY IN. Nobody agrees to marry the person they
    ; are already married to.
    ;
    ; The latch is a COMPARISON, not a flag, which is why there is no unlatch
    ; anywhere: it tests the stored state against the CURRENT one. A divorce drops
    ; the current state, the two stop matching, and the next real transition pays
    ; in full. The release is the event, which is what the design asked for.
    ;
    ; RUPTURES ARE EXEMPT. A negative landmark is not entering a state, and two
    ; people at the same rung can wound each other more than once.
    ;
    ; Doubly worth having now: Bond Pace multiplies earnings, so on Fast a
    ; double-paid landmark is 700 a time. The amplifier shipped in 1.1.2 before
    ; this leak was closed.
    Int commitState = CommitmentState(akActor)
    If landmark && commitState > 0 && \
       StorageUtil.GetIntValue(akActor, "SNRom_LandmarkState", 0) == commitState
        Diag(LOG_INFO(), "Landmark for " + akActor.GetDisplayName() + \
            " downgraded - already at commitment state " + commitState + \
            " and a landmark was already paid for reaching it. Nothing new was decided.")
        points   = SNRom_Decorators.WeightToPoints("MAJOR")
        landmark = False
        defining = False
    EndIf

    If defining
        ; A relationship gets to be redefined rarely. Without this, two
        ; enthusiastic conversations in an afternoon would carry someone from
        ; Stranger most of the way to Confidant.
        Float lmCool = SkyrimNetApi.GetConfigFloat(CFG(), "talkLandmarkDays", 3.0)
        If (now - StorageUtil.GetFloatValue(akActor, "SNRom_LastLandmark", -999.0)) < lmCool
            Diag(LOG_INFO(), "Defining moment (" + w + ") for " + akActor.GetDisplayName() + \
                " downgraded - one was recorded within the last " + lmCool + " days")
            ; Downgrade toward the ORDINARY weight in the same direction. A
            ; second rupture inside the window is still a bad conversation; it
            ; must not silently become a POSITIVE 120 the way it would if both
            ; branches downgraded to MAJOR.
            If rupture
                points = -SNRom_Decorators.WeightToPoints("MAJOR")
            Else
                points = SNRom_Decorators.WeightToPoints("MAJOR")
            EndIf
            landmark = False
            rupture  = False
            defining = False
        Else
            StorageUtil.SetFloatValue(akActor, "SNRom_LastLandmark", now)
            If landmark && commitState > 0
                StorageUtil.SetIntValue(akActor, "SNRom_LandmarkState", commitState)
            EndIf
        EndIf
    EndIf

    ; -- SCALE ONCE, HERE, AND USE THE RESULT EVERYWHERE ---------------------
    ; points is the weight the assessor chose. awarded is what actually lands.
    ; Keeping both is the fix for two bugs found together on 2026-08-27.
    ;
    ; THE LOG WAS LYING. The award line reported "SMALL 10 pts" while Romantasy
    ; recorded 5 - the Diag was composed from the unscaled value and the scaling
    ; happened later, inside the ModifyPoints call. On Slow every line overstated
    ; by double; on Fast it halved. This log is how the mod gets diagnosed, so a
    ; number in it that never happened is worse than no number at all.
    ;
    ; THE LEVER WAS QUADRATIC, which only became visible once the two numbers
    ; were put side by side. The daily cap was scaled but the running total
    ; counted RAW points, so Slow halved each award AND halved how many fit in a
    ; day - 50 points where 100 was intended, 800 on Fast where 400 was.
    ; Counting the APPLIED value against the scaled cap makes it linear: the
    ; same number of awards a day at every setting, each worth proportionally
    ; more or less. That is what one lever is supposed to mean.
    Int awarded = ScaleAward(points)

    ; Daily budget, so ordinary conversation cannot be farmed. Landmarks are
    ; deliberately exempt: the whole point is that the day two people decide
    ; what they are to each other is not an ordinary day.
    If !defining
        ; THE CAP SCALES WITH THE LEVER, or the fast end silently stops being fast.
        ; talkDailyCap is 200 - four REAL awards. Triple the awards without
        ; touching the cap and a talkative day hits the ceiling three times sooner,
        ; so "Much Faster" would quietly become "Normal, but earlier" with nothing
        ; saying so. Scaling it keeps the setting honest in both directions.
        Int cap = ScaleAward(SkyrimNetApi.GetConfigInt(CFG(), "talkDailyCap", 200))
        Int day = now as Int
        If StorageUtil.GetIntValue(akActor, "SNRom_TalkDay", -1) != day
            StorageUtil.SetIntValue(akActor, "SNRom_TalkDay", day)
            StorageUtil.SetIntValue(akActor, "SNRom_TalkToday", 0)
        EndIf
        Int spent = StorageUtil.GetIntValue(akActor, "SNRom_TalkToday", 0)
        Int room = cap - spent
        If room <= 0
            Diag(LOG_INFO(), "Daily conversation budget spent for " + akActor.GetDisplayName() + " - award dropped")
            Return
        EndIf
        If awarded > room
            awarded = room
        ElseIf awarded < -room
            awarded = -room
        EndIf
        Int used = awarded
        If used < 0
            used = -used
        EndIf
        StorageUtil.SetIntValue(akActor, "SNRom_TalkToday", spent + used)
    EndIf

    ; CHECK THE RETURN. In 1.x Romantasy rejected points for an actor it did not
    ; yet consider enrolled - it snapshotted its roster at LOAD, so every NPC
    ; enrolled during a session was invisible to it until the next one.
    ; Ignoring the return meant writing a ledger row for an award that never
    ; happened. From 2.0 the one refusal left is a Romantasy copy that did not
    ; verify (ImportPoints), and the rule stands.
    ;
    ; Observed 2026-08-01: Svana lost 40 and Haelga lost 350 - the first LANDMARK
    ; this project ever produced - both recorded in the ledger as if they landed,
    ; both actually discarded. The tell is `ta:-1`, i.e. GetLevel() == 0.
    ; analyze_romance.py would have reported ~390 phantom points as earned.
    ; The one moment in normal play where an award must not reach Romantasy: it
    ; would carry an unanswered romance into Lover. Withheld, not written and
    ; corrected, so there is no false LOVER splash and no phantom tier event.
    ;
    ; EARNED, so the consent gate inside ApplyDepth decides the withhold.
    Int result = ApplyDepth(akActor, awarded, asWhat, True, "talk")
    If result == DEPTH_WITHHELD()
        Ledger(akActor, "withheld", "", awarded, 1, asWhat)
        Return
    EndIf
    Bool applied = result > 0
    If !applied
        ; Roll back what we already spent. Without this a rejected award still
        ; burns the 3-day landmark cooldown and the daily conversation budget -
        ; so Haelga's lost 350 would ALSO have downgraded her next genuine
        ; landmark to MAJOR, for an award that never existed.
        If defining
            StorageUtil.UnsetFloatValue(akActor, "SNRom_LastLandmark")
            ; And the state latch, for the same reason - a refused award must not
            ; consume the one landmark this transition is allowed.
            StorageUtil.UnsetIntValue(akActor, "SNRom_LandmarkState")
        Else
            Int refund = awarded
            If refund < 0
                refund = -refund
            EndIf
            StorageUtil.SetIntValue(akActor, "SNRom_TalkToday", \
                StorageUtil.GetIntValue(akActor, "SNRom_TalkToday", 0) - refund)
        EndIf
        Diag(LOG_ERROR(), "Could not write " + awarded + " pts for " + \
            akActor.GetDisplayName() + " - their points are not ours yet and could not be " + \
            "brought over from Romantasy (see the line above). Award LOST, no ledger row written.")
        Return
    EndIf
    Ledger(akActor, "talk", "", awarded, 1, asWhat)
    ; REPORT BOTH. The weight the assessor chose is diagnostically useful and so
    ; is the number that landed; showing only one of them is how this was missed.
    String paceNote = ""
    If awarded != points
        paceNote = " -> " + awarded + " applied (Bond Pace: " + \
            SkyrimNetApi.GetConfigString(CFG(), "bondPace", "Normal") + ")"
    EndIf
    Diag(LOG_INFO(), "Talk award for " + akActor.GetDisplayName() + ": " + \
        asWeight + " " + points + " pts" + paceNote + " - " + asWhat)

    ; Only a redefinition is worth writing into the world as an event others
    ; can refer to. Everything smaller is a private shift and stays one.
    If landmark
        SkyrimNetApi.RegisterPersistentEvent(akActor.GetDisplayName() + " and " + \
            Game.GetPlayer().GetDisplayName() + " have named what they are to each other. " + asWhat, \
            akActor, Game.GetPlayer())
    EndIf

    ; A rupture ENDS things, so it does more than score. EndRomance clears the
    ; spark and caps depth; doing it here rather than in the handler keeps the
    ; whole "what a weight means" decision in one place.
    ;
    ; Ordered AFTER the ModifyPoints above so the -350 lands first and the cap
    ; is applied to the post-award total. Reversing them would let the cap pull
    ; someone to 1500 and the award then drop them to 1150, which is a second
    ; punishment for one event.
    If rupture
        SkyrimNetApi.RegisterPersistentEvent(akActor.GetDisplayName() + " and " + \
            Game.GetPlayer().GetDisplayName() + " are no longer what they were to each other. " + asWhat, \
            akActor, Game.GetPlayer())
        EndRomance(akActor, asWhat)
    EndIf
EndFunction

Function AssessNextSpark()
    { Picks ONE eligible character who can observe the player (Observers) and
      asks whether the bond has crossed. A non-follower can spark (design 3.2,
      question 9).

      One at a time, on a long interval, because this is a once-per-NPC
      transition that rewrites how she speaks for the rest of the game. There
      is no value in asking often and real cost in asking carelessly. }
    If !_ready
        Return
    EndIf
    If SkyrimNetApi.GetConfigBool(CFG(), "sparkEnabled", True) == False
        Return
    EndIf
    If _sparkActor != None
        If SlotStale(_sparkPendingAt)
            Diag(LOG_WARN(), "Spark slot held by " + _sparkName + \
                " with no callback for " + PendingTimeoutSeconds() + \
                "s - releasing. Two causes look identical from here: the prompt failed to " + \
                    "render, or the LLM call timed out. SkyrimNet.log tells them apart - a " + \
                    "template error names the file, while Request timeout, Transferred a " + \
                    "partial file or a JSON parse error means the backend, not us.")
            _sparkActor = None
        Else
            Return                              ; one assessment genuinely in flight
        EndIf
    EndIf

    ; Most overdue wins - same starvation fix as AssessNextTalk, and it matters
    ; MORE here. Spark fires once per NPC ever, so a follower stuck behind two
    ; earlier enrollments could never cross into romance at all, however long
    ; she traveled. Still exactly one per tick.
    Float now = Utility.GetCurrentGameTime()
    Float cooldown = SkyrimNetApi.GetConfigFloat(CFG(), "sparkCooldownHours", 6.0) / 24.0
    Int n = 0
    If _observers
        n = _observers.Length
    EndIf
    Int i = 0
    Actor pick = None
    Float bestWait = -1.0
    While i < n
        Actor a = _observers[i]
        If a != None && SparkCandidate(a, now, cooldown)
            Float last = StorageUtil.GetFloatValue(a, "SNRom_LastSparkCheck", 0.0)
            If (now - last) > bestWait
                bestWait = now - last
                pick     = a
            EndIf
        EndIf
        i += 1
    EndWhile

    If pick == None
        Return
    EndIf
    StorageUtil.SetFloatValue(pick, "SNRom_LastSparkCheck", now)
    Diag(LOG_DEBUG(), "Spark queue: picked " + pick.GetDisplayName() + \
        " after " + (bestWait * 24.0) + " game hours waiting")
    AssessSpark(pick)
EndFunction

Bool Function SparkCandidate(Actor akActor, Float afNow, Float afCooldown)
    { Cheap local filters BEFORE spending an LLM call. }
    If SNRom_Decorators.IsSparked(akActor)
        Return False                            ; once only, ever
    EndIf
    ; Alive and near the player already: akActor comes from Observers. This
    ; asked IsFollowing until 2.0; anyone enrolled can spark (design 3.2).

    ; ---- TENURE GATE ------------------------------------------------------
    ; An NPC's FIRST assessment runs with SNRom_LastSparkCheck at 0.0, so the
    ; prompt window is unbounded - her whole history and diary judged at once.
    ; Every NPC gets exactly one of those, and on 2026-07-31 three in a row came
    ; back YES (Nicollette, Kayla, Jordis), each on her first look. That does not
    ; settle with time: each NEW companion repeats it, so the spark stops being a
    ; rare crossing and becomes "enrolled, therefore in love" - precisely the
    ; outcome this gate exists to prevent.
    ;
    ; Papyrus, not prose. The prompt cannot be trusted to hold a line the model
    ; is free to reason past, and prompt-lessons records this project
    ; over-correcting three separate times when a threshold was tightened in
    ; wording. A hard gate is also unbypassable in the one direction that
    ; matters: SNRom_Sparked is once-per-NPC-ever and cannot be undone.
    ;
    ; The exemption is the forward hook for tier seeding. SNRom_SeedRomantic is
    ; written by nothing yet, so it reads 0 and the gate always applies today.
    ; When seeding lands, an NPC whose romance is an ESTABLISHED FACT (MARAS
    ; married/engaged, or vanilla relationship rank 4) gets flagged and skips
    ; the wait - a spouse should not serve a probation period. Deliberately NOT
    ; keyed off points or tier: a seeded bond depth says they have history, not
    ; that she is in love with him.
    If StorageUtil.GetIntValue(akActor, "SNRom_SeedRomantic", 0) != 1
        Float enrolled = StorageUtil.GetFloatValue(akActor, "SNRom_EnrolledAt", 0.0)
        If enrolled <= 0.0
            ; Enrolled before this key existed. Stamp it now and start her clock
            ; from here - a self-healing backfill. Writing inside a predicate is
            ; deliberate: it is idempotent, happens once per actor, and the
            ; alternative is an NPC who can never become eligible at all.
            StorageUtil.SetFloatValue(akActor, "SNRom_EnrolledAt", afNow)
            Return False
        EndIf
        If (afNow - enrolled) < SkyrimNetApi.GetConfigFloat(CFG(), "sparkMinDaysEnrolled", 2.0)
            Return False
        EndIf
    EndIf
    If !akActor.Is3DLoaded()
        Return False                            ; not present; recent dialogue cannot be about her
    EndIf
    ; Orientation gate. Almost always passes today because orientation is
    ; UNKNOWN for nearly everyone and RomanceOk is permissive unless STATED -
    ; but when it IS known, sparking an impossible pairing would strand the
    ; bond at the "cannot quite become it" rung forever.
    If !SNRom_Decorators.RomanceOk(akActor)
        Return False
    EndIf
    Return (afNow - StorageUtil.GetFloatValue(akActor, "SNRom_LastSparkCheck", 0.0)) >= afCooldown
EndFunction

Function AssessSpark(Actor akActor)
    _sparkActor = akActor
    _sparkName  = akActor.GetDisplayName()
    _sparkPendingAt = Utility.GetCurrentRealTime()
    ; Ardor is passed so the assessment can calibrate against HER rather than
    ; against a fixed threshold. The same words mean different things from
    ; different people: warmth from a reserved character is evidence, the same
    ; warmth from an effusive one is her ordinary register. Without this the
    ; judgment is uniform, which makes everyone equally hard to reach instead
    ; of differently hard - the opposite of the point.
    String ctx = "{\"npc_name\":\"" + _sparkName + "\"" + \
        ",\"npc_formid\":" + akActor.GetFormID() + \
        ",\"npc_ardor\":\"" + SNRom_Decorators.ArdorWord(StorageUtil.GetIntValue(akActor, "SNRom_Ardor", 2)) + "\"" + MarasContext(akActor) + "}"
    Int rc = SkyrimNetApi.SendCustomPromptToLLM("snrom_spark_assess", VariantName(), ctx, \
        Self, "SNRom_Bridge", "OnSparkAssessed")
    Diag(LOG_INFO(), "Spark assessment sent for " + _sparkName + " (rc=" + rc + ")")
    If rc != 1
        _sparkActor = None
    EndIf
EndFunction

Event OnSparkAssessed(String asResponse, Int aiSuccess)
    Actor who = _sparkActor
    String asked = _sparkName
    _sparkActor = None

    If who == None || aiSuccess != 1
        Return                                  ; silence; it will be asked again
    EndIf

    ; Echo check, same reasoning as disposition authoring: models answer as a
    ; nearby NPC often enough that a mismatched name must void the response.
    ; Getting this wrong here is worse - it would spark the wrong person.
    String echoed = SNRom_Decorators.NameCore(SNRom_Decorators.FieldValue(asResponse, "NAME:"))
    If echoed != "" && echoed != SNRom_Decorators.NameCore(asked)
        Diag(LOG_ERROR(), "Spark echo mismatch: asked about '" + asked + "', answered as '" + echoed + "'. Discarded.")
        Return
    EndIf

    String verdict = SNRom_Decorators.Upper(SNRom_Decorators.FieldValue(asResponse, "CROSSED:"))
    String momentText = SNRom_Decorators.FieldValue(asResponse, "MOMENT:")

    ; Require an affirmative AND a stated moment. "YES" with no moment means
    ; the model asserted a crossing it could not point at, which is exactly
    ; the answer not to act on - and MOMENT is the last field, so its absence
    ; also catches a truncated response.
    If verdict != "YES"
        ; A CLEAN NO IS AN ANSWER, and recording it is what frees the bond to
        ; climb. Until this existed, "no romance here" and "never asked" looked
        ; identical, so HoldShortOfLover could not tell a deep friendship from
        ; an unexamined one.
        StorageUtil.SetIntValue(who, "SNRom_SparkDecided", 1)
        Diag(LOG_INFO(), "No spark for " + asked + " (answered '" + verdict + "')")
        ; Anything held back while the answer was pending was held for a question
        ; that will now never be put. A platonic bond has no consent to give, so
        ; the points are simply owed.
        Int held = StorageUtil.GetIntValue(who, "SNRom_BankedPoints", 0)
        If held > 0
            StorageUtil.UnsetIntValue(who, "SNRom_AskPending")
            ; The bank is cleared only once the release lands, as in
            ; AcceptRomance: clearing it first lost it whenever Romantasy
            ; refused someone not following.
            If ApplyDepth(who, held, "Held while the bond was still unnamed", True, "released") > 0
                StorageUtil.UnsetIntValue(who, "SNRom_BankedPoints")
                Ledger(who, "unbank", "", held, 1, "Released - judged platonic")
                Diag(LOG_INFO(), "Released " + held + " pts held for " + asked +                     " while the spark was undecided - judged platonic, so depth is free. " +                     "Now " + PointsOf(who) + " pts.")
            EndIf
        EndIf
        Return
    EndIf
    If momentText == "" || SNRom_Decorators.Upper(momentText) == "NONE"
        Diag(LOG_WARN(), "Spark claimed for " + asked + " with no moment named - discarded")
        Return
    EndIf

    ApplySpark(who, momentText)
EndEvent

Bool Function SparkDecided(Actor akActor) Global
    { Has the spark assessor ever returned a USABLE verdict for this actor?

      THE THIRD STATE, and its absence is what let Jarl Laila Law-Giver cross
      into Lover unasked on 2026-09-05. Before this there were two observable
      conditions - sparked, and not sparked - and "judged platonic" was
      indistinguishable from "never looked at". HoldShortOfLover keys on the
      difference: a bond JUDGED platonic must climb freely to Spouse-tier depth,
      but one nobody has judged yet has to wait, because the question it would
      be asked has not been put.

      SET ONLY BY A CLEAN VERDICT. An echo mismatch, a truncated response, a
      YES with no moment named - none of those are answers, and marking them
      decided would silence the gate on exactly the actors whose reads are
      failing. }
    If akActor == None
        Return False
    EndIf
    Return StorageUtil.GetIntValue(akActor, "SNRom_SparkDecided", 0) == 1
EndFunction

Function RequestSparkNow(Actor akActor)
    { Ask the spark assessor about someone OUT OF TURN, bypassing the tenure and
      cooldown gates that the tick applies.

      WHY THE TICK IS NOT ENOUGH. SparkEligible makes an actor wait
      sparkMinDaysEnrolled (2.0) unless SNRom_SeedRomantic is set, and that flag
      is only written for a romance the game RECORDS - a MARAS marriage or
      vanilla rank 4. Laila had neither: a fresh enrollment, a seed read of
      DEVOTED from a diary describing physical intimacy, and 1999 points inside
      0.2 game days. The talk assessor reached her long before the spark
      assessor was allowed to.

      This does NOT set the spark, and that distinction is the same one
      SeedRomanticFlag makes: the assessor still decides, it is simply asked
      sooner. Everything that protects the answer stays - the echo check, the
      required moment, RomanceOk, and the single pending slot.

      Cheap and self-limiting: it declines immediately if a read is already out,
      if they are already sparked, or if a verdict is already on record. }
    If akActor == None || !_ready
        Return
    EndIf
    If SNRom_Decorators.IsSparked(akActor) || SparkDecided(akActor)
        Return
    EndIf
    If !akActor.Is3DLoaded()
        Return                                  ; the prompt reads recent dialogue
    EndIf
    If !SNRom_Decorators.RomanceOk(akActor)
        Return                                  ; sparking an impossible pairing strands it
    EndIf
    If _sparkActor != None
        ; The tick will come round again, and HoldShortOfLover keeps holding
        ; until it does, so this costs nothing but a log line.
        Diag(LOG_DEBUG(), "Spark request for " + akActor.GetDisplayName() +             " deferred - a read for " + _sparkName + " is still out.")
        Return
    EndIf
    Diag(LOG_INFO(), "Asking the spark assessor about " + akActor.GetDisplayName() +         " out of turn - they are deep enough that the next award could cross Lover.")
    AssessSpark(akActor)
EndFunction

Function ApplySpark(Actor akActor, String asMoment)
    { The crossing itself. Everything AutoEnroll deliberately withheld happens
      here, because now something actually has happened. }
    StorageUtil.SetIntValue(akActor, "SNRom_Sparked", 1)
    StorageUtil.SetIntValue(akActor, "SNRom_SparkDecided", 1)
    StorageUtil.SetFloatValue(akActor, "SNRom_SparkedAt", Utility.GetCurrentGameTime())
    ; A HOLD THAT PREDATES THE VERDICT NOW HAS ITS QUESTION. Points banked while
    ; the spark was undecided were withheld precisely because nobody could be
    ; asked yet; the moment the answer is YES, the asking is owed. Without this
    ; the bank would sit until the next award happened to arrive.
    If StorageUtil.GetIntValue(akActor, "SNRom_BankedPoints", 0) > 0
        StorageUtil.SetIntValue(akActor, "SNRom_AskPending", 1)
        Diag(LOG_INFO(), "Spark confirmed for " + akActor.GetDisplayName() +             " with " + StorageUtil.GetIntValue(akActor, "SNRom_BankedPoints", 0) +             " pts already held - raising the question now.")
    EndIf

    ApplyDepth(akActor, ScaleAward(25), asMoment, False, "spark")

    ; A SPARK IS HERS ALONE, SO IT IS A THOUGHT, NOT AN EVENT. This used to be
    ; RegisterPersistentEvent("<her> and <player> have reached an understanding
    ; neither has named. <moment>"), which is wrong twice over. It claims a
    ; MUTUAL understanding for a verdict judged "from her side - unrequited is a
    ; real answer" (the spark prompt's own words). And a persistent event is
    ; shared history: Gisli's, 2026-09-24, reached Jordis's dialogue prompts 7
    ; times as `Gisli (to Haruk): *...I let him overpower me on the furs...*`,
    ; spoken aloud as far as every bystander could tell, and fed SkyrimNet's
    ; agency engine and memory builder besides.
    ;
    ; GenerateNPCThought (Beta 25) stores a thought whose audience is the
    ; thinking NPC only and surfaces it in HER later prompts - the private
    ; shift the romantic ladder's first rung already describes ("you have not
    ; named it, even to yourself"). It can skip on SkyrimNet's thought cooldown
    ; or while she sleeps; that loses only colour, because the spark itself is
    ; the StorageUtil flag above and the Romantasy entry, not this line.
    Int thoughtRc = SkyrimNetApi.GenerateNPCThought(akActor, "Something has shifted in how you regard " + \
        Game.GetPlayer().GetDisplayName() + ", though you have said nothing of it and do not know whether it is returned. What did it: " + asMoment)
    If thoughtRc != 0
        Diag(LOG_WARN(), "Spark thought for " + akActor.GetDisplayName() + " was not generated (rc=" + thoughtRc + \
            ") - the spark stands; only the private thought is missing.", True)
    EndIf

    Ledger(akActor, "spark", "", 25, 1, asMoment)
    Diag(LOG_INFO(), "SPARK: " + akActor.GetDisplayName() + " crossed into romance - " + asMoment)
EndFunction

; ===========================================================================
; Disposition drift - people change, but not overnight and not for one night
;
; THE PROBLEM THIS SOLVES IS NOT "characters never change". It is that they
; used to change INSTANTLY and IDENTICALLY: whatever her disposition said, the
; player could have anyone in love, in bed and pregnant inside a day. The
; opposite failure is just as bad - a character who flips on every good evening
; is not evolving, she is unpredictable.
;
; So the rule is a PATTERN, not an event. Three independent gates, all in
; Papyrus where a model cannot reason past them:
;
;   1. TIME     - driftMinDays game days since her last review.
;   2. EVIDENCE - driftMinEvents scoring events since her last review, counted
;                 in Ledger. A quiet fortnight earns no review at all.
;   3. ONE RUNG - whatever comes back, ApplyDrift moves her at most one step.
;                 Reaching NEVER from CASUAL takes three separate reviews, each
;                 with its own pattern behind it.
;
; NOT A RE-AUTHOR. A full re-author asks "who is this person" from scratch and
; every field is free to move for no reason - Elisif came back ROMANTIC,
; ROMANTIC, then GUARDED across three runs with no gameplay between them. This
; asks ONE narrow question, supplies the CURRENT value, and treats "unchanged"
; as the cheapest and most likely answer.
;
; ORIENTATION IS NOT ON THE LADDER. Who someone is attracted to does not drift
; because of a good month, and a wrong answer there would be both offensive and
; unfixable. Only intimacy, ardor and exclusivity rotate.
;
; NOTHING HERE IS A ONE-WAY DOOR. NEVER is reachable and it is leavable; it
; just takes as long to walk back as it took to reach. Only genuinely asexual,
; celibate or monastic characters should sit there permanently, and that is the
; authoring prompt's job, not this one's.
; ===========================================================================

Actor  _driftActor
String _driftName
Int    _driftField
Float  _driftPendingAt

Int Function DRIFT_INTIMACY() Global
    Return 0
EndFunction

Int Function DRIFT_ARDOR() Global
    Return 1
EndFunction

Int Function DRIFT_EXCLUSIVITY() Global
    Return 2
EndFunction

String Function DriftFieldName(Int aiField) Global
    If aiField == DRIFT_INTIMACY()
        Return "INTIMACY"
    ElseIf aiField == DRIFT_ARDOR()
        Return "ARDOR"
    EndIf
    Return "EXCLUSIVITY"
EndFunction

Bool Function DriftIsOn() Global
    { Named so it cannot case-fold into its own config path. See the note on
      VoiceLeadSeconds for what that collision costs. }
    Return SkyrimNetApi.GetConfigBool(CFG(), "driftEnabled", True)
EndFunction

Float Function DriftDays() Global
    Return SkyrimNetApi.GetConfigFloat(CFG(), "driftMinDays", 7.0)
EndFunction

Int Function DriftEvents() Global
    Return SkyrimNetApi.GetConfigInt(CFG(), "driftMinEvents", 6)
EndFunction

Float Function DriftSpanDays() Global
    { Game days that must separate the first and last scoring event before a
      review is worth asking for. 1.0 means "something happened on a later day
      than the first thing", which is the minimum that can constitute a pattern
      at all. Named so it cannot case-fold into its own config path. }
    Return SkyrimNetApi.GetConfigFloat(CFG(), "driftMinSpanDays", 1.0)
EndFunction

Function AssessNextDrift()
    { Picks ONE follower who has earned a review and asks about ONE field. }
    If !_ready || !DriftIsOn()
        Return
    EndIf
    If _driftActor != None
        If SlotStale(_driftPendingAt)
            Diag(LOG_WARN(), "Drift slot held by " + _driftName + \
                " with no callback for " + PendingTimeoutSeconds() + \
                "s - releasing. Two causes look identical from here: the prompt failed to " + \
                    "render, or the LLM call timed out. SkyrimNet.log tells them apart - a " + \
                    "template error names the file, while Request timeout, Transferred a " + \
                    "partial file or a JSON parse error means the backend, not us.")
            _driftActor = None
        Else
            Return
        EndIf
    EndIf

    ; Most overdue wins, same starvation fix as the other two assessors.
    Float now = Utility.GetCurrentGameTime()
    Int n = 0
    If _observers
        n = _observers.Length
    EndIf
    Int i = 0
    Actor pick = None
    Float bestWait = -1.0
    While i < n
        Actor a = _observers[i]
        If a != None && DriftCandidate(a, now)
            Float last = StorageUtil.GetFloatValue(a, "SNRom_LastDriftCheck", 0.0)
            If (now - last) > bestWait
                bestWait = now - last
                pick     = a
            EndIf
        EndIf
        i += 1
    EndWhile

    If pick == None
        Return
    EndIf
    AssessDrift(pick)
EndFunction

Bool Function DriftCandidate(Actor akActor, Float afNow)
    { Cheap local filters BEFORE spending an LLM call, and the two gates that
      make this a pattern rather than a reaction. }
    If StorageUtil.GetIntValue(akActor, "SNRom_DispositionAuthored", 0) != 1
        Return False                            ; nothing to drift FROM yet
    EndIf
    ; Alive, loaded and near the player already: akActor comes from Observers.

    ; ---- GATE 2: EVIDENCE -------------------------------------------------
    ; Checked before the clock, because it is the cheaper read and because it
    ; is the gate that actually carries the design. A follower who has been
    ; sitting in Breezehome for a month has had no new pattern of ANYTHING and
    ; must not be reviewed however long she has waited.
    If StorageUtil.GetIntValue(akActor, "SNRom_EventsSinceDrift", 0) < DriftEvents()
        Return False
    EndIf

    ; ---- GATE 2b: THE EVENTS MUST SPAN MORE THAN ONE DAY -------------------
    ; The count alone is satisfiable by a single intense evening, and that is
    ; the exact material a review cannot answer honestly: asked for a pattern
    ; and shown one occasion, the model manufactures one rather than declining.
    ; Requiring a span makes the impossible question un-askable instead of
    ; asking it and then policing the answer.
    Float firstDay = StorageUtil.GetFloatValue(akActor, "SNRom_DriftFirstDay", -1.0)
    Float lastDay  = StorageUtil.GetFloatValue(akActor, "SNRom_DriftLastDay", -1.0)
    If firstDay < 0.0 || (lastDay - firstDay) < DriftSpanDays()
        Return False
    EndIf

    ; ---- GATE 1: TIME -----------------------------------------------------
    ; First review is stamped rather than taken. Otherwise an NPC authored long
    ; ago arrives with LastDriftCheck at 0.0, reads as decades overdue, and is
    ; reviewed on the very first tick she becomes eligible - the same
    ; unbounded-first-window bug the spark tenure gate exists to fix.
    Float last = StorageUtil.GetFloatValue(akActor, "SNRom_LastDriftCheck", 0.0)
    If last <= 0.0
        StorageUtil.SetFloatValue(akActor, "SNRom_LastDriftCheck", afNow)
        Return False
    EndIf
    Return (afNow - last) >= DriftDays()
EndFunction

Function SetCharacterField(Actor akActor, Int aiField, Int aiValue)
    { DEV TOOL. Writes ONE character field directly, with no LLM involved.

      Dispatch with functionName SetCharacterField and THREE arguments - a hex
      FormID, a field number and a value.

        0 intimacy    - value is a RANK: 0 casual, 1 romantic, 2 guarded, 3 never
        1 ardor       - 0 reserved .. 4 intense
        2 exclusivity - 0 to 100

      WHY IT EXISTS: to REPAIR, not to author. A drift verdict that should not
      have been applied leaves a character field wrong, and until this existed
      the only ways back were a full re-author - which rerolls every field and
      permanently adds preferences - or waiting for a future review to walk it
      back. Both are worse than writing the one number that is wrong.

      Intimacy takes a rank rather than a minimum tier because the stored form
      is not ordered: NEVER is -1, which sorts below CASUAL. IntimacyRank and
      MinTierFromRank exist for exactly this, and the bypass is derived here so
      it cannot drift out of step with the tier. }
    If !_ready || akActor == None
        Return
    EndIf
    String who = akActor.GetDisplayName()
    If aiField == DRIFT_INTIMACY()
        Int rank = aiValue
        If rank < 0
            rank = 0
        ElseIf rank > 3
            rank = 3
        EndIf
        Int tier = SNRom_Decorators.MinTierFromRank(rank)
        String word = SNRom_Decorators.IntimacyWordFromTier(tier)
        StorageUtil.SetIntValue(akActor, "SNRom_PhysMinTier", tier)
        StorageUtil.SetIntValue(akActor, "SNRom_PhysAttrBypass", \
            SNRom_Decorators.IntimacyToBypass(word))
        Diag(LOG_INFO(), "REPAIR: " + who + " INTIMACY set to " + word + \
            " (minTier " + tier + ")")
    ElseIf aiField == DRIFT_ARDOR()
        Int a = aiValue
        If a < 0
            a = 0
        ElseIf a > 4
            a = 4
        EndIf
        StorageUtil.SetIntValue(akActor, "SNRom_Ardor", a)
        Diag(LOG_INFO(), "REPAIR: " + who + " ARDOR set to " + \
            SNRom_Decorators.ArdorWord(a))
    Else
        Int e = aiValue
        If e < 0
            e = 0
        ElseIf e > 100
            e = 100
        EndIf
        StorageUtil.SetIntValue(akActor, "SNRom_Exclusivity", e)
        Diag(LOG_INFO(), "REPAIR: " + who + " EXCLUSIVITY set to " + e + " out of 100")
    EndIf
    SyncOurBlocks(akActor, "?", "after a repair")
EndFunction

Function ForceDriftReview(Actor akActor, Int aiField)
    { DEV TOOL. Reviews someone NOW, bypassing both gates.

      Dispatch with functionName ForceDriftReview and TWO arguments - a hex
      FormID and a field number. Papyrus default parameter values do not apply
      through the web API, so the count must match exactly or the call dies with
      an argument-count mismatch visible only in SkyrimNet.log.

        0 intimacy, 1 ardor, 2 exclusivity, anything else keeps the rotation.

      WHY THIS IS A DEV TOOL AND NOT A FEATURE. The two gates ARE the design -
      driftMinDays and driftMinEvents are what make a change a pattern rather
      than a reaction, and a build where they can be skipped in ordinary play is
      a build where personalities move on one good evening again. This exists so
      the drift path can be exercised without waiting a game week for the first
      honest review, and for nothing else.

      It still cannot invent a verdict. Everything downstream is untouched: the
      response must name a pattern spanning more than one occasion, the echo
      check still voids a mismatched name, and ApplyDrift still moves exactly
      one rung. A forced review of someone with a quiet history should come back
      NO, and that is the correct result rather than a failed test. }
    If !_ready || akActor == None
        Return
    EndIf
    If _driftActor != None
        Diag(LOG_WARN(), "Releasing the drift slot held by " + _driftName + \
            " to force a review of " + akActor.GetDisplayName())
        _driftActor = None
    EndIf
    If aiField >= 0 && aiField <= 2
        StorageUtil.SetIntValue(akActor, "SNRom_DriftField", aiField)
    EndIf
    ; Report the span being bypassed. Five forced reviews were run against a
    ; single evening's material and read as the feature failing, when the
    ; natural path would never have asked at all. A forced run must say what it
    ; is overriding so its result can be interpreted honestly.
    Float firstDay = StorageUtil.GetFloatValue(akActor, "SNRom_DriftFirstDay", -1.0)
    Float lastDay  = StorageUtil.GetFloatValue(akActor, "SNRom_DriftLastDay", -1.0)
    String span = "no scoring events recorded since the last review"
    If firstDay >= 0.0
        span = "their events span " + (lastDay - firstDay) + " game days (needs " + \
            DriftSpanDays() + ")"
    EndIf
    Diag(LOG_INFO(), "FORCED drift review for " + akActor.GetDisplayName() + \
        " - both gates bypassed, this is a dev tool. " + span + ". If that is under " + \
        "the requirement, the material is one occasion and NO is the only honest " + \
        "answer - a YES here is manufactured, not a bug in the verdict.")
    AssessDrift(akActor)
EndFunction

Bool Function DriftFieldHeld(Actor akActor, Int aiField)
    If aiField == DRIFT_ARDOR()
        Return BioPlayerHolds(akActor, BIO_EXPRESSION())
    ElseIf aiField == DRIFT_EXCLUSIVITY()
        Return BioPlayerHolds(akActor, BIO_ATTACHMENT())
    EndIf
    Return False
EndFunction

Function AssessDrift(Actor akActor)
    { Asks the one question, about the one field whose turn it is. }
    _driftActor = akActor
    _driftName  = akActor.GetDisplayName()
    _driftPendingAt = Utility.GetCurrentRealTime()

    ; Rotate rather than pick. Choosing the field "most likely to have moved"
    ; would need a judgment this code cannot make, and would quietly bias
    ; every review toward whichever axis the last award happened to touch.
    _driftField = StorageUtil.GetIntValue(akActor, "SNRom_DriftField", 0)
    ; A field the PLAYER answered with a bio block is theirs: drift does not
    ; review it, so no call is spent on a step that would not be taken. Our
    ; own blocks do not hold a field - SyncOurBlocks moves them with it.
    ; Intimacy has no block, so this always ends on a reviewable field.
    Int tries = 0
    While tries < 2 && DriftFieldHeld(akActor, _driftField)
        Diag(LOG_INFO(), "Drift skips " + DriftFieldName(_driftField) + " for " + _driftName + \
            " - the player's own bio block answers it.")
        _driftField = (_driftField + 1) % 3
        tries += 1
    EndWhile
    StorageUtil.SetIntValue(akActor, "SNRom_DriftField", (_driftField + 1) % 3)

    Int minTier = StorageUtil.GetIntValue(akActor, "SNRom_PhysMinTier", 4)
    String current = ""
    If _driftField == DRIFT_INTIMACY()
        current = SNRom_Decorators.IntimacyWordFromTier(minTier)
    ElseIf _driftField == DRIFT_ARDOR()
        current = SNRom_Decorators.ArdorWord(StorageUtil.GetIntValue(akActor, "SNRom_Ardor", 2))
    Else
        current = StorageUtil.GetIntValue(akActor, "SNRom_Exclusivity", 50) + " out of 100"
    EndIf

    ; Her own stated WHY travels with the question. The bar for changing
    ; someone has to be HER bar - the same month should move a woman who keeps
    ; everyone at arm's length far less than one who falls hard and often. This
    ; is the anti-uniformity guard, and without it every character drifts at
    ; the same speed, which is just the old problem wearing a slower coat.
    String ctx = "{\"npc_name\":\"" + Escape(_driftName) + "\"" + \
        ",\"npc_formid\":" + akActor.GetFormID() + \
        ",\"drift_field\":\"" + DriftFieldName(_driftField) + "\"" + \
        ",\"drift_current\":\"" + Escape(current) + "\"" + \
        ",\"drift_days\":" + DriftDays() + \
        ",\"npc_why\":\"" + Escape(StoreGetText(akActor, "Why")) + "\"" + MarasContext(akActor) + "}"

    Int rc = SkyrimNetApi.SendCustomPromptToLLM("snrom_disposition_drift", VariantName(), ctx, \
        Self, "SNRom_Bridge", "OnDriftAssessed")
    Diag(LOG_INFO(), "Drift review sent for " + _driftName + " on " + \
        DriftFieldName(_driftField) + " (currently " + current + ", rc=" + rc + ")")
    If rc != 1
        _driftActor = None
    EndIf
EndFunction

Event OnDriftAssessed(String asResponse, Int aiSuccess)
    Actor who    = _driftActor
    String asked = _driftName
    Int field    = _driftField
    _driftActor  = None

    If who == None || aiSuccess != 1
        Return                                  ; silence; she will be asked again
    EndIf

    ; Stamp the review as TAKEN regardless of the answer, and only here. A
    ; review that ran and said "no change" has still spent its evidence - not
    ; resetting would leave her permanently eligible, asking every tick forever
    ; and burning a call each time.
    StorageUtil.SetFloatValue(who, "SNRom_LastDriftCheck", Utility.GetCurrentGameTime())
    StorageUtil.SetIntValue(who, "SNRom_EventsSinceDrift", 0)
    ; The span window restarts with the count. Leaving FirstDay behind would let
    ; a single later event pair with a month-old one and satisfy the span
    ; forever after, which is the opposite of asking "has this kept happening".
    StorageUtil.UnsetFloatValue(who, "SNRom_DriftFirstDay")
    StorageUtil.UnsetFloatValue(who, "SNRom_DriftLastDay")

    String echoed = SNRom_Decorators.NameCore(SNRom_Decorators.FieldValue(asResponse, "NAME:"))
    If echoed != "" && echoed != SNRom_Decorators.NameCore(asked)
        Diag(LOG_ERROR(), "Drift echo mismatch: asked about '" + asked + \
            "', answered as '" + echoed + "'. Discarded.")
        Return
    EndIf

    String verdict = SNRom_Decorators.Upper(SNRom_Decorators.FieldValue(asResponse, "CHANGED:"))
    String pattern = SNRom_Decorators.FieldValue(asResponse, "PATTERN:")
    String toward  = SNRom_Decorators.Upper(SNRom_Decorators.FieldValue(asResponse, "DIRECTION:"))

    If verdict != "YES"
        Diag(LOG_INFO(), "No drift for " + asked + " on " + DriftFieldName(field) + \
            " (answered '" + verdict + "') - unchanged is the expected answer")
        Return
    EndIf
    ; Same belt-and-braces as the spark assessor: an affirmative with nothing
    ; behind it is the answer NOT to act on. PATTERN is also the last field, so
    ; its absence catches a truncated response at the same time.
    If pattern == "" || SNRom_Decorators.Upper(pattern) == "NONE"
        Diag(LOG_WARN(), "Drift claimed for " + asked + " with no pattern named - discarded")
        Return
    EndIf
    ; TWO OR MORE CITED OCCASIONS, counted rather than requested. A pattern is
    ; made of occasions; a model answering from whatever is most vivid nearby
    ; can restate one moment convincingly and cannot produce two dated ones.
    ; This is the check that makes "not an event, a PATTERN" enforceable.
    Int cited = SNRom_Decorators.CountOccasions( \
        SNRom_Decorators.FieldValue(asResponse, "OCCASIONS:"))
    If cited < 2
        Diag(LOG_WARN(), "Drift for " + asked + " discarded - a pattern needs moments on at " + \
            "least two DIFFERENT DAYS and only " + cited + " distinct dated occasion(s) were " + \
            "cited. Undated citations, and several from one evening, do not count. " + \
            "Claimed pattern was: " + pattern)
        Return
    EndIf

    ; The prompt has excluded watched events since it was written, was tightened
    ; twice, and the model cited them both times anyway. See PatternIsWatching.
    If SNRom_Decorators.PatternIsWatching(pattern)
        Diag(LOG_WARN(), "Drift for " + asked + " discarded - the pattern rests on what " + \
            "they WATCHED, which is an account of being present rather than evidence " + \
            "about the two of them. Pattern was: " + pattern)
        Return
    EndIf
    If toward != "OPEN" && toward != "CLOSED"
        Diag(LOG_WARN(), "Drift for " + asked + " gave no usable direction ('" + \
            toward + "') - discarded")
        Return
    EndIf

    ApplyDrift(who, field, (toward == "OPEN"), pattern)
EndEvent

Function ApplyDrift(Actor akActor, Int aiField, Bool abOpen, String asPattern)
    { Moves ONE field by exactly ONE step, and writes what earned it.

      The step sizes are ours, not the model's - it is asked only which way,
      never how far. That is the same separation the conversational weights
      use, and for the same reason: a model asked for a magnitude will
      eventually give a large one. }
    String who = akActor.GetDisplayName()
    String before = ""
    String after  = ""

    If aiField == DRIFT_INTIMACY()
        Int rank = SNRom_Decorators.IntimacyRank(StorageUtil.GetIntValue(akActor, "SNRom_PhysMinTier", 4))
        before = SNRom_Decorators.IntimacyWordFromTier(SNRom_Decorators.MinTierFromRank(rank))
        If abOpen
            rank -= 1
        Else
            rank += 1
        EndIf
        If rank < 0
            rank = 0
        ElseIf rank > 3
            rank = 3
        EndIf
        Int newTier = SNRom_Decorators.MinTierFromRank(rank)
        after = SNRom_Decorators.IntimacyWordFromTier(newTier)
        StorageUtil.SetIntValue(akActor, "SNRom_PhysMinTier", newTier)
        ; The bypass is derived from intimacy, never stored independently, so it
        ; MUST be rewritten here. Forgetting it would leave a woman who has
        ; drifted to CASUAL still gated behind Lover - the drift would show in
        ; the logs and change nothing in play, which is the worst kind of bug.
        StorageUtil.SetIntValue(akActor, "SNRom_PhysAttrBypass", \
            SNRom_Decorators.IntimacyToBypass(after))

    ElseIf aiField == DRIFT_ARDOR()
        Int ardor = StorageUtil.GetIntValue(akActor, "SNRom_Ardor", 2)
        before = SNRom_Decorators.ArdorWord(ardor)
        If abOpen
            ardor += 1
        Else
            ardor -= 1
        EndIf
        If ardor < 0
            ardor = 0
        ElseIf ardor > 4
            ardor = 4
        EndIf
        after = SNRom_Decorators.ArdorWord(ardor)
        StorageUtil.SetIntValue(akActor, "SNRom_Ardor", ardor)

    Else
        Int excl = StorageUtil.GetIntValue(akActor, "SNRom_Exclusivity", 50)
        before = excl + " out of 100"
        ; 20 points, so the full span is five reviews end to end. At
        ; driftMinDays of 7 that is a season of sustained behavior to go from
        ; wholly open to wholly singular, which is about right for a thing
        ; people rarely do quickly.
        ;
        ; THIS AXIS RUNS BACKWARDS FROM THE OTHER TWO, and getting it wrong is
        ; silent. For intimacy and ardor, OPEN means a HIGHER value - closer to
        ; CASUAL, more demonstrative. For exclusivity, OPEN means open to
        ; SHARING, which is a LOWER number: 0 is untroubled by others and 100
        ; cannot share. The prompt says so in as many words; this code did not,
        ; and the very first live review moved Jordis from 60 to 80 on a verdict
        ; that meant 40. Caught only because the forced-review tool made it
        ; possible to see one fire at all instead of waiting a game week.
        If abOpen
            excl -= 20
        Else
            excl += 20
        EndIf
        If excl < 0
            excl = 0
        ElseIf excl > 100
            excl = 100
        EndIf
        after = excl + " out of 100"
        StorageUtil.SetIntValue(akActor, "SNRom_Exclusivity", excl)
    EndIf

    If before == after
        Diag(LOG_INFO(), "Drift for " + who + " on " + DriftFieldName(aiField) + \
            " was already at the end of its range (" + before + ") - nothing to move")
        Return
    EndIf

    Diag(LOG_INFO(), "DRIFT: " + who + " " + DriftFieldName(aiField) + " " + \
        before + " -> " + after + " - " + asPattern)
    ; Our block for this field (if it is ours alone) follows the character, or
    ; the bio and the bond prompt would contradict each other.
    SyncOurBlocks(akActor, "?", "after drift")
    ; Written into the world, because this is a person changing and the people
    ; around her should be able to refer to it. Not a persistent event for the
    ; other two - only a change she has actually lived is worth remembering.
    SkyrimNetApi.RegisterPersistentEvent(who + " has been changing, in a way " + \
        Game.GetPlayer().GetDisplayName() + " has had a hand in. " + asPattern, \
        akActor, Game.GetPlayer())
EndFunction

Function PumpAuthoringQueue()
    { Starts the next queued authoring, if any and if nothing is in flight. }
    If _pendingActor != None
        Return
    EndIf
    Int n = StorageUtil.FormListCount(None, "SNRom_AuthorQueue")
    If n <= 0
        Return
    EndIf
    Form f = StorageUtil.FormListGet(None, "SNRom_AuthorQueue", 0)
    StorageUtil.FormListRemoveAt(None, "SNRom_AuthorQueue", 0)
    Actor next = f as Actor
    If next != None
        Diag(LOG_INFO(), "Dequeued " + next.GetDisplayName() + " for authoring (" + (n - 1) + " left)")
        AuthorDisposition(next)
    Else
        RegisterForSingleUpdate(2.0)   ; bad entry - skip it and keep draining
    EndIf
EndFunction

Event OnDispositionAuthored(String asResponse, Int aiSuccess)
    { SkyrimNet's callback for AuthorDisposition, named in its dispatch. A
      thin wrapper since WP2, like OnSeedAssessed: DispositionAuthored has six
      early exits, and an open dashboard wants the row - traits as well as the
      prose ApplyProse pushes - after whichever one runs. A re-author or
      preference repair started from the dashboard ends here. }
    Actor who = _pendingActor
    _limitPicks = "?"
    DispositionAuthored(asResponse, aiSuccess)
    ; After every exit DispositionAuthored has: a success set _limitPicks from
    ; the response, a failure left it "?" (lifted limits go back on).
    SyncAfterAuthoring(who, _limitPicks)
    If _dashText
        PushBond(who, 0)
    EndIf
EndEvent

String _limitPicks = "?"   ; the authoring response's LIMIT_BLOCKS, as keys; "?" = none given

Function DispositionAuthored(String asResponse, Int aiSuccess)
    Actor who = _pendingActor
    String asked = _pendingName
    _pendingActor = None

    ; Drain the queue from OnUpdate rather than at each return below. This
    ; event has six early exits and pumping at every one of them is exactly
    ; the kind of thing that gets missed when a seventh is added later.
    RegisterForSingleUpdate(2.0)

    ; Raw response is logged BEFORE any parsing, always. Without it, "this
    ; follower has the wrong personality" is unattributable - you cannot tell
    ; a bad model from a bad parser.
    LogDisposition(asked, aiSuccess, asResponse, "")

    If who == None
        Return
    EndIf
    If aiSuccess != 1
        Diag(LOG_WARN(), "Disposition LLM call failed for " + asked + " - archetype fallback")
        ApplyArchetype(who)
        Return
    EndIf

    ; --- actor-confusion guard -------------------------------------------
    ; Models routinely answer as a nearby NPC instead of the one asked about.
    ; A wrong personality would persist forever, so a mismatched echo voids
    ; the entire response.
    String echoed = SNRom_Decorators.NameCore(SNRom_Decorators.FieldValue(asResponse, "NAME:"))
    If echoed != "" && echoed != SNRom_Decorators.NameCore(asked)
        Diag(LOG_ERROR(), "Disposition echo mismatch: asked for '" + asked + "', model answered as '" + echoed + "'. Discarded.")
        LogDisposition(asked, aiSuccess, asResponse, "echo-mismatch:" + echoed)
        ApplyArchetype(who)
        Return
    EndIf

    ; --- truncation guard, in two halves ----------------------------------
    ; The answer format now puts the small character fields and WHY BEFORE the
    ; lists, precisely so a runaway list cannot destroy the judgment that
    ; preceded it. Jordis blew the 750-char callback cap twice by transcribing
    ; the catalogue, and under the old ordering that cost her ORIENTATION,
    ; INTIMACY and everything else too.
    ;
    ; EXCLUSIVITY is the last character field, so its absence means the
    ; response died before even the cheap part finished - genuinely unusable.
    If SNRom_Decorators.FieldValue(asResponse, "EXCLUSIVITY:") == ""
        Diag(LOG_ERROR(), "Truncated response for " + asked + \
            " (no EXCLUSIVITY: - died before the character block finished). Discarded.")
        LogDisposition(asked, aiSuccess, asResponse, "truncated-early")
        ApplyArchetype(who)
        Return
    EndIf

    ; THE CHARACTER IS THE WHOLE ANSWER FROM 2.0. The response may still carry
    ; LIKES and DISLIKES lines until the prompt stops asking for them; they are
    ; not read. Romantasy's preferences do not carry into Relationships (the
    ; author, 2026-09-30), and phase 5 brings preferences back on our own
    ; vocabulary. Which retires 1.x's preference guards with them: the
    ; list-truncation fallback, other authors' preferences, the player-managed
    ; flag and Romantasy's refusals were all about writing into Romantasy.
    ;
    ; What the response must carry is the character block, which the
    ; truncation guard above has already checked reached EXCLUSIVITY. The
    ; lists were always last, precisely so a runaway list could not destroy
    ; the judgment that preceded it.
    ApplyCharacter(who, asResponse)
    StorageUtil.SetIntValue(who, "SNRom_DispositionAuthored", 1)

    ; Same rule the character fields already follow in ApplyCharacter: an ABSENT
    ; field is not an answer of "blank", it means the response did not carry one.
    ; Writing "" here erases a good earlier line, and WHY is the ONLY field
    ; BuildCircle can read - so losing it silently takes circle differentiation
    ; down with it for every NPC authored afterwards, which is exactly the
    ; symptom that read as "it reverted with the save" for two sessions.
    ApplyProse(who, asResponse, asked)

    Diag(LOG_INFO(), "Disposition authored for " + asked)
    LogDisposition(asked, aiSuccess, asResponse, "applied")
EndFunction

Function ApplyProse(Actor akActor, String asResponse, String asName)
    { The three free-text fields: WHY, LIMIT and ADDRESS.

      Extracted from OnDispositionAuthored so the character-only path can write
      them without also touching preferences. Shared rather than duplicated: WHY
      is the one field BuildCircle used to read, and a second copy of this logic
      drifting out of step would take circle differentiation down silently.

      ABSENT IS NOT BLANK, for all three. Writing "" erases a good earlier line.
      A truncated response carries no fields at all, and treating that as an
      answer of "nothing" is how a working disposition gets wiped by a failed
      re-author. }
    String whyLine = SNRom_Decorators.FieldValue(asResponse, "WHY:")
    If whyLine != ""
        StoreSetText(akActor, "Why", whyLine)
    Else
        Diag(LOG_WARN(), "No WHY in response for " + asName + " - previous line kept")
    EndIf
    ; LIMIT - what she will not do. Same absent-is-not-blank rule.
    ;
    ; The mod modelled desire on five axes and refusal on none, so every
    ; judgment call had a thumb on the scale toward yes: an LLM with no stated
    ; boundary and a persistent player will comply, whoever the character is.
    ; The author confirmed it by test - every female NPC could be talked into
    ; anything regardless of her authored personality.
    ;
    ; FREE TEXT, not an enum, and this is the one place that rule really earns
    ; itself: a fixed set of refusals would give every NPC the same three
    ; boundaries and produce exactly the uniform friction this project keeps
    ; designing away from. What someone will not do is as particular as what
    ; they want.
    String limitLine = SNRom_Decorators.FieldValue(asResponse, "LIMIT:")
    If limitLine != ""
        StoreSetText(akActor, "Limit", limitLine)
    Else
        Diag(LOG_WARN(), "No LIMIT in response for " + asName + " - previous line kept")
    EndIf

    ; ADDRESS - what they call the player.
    ;
    ; PINNED, NOT REMEMBERED. This has been unreliable in SkyrimNet since before
    ; this mod existed, and the reason is structural: a form of address lives
    ; only in dialogue history and retrieved memories, and BOTH are windowed.
    ; The recent-events buffer rolls over; get_relevant_memories returns four
    ; items by relevance. A name established three days ago simply falls out of
    ; context and the NPC reverts to whatever the base bio implies.
    ;
    ; A stored field rendered unconditionally into character_bio cannot be
    ; forgotten because it is never retrieved - it is always present.
    ;
    ; Free text rather than a single name, deliberately. Real address is
    ; contextual: a wife says "Honey" at home and "my husband" to a stranger;
    ; a housecarl switches between a name and a title depending on who is
    ; listening. "Haruk, or Thane in public" carries that; a bare string cannot.
    ; NOT WARNED ON WHEN ABSENT, unlike WHY and LIMIT above. The authoring
    ; prompt does not ask for ADDRESS and should not: a form of address is
    ; established in play, by someone actually saying it, and authoring runs
    ; the moment an NPC enrolls - inventing a pet name for a person they have
    ; barely met is exactly the "forcing a guess" failure the orientation BASIS
    ; field exists to prevent.
    ;
    ; snrom_talk_assess owns this field, and its reader (SEE the ADDRESS
    ; re-establish block in the talk path) treats absence as "unchanged" with
    ; no warning at all. This path only takes one if a model volunteers it.
    ;
    ; It DID warn until 1.0.2, on a field its own prompt never requested: 65 of
    ; 72 authorings logged it, against 0 for WHY and 0 for LIMIT. A warning that
    ; fires on 90% of healthy runs trains you to ignore the log.
    String addressLine = SNRom_Decorators.FieldValue(asResponse, "ADDRESS:")
    If addressLine != ""
        StoreSetText(akActor, "Address", addressLine)
    EndIf
    ; THE DASHBOARD HOLDS THIS TEXT once a full refresh has answered this
    ; session, so the change goes to it now, not at the next load. A Bool when
    ; nobody has opened it. See PushBondText.
    If _dashText
        PushBondText(akActor)
    EndIf
EndFunction

Function ApplyCharacter(Actor akActor, String asResponse)
    { Writes the six keys that gate romance and intimacy. Until 2026-07-28 all
      six were read-with-a-default and written by NOTHING, so every NPC in the
      game shared one hardcoded personality and both gates were decorative.

      Written ONLY here, on a successful authored response that has already
      passed the name echo-check - so a response answering as the wrong NPC
      cannot rewrite someone's sexuality.

      Orientation and intimacy are deliberately independent. Sapphire is the
      case that proves it: someone who shuns commitment may never cross into
      Lover, and should still be able to want someone she is attracted to.
      That is CASUAL intimacy with a high bar for love - two separate fields,
      because collapsing them into one romance axis loses her entirely. }
    ; Checked, because FieldValue is a substring Find and these two keys share
    ; a prefix: "SEXUAL_ORIENTATION:" does NOT occur inside
    ; "SEXUAL_ORIENTATION_BASIS:" (the character after SEXUAL_ORIENTATION is an
    ; underscore, not a colon), so the two lookups cannot collide in either
    ; order. The same held for the old ORIENTATION/ORIENTATION_BASIS pair and
    ; has to be re-checked on every rename, not assumed. If a key is ever added
    ; that DOES nest - "INTIMACY:" inside "INTIMACY_NOTE:" would - FieldValue
    ; needs to anchor on line starts instead.
    ;
    ; Note the old label is a SUFFIX of the new one: a stale lookup for
    ; "ORIENTATION:" would now match inside "SEXUAL_ORIENTATION:" and appear to
    ; work. Both lookups moved together here; if a third ever appears, it must
    ; use the full new key.
    String basisWord  = SNRom_Decorators.FieldValue(asResponse, "SEXUAL_ORIENTATION_BASIS:")
    String orientWord = SNRom_Decorators.FieldValue(asResponse, "SEXUAL_ORIENTATION:")
    String intimWord  = SNRom_Decorators.FieldValue(asResponse, "INTIMACY:")

    Int basis   = SNRom_Decorators.OrientationBasisToInt(basisWord)
    Int orient  = SNRom_Decorators.OrientationToInt(orientWord)
    Int minTier = SNRom_Decorators.IntimacyToMinTier(intimWord)
    Int bypass  = SNRom_Decorators.IntimacyToBypass(intimWord)
    Int ardor   = SNRom_Decorators.ArdorToInt(SNRom_Decorators.FieldValue(asResponse, "ARDOR:"))
    Int excl    = SNRom_Decorators.ExclusivityToInt(SNRom_Decorators.FieldValue(asResponse, "EXCLUSIVITY:"))

    ; ONLY write a field the response actually contained. An ABSENT field is
    ; not an answer of "default" - it means the response was truncated or
    ; malformed, and writing the mapper's fallback silently destroys a good
    ; earlier read.
    ;
    ; This is not hypothetical. Jordis returned 34 likes, blew past the 750
    ; character callback cap, and was cut off before ORIENTATION/INTIMACY ever
    ; appeared. Every field arrived as "", every mapper returned its safe
    ; default, and her authored GUARDED/exclusivity-75 was overwritten with
    ; minTier4/50 by a response that never mentioned either.
    ; A RECORDED MARRIAGE OUTRANKS AN AUTHORED ORIENTATION, AT WRITE TIME.
    ;
    ; RomanceOk has enforced this on READ since the first time Elisif came back
    ; ORIENTATION: WOMEN / BASIS: STATED while married to a male player. This
    ; adds the same rule where the bad value ENTERS, because on 2026-08-07 the
    ; model produced that answer three more times while being told, in the same
    ; prompt, that she is married to Haruk who is Male, that the answer must
    ; include him, and that ORIENTATION is not the character's own gender. All
    ; three instructions rendered; all three were ignored. Persuasion is spent.
    ;
    ; ORIENTATION ONLY. The author's call, and it is the right line: some wives
    ; genuinely are guarded about intimacy, reserved in ardor, or fiercely
    ; exclusive, and a marriage says nothing about any of that. Clamping those
    ; would flatten exactly the per-character variation this mod exists to
    ; create. The marriage establishes precisely one fact - that this person
    ; married the player - so it may overrule precisely one field.
    ;
    ; REFUSE, DO NOT SUBSTITUTE. Storing MEN would deny any same-sex attraction
    ; she may also have; storing ANY would assert one. Neither is established by
    ; a marriage. Dropping the field leaves whatever was already known (unset
    ; reads as ANY/unknown, which RomanceOk treats permissively), so we never
    ; write a fact the game did not give us.
    Bool orientStored = False
    If orientWord != ""
        If IsMarriedToPlayer(akActor) && OrientationExcludesPlayer(orient)
            Diag(LOG_WARN(), "Rejected authored orientation '" + orientWord + "' (basis '" + basisWord + \
                "') for " + akActor.GetDisplayName() + " - she is married to the player, which the game " + \
                "records, so an orientation excluding them cannot be true. Field left as it was; " + \
                "every other authored field kept.")
        Else
            StorageUtil.SetIntValue(akActor, "SNRom_Orientation", orient)
            StorageUtil.SetIntValue(akActor, "SNRom_OrientationKnown", basis)
            orientStored = True
        EndIf
    EndIf
    If intimWord != ""
        StorageUtil.SetIntValue(akActor, "SNRom_PhysMinTier", minTier)
        StorageUtil.SetIntValue(akActor, "SNRom_PhysAttrBypass", bypass)
    EndIf
    If SNRom_Decorators.FieldValue(asResponse, "ARDOR:") != ""
        StorageUtil.SetIntValue(akActor, "SNRom_Ardor", ardor)
    EndIf
    If SNRom_Decorators.FieldValue(asResponse, "EXCLUSIVITY:") != ""
        StorageUtil.SetIntValue(akActor, "SNRom_Exclusivity", excl)
    EndIf

    ; Log the WORDS beside the numbers. "orientation=2" is unreadable six
    ; months from now, and an unparsed word silently becoming a default is
    ; exactly the failure this whole session kept running into.
    ; Orientation reports what was STORED, not what was authored. Before this,
    ; a rejected value still printed as "orientation='women'->2" and the line
    ; read as though it had been written - the exact "unparsed word silently
    ; becoming a default" confusion this log exists to prevent, just inverted.
    String orientPart = "orientation='" + orientWord + "'->" + orient + \
        " basis='" + basisWord + "'->" + basis
    If orientWord != "" && !orientStored
        orientPart = "orientation=REJECTED(authored '" + orientWord + "', married to player) - unchanged"
    EndIf
    Diag(LOG_INFO(), "Character for " + akActor.GetDisplayName() + \
        ": " + orientPart + \
        " intimacy='" + intimWord + "'->minTier" + minTier + "/bypass" + bypass + \
        " ardor=" + ardor + " exclusivity=" + excl)
    ; Applied blocks overrule the model on the three fields they answer - after
    ; the authored write, so the log above keeps what the model said and the
    ; override lines below say what was corrected.
    EnforceBlockAnswers(akActor)
    ; The Limits blocks this authoring picked, applied by OnDispositionAuthored
    ; once every exit has run (2.1, WP-B).
    _limitPicks = ParseLimitPicks(asResponse)
    ; READS BACK WHAT WAS STORED rather than reporting the parsed values above.
    ; A field the response omitted is deliberately not written - see the note on
    ; absent fields - and an orientation can be REJECTED outright for a married
    ; actor, so announcing the parse would tell the player something was changed
    ; when it was not. This is a repair tool; the number it reports has to be the
    ; number that is now on file.
    AnnounceAuthored(akActor, akActor.GetDisplayName() + " re-authored: exclusivity " + \
        StorageUtil.GetIntValue(akActor, "SNRom_Exclusivity", 50) + ", ardor " + \
        StorageUtil.GetIntValue(akActor, "SNRom_Ardor", 2) + ", " + \
        SNRom_Decorators.IntimacyWordFromTier(StorageUtil.GetIntValue(akActor, "SNRom_PhysMinTier", 4)) + ".")
EndFunction

Function EnforceBlockAnswers(Actor akActor)
    { THE PLAYER'S BLOCKS WIN, ENFORCED RATHER THAN ASKED FOR.

      A Drawn To, Expression or Attachment block the player applied is a
      direct answer, and the authoring prompt has always said so. Vivienne
      Onis, 2026-09-28: Drawn To: Both applied, re-authored ATTRACTED_TO_MEN
      anyway. Once persuasion is spent, the fact is written where the value
      enters - here after authoring, and on every load (BioBlocksOnLoad),
      because blocks are applied whenever the player likes: 22 of 78 people
      with an Expression block once disagreed with their ardor.

      Decided natively since 2.1 (SNRom_Native.BioPlan): a block of ours,
      alone in its category, is our earlier guess and not the player's answer,
      and is skipped; two different answers, or wording we do not know, are
      reported and left alone; a recorded marriage outranks a Drawn To block
      that excludes the player. }
    If akActor == None || !SeverActionsPresent()
        Return
    EndIf
    BioRun(akActor, SNRom_SABio.AssignedTitles(akActor), BIO_ENFORCE(), -1, "authoring")
EndFunction



; ===========================================================================
; WP-B (2.1): OUR RELATIONSHIPS BIO BLOCKS, CHOSEN BY THE MODEL.
;
; Every enrolled person carries the Relationships blocks from the start, so
; nobody applies them by hand, and the player can change any of them at any
; time. Players asked for personality to be as LLM-driven as possible.
;
; THE BLOCKS COME FROM THE AUTHORING RESULT, NOT FROM A SEPARATE CALL. Drawn
; To, Expression and Attachment map one to one onto the fields authoring
; already writes; Limits is the only free choice, and authoring makes it in
; the same call (LIMIT_BLOCKS). Same judgment, one call fewer, and the blocks
; can never disagree with the character.
;
; OURS VERSUS THE PLAYER'S. SNRom_BioOurs_<cat> records the block we applied
; (Limits: up to two). AN INT, NEVER A STRING: StorageUtil strings on actors
; do not survive a reload (see "Durable text store"). The first in-game run
; stored this as text and lost 93 of 99 records at the next load - PapyrusUtil
; logged "STRV Load / Data Shrink: 83 -> 14" - after which every block of
; ours read as the player's. BioRecGet/BioRecSet translate. A category is OURS ALONE while what we applied is
; still applied and nothing else is in that category. Then it is ours to keep
; in step with drift, and to lift before a re-author so it does not steer the
; rewrite. Anything else in a category is the player's choice: never touched,
; and it wins (EnforceBlockAnswers).
;
; "-" MEANS THE PLAYER TOOK OURS OFF, and we never put one back in that
; category for that person. SeverActions' rule, and ours: a player's removal
; must stick, which is also why nothing is applied on load except into an
; empty category we never filled.
;
; ONLY INTO AN EMPTY CATEGORY. 64% of the roster on the development save
; already carries Relationships blocks applied by hand (measured 2026-10-05);
; those are the player's and stay exactly as they are.
; ===========================================================================

Int _bioApi = -1   ; -1 not yet checked this session, 0 unavailable, 1 SeverActions Bio Blocks API v1+

Int Function BIO_DRAWN() Global
    Return 0
EndFunction
Int Function BIO_EXPRESSION() Global
    Return 1
EndFunction
Int Function BIO_ATTACHMENT() Global
    Return 2
EndFunction
Int Function BIO_LIMITS() Global
    Return 3
EndFunction


String Function BioCatName(Int aiCat) Global
    If aiCat == 0
        Return "Drawn To"
    ElseIf aiCat == 1
        Return "Expression"
    ElseIf aiCat == 2
        Return "Attachment"
    EndIf
    Return "Limits"
EndFunction


Bool Function BioAssignOn()
    Return _bioApi == 1 && SkyrimNetApi.GetConfigBool(CFG(), "bioBlocksAssign", True)
EndFunction


String Function LimitKeyFromWord(String asWord) Global
    { LIMIT_BLOCKS answers, one word per block. "" for anything else. }
    String w = SNRom_Decorators.Upper(SNRom_Decorators.Trim(asWord))
    If w == "SECRET"
        Return "limits.will-not-be-a-secret"
    ElseIf w == "TRUTH"
        Return "limits.will-not-be-spared-the-truth"
    ElseIf w == "BETWEEN"
        Return "limits.will-not-come-between"
    ElseIf w == "CRUELTY"
        Return "limits.will-not-stay-for-cruelty"
    ElseIf w == "OWNED"
        Return "limits.will-not-be-owned"
    ElseIf w == "COMPETE"
        Return "limits.will-not-compete-for-a-place"
    EndIf
    Return ""
EndFunction

String Function ParseLimitPicks(String asResponse)
    { "?" when the response has no LIMIT_BLOCKS line (an older prompt, or a
      truncated answer): the caller then keeps what was there. "" for NONE.
      Otherwise up to two keys, comma-separated, unknown words dropped. }
    String line = SNRom_Decorators.FieldValue(asResponse, "LIMIT_BLOCKS:")
    If line == ""
        Return "?"
    EndIf
    String[] words = StringUtil.Split(line, ",")
    String picks = ""
    Int got = 0
    Int i = 0
    While i < words.Length && got < 2
        String k = LimitKeyFromWord(words[i])
        If k != "" && StringUtil.Find("," + picks + ",", "," + k + ",") < 0
            If picks != ""
                picks += ","
            EndIf
            picks += k
            got += 1
        EndIf
        i += 1
    EndWhile
    Return picks
EndFunction

; ---- The record, as an Int --------------------------------------------------
; SNRom_BioOurs_<cat>: 0 none, -1 the player took ours off ("-"), otherwise
;   Drawn To / Expression / Attachment: 1 + the block's place in BioCatKey,
;   Limits: a bit per block (bit i = BioCatKey(3, i)), so up to two fit.
; SNRom_BioLiftedLimits: Limits bits, the same encoding.

String Function BioCatKey(Int aiCat, Int aiIndex) Global
    { Our keys, in a FIXED order that the stored record depends on: append
      only, never reorder. "" past the end. }
    If aiCat == 0
        If aiIndex == 0
            Return "drawn-to.men"
        ElseIf aiIndex == 1
            Return "drawn-to.women"
        ElseIf aiIndex == 2
            Return "drawn-to.both"
        ElseIf aiIndex == 3
            Return "drawn-to.no-one"
        EndIf
    ElseIf aiCat == 1
        If aiIndex == 0
            Return "expression.reserved-and-undemonstrative"
        ElseIf aiIndex == 1
            Return "expression.measured-shows-little"
        ElseIf aiIndex == 2
            Return "expression.warm-but-not-effusive"
        ElseIf aiIndex == 3
            Return "expression.open-about-what-they-feel"
        ElseIf aiIndex == 4
            Return "expression.intense-and-unmistakable"
        EndIf
    ElseIf aiCat == 2
        If aiIndex == 0
            Return "attachment.untroubled-by-others"
        ElseIf aiIndex == 1
            Return "attachment.accepts-others-easily"
        ElseIf aiIndex == 2
            Return "attachment.expects-the-usual-arrangement"
        ElseIf aiIndex == 3
            Return "attachment.needs-to-be-the-only-one"
        ElseIf aiIndex == 4
            Return "attachment.cannot-share-at-all"
        EndIf
    Else
        If aiIndex == 0
            Return "limits.will-not-be-a-secret"
        ElseIf aiIndex == 1
            Return "limits.will-not-be-spared-the-truth"
        ElseIf aiIndex == 2
            Return "limits.will-not-come-between"
        ElseIf aiIndex == 3
            Return "limits.will-not-stay-for-cruelty"
        ElseIf aiIndex == 4
            Return "limits.will-not-be-owned"
        ElseIf aiIndex == 5
            Return "limits.will-not-compete-for-a-place"
        EndIf
    EndIf
    Return ""
EndFunction

Int Function BioKeyIndex(Int aiCat, String asKey) Global
    { The key's place in BioCatKey, or -1. }
    Int i = 0
    While i < 6
        String k = BioCatKey(aiCat, i)
        If k == ""
            Return -1
        ElseIf k == asKey
            Return i
        EndIf
        i += 1
    EndWhile
    Return -1
EndFunction

Int Function BioLimitBits(String asCsv) Global
    Int bits = 0
    If asCsv == "" || asCsv == "-"
        Return 0
    EndIf
    String[] keys = StringUtil.Split(asCsv, ",")
    Int i = 0
    While i < keys.Length
        Int at = BioKeyIndex(3, keys[i])
        If at >= 0
            bits = Math.LogicalOr(bits, Math.LeftShift(1, at))
        EndIf
        i += 1
    EndWhile
    Return bits
EndFunction

String Function BioLimitKeys(Int aiBits) Global
    String csv = ""
    Int i = 0
    While i < 6
        If Math.LogicalAnd(aiBits, Math.LeftShift(1, i)) != 0
            If csv != ""
                csv += ","
            EndIf
            csv += BioCatKey(3, i)
        EndIf
        i += 1
    EndWhile
    Return csv
EndFunction

String Function BioRecGet(Actor akActor, Int aiCat) Global
    { What we applied in this category, as keys: "" none, "-" the player took
      ours off, otherwise a key (Limits: comma-separated keys). }
    Int v = StorageUtil.GetIntValue(akActor, "SNRom_BioOurs_" + aiCat, 0)
    If v == 0
        Return ""
    ElseIf v < 0
        Return "-"
    ElseIf aiCat == 3
        Return BioLimitKeys(v)
    EndIf
    Return BioCatKey(aiCat, v - 1)
EndFunction

Function BioRecSet(Actor akActor, Int aiCat, String asKeys) Global
    { Records asKeys (as BioRecGet returns them) as what we applied. }
    Int v = 0
    If asKeys == "-"
        v = -1
    ElseIf asKeys != ""
        If aiCat == 3
            v = BioLimitBits(asKeys)
        Else
            v = BioKeyIndex(aiCat, asKeys) + 1
        EndIf
    EndIf
    If v == 0
        StorageUtil.UnsetIntValue(akActor, "SNRom_BioOurs_" + aiCat)
    Else
        StorageUtil.SetIntValue(akActor, "SNRom_BioOurs_" + aiCat, v)
    EndIf
EndFunction

Function MarkBioOurs(Actor akActor, Int aiCat, String asKey)
    { DEV TOOL, for the web API (execute-quest-script-function, arguments: a
      hex FormID, the category 0-3, a key). Records asKey as a block we
      applied, when the person carries it. Written to recover the records the
      text-based first build lost on reload; harmless otherwise. Limits add to
      what is already recorded. }
    If akActor == None || _bioApi != 1
        Return
    EndIf
    If !SNRom_SABio.IsApplied(akActor, asKey)
        Diag(LOG_WARN(), "MarkBioOurs: " + akActor.GetDisplayName() + " does not carry '" + asKey + "' - not recorded")
        Return
    EndIf
    String rec = asKey
    If aiCat == 3
        String had = BioRecGet(akActor, 3)
        If had != "" && had != "-" && StringUtil.Find("," + had + ",", "," + asKey + ",") < 0
            rec = had + "," + asKey
        ElseIf had != "" && had != "-"
            rec = had
        EndIf
    EndIf
    BioRecSet(akActor, aiCat, rec)
    Diag(LOG_INFO(), "MarkBioOurs: " + akActor.GetDisplayName() + " " + BioCatName(aiCat) + " recorded as ours: '" + rec + "'")
EndFunction




Bool Function BioPlayerHolds(Actor akActor, Int aiCat)
    { True when the player's own choice sits in this category, so the field
      it answers is theirs: drift does not move it. }
    If akActor == None || !SeverActionsPresent() || _dashNatives < 8
        Return False
    EndIf
    Int[] plan = SNRom_Native.BioPlan(akActor, SNRom_SABio.AssignedTitles(akActor), BioState(akActor, 0, -1))
    If !plan || plan.Length < 13
        Return False
    EndIf
    Return Math.LogicalAnd(plan[5], Math.LeftShift(1, aiCat)) != 0
EndFunction



Int Function SyncOurBlocks(Actor akActor, String asLimitPicks, String asWhy)
    { Puts our blocks where they belong, and only there. Returns how many
      blocks it applied or took off.

      asLimitPicks: "?" leaves Limits alone (drift, repair, load - nothing has
      chosen limits); otherwise the authoring call's picks, "" for none.

      Per category: empty and never ours -> the matching block. Ours alone ->
      swapped when the character moved. The player's, or taken off by the
      player -> left alone. Children get none of ours. Decided natively
      (SNRom_Native.BioPlan). }
    If akActor == None || !BioAssignOn() || !IsEnrolled(akActor)
        Return 0
    EndIf
    Int picks = -1
    If asLimitPicks != "?"
        picks = BioLimitBits(asLimitPicks)
    EndIf
    Return BioRun(akActor, SNRom_SABio.AssignedTitles(akActor), BIO_SYNC(), picks, asWhy)
EndFunction





Function LiftOurBlocks(Actor akActor)
    { Before a re-author: take off the blocks that are ours alone, so they do
      not steer the rewrite. The authoring prompt reads every Relationships
      block as the player's direct answer, which outranks everything; ours are
      only our previous guess. The player's stay, and still win.

      Limits we lift are remembered in SNRom_BioLiftedLimits, so a re-author
      that fails, or answers without picking limits, puts them back. }
    If akActor == None || _bioApi != 1
        Return
    EndIf
    BioRun(akActor, SNRom_SABio.AssignedTitles(akActor), BIO_LIFT(), -1, "re-author")
EndFunction

Function SyncAfterAuthoring(Actor akActor, String asLimitPicks)
    { After any authoring outcome - success, archetype fallback, or "already
      authored". Limits come from the response when it picked them, else from
      what a re-author lifted. }
    If akActor == None
        Return
    EndIf
    String picks = asLimitPicks
    String lifted = BioLimitKeys(StorageUtil.GetIntValue(akActor, "SNRom_BioLiftedLimits", 0))
    If picks == "?" && lifted != ""
        picks = lifted
    EndIf
    StorageUtil.UnsetIntValue(akActor, "SNRom_BioLiftedLimits")
    SyncOurBlocks(akActor, picks, "after authoring")
EndFunction

Function BioBlocksOnLoad()
    { Every game load. Offers both libraries (new text reaches players this
      way), then walks the roster once:

        - the player's own blocks set their traits (they are applied whenever
          the player likes, so authoring alone is not enough);
        - our blocks fill empty categories from the current character (the
          one-time backfill, and everyone enrolled since), with no model call,
          and leave Limits alone: nothing has chosen them;
        - a block of ours the player took off is recorded as theirs.

      ONE CALL INTO SEVERACTIONS AND ONE INTO THE DLL PER PERSON. Until 2.1's
      native BioPlan this was Papyrus string handling, about 250 small calls a
      person and 25-35 s of background Papyrus a load for 130 people with
      nothing to change. }
    _bioApi = 0
    If !SeverActionsPresent()
        Return
    EndIf
    If _dashNatives < 8
        Diag(LOG_WARN(), "Bio blocks need SkyrimNetRelationships.dll from 2.1 (natives v8; this one reports v" + \
            _dashNatives + ") - not offered or applied.")
        Return
    EndIf
    If SNRom_SABio.Version() < 1
        Diag(LOG_INFO(), "SeverActions is older than 4.0.1 (no Bio Blocks API) - our bio blocks are not offered or applied.")
        Return
    EndIf
    _bioApi = 1
    Int defined = SNRom_SABio.DefineAll()
    Diag(LOG_INFO(), "Bio blocks: SeverActions accepted " + defined + " of 81 (any missing were deleted by the player, which is final).")

    _bioWalkPending = False
    If !BioStoreLooksLoaded()
        _bioWalkPending = True
        Diag(LOG_WARN(), "Bio blocks: SeverActions reports no blocks on anyone we applied blocks to - its save " + \
            "data may not be loaded yet. Not checking the roster now; trying again at the next housekeeping.")
        Return
    EndIf

    Int count = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int changed = 0
    Int i = 0
    While i < count
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None && !a.IsDead() && IsEnrolled(a)
            changed += BioRun(a, SNRom_SABio.AssignedTitles(a), Math.LogicalOr(BIO_ENFORCE(), BIO_SYNC()), -1, "on load")
        EndIf
        i += 1
    EndWhile
    Diag(LOG_INFO(), "Bio blocks: checked " + count + " enrolled, applied or took off " + changed + " of ours" + \
        BioAssignWord() + ".")
EndFunction

Int Function BIO_ENFORCE() Global
    Return 8
EndFunction
Int Function BIO_SYNC() Global
    Return 16
EndFunction
Int Function BIO_LIFT() Global
    Return 32
EndFunction

Int[] Function BioState(Actor akActor, Int aiMode, Int aiLimitPicks)
    { One person's stored values, for SNRom_Native.BioPlan (layout in
      native/src/BioPlan.h): orientation, its basis, ardor, exclusivity, the
      four records, marriage, flags, Limits picks. }
    Int[] s = new Int[11]
    s[0] = StorageUtil.GetIntValue(akActor, "SNRom_Orientation", 3)
    s[1] = StorageUtil.GetIntValue(akActor, "SNRom_OrientationKnown", 0)
    s[2] = StorageUtil.GetIntValue(akActor, "SNRom_Ardor", 2)
    s[3] = StorageUtil.GetIntValue(akActor, "SNRom_Exclusivity", 50)
    s[4] = StorageUtil.GetIntValue(akActor, "SNRom_BioOurs_0", 0)
    s[5] = StorageUtil.GetIntValue(akActor, "SNRom_BioOurs_1", 0)
    s[6] = StorageUtil.GetIntValue(akActor, "SNRom_BioOurs_2", 0)
    s[7] = StorageUtil.GetIntValue(akActor, "SNRom_BioOurs_3", 0)
    ; Only an enforcement can use it, and asking MARAS costs calls.
    If Math.LogicalAnd(aiMode, BIO_ENFORCE()) != 0 && IsMarriedToPlayer(akActor)
        s[8] = 1
    EndIf
    Int flags = aiMode
    If _bioApi == 1
        flags = Math.LogicalOr(flags, 1)
    EndIf
    If BioAssignOn()
        flags = Math.LogicalOr(flags, 2)
    EndIf
    If IsEnrolled(akActor)
        flags = Math.LogicalOr(flags, 4)
    EndIf
    s[9] = flags
    s[10] = aiLimitPicks
    Return s
EndFunction

Int Function BioRun(Actor akActor, String[] akTitles, Int aiMode, Int aiLimitPicks, String asWhy)
    { Asks the DLL what to do about one person's blocks, and does it: writes
      the traits the player's blocks set, applies and takes off our blocks,
      and records what is ours. Returns how many blocks it applied or took off.
      Writes and SeverActions calls happen only for what changes. }
    If akActor == None || _dashNatives < 8
        Return 0
    EndIf
    Int[] p = SNRom_Native.BioPlan(akActor, akTitles, BioState(akActor, aiMode, aiLimitPicks))
    If !p || p.Length < 13
        Return 0
    EndIf
    String who = akActor.GetDisplayName()

    ; ---- the traits the player's own blocks set ----
    If p[0] >= 0
        StorageUtil.SetIntValue(akActor, "SNRom_Orientation", p[0])
        StorageUtil.SetIntValue(akActor, "SNRom_OrientationKnown", p[1])
        Diag(LOG_INFO(), "BLOCK OVERRIDE for " + who + ": orientation -> " + p[0] + " / STATED, from their own Drawn To block.")
    EndIf
    If p[2] >= 0
        StorageUtil.SetIntValue(akActor, "SNRom_Ardor", p[2])
        Diag(LOG_INFO(), "BLOCK OVERRIDE for " + who + ": ardor -> " + SNRom_Decorators.ArdorWord(p[2]) + \
            ", from their own Expression block.")
    EndIf
    If p[3] >= 0
        StorageUtil.SetIntValue(akActor, "SNRom_Exclusivity", p[3])
        Diag(LOG_INFO(), "BLOCK OVERRIDE for " + who + ": exclusivity -> " + p[3] + ", from their own Attachment block.")
    EndIf

    ; ---- notes ----
    Int notes = p[10]
    Int cat = 0
    While cat < 4
        If Math.LogicalAnd(notes, Math.LeftShift(1, cat)) != 0
            Diag(LOG_INFO(), who + ": the " + BioCatName(cat) + \
                " block we applied was taken off. That category is the player's now; we will not apply one there again.")
        EndIf
        If cat < 3 && Math.LogicalAnd(notes, Math.LeftShift(1, 4 + cat)) != 0
            Diag(LOG_WARN(), who + "'s " + BioCatName(cat) + " blocks are not one of the library's answers, or two " + \
                "disagree - that trait is left as authored.")
        EndIf
        cat += 1
    EndWhile
    If Math.LogicalAnd(notes, 256) != 0
        Diag(LOG_WARN(), "Drawn To block NOT applied to " + who + \
            " - the game records a marriage to the player, which the block contradicts. Fix the block.")
    EndIf

    ; ---- before the records change, for the log ----
    String[] before = new String[4]
    cat = 0
    While cat < 4
        before[cat] = BioRecGet(akActor, cat)
        cat += 1
    EndWhile

    ; ---- the blocks ----
    Int[] refused = new Int[4]   ; per category: bits of keys SeverActions refused
    Int n = p[12]
    Int done = 0
    Int i = 0
    While i < n && 13 + i * 3 + 2 < p.Length
        Int op = p[13 + i * 3]
        Int c = p[14 + i * 3]
        Int k = p[15 + i * 3]
        String bkey = BioCatKey(c, k)
        If op == 1
            If SNRom_SABio.Apply(akActor, bkey)
                done += 1
            Else
                refused[c] = Math.LogicalOr(refused[c], Math.LeftShift(1, k))
                Diag(LOG_WARN(), "SeverActions refused block '" + bkey + "' for " + who + \
                    " - most likely the player deleted it from the library, which is final.")
            EndIf
        ElseIf op == 2
            SNRom_SABio.Unapply(akActor, bkey)
            done += 1
        EndIf
        i += 1
    EndWhile

    ; ---- what is ours now ----
    cat = 0
    While cat < 4
        Int rec = p[6 + cat]
        If rec != -999
            If rec > 0 && refused[cat] != 0
                If cat == 3
                    rec = Math.LogicalAnd(rec, Math.LogicalNot(refused[cat]))
                ElseIf Math.LogicalAnd(refused[cat], Math.LeftShift(1, rec - 1)) != 0
                    rec = 0
                EndIf
            EndIf
            If rec == 0
                StorageUtil.UnsetIntValue(akActor, "SNRom_BioOurs_" + cat)
            Else
                StorageUtil.SetIntValue(akActor, "SNRom_BioOurs_" + cat, rec)
            EndIf
            String after = BioRecGet(akActor, cat)
            If after != before[cat] && after != "-"
                Diag(LOG_INFO(), "BIO BLOCKS (" + asWhy + ") " + who + " " + BioCatName(cat) + \
                    ": '" + before[cat] + "' -> '" + after + "'")
            EndIf
        EndIf
        ; Which categories hold a block, for the bond prompt (get_romance).
        If Math.LogicalAnd(p[4], Math.LeftShift(1, cat)) != 0
            StorageUtil.SetIntValue(akActor, "SNRom_BioHas_" + cat, 1)
        Else
            StorageUtil.UnsetIntValue(akActor, "SNRom_BioHas_" + cat)
        EndIf
        cat += 1
    EndWhile

    If Math.LogicalAnd(aiMode, BIO_LIFT()) != 0
        If p[11] > 0
            StorageUtil.SetIntValue(akActor, "SNRom_BioLiftedLimits", p[11])
        Else
            StorageUtil.UnsetIntValue(akActor, "SNRom_BioLiftedLimits")
        EndIf
    EndIf
    Return done
EndFunction

Bool _bioWalkPending = False

Bool Function BioStoreLooksLoaded()
    { NEVER JUDGE FROM AN EMPTY STORE. If SeverActions' per-save assignments
      were not loaded yet, every block we applied would look taken off, and
      BioNoticeRemoval would mark each of those categories "-": the player's,
      for good. Permanent damage from a timing fault.

      Measured 2026-10-05, it does not happen: SeverActions loads its library
      at game start and restores the assignments from the co-save during the
      load itself (11:30:35), well before OnPlayerLoadGame reaches us
      (11:33:12). The minute SeverActions takes to settle is its own scripts,
      which the Bio Blocks API does not wait on. This guard is for the day
      that changes.

      True unless someone we recorded blocks for carries none at all, and
      nobody we recorded blocks for carries any. Stops at the first person
      with any block, so it usually costs one call. }
    Int count = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int recorded = 0
    Int i = 0
    While i < count
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        If a != None && BioHasRecord(a)
            recorded += 1
            String[] titles = SNRom_SABio.AssignedTitles(a)
            If titles && titles.Length > 0
                Return True
            EndIf
        EndIf
        i += 1
    EndWhile
    Return recorded == 0
EndFunction

Bool Function BioHasRecord(Actor akActor)
    Int cat = 0
    While cat < 4
        String rec = BioRecGet(akActor, cat)
        If rec != "" && rec != "-"
            Return True
        EndIf
        cat += 1
    EndWhile
    Return False
EndFunction

String Function BioAssignWord()
    If BioAssignOn()
        Return ""
    EndIf
    Return " (Assign Relationships Bio Blocks is off, so only the player's blocks were read)"
EndFunction





Function ApplyArchetype(Actor akActor)
    { The fallback when authoring fails: the character fields keep their
      defaults, and SNRom_DispositionAuthored 2 marks the actor for a real
      authoring at the next chance (AuthorDisposition retries 2).

      1.x wrote two archetype preferences into Romantasy here. From 2.0 there
      is nothing to write - which also fixes what the marker did to someone
      ALREADY authored: a failed re-author set them to 2, "archetype", when
      their authored character was intact. Only someone never authored is
      marked now. }
    ; SAY SO IF A PERSON IS STANDING THERE WAITING. Reaching the fallback means
    ; the LLM call failed, echoed the wrong actor, or came back truncated - all
    ; of which are invisible from inside the game, and all of which leave the
    ; player believing a repair happened. Their old character is still intact in
    ; that case, which is the part worth telling them.
    AnnounceAuthored(akActor, akActor.GetDisplayName() + " could not be re-authored - the read failed. Their character is unchanged; try again.")
    If StorageUtil.GetIntValue(akActor, "SNRom_DispositionAuthored", 0) == 0
        StorageUtil.SetIntValue(akActor, "SNRom_DispositionAuthored", 2)     ; 2 = archetype
        Diag(LOG_INFO(), "Archetype disposition applied to " + akActor.GetDisplayName())
    Else
        Diag(LOG_INFO(), "Authoring failed for " + akActor.GetDisplayName() + \
            " - their existing character is kept")
    EndIf
    ; Blocks from the character as it stands, and any limits a re-author
    ; lifted go back on.
    SyncAfterAuthoring(akActor, "?")
EndFunction

Function LogDisposition(String asName, Int aiSuccess, String asRaw, String asOutcome)
    String row = "{\"npc\":\"" + Escape(asName) + "\"" + \
        ",\"gd\":" + Utility.GetCurrentGameTime() + \
        ",\"success\":" + aiSuccess + \
        ",\"outcome\":\"" + asOutcome + "\"" + \
        ",\"raw\":\"" + SNRom_Decorators.JsonEscape(asRaw) + "\"}"
    WriteLog("dispositions.jsonl", "Data/SKSE/Plugins/SkyrimNet Relationships/logs/dispositions.jsonl", row + NL())
EndFunction

; ===========================================================================
; Diagnostic: isolates SendCustomPromptToLLM mechanism from prompt content.
; snrom_test.prompt is one line with no template variables. If this returns
; text but the disposition prompt does not, the fault is in the prompt or its
; context JSON, not in the call path.
; ===========================================================================
; ===========================================================================
; Diagnostic: does plugin config reach Papyrus AT ALL?
;
; Every default here is a SENTINEL that cannot occur in settings.yaml. That is
; the entire point. Passing a default equal to the configured value proves
; nothing - "awardMaxPoints clamps at 75" was read as proof the key arrived,
; when the code default was ALSO 75 and the two are indistinguishable. The
; only key whose config value differs from its code default is llmVariant, and
; that one demonstrably returns the default.
;
; If you see the sentinels, the manifest is decorative and every GetConfig*
; call in this script is silently taking its default branch.
; ===========================================================================
Function TestConfig()
    Diag(LOG_ERROR(), "CFG str  llmVariant='" + SkyrimNetApi.GetConfigString(CFG(), "llmVariant", "SENTINEL") + "' (settings.yaml: sever_background)")
    Diag(LOG_ERROR(), "CFG int  awardMaxPoints=" + SkyrimNetApi.GetConfigInt(CFG(), "awardMaxPoints", -999) + " (settings.yaml: 75)")
    Diag(LOG_ERROR(), "CFG int  logFlushEvery=" + SkyrimNetApi.GetConfigInt(CFG(), "logFlushEvery", -999) + " (settings.yaml: 25)")
    Diag(LOG_ERROR(), "CFG bool enrollmentOrganic=" + SkyrimNetApi.GetConfigBool(CFG(), "enrollmentOrganic", False) + " (settings.yaml: true)")
EndFunction

; The TestPrompt / TestPromptWithCtx / TestRender diagnostics that debugged
; the section-marker bug were removed once it was confirmed fixed (2026-07-27).
; If SendCustomPromptToLLM ever "returns empty" again: read SkyrimNet.log
; FIRST - "Messages array is empty" means a prompt is missing its
; [ system ]/[ user ] markers, and no variant or provider theory is worth an
; hour until that line has been ruled out. TestConfig above is kept
; deliberately: it is the only probe that can tell "config arrived" from
; "default taken", and it costs nothing.
