Scriptname SNRom_Bridge extends Quest
{ SkyrimNet <-> Romantasy bridge.

  Romantasy owns points, tiers, persistence and UI. This script owns
  everything SkyrimNet needs to read or move that state, plus the disposition
  store the LLM authors into.

  Design notes worth keeping in view:
   - Romantasy snapshots its follower roster AND every follower's preference
     config at load. Points remain live. See CommitConfig() below.
   - Romantasy fires exactly one ModEvent per point change, so the handlers
     here see EVERY movement including Romantasy's own passive awards. That
     is the only way to build a complete ledger.
   - OnLevelChanged carries the new level but NOT the delta, so both handlers
     diff GetPoints() against a cached value rather than trusting numArg. }

; ---------------------------------------------------------------------------
; State
;
; DELIBERATELY ZERO PROPERTIES. Nothing here is ever set in the Creation Kit -
; ROM_RomanceLevel is resolved at runtime from CS_Romantasy.esp, and the rest
; are constants. Declaring them as properties gave CK a property list to
; enumerate when saving the quest, for no benefit. A script with no properties
; is the least CK has to chew on, and there is nothing for a user to leave
; unfilled.
; ---------------------------------------------------------------------------
Faction  _romanceLevel
Int      _seq
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

      NEVER CALL THIS ON A TRANSFER. EnforceLoverCeiling claws back the overflow
      above 2499 and banks it; AcceptRomance returns the banked amount in full.
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

    ; Register FIRST, unconditionally. If Romantasy is missing the decorators
    ; must still exist, or every prompt referencing them errors out instead of
    ; rendering "not enrolled". Degrade quietly, never disappear.
    RegisterDecorators()
    RegisterEvents()

    _romanceLevel = ResolveRomanceFaction()
    If _romanceLevel == None
        _ready = False
        Diag(LOG_ERROR(), "ROM_RomanceLevel unresolved - CS_Romantasy.esp missing, or GetFormFromFile failed on an ESL. Integration inert.")
        Return
    EndIf

    _ready = True
    ; ROMANTASY API LEVEL, read ONCE per session and cached.
    ;
    ; Papyrus cannot test whether a native exists. Against Romantasy 1.01 this
    ; call is unregistered, logs a Papyrus error and returns 0 - and 0 < 3 is
    ; exactly the answer we want, so the gate bootstraps itself. But every call
    ; to a missing native writes to Papyrus.0.log, so it must not be per-award.
    ;
    ; Held in StorageUtil rather than a script variable because CommitConfig and
    ; the preference writer are Global and cannot see script state.
    StorageUtil.SetIntValue(None, "SNRom_RomApi", Romantasy.GetApiVersion())
    Diag(LOG_INFO(), "Romantasy API level " + RomApi() + " (3+ enables live enrollment and preference removal; Romantasy 1.1.0 reports 4)")
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
    Diag(LOG_INFO(), "Bridge ready. ROM_RomanceLevel resolved. Assessing every " + \
        AssessIntervalHours() + "h, housekeeping every " + SparkIntervalHours() + "h.")
    ; Catch up immediately rather than waiting a game hour or two. This is the
    ; path that finds followers SeverActions never announces.
    SweepFollowers()
EndFunction

Faction Function ResolveRomanceFaction() Global
    { CS_Romantasy.esp is ESL-flagged. GetFormFromFile takes the plugin-local
      FormID (0x800) and SKSE is expected to handle the ESL indirection.

      If this proves unreliable in practice, the fallback is a Faction
      PROPERTY filled in the Creation Kit - which costs us CS_Romantasy.esp
      as a hard master, but is completely deterministic. Do not replace this
      with a scan over the FE range; that is 4096 GetForm calls on every load
      to avoid one master. }
    Return Game.GetFormFromFile(0x00000800, "CS_Romantasy.esp") as Faction
EndFunction

Function RegisterEvents()
    RegisterForModEvent("Romantasy_OnLevelChanged", "OnRomLevelChanged")
    RegisterForModEvent("Romantasy_OnPreference", "OnRomPreference")
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
    Int a = SkyrimNetApi.RegisterDecorator("romance_is_enrolled", "SNRom_Decorators", "IsEnrolled")
    Int b = SkyrimNetApi.RegisterDecorator("romance_can_begin",   "SNRom_Decorators", "CanBegin")
    Int c = SkyrimNetApi.RegisterDecorator("romance_physical_ok", "SNRom_Decorators", "PhysicalOk")
    Int e = SkyrimNetApi.RegisterDecorator("get_romance",         "SNRom_Decorators", "GetRomance")
    Diag(LOG_INFO(), "RegisterDecorator rc: is_enrolled=" + a + " can_begin=" + b + \
        " physical_ok=" + c + " get_romance=" + e)
EndFunction

; ===========================================================================
; The one line that changes when Romantasy ships RefreshFollower
; ===========================================================================

; ===========================================================================
; OffsetToStatName lives HERE, not beside LabelToOffset in SNRom_Decorators,
; and the reason is not organisational.
;
; Papyrus interns strings CASE-INSENSITIVELY, first spelling wins. The label
; whitelist in SNRom_Decorators stores "ANIMALS KILLED"; putting "Animals
; Killed" in that same script folded it onto the uppercase form, and the
; compiled pex returned "ANIMALS KILLED" for forty-eight of the fifty-eight
; names. Only the ten shorthand-differing ones survived intact - proven by
; grepping the pex, which is the only place this is visible at all.
;
; This script holds none of those uppercase literals, so the canonical names
; survive compilation. Verify after ANY edit here: the pex must contain
; "Animals Killed" in title case.
; ===========================================================================

String Function OffsetToStatName(Int aiOffset) Global
    { Maps a ROM_ preference faction's plugin-local FormID to the statistic NAME
      Romantasy.SetPreference expects. GENERATED from CS_Romantasy.esp, from each
      FACT record's FULL field, so it cannot drift from the records themselves.

      THIS IS NOT _labelmap.inc REVERSED, and that is the whole reason it exists.
      Ten of our prompt-facing labels are shorthands that are NOT the statistic
      name: CIVIL WAR COMPLETED is really "Civil War Quests Completed", COMPANIONS
      COMPLETED is "The Companions Quests Completed". That never mattered while a
      FormID was the identity and the label only had to be unique among labels.
      SetPreference matches on the NAME, so reusing the label would fail for
      exactly those ten and no others - ten silent rejections out of fifty-eight,
      which would read like a model fault for weeks.

      Returns "" for anything unmapped; callers must treat that as do-not-write. }
    If aiOffset == 0x801
        Return "Locations Discovered"
    ElseIf aiOffset == 0x802
        Return "Dungeons Cleared"
    ElseIf aiOffset == 0x803
        Return "Days Passed"
    ElseIf aiOffset == 0x804
        Return "Standing Stones Found"
    ElseIf aiOffset == 0x805
        Return "Chests Looted"
    ElseIf aiOffset == 0x806
        Return "Skill Increases"
    ElseIf aiOffset == 0x807
        Return "Skill Books Read"
    ElseIf aiOffset == 0x808
        Return "Barters"
    ElseIf aiOffset == 0x809
        Return "Persuasions"
    ElseIf aiOffset == 0x80A
        Return "Bribes"
    ElseIf aiOffset == 0x80B
        Return "Intimidations"
    ElseIf aiOffset == 0x80C
        Return "Diseases Contracted"
    ElseIf aiOffset == 0x80D
        Return "Days as a Vampire"
    ElseIf aiOffset == 0x80E
        Return "Days as a Werewolf"
    ElseIf aiOffset == 0x80F
        Return "Necks Bitten"
    ElseIf aiOffset == 0x810
        Return "Vampirism Cures"
    ElseIf aiOffset == 0x811
        Return "Werewolf Transformations"
    ElseIf aiOffset == 0x812
        Return "Mauls"
    ElseIf aiOffset == 0x813
        Return "Quests Completed"
    ElseIf aiOffset == 0x814
        Return "Misc Objectives Completed"
    ElseIf aiOffset == 0x815
        Return "Main Quests Completed"
    ElseIf aiOffset == 0x816
        Return "Side Quests Completed"
    ElseIf aiOffset == 0x817
        Return "The Companions Quests Completed"
    ElseIf aiOffset == 0x818
        Return "College of Winterhold Quests Completed"
    ElseIf aiOffset == 0x819
        Return "Thieves' Guild Quests Completed"
    ElseIf aiOffset == 0x81A
        Return "The Dark Brotherhood Quests Completed"
    ElseIf aiOffset == 0x81B
        Return "Civil War Quests Completed"
    ElseIf aiOffset == 0x81C
        Return "Daedric Quests Completed"
    ElseIf aiOffset == 0x81D
        Return "Dawnguard Quests Completed"
    ElseIf aiOffset == 0x81E
        Return "Dragonborn Quests Completed"
    ElseIf aiOffset == 0x81F
        Return "Questlines Completed"
    ElseIf aiOffset == 0x820
        Return "People Killed"
    ElseIf aiOffset == 0x821
        Return "Animals Killed"
    ElseIf aiOffset == 0x822
        Return "Creatures Killed"
    ElseIf aiOffset == 0x823
        Return "Undead Killed"
    ElseIf aiOffset == 0x824
        Return "Daedra Killed"
    ElseIf aiOffset == 0x825
        Return "Automatons Killed"
    ElseIf aiOffset == 0x826
        Return "Critical Strikes"
    ElseIf aiOffset == 0x827
        Return "Sneak Attacks"
    ElseIf aiOffset == 0x828
        Return "Backstabs"
    ElseIf aiOffset == 0x829
        Return "Weapons Disarmed"
    ElseIf aiOffset == 0x82A
        Return "Bunnies Slaughtered"
    ElseIf aiOffset == 0x82B
        Return "Spells Learned"
    ElseIf aiOffset == 0x82C
        Return "Dragon Souls Collected"
    ElseIf aiOffset == 0x82D
        Return "Shouts Learned"
    ElseIf aiOffset == 0x82E
        Return "Souls Trapped"
    ElseIf aiOffset == 0x82F
        Return "Magic Items Made"
    ElseIf aiOffset == 0x830
        Return "Weapons Made"
    ElseIf aiOffset == 0x831
        Return "Armor Made"
    ElseIf aiOffset == 0x832
        Return "Potions Mixed"
    ElseIf aiOffset == 0x833
        Return "Poisons Mixed"
    ElseIf aiOffset == 0x834
        Return "Locks Picked"
    ElseIf aiOffset == 0x835
        Return "Pockets Picked"
    ElseIf aiOffset == 0x836
        Return "Items Stolen"
    ElseIf aiOffset == 0x837
        Return "Assaults"
    ElseIf aiOffset == 0x838
        Return "Murders"
    ElseIf aiOffset == 0x839
        Return "Horses Stolen"
    ElseIf aiOffset == 0x83A
        Return "Trespasses"
    EndIf
    Return ""
EndFunction

Int Function HeldPreferenceCount(Actor akActor) Global
    { How many preference factions this actor holds, of ANY kind. Walks the same
      contiguous 0x801-0x83A range CountHighFrequencyHeld and ClearDisposition
      use, so there is one enumeration of that range to be wrong about.

      Faction reads rather than GetPreference on purpose: this has to answer on
      Romantasy 1.01 too, where there is no read API and factions are all there
      is. }
    If akActor == None
        Return 0
    EndIf
    Int held = 0
    Int off = 0x801
    While off <= 0x83A
        Faction f = Game.GetFormFromFile(off, "CS_Romantasy.esp") as Faction
        If f != None && akActor.GetFactionRank(f) >= 0
            held += 1
        EndIf
        off += 1
    EndWhile
    Return held
EndFunction

Bool Function PreferencesAreForeign(Actor akActor) Global
    { True when this actor already holds preferences THIS MOD did not write.

      WE DO NOT OVERWRITE ANOTHER AUTHOR'S WORK. A custom-follower framework can
      register its NPCs into Romantasy at runtime and give them the likes and
      dislikes their author wrote by hand - Troth does exactly this. Those
      preferences are part of the character somebody designed, and they arrive
      through the same faction ranks ours do, so nothing distinguishes them at
      the data level. Whoever writes last would win, and after API 3 that is us,
      with ClearPreferences.

      Neither existing guard covers this. IsPreferencesManual only catches a
      player who sealed them in Romantasy's editor. Romantasy's own
      author-defined rejection only covers followers slaved through plugin
      records - a runtime AddToFaction produces an `external` follower, the same
      class as ours, which is provably writable: every SetPreference we made for
      Silana Petreia succeeded on 2026-08-21.

      So the rule is FIRST WRITER KEEPS IT, decided by evidence rather than by
      load order. Ours is anything we have authored; everything else is somebody
      else's. }
    If akActor == None
        Return False
    EndIf
    ; STICKY, and it has to be. The detection site also sets
    ; SNRom_DispositionAuthored so we stop pestering the LLM about someone we are
    ; never going to write - but that flag is what the ours/theirs test below
    ; reads, so without this line the guard would protect them exactly once and
    ; then classify them as ours forever. Found before shipping, by asking what
    ; the SECOND authoring attempt would do.
    ; NO SNRom_ForceAuthor CHECK HERE, and it is worth saying why so nobody adds
    ; one. AuthorDisposition CONSUMES that flag when it dispatches, long before
    ; the LLM answers, and this function runs in the callback - so the flag is
    ; always gone by the time we could read it. A check on it would look like an
    ; ownership override and do nothing at all.
    ;
    ; Preserving SNRom_DispositionAuthored across a re-author is what actually
    ; solves that, and ClearDisposition is the escape hatch for an actor marked
    ; foreign by mistake.
    If StorageUtil.GetIntValue(akActor, "SNRom_PrefsForeign", 0) == 1
        Return True
    EndIf
    ; ANY non-zero means WE wrote them. 1 is LLM-authored, 2 is the archetype
    ; fallback - ApplyArchetype writes preferences directly and marks them 2.
    ; Testing == 1 would have classified every archetype follower as somebody
    ; else's work, marked them sticky, and silently stopped us ever authoring
    ; them. Caught by reading ApplyArchetype rather than assuming the flag was
    ; a boolean.
    If StorageUtil.GetIntValue(akActor, "SNRom_DispositionAuthored", 0) > 0
        Return False
    EndIf
    Return HeldPreferenceCount(akActor) > 0
EndFunction

Int Function RomApi() Global
    { Romantasy's API level, 0 if it predates GetApiVersion. Cached at bootstrap;
      see the note there for why it is not read on demand.

      THE API LEVEL AND THE NEXUS VERSION ARE DIFFERENT NUMBERS, and nothing in
      either mod states the mapping. Romantasy 1.1.0 on Nexus reports level 4.
      The private builds this was developed against reported 3, which is why an
      earlier comment here said "3 = 1.1.0" - wrong, and it shipped that way in
      1.0.0. The gate tests >= 3 because 3 is the level that introduced the
      calls; 4 satisfies it. Anything below 3 is 1.01 or earlier, where
      enrollment needs a reload and preferences cannot be removed. }
    Return StorageUtil.GetIntValue(None, "SNRom_RomApi", 0)
EndFunction

Bool Function CommitConfig(Actor akActor) Global
    { Makes faction-level configuration (roster membership, preference ranks)
      visible to Romantasy WITHOUT a reload.

      Romantasy 1.01 has no such call - it reads faction tags once at load,
      because its documented integration path is static plugin records edited
      in the Creation Kit. Confirmed empirically: AddToFaction at runtime is
      written to the save but ignored until the next load, for both the
      ROM_RomanceLevel marker and preference factions.

      ColdSun has agreed to add a refresh entry point (expected <= 2026-07-29).
      When it lands, this becomes a single delegating line:

          Return Romantasy.RefreshFollower(akActor)

      Everything downstream keys off the return value, so nothing else needs
      to change:
        True  - config is live now
        False - config written, effective next load; caller should notify the
                player and fall back to interim scoring.

      API 3 GIVES US THE CALL, and it is not the RefreshFollower above. It is
      ClearPreferences, which synchronously locates or discovers the actor,
      mutates its factions, refreshes its cached preferences and returns. It
      does not wait for RefreshLoadedFollowers, which only runs on dashboard
      sync, a tracked-stat event or the debug point operation. AutoEnroll adds
      them to ROM_RomanceLevel immediately before calling this, which satisfies
      the documented precondition.

      A new enrollee has no preferences, so the clear is a no-op on data and
      exists only to force that discovery. }
    If RomApi() < 3
        Return False
    EndIf
    If PreferencesAreForeign(akActor)
        ; SOMEBODY ELSE AUTHORED THESE. ClearPreferences is our discovery
        ; mechanism, but an actor who already holds preferences is by definition
        ; already known to Romantasy - somebody set them - so there is nothing to
        ; discover and everything to lose. Report not-live; passive discovery
        ; reaches them on its own schedule.
        Return False
    EndIf
    If Romantasy.IsPreferencesManual(akActor)
        ; THE PLAYER OWNS THIS ONE'S PREFERENCES, and ClearPreferences is the
        ; only call we have that forces discovery. Destroying their editing to
        ; make a log line read True is the wrong trade - report not-live and let
        ; Romantasy's passive discovery reach them on its own schedule.
        ; No Diag here - this function is Global and Diag is a member. The
        ; caller logs the live/not-live outcome; this comment is the record of
        ; WHY it came back false for a player-managed follower.
        Return False
    EndIf
    If Romantasy.ClearPreferences(akActor)
        Return True
    EndIf
    ; THE CLEAR CAN BE REFUSED WITHOUT ANYTHING BEING WRONG. Romantasy rejects it
    ; for a follower it considers author-defined, and that says nothing about
    ; whether the follower is live - Endarie was mirrored to ROM_RomanceLevel and
    ; refused a clear 56ms later, on 2026-08-21. Reporting not-live there made the
    ; log claim the reload caveat was back.
    ;
    ; So ask the question that actually matters: does Romantasy have a level for
    ; them? That is the same test CanBegin uses for "already enrolled".
    Return Romantasy.GetLevel(akActor) > 0
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

    akActor.AddToFaction(_romanceLevel)
    akActor.SetFactionRank(_romanceLevel, 0)

    Bool live = CommitConfig(akActor)
    If StorageUtil.GetIntValue(akActor, "SNRom_ClearRefused", 0) == 1
        StorageUtil.UnsetIntValue(akActor, "SNRom_ClearRefused")
        Diag(LOG_WARN(), "Romantasy refused the preference clear for " + akActor.GetDisplayName() + " - it considers them author-defined. Enrollment itself is live=" + live + "; their preferences belong to whoever authored them.")
    EndIf
    StorageUtil.SetIntValue(akActor, "SNRom_Enrolled", 1)
    StorageUtil.SetFloatValue(akActor, "SNRom_EnrolledAt", Utility.GetCurrentGameTime())
    ; BeginSpark IS the spark - this is what puts her on the romantic ladder in
    ; 0330_romantasy_bond rather than the platonic one. Once followers
    ; auto-enroll, enrollment alone will stop meaning anything about romance
    ; and this flag becomes the only thing that does.
    StorageUtil.SetIntValue(akActor, "SNRom_Sparked", 1)
    ; Roster membership is what ResolveFromBase matches against, so an NPC
    ; enrolled through BeginSpark rather than AutoEnroll must be on it too -
    ; otherwise her passive scoring falls back to the fragile name lookup.
    StorageUtil.FormListAdd(None, "SNRom_Roster", akActor, False)

    ; Authored beats land immediately regardless of the load-time constraint,
    ; so the bond is never sitting at a bare zero after a real moment.
    MarkSelfAward(akActor)
    Romantasy.ModifyPoints(akActor, ScaleAward(25), asReason, False)

    SkyrimNetApi.RegisterPersistentEvent( \
        akActor.GetDisplayName() + " and " + Game.GetPlayer().GetDisplayName() + \
        " have reached an understanding neither has named. " + asReason, akActor, Game.GetPlayer())

    Ledger(akActor, "enroll", "", 25, 1, asReason)

    ; The distinctive Phase 3 beat: enrollment is what makes a person's likes
    ; and dislikes matter, so enrollment is what authors them. Async - the
    ; callback lands whenever the LLM answers; nothing here waits on it.
    AuthorDisposition(akActor)

    If !live
        Diag(LOG_INFO(), "Enrolled " + akActor.GetDisplayName() + \
            " - dashboard and passive scoring active after next load.")
    EndIf
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
      enrollment, and the enrollment debounce now absorbs even that. }
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
    ; Enrollment is PERMANENT and there is no clean undo short of UnenrollActor,
    ; which cannot reach Romantasy's own preference copy - that is restored from
    ; its snapshot on the next load. So an accidental follower is close to a
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
        Diag(LOG_INFO(), "Noticed " + akActor.GetDisplayName() + \
            " following - enrollment held until they are still here in " + \
            SkyrimNetApi.GetConfigFloat(CFG(), "enrollmentDelayHours", 2.0) + " game hours")
        Return
    EndIf
    If (now - firstSeen) < (SkyrimNetApi.GetConfigFloat(CFG(), "enrollmentDelayHours", 2.0) / 24.0)
        Return                                  ; still serving the waiting period
    EndIf

    akActor.AddToFaction(_romanceLevel)
    akActor.SetFactionRank(_romanceLevel, 0)
    Bool live = CommitConfig(akActor)
    If StorageUtil.GetIntValue(akActor, "SNRom_ClearRefused", 0) == 1
        StorageUtil.UnsetIntValue(akActor, "SNRom_ClearRefused")
        Diag(LOG_WARN(), "Romantasy refused the preference clear for " + akActor.GetDisplayName() + " - it considers them author-defined. Enrollment itself is live=" + live + "; their preferences belong to whoever authored them.")
    EndIf

    StorageUtil.SetIntValue(akActor, "SNRom_Enrolled", 1)
    ; THE flag that keeps IsSparked honest. Faction membership used to imply a
    ; deliberate act; once anyone who signs on is enrolled it implies nothing,
    ; and this is what tells the platonic/romantic split which is which.
    StorageUtil.SetIntValue(akActor, "SNRom_AutoEnrolled", 1)
    StorageUtil.SetFloatValue(akActor, "SNRom_EnrolledAt", Utility.GetCurrentGameTime())

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
    Diag(LOG_INFO(), "Auto-enrolled " + akActor.GetDisplayName() + " at Stranger/0" + \
        " (platonic until sparked)" + " - Romantasy scoring live: " + live)

    AuthorDisposition(akActor)
EndFunction

Function MarkMoment(Actor akActor, Int aiMagnitude, String asReason, String asActivity)
    { RomanceMarkMoment. The workhorse: an authored beat, optionally routed
      through her own like/dislike config so one event helps, hurts, or does
      nothing depending on who she is. }
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
    If aiMagnitude == 0
        Diag(LOG_ERROR(), "MarkMoment for " + akActor.GetDisplayName() + \
            " arrived with magnitude 0 - the model parameter did not parse as " + \
            "a number, so the payload was damaged in transit. No points and no " + \
            "ledger row. The reason it sent was: " + asReason)
        Return
    EndIf

    Int cap = SkyrimNetApi.GetConfigInt(CFG(), "awardMaxPoints", 75)
    Int clamped   = ClampAward(aiMagnitude, asActivity, cap)
    Int magnitude = ScaleAward(clamped)

    ; Armed once for the whole award. Whichever branch below fires - preference
    ; routing or a flat award - it is still one point change and one echoed
    ; event, and only one of them can happen.
    MarkSelfAward(akActor)
    Bool routed = False
    If asActivity != ""
        ; ApplyPreference multiplies by the stat's weight and returns False if
        ; she has no LOADED opinion - which includes preferences we authored
        ; this session that Romantasy cannot see yet.
        routed = Romantasy.ApplyPreference(akActor, asActivity, magnitude, True)
    EndIf

    Bool landed = routed
    If !routed
        landed = Romantasy.ModifyPoints(akActor, magnitude, asReason, True)
    EndIf

    ; -- A REFUSED AWARD MUST NOT LEAVE A LEDGER ROW -------------------------
    ; The return value used to be discarded and the row written unconditionally,
    ; so when Romantasy declined, this function awarded nothing, said nothing, and
    ; then wrote the points into the journal anyway. The player reads that journal.
    ;
    ; The talk path has always handled this - "Award LOST, no ledger row written" -
    ; so this was an inconsistency between the two award routes rather than an
    ; oversight in the design.
    ;
    ; THE COMMON TRIGGER IS DISMISSAL, not anything exotic. Romantasy only adjusts
    ; points for someone actively following, so an authored beat for a companion
    ; waiting at home is refused outright:
    ;
    ;   Romantasy skipped <reason> point adjustment for Jordis the Sword-Maiden;
    ;   follower is not actively following
    ;
    ; Measured 2026-08-28. It is silent on our side and always was.
    If !landed
        Diag(LOG_ERROR(), "Romantasy refused " + magnitude + " pts for " + \
            akActor.GetDisplayName() + " - it only adjusts points for someone " + \
            "actively following, so a dismissed or waiting companion is declined. " + \
            "Award LOST, no ledger row written.")
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
    If clamped != aiMagnitude
        moved = " (model asked " + aiMagnitude + ", capped at " + cap + ")"
    EndIf
    If magnitude != clamped
        moved = moved + " -> " + magnitude + " applied (Bond Pace: " + \
            SkyrimNetApi.GetConfigString(CFG(), "bondPace", "Normal") + ")"
    EndIf
    String route = "flat"
    If routed
        route = "routed through " + asActivity
    EndIf
    Diag(LOG_INFO(), "Moment for " + akActor.GetDisplayName() + ": " + \
        clamped + " pts" + moved + " [" + route + "] - " + asReason)

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
            (Romantasy.GetLevel(akActor) - 1) + " with points intact. Spark window reset to now; " + \
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

      THE ORDERING IS WHAT MAKES THIS WORK, and it was already right: Ledger
      calls CheckRomanceQuestion BEFORE EnforceLoverCeiling. So an award to 2100
      is seen at 2100, the question is flagged, and only then is the overflow
      banked down to this ceiling. Reverse them and the question could never
      fire, because she would never be observed above 1999. }
    Return LOVER_MIN() - 1
EndFunction
Function EnforceLoverCeiling(Actor akActor)
    { Hold an UNANSWERED romance just below Lover, banking the overflow.

      BANKED, NOT DISCARDED. The points were earned and the player watched them
      accrue; deleting them to enforce a gate would be the one direction that
      is hard to justify. They come back in full the moment the answer is yes,
      so saying yes to someone who has been waiting a long time lands where the
      relationship actually is rather than making her climb again.

      Only bites while SPARKED and UNANSWERED. A platonic bond has no gate to
      pass and should reach Spouse-tier depth freely - two people can be that
      close without romance, which is the two-track design. A married NPC is
      seeded ACCEPTED from the ceremony and never reaches here. }
    If akActor == None || !_ready
        Return
    EndIf
    If StorageUtil.GetIntValue(akActor, "SNRom_PlayerStance", 0) != STANCE_UNANSWERED()
        Return
    EndIf
    If !SNRom_Decorators.IsSparked(akActor)
        Return
    EndIf
    Int over = Romantasy.GetPoints(akActor) - UNANSWERED_MAX()
    If over <= 0
        Return
    EndIf
    ; No Ledger call on this path. Ledger is what CALLS us, and logging the
    ; clawback through it would recurse. The Diag line is the record.
    MarkSelfAward(akActor)
    ; NOT ScaleAward: this is a TRANSFER. It banks the overflow for AcceptRomance
    ; to hand back in full, and scaling one side of a round trip destroys points.
    If Romantasy.ModifyPoints(akActor, -over, "Held short of Lover pending an answer", True)
        Int banked = StorageUtil.GetIntValue(akActor, "SNRom_BankedPoints", 0) + over
        StorageUtil.SetIntValue(akActor, "SNRom_BankedPoints", banked)
        Diag(LOG_INFO(), "Held " + akActor.GetDisplayName() + " just below Lover - " + over + \
            " pts banked (" + banked + " total) until the question is answered. She keeps what she earned.")
    Else
        Diag(LOG_ERROR(), "ModifyPoints refused the Lover ceiling for " + akActor.GetDisplayName() + \
            " - she is past " + UNANSWERED_MAX() + " with the question still unanswered")
    EndIf
EndFunction

Function AcceptRomance(Actor akActor)
    { The player says yes. Only this opens tier 4+ as a realized romance. }
    SetStance(akActor, STANCE_ACCEPTED(), "accepted")
    If akActor == None || !_ready
        Return
    EndIf
    ; Release whatever the ceiling held back. Doing this AFTER the stance write
    ; matters: EnforceLoverCeiling reads the stance, so releasing first would
    ; be clawed straight back on the next point change.
    Int banked = StorageUtil.GetIntValue(akActor, "SNRom_BankedPoints", 0)
    If banked <= 0
        Return
    EndIf
    StorageUtil.UnsetIntValue(akActor, "SNRom_BankedPoints")
    MarkSelfAward(akActor)
    ; NOT ScaleAward: the other half of the ceiling round trip. The player watched
    ; these accrue and was promised them back, whole.
    If Romantasy.ModifyPoints(akActor, banked, "What was held while the question waited", True)
        Ledger(akActor, "unbank", "", banked, 1, "Released on acceptance")
        Diag(LOG_INFO(), "Released " + banked + " banked pts to " + akActor.GetDisplayName() + \
            " on acceptance -> " + Romantasy.GetPoints(akActor) + " pts, tier " + \
            (Romantasy.GetLevel(akActor) - 1) + ". The waiting cost her nothing.")
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
      ReopenRomance can make the question live again - people reconsider.

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
    Int had = Romantasy.GetPoints(akActor)
    Int drop = FRIEND_MID() - had
    If drop >= 0
        Diag(LOG_INFO(), who + " was turned down at " + had + " pts - already at or below " + \
            FRIEND_MID() + ", so depth is unchanged.")
        Return
    EndIf
    MarkSelfAward(akActor)
    If Romantasy.ModifyPoints(akActor, ScaleAward(drop), "Turned down", True)
        Ledger(akActor, "declined", "", drop, 1, "Turned down")
        Diag(LOG_INFO(), "Turned down " + who + ": " + had + " -> " + Romantasy.GetPoints(akActor) + \
            " pts, tier " + (Romantasy.GetLevel(akActor) - 1) + ". She keeps the spark and everything " + \
            "she believes; what she loses is the closeness that got her to the question.")
    Else
        Diag(LOG_ERROR(), "ModifyPoints refused the decline setback for " + who + " - stance is set but depth is unchanged")
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
        " (tier " + (Romantasy.GetLevel(akActor) - 1) + ", sparked=" + \
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

    Int had = Romantasy.GetPoints(akActor)
    Int drop = ENDED_CAP() - had
    If drop < 0
        MarkSelfAward(akActor)
        If Romantasy.ModifyPoints(akActor, ScaleAward(drop), asReason, True)
            Ledger(akActor, "end", "", drop, 1, asReason)
            Diag(LOG_INFO(), "Romance ended for " + who + ": " + had + " -> " + \
                Romantasy.GetPoints(akActor) + " pts, tier " + (Romantasy.GetLevel(akActor) - 1) + \
                " (" + Romantasy.GetLevelName(akActor) + "). Back on the platonic ladder; " + \
                "romance can be judged again after the tenure gate. " + asReason)
        Else
            Diag(LOG_ERROR(), "Romance ended for " + who + " but Romantasy REJECTED the " + \
                drop + " pt cap - the ladder reverted, the tier did not.")
        EndIf
    Else
        Diag(LOG_INFO(), "Romance ended for " + who + " at " + had + " pts - already at or below " + \
            ENDED_CAP() + ", so depth is unchanged. Back on the platonic ladder. " + asReason)
    EndIf
EndFunction

; ===========================================================================
; Award clamping
; ===========================================================================

Int Function ClampAward(Int aiMagnitude, String asActivity, Int aiCap) Global
    { ApplyPreference multiplies magnitude by the stat's weight, so a
      magnitude of 5 on a weight-20 stat is 100 points - past any sane cap.
      Clamp on the PRODUCT, not the raw magnitude. This lives in Papyrus and
      not in an action description precisely because the model cannot ignore
      it here. }
    Int weight = StatWeight(asActivity)
    Int maxMag = aiCap
    If weight > 1
        maxMag = aiCap / weight
        If maxMag < 1
            maxMag = 1
        EndIf
    EndIf
    If aiMagnitude > maxMag
        Return maxMag
    ElseIf aiMagnitude < -maxMag
        Return -maxMag
    EndIf
    Return aiMagnitude
EndFunction

Int Function StatWeight(String asActivity) Global
    { Romantasy's fixed per-activity weights. Ours must match exactly, or a
      cleared dungeon changes value across the reload handoff and pacing
      visibly shifts. Default 1 covers the large weight-1 majority. }
    If asActivity == ""
        Return 1
    EndIf
    String a = asActivity
    If a == "ROM_QuestlinesCompleted" || a == "Questlines Completed"
        Return 20
    ElseIf StringUtil.Find(a, "Completed") > -1 && StringUtil.Find(a, "Quests") < 0 && StringUtil.Find(a, "Objectives") < 0
        Return 10   ; guild questlines: Companions, College, Thieves, DB, CivilWar, Daedric, Dawnguard, Dragonborn
    ElseIf a == "ROM_Murders" || a == "Murders" || a == "ROM_WerewolfTransformations" || a == "Werewolf Transformations"
        Return 5
    ElseIf a == "ROM_MainQuestsCompleted" || a == "Main Quests Completed" || a == "ROM_SideQuestsCompleted" || a == "Side Quests Completed"
        Return 5
    ElseIf a == "ROM_QuestsCompleted" || a == "Quests Completed" || a == "ROM_MiscObjectivesCompleted" || a == "Misc Objectives Completed"
        Return 3
    ElseIf a == "ROM_LocationsDiscovered" || a == "ROM_DungeonsCleared" || a == "ROM_StandingStonesFound" \
        || a == "ROM_DaysPassed" || a == "ROM_SkillIncreases" || a == "ROM_SpellsLearned" \
        || a == "ROM_ShoutsLearned" || a == "ROM_DragonSoulsCollected" || a == "ROM_Assaults" \
        || a == "ROM_HorsesStolen" || a == "ROM_Trespasses" || a == "ROM_DaysVampire" \
        || a == "ROM_NecksBitten" || a == "ROM_VampirismCures" || a == "ROM_DaysWerewolf" || a == "ROM_Mauls"
        Return 2
    EndIf
    Return 1
EndFunction

; ===========================================================================
; ModEvent handlers - the complete-ledger path
; ===========================================================================

Event OnRomLevelChanged(String eventName, String strArg, Float numArg, Form sender)
    HandleRomEvent(sender, "", numArg as Int, True)
EndEvent

Event OnRomPreference(String eventName, String strArg, Float numArg, Form sender)
    HandleRomEvent(sender, strArg, numArg as Int, False)
EndEvent

Function HandleRomEvent(Form akSender, String asStat, Int aiNumArg, Bool abTierChange)
    { sender is the base NPC (ActorBase), not a reference, so resolve by name.
      OnLevelChanged gives the new level but no delta - hence the GetPoints
      diff, which yields an exact figure whichever event fired. }
    If !_ready || akSender == None
        Return
    EndIf
    ActorBase base = akSender as ActorBase
    If base == None
        Return
    EndIf
    Actor who = ResolveFromBase(base)
    If who != None
        ; Second self-heal. If she resolved only via the name fallback she is
        ; not on the roster yet; adding her now means the next event resolves
        ; by form, which keeps working when she is unloaded and the name
        ; lookup cannot.
        StorageUtil.FormListAdd(None, "SNRom_Roster", who, False)
    EndIf
    If who == None
        ; Was a silent Return. An unresolvable sender means every passive point
        ; Romantasy awards that NPC vanishes, and the ledger simply shows a
        ; follower who never adventures.
        Diag(LOG_WARN(), "Unresolved Romantasy event for base '" + base.GetName() + \
            "' - passive scoring for this NPC is being dropped")
        Return
    EndIf

    Int now = Romantasy.GetPoints(who)
    Int was = StorageUtil.GetIntValue(who, "SNRom_LastPoints", 0)
    Int delta = now - was
    StorageUtil.SetIntValue(who, "SNRom_LastPoints", now)

    If delta == 0
        Return
    EndIf

    ; Awards we originated are already logged by their own call sites.
    If StorageUtil.GetIntValue(who, "SNRom_SelfAward", 0) == 1
        StorageUtil.SetIntValue(who, "SNRom_SelfAward", 0)
        Return
    EndIf

    Ledger(who, "passive", asStat, delta, 1, "")

    If abTierChange
        Diag(LOG_INFO(), who.GetDisplayName() + " crossed a tier (level " + aiNumArg + ", " + now + " pts)")
    EndIf
EndFunction

; ===========================================================================
; Decorators (JSON out, consumed by prompts and eligibility rules)
; ===========================================================================


; ===========================================================================
; Helpers
; ===========================================================================

Bool Function IsEnrolled(Actor akActor)
    Return akActor != None && Romantasy.GetLevel(akActor) > 0
EndFunction

Actor Function ResolveFromBase(ActorBase akBase)
    { Romantasy's ModEvents carry the ActorBase, not a reference, and the
      obvious resolution - FindActorByName(base.GetName()) - is WRONG for
      anyone whose display name differs from their base name.

      Nicollette is the case that exposed it. Born through Fertility Mode
      Reloaded, her ActorBase is still named "Player's Nord Mage Daughter"
      while the reference displays as "Nicollette" - which is also why
      Romantasy's own UI shows her that way. The name lookup found nothing,
      HandleRomEvent returned silently, and every passive point she earned
      was discarded. She would have looked like a follower who simply never
      adventures.

      Matching the roster by ActorBase is name-independent and exact, so it
      survives renames, titles, and any mod that builds an actor from a
      generic base. The name lookup stays as a fallback for NPCs Romantasy
      tracks that we never enrolled. }
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

Function MarkSelfAward(Actor akActor)
    { Call IMMEDIATELY before any Romantasy award we originate.

      Romantasy echoes every point change back as a ModEvent, so an award we
      made arrives at HandleRomEvent looking exactly like Romantasy's own
      passive scoring. That handler checks this flag to tell them apart - but
      until 2026-07-29 NOTHING ever set it to 1. The flag was read, and the
      only write was the reset to 0, so every authored beat was logged TWICE:
      once by its own call site and once as a "passive" row. analyze_romance.py
      splits contribution by channel, so the balance analysis has been
      reporting adventuring points that never happened.

      A tier crossing can fire two events for one award. That is safe: the
      first consumes the flag and updates SNRom_LastPoints, so the second sees
      delta == 0 and returns before reaching this check.

      Residual, accepted: if an award resolves to zero points no event fires
      and the flag stays armed, swallowing the next genuine passive row. Far
      smaller than the bug it replaces. }
    StorageUtil.SetIntValue(akActor, "SNRom_SelfAward", 1)
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
      a single step, and the obvious hook is already dead. HandleRomEvent
      returns on the SelfAward flag BEFORE reaching its abTierChange branch, so
      "crossed a tier" appears zero times in a log where Jordis sat at 2011
      points. Anything built on that edge would silently never fire.

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
    If Romantasy.GetPoints(akActor) < LOVER_MIN()
        Return
    EndIf

    StorageUtil.SetIntValue(akActor, "SNRom_AskPending", 1)
    ; Zero rather than now, so the sweep raises it at the first opportunity
    ; instead of serving a retry interval before anyone has been asked once.
    StorageUtil.SetFloatValue(akActor, "SNRom_LastAskAttempt", 0.0)
    Diag(LOG_INFO(), "Question owed to " + akActor.GetDisplayName() + " at " + \
        Romantasy.GetPoints(akActor) + " pts (tier " + (Romantasy.GetLevel(akActor) - 1) + \
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
    ; Immediately after, and for the same reason: Ledger is the one place every
    ; point change passes through, so it is the only hook that cannot be missed
    ; when a new award path is added.
    EnforceLoverCeiling(akActor)

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

    If SkyrimNetApi.GetConfigBool(CFG(), "logLedgerEnabled", True) == False
        Return
    EndIf
    Int tier = Romantasy.GetLevel(akActor) - 1
    String row = "{\"gd\":" + Utility.GetCurrentGameTime() + \
        ",\"npc\":\"" + Escape(akActor.GetDisplayName()) + "\"" + \
        ",\"ch\":\"" + asChannel + "\"" + \
        ",\"act\":\"" + asActivity + "\"" + \
        ",\"d\":" + aiDelta + ",\"n\":" + aiCount + \
        ",\"tot\":" + Romantasy.GetPoints(akActor) + \
        ",\"ta\":" + tier + \
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
    MiscUtil.WriteToFile(LedgerPath(), blob, True, False)
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

Function Diag(Int aiLevel, String asText)
    { Every line carries its own sequence number and game time.

      MiscUtil.WriteToFile does NOT guarantee ordering - entries arrive in
      blocks, grouped by call site rather than chronologically, and recent
      writes can lag behind by minutes. Reading position in the file as
      "when it happened" is wrong, and reading absence as "it did not run" is
      worse. Self-stamping every line is the only way to reconstruct order. }
    Int configured = SkyrimNetApi.GetConfigInt(CFG(), "logLevel", 3)
    If aiLevel > configured
        Return
    EndIf
    _seq += 1
    String line = "[" + _seq + "] gd=" + Utility.GetCurrentGameTime() + " L" + aiLevel + " " + asText
    MiscUtil.WriteToFile(DiagPath(), line + NL(), True, False)
    If SkyrimNetApi.GetConfigBool(CFG(), "logNotifications", False)
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
Int    _lastApplied     ; newly-applied count from the most recent ApplyPreferenceList

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


String Function StoreFile() Global
    { Flat filename, no subfolder. JsonUtil accepts a path here, but whether it
      CREATES a missing directory is undocumented, and a silent write failure is
      the one outcome this whole store exists to avoid. }
    Return "SNRom_Dispositions"
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

String Function StoreGetText(Actor akActor, String asField) Global
    { Falls back to the old StorageUtil location so NPCs authored before this
      change keep working for the rest of the current session. Their value is
      still lost on the next load - nothing can recover a string the co-save
      never kept - but they degrade to blank rather than breaking. }
    If akActor == None
        Return ""
    EndIf
    String v = JsonUtil.GetStringValue(StoreFile(), StoreKey(akActor, asField), "")
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
    { Wipes every authored preference and character field back to unset.

      Needed because preferences ACCUMULATE - ApplyPreferenceList never
      overwrites, which is right for protecting an established opinion but
      means a bad authoring run cannot be undone by re-running. Jordis ended
      up holding 34 likes from one truncated response; no amount of
      re-authoring removes them.

      The ROM_ preference factions are contiguous 0x801-0x83A (58 records),
      verified against LabelToOffset, so this walks the range rather than
      duplicating the whitelist. }
    If akActor == None
        Return
    EndIf
    Int off = 0x801
    Int removed = 0
    While off <= 0x83A
        Faction f = Game.GetFormFromFile(off, "CS_Romantasy.esp") as Faction
        If f != None && akActor.GetFactionRank(f) >= 0
            akActor.RemoveFromFaction(f)
            removed += 1
        EndIf
        off += 1
    EndWhile
    StorageUtil.UnsetIntValue(akActor, "SNRom_Orientation")
    StorageUtil.UnsetIntValue(akActor, "SNRom_OrientationKnown")
    StorageUtil.UnsetIntValue(akActor, "SNRom_PhysMinTier")
    StorageUtil.UnsetIntValue(akActor, "SNRom_PhysAttrBypass")
    StorageUtil.UnsetIntValue(akActor, "SNRom_Ardor")
    StorageUtil.UnsetIntValue(akActor, "SNRom_Exclusivity")
    StorageUtil.SetIntValue(akActor, "SNRom_DispositionAuthored", 0)
    ; A deliberate reset really resets - otherwise an actor mistakenly marked as
    ; somebody else's could never be re-adopted without editing the co-save.
    StorageUtil.UnsetIntValue(akActor, "SNRom_PrefsForeign")
    Diag(LOG_INFO(), "Cleared disposition for " + akActor.GetDisplayName() + \
        " - removed " + removed + " preference factions, character fields unset")
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
    Int shown = 0
    String out = ""
    Bool more = True

    ; Selection sort, five passes over a roster of ~20. Papyrus has no sort and
    ; no break, so each pass scans for the best remaining candidate and the loop
    ; is guarded rather than exited. Cheap enough at this size, and it runs once
    ; per authoring.
    While shown < 5 && more
        Actor best = None
        Float bestRank = -1.0
        Int i = 0
        While i < n
            Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
            ; Only someone actually authored. An unauthored NPC carries nothing
            ; but mapper defaults, and listing those differentiates against a
            ; fiction.
            If a != None && a != akExclude && \
               StorageUtil.GetIntValue(a, "SNRom_DispositionAuthored", 0) == 1 && \
               !AlreadyPicked(picked, shown, a)
                ; Rank = when they last traveled with the player, with current
                ; followers lifted above every former one. Game time is days
                ; since game start and will not approach the offset in any
                ; playthrough, so the two bands cannot overlap.
                Float rank = StorageUtil.GetFloatValue(a, "SNRom_LastFollowingAt", 0.0)
                If IsFollowing(a)
                    rank += 1000000.0
                EndIf
                If rank > bestRank
                    bestRank = rank
                    best = a
                EndIf
            EndIf
            i += 1
        EndWhile
        If best == None
            more = False
        Else
            picked[shown] = best
            If out != ""
                out += "   "
            EndIf
            out += "- " + best.GetDisplayName() + ": " + \
                SNRom_Decorators.IntimacyWordFromTier( \
                    StorageUtil.GetIntValue(best, "SNRom_PhysMinTier", 4)) + \
                ", " + SNRom_Decorators.ArdorWord( \
                    StorageUtil.GetIntValue(best, "SNRom_Ardor", 2)) + \
                ", exclusivity " + StorageUtil.GetIntValue(best, "SNRom_Exclusivity", 50)
            shown += 1
        EndIf
    EndWhile
    Return out
EndFunction

Bool Function AlreadyPicked(Actor[] akPicked, Int aiCount, Actor akActor)
    { Selection-sort bookkeeping for BuildCircle. }
    Int i = 0
    While i < aiCount
        If akPicked[i] == akActor
            Return True
        EndIf
        i += 1
    EndWhile
    Return False
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

      HONEST ABOUT WHAT THIS CANNOT DO. Romantasy keeps its own persistent
      per-follower preference set and restores it on load, so the ROM_ faction
      memberships come back however thoroughly we remove them - proved by the
      Jordis double-clear test. This does NOT return an NPC to pristine.

      What it DOES do is stop us ever acting on them again: off the roster, so
      neither assessor can enumerate them and BuildCircle cannot cite them;
      SNRom_Enrolled cleared, so AutoEnroll treats them as new; and the debounce
      stamp cleared, so re-adding them deliberately still serves the full
      waiting period rather than enrolling instantly on the old stamp.

      Their leftover Romantasy preferences are inert while they are not
      following, because Romantasy only awards points to active followers. }
    If akActor == None
        Return
    EndIf
    String who = akActor.GetDisplayName()
    StorageUtil.FormListRemove(None, "SNRom_Roster", akActor, True)
    StorageUtil.UnsetIntValue(akActor, "SNRom_Enrolled")
    StorageUtil.UnsetIntValue(akActor, "SNRom_AutoEnrolled")
    StorageUtil.UnsetFloatValue(akActor, "SNRom_FirstSeenFollowing")
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
    Diag(LOG_INFO(), "Un-enrolled " + who + " - off the roster, no longer assessed. " + \
        "Romantasy preference factions remain (it restores its own copy on load) " + \
        "but are inert while they are not following. Roster now " + \
        StorageUtil.FormListCount(None, "SNRom_Roster"))
EndFunction

Function ReauthorCharacter(Actor akActor)
    { Re-author the CHARACTER BLOCK ONLY - orientation, intimacy, ardor,
      exclusivity, WHY, LIMIT, ADDRESS - leaving preferences exactly as they are.

      Dispatch by hand with execute-quest-script-function, questEditorId
      SNRom_Quest, scriptName SNRom_Bridge, functionName ReauthorCharacter, one
      hex FormID argument.

      USE THIS, NOT ReauthorDisposition, for anyone who already has a preference
      list you are happy with. ReauthorDisposition permanently ADDS preferences
      on every run and they cannot be removed across a reload, so repeatedly
      re-authoring an established NPC degrades her by inflating what she cares
      about until nothing stands out.

      The flag is per-actor rather than a script variable because authoring
      QUEUES - PumpAuthoringQueue holds one pending slot and others wait, so a
      single Bool would be read by whichever response came back next. }
    If akActor == None
        Return
    EndIf
    StorageUtil.SetIntValue(akActor, "SNRom_CharOnly", 1)
    Diag(LOG_INFO(), "Re-authoring CHARACTER ONLY for " + akActor.GetDisplayName() + \
        " - preferences will not be touched")
    ReauthorDisposition(akActor)
EndFunction

Function RepairPreferences(Actor akActor)
    { THE REPAIR FOR ROMANTASY 1.1.0's AUTHOR-DEFINED BUG. One argument, so it
      dispatches from the dashboard.

      1.1.0 classified every runtime-enrolled follower as author-defined and
      refused all preference writes. This mod handled that correctly - it stopped
      writing rather than fighting - and latched SNRom_PrefsForeign so it would
      never overwrite preferences it had decided belonged to someone else. That
      latch is deliberately sticky: first writer keeps it.

      The problem is that it OUTLIVES the bug. Updating to 1.1.1 fixes Romantasy,
      but our own flag is still set, so ReauthorDisposition keeps declining and
      the follower stays permanently preference-less. Reported by two users
      2026-08-24, both enrolled under 1.1.0.

      WHY NOT JUST TELL THEM TO RUN ClearDisposition FIRST. That works - it is
      what every repair in development used - but it removes the 58 preference
      factions AND unsets orientation, intimacy, ardor and exclusivity, so the
      character is rerolled to fix the preferences. For these users the character
      authored FINE; only the preferences were refused. Throwing away the half
      that worked to repair the half that did not is the wrong trade, and asking
      a user to make two calls in the right order invites making one.

      So this clears only what actually blocks: the ownership latch and the
      refusal marker. ApplyPreferenceList never overwrites an existing opinion,
      so a follower who does hold real preferences keeps them.

      IT DOES REWRITE THE CHARACTER, and the first version of this comment
      claimed otherwise. ReauthorDisposition dispatches ONE authoring call whose
      response carries the character block and the preference lists together and
      the callback applies both - there is no preferences-only path. Measured on
      Endarie 2026-08-25: orientation BOTH -> MEN, ardor 0 -> 1, exclusivity
      100 -> 50.

      That is the right outcome HERE, because her old values were authored under
      the unanchored exclusivity scale and 100 was the bug. But it is not what
      the name promises, so it gets said plainly: repairing preferences re-rolls
      the person. ReauthorCharacter is the character-only tool.

      If they are still on 1.1.0 this will simply be refused again, the latch
      will be re-set, and the log will say so - which is the honest outcome and
      tells them the update is the actual fix. }
    If akActor == None || !_ready
        Return
    EndIf
    Int held = HeldPreferenceCount(akActor)
    Bool wasForeign = StorageUtil.GetIntValue(akActor, "SNRom_PrefsForeign", 0) == 1
    StorageUtil.UnsetIntValue(akActor, "SNRom_PrefsForeign")
    StorageUtil.UnsetIntValue(akActor, "SNRom_ClearRefused")
    Diag(LOG_INFO(), "Repairing preferences for " + akActor.GetDisplayName() + \
        " - held " + held + ", ownership latch was " + wasForeign + \
        ". Re-authoring: preferences are added, character is rewritten.")
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

      Safe to repeat: ApplyPreferenceList never overwrites an existing
      opinion, so re-authoring ADDS newly-named likes and refreshes the
      character fields without erasing anything she already believes. }
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
    AuthorDisposition(akActor)
EndFunction

Function AuthorDisposition(Actor akActor)
    If !_ready || akActor == None
        Return
    EndIf
    ; 1 = LLM-authored: never redo - her opinions are her personality now, and
    ; a re-enrollment after EndRomance must not reroll who she is.
    ; 2 = archetype fallback: DO retry - the fallback was a stopgap, and a
    ; fresh enrollment is the natural moment to upgrade it to the real thing
    ; (ApplyPreferenceList never overwrites, so the archetype picks survive).
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
    ; StoreGetText reads SNRom_Dispositions.json, a FILE - not save data, so it
    ; does not roll back. A stored WHY is durable evidence that this person was
    ; authored, whatever the save believes. Checked second because it is a
    ; string read and the Int above answers the common case.
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
    ; 0..57 inclusive: RandomInt's upper bound IS inclusive in Papyrus, and the
    ; catalogue is 58 entries, so this can name any starting position. The
    ; prompt reads it through default(cat_seed, 0), so an older .pex that does
    ; not send it renders the list unrotated instead of rendering nothing.
    Int catSeed = Utility.RandomInt(0, 57)

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

    String ctx = "{\"npc_name\":\"" + _pendingName + "\"" + \
        ",\"npc_formid\":" + akActor.GetFormID() + \
        ",\"cat_seed\":" + catSeed + \
        ",\"npc_married\":" + marriedFlag + \
        ",\"circle\":\"" + circleText + "\"" + \
        ",\"npc_bio\":\"" + b.GetRace().GetName() + ", " + \
        SNRom_Decorators.SexWord(b.GetSex()) + ", level " + akActor.GetLevel() + \
        ". Traveling companion of the Dragonborn.\"}"

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
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int i = 0
    Actor pick = None
    Float bestWait = -1.0
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        ; IsFollowing, matching every other candidate test in this script. The
        ; ratio only matters while they are with the player, and refreshing it
        ; for someone dismissed to Whiterun spends the budget on a number
        ; nothing will read.
        If a != None && !a.IsDead() && IsFollowing(a)
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
      is the correct answer for a game that only models the wedding. }
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
      contradict a recorded marriage - see the note there. }
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
    Int current = Romantasy.GetPoints(akActor)
    Int delta = target - current
    If delta <= 0
        StorageUtil.SetIntValue(akActor, "SNRom_Seeded", 1)
        Diag(LOG_INFO(), "Seeding: " + akActor.GetDisplayName() + " needs none - history justifies " + \
            target + " and they already have " + current)
        SeedRomanticFlag(akActor)
        Return True
    EndIf

    MarkSelfAward(akActor)
    ; NOT ScaleAward: seeding describes a relationship that existed before this mod
    ; was installed. A slow setting must not retroactively shrink someone's past.
    Bool applied = Romantasy.ModifyPoints(akActor, delta, "Prior history together", True)
    If !applied
        ; NOT an error, and deliberately not stamped. This is the EXPECTED path
        ; for a newly enrolled NPC and it resolves itself on the next game load.
        ; Stamping SNRom_Seeded here would mean an NPC enrolled mid-session is
        ; never seeded at all, silently.
        Diag(LOG_DEBUG(), "Seeding: Romantasy is not scoring " + akActor.GetDisplayName() + \
            " yet - will retry. This is normal until one game load after enrollment.")
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
        Romantasy.GetPoints(akActor) + " pts, tier " + (Romantasy.GetLevel(akActor) - 1) + \
        " (" + Romantasy.GetLevelName(akActor) + "). rapport=" + rapportNow + \
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

Event OnMarasStatusChanged(String asEventName, String asStatus, Float afStatusEnum, Form akSender)
    { MARAS announced a relationship change. The only one that matters here is a
      marriage: it raises the seed ceiling from 2000 to 2500, and it is the one
      fact an authored trait is never allowed to contradict.

      Re-seeds rather than topping up, because ReseedActor already clears the
      stamp and re-runs the whole computation, which will now see the marriage
      and land on Spouse. Other statuses are ignored: engagement is already read
      at seed time, and a divorce must NOT claw points back - those were earned,
      and Romantasy owns what a break-up costs. }
    Actor who = akSender as Actor
    If who == None || !_ready
        Return
    EndIf
    If SNRom_Decorators.Upper(SNRom_Decorators.Trim(asStatus)) != "MARRIED"
        Return
    EndIf
    If !IsEnrolled(who)
        Return
    EndIf
    Diag(LOG_INFO(), "MARAS reports " + who.GetDisplayName() + \
        " is now married - re-seeding so the Spouse ceiling applies." + MarasStateLine(who))
    ReseedActor(who)
EndEvent

Function ReconcileMarriages()
    { Heal a spouse who was seeded before MARAS could say they were married.
      ONE CHECK PER FOLLOWER PER SAVE LOAD.

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

      NON-FOLLOWERS ARE NEVER STAMPED, deliberately. Romantasy refuses to adjust
      points for anyone not actively following, so stamping a spouse waiting at
      home would mark them checked while doing nothing for them, and they would
      be skipped for the rest of the session once they started travelling. }
    If !_ready
        Return
    EndIf
    If SkyrimNetApi.GetConfigBool(CFG(), "seedEnabled", True) == False
        Return
    EndIf
    Int session      = StorageUtil.GetIntValue(None, "SNRom_SessionId", 0)
    Int spouseFloor  = 2500
    Int i = 0
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
        ; Cheapest test first: everyone settled this session stops here.
        If a != None && StorageUtil.GetIntValue(a, "SNRom_MarriageChecked", -1) != session
            If !a.IsDead() && IsFollowing(a)
                StorageUtil.SetIntValue(a, "SNRom_MarriageChecked", session)
                If IsMarriedToPlayer(a)
                    Int have = Romantasy.GetPoints(a)
                    If have < spouseFloor
                        MarkSelfAward(a)
                        ; NOT ScaleAward: a correction to prior history, the same
                        ; exemption seeding has. Bond Pace must not shrink a
                        ; marriage that already happened.
                        If Romantasy.ModifyPoints(a, spouseFloor - have, "Married to you", True)
                            Diag(LOG_INFO(), "Marriage reconcile: " + a.GetDisplayName() + \
                                " is married but held only " + have + " pts - raised to " + \
                                spouseFloor + "." + MarasStateLine(a))
                        Else
                            ; Unstamp so the next tick tries again - a refusal here
                            ; means they stopped following between the check above
                            ; and this call, which is a race worth retrying.
                            StorageUtil.SetIntValue(a, "SNRom_MarriageChecked", -1)
                            Diag(LOG_WARN(), "Marriage reconcile: Romantasy refused the top-up for " + \
                                a.GetDisplayName() + " - not following any more? Will retry.")
                        EndIf
                    EndIf
                EndIf
            EndIf
        EndIf
        i += 1
    EndWhile
EndFunction
Function TestProposalBlock(Actor akActor, Int aiMode)
    { DIAGNOSTIC, NOT THE FEATURE. Delete once it has answered.

      THE QUESTION: does MARAS actually gate its proposal on the
      TTM_IgnoreProposal keyword, and does it still do so for an actor MARAS has
      ALREADY registered as a candidate? The keyword is a record in TT_MARAS.esp
      and appears in none of the SKSE DLLs, so it is almost certainly read by a
      dialogue condition - which would be ideal, because conditions re-evaluate
      every time dialogue is built and a runtime toggle would bite immediately.
      That is an INFERENCE from where the string is absent. It has not been read
      out of the plugin, and this function exists so nobody builds the gate on
      top of a guess.

      MODES, because base and reference are different questions and answering
      them together would tell us nothing about which one MARAS looks at:
        1 - add to the ACTOR BASE   (what HasKeyword resolves through)
        2 - add to the REFERENCE    (leaves other instances alone)
        3 - add to both
        0 - remove from both

      HOW TO READ THE RESULT: set a mode, then talk to them. If the MARAS
      proposal option is gone, the keyword gates it and the gate is buildable.
      If it is still there, the keyword gates something earlier - candidacy
      registration, most likely - and blocking an existing candidate needs a
      different lever entirely.

      SAFETY: po3 describes AddKeywordToForm as runtime-only rather than
      persisted, so a reload should clear anything this adds. UNVERIFIED. Mode 0
      is the intended undo; a reload is the fallback, not the plan. }
    If akActor == None || !_ready
        Return
    EndIf
    Keyword kw = Keyword.GetKeyword("TTM_IgnoreProposal")
    If kw == None
        Diag(LOG_ERROR(), "TestProposalBlock: TTM_IgnoreProposal did not resolve. " + \
            "TT_MARAS.esp not loaded, or the keyword is named differently than the " + \
            "SPID ini implies.")
        Return
    EndIf
    ActorBase b   = akActor.GetActorBase()
    Bool before   = akActor.HasKeyword(kw)
    String didWhat = "none"
    If aiMode == 1
        PO3_SKSEFunctions.AddKeywordToForm(b, kw)
        didWhat = "added to base"
    ElseIf aiMode == 2
        PO3_SKSEFunctions.AddKeywordToRef(akActor, kw)
        didWhat = "added to ref"
    ElseIf aiMode == 3
        PO3_SKSEFunctions.AddKeywordToForm(b, kw)
        PO3_SKSEFunctions.AddKeywordToRef(akActor, kw)
        didWhat = "added to base and ref"
    Else
        PO3_SKSEFunctions.RemoveKeywordOnForm(b, kw)
        PO3_SKSEFunctions.RemoveKeywordFromRef(akActor, kw)
        didWhat = "removed from base and ref"
    EndIf
    Diag(LOG_INFO(), "TestProposalBlock " + akActor.GetDisplayName() + ": " + didWhat + \
        " | HasKeyword before=" + before + " after=" + akActor.HasKeyword(kw) + \
        " | points=" + Romantasy.GetPoints(akActor) + MarasStateLine(akActor))
EndFunction
Actor  _seedActor
String _seedName

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
    If _seedActor != None
        ; SAY SO. Lisbet was requested while Silana was still pending and this
        ; returned in silence, so the test looked like a failed call rather than
        ; a queue doing its job. One line is the difference.
        Diag(LOG_WARN(), "Seed assessment for " + akActor.GetDisplayName() + \
            " skipped - a read for " + _seedName + " is still pending. Ask again.")
        Return
    EndIf
    _seedActor = akActor
    _seedName  = akActor.GetDisplayName()
    String prior = "vanilla relationship rank " + akActor.GetRelationshipRank(Game.GetPlayer())
    If SeverActionsPresent()
        prior = prior + ", SeverActions rapport " + SeverActionsNative.Native_GetRapport(akActor)
    EndIf
    String ctx = "{\"npc_name\":\"" + _seedName + "\"" + \
        ",\"npc_formid\":" + akActor.GetFormID() + \
        ",\"npc_bio\":\"" + Escape(akActor.GetActorBase().GetRace().GetName()) + ", traveling companion\"" + \
        ",\"npc_prior\":\"" + Escape(prior) + "\"" + MarasContext(akActor) + "}"
    Int rc = SkyrimNetApi.SendCustomPromptToLLM("snrom_seed_assess", VariantName(), ctx, \
        Self, "SNRom_Bridge", "OnSeedAssessed")
    Diag(LOG_INFO(), "Seed assessment sent for " + _seedName + " (rc=" + rc + ")")
    If rc != 1
        _seedActor = None
    EndIf
EndFunction

Event OnSeedAssessed(String asResponse, Int aiSuccess)
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
    _seedActor = None
    If who == None || aiSuccess != 1
        Diag(LOG_WARN(), "Seed assessment for " + asked + " failed or returned nothing")
        Return
    EndIf
    String echoed = SNRom_Decorators.NameCore(SNRom_Decorators.FieldValue(asResponse, "NAME:"))
    If echoed != "" && echoed != SNRom_Decorators.NameCore(asked)
        Diag(LOG_ERROR(), "Seed echo mismatch: asked about " + asked + ", answered as " + \
            echoed + ". Discarded.")
        Return
    EndIf
    String standing = SNRom_Decorators.FieldValue(asResponse, "STANDING:")
    String because  = SNRom_Decorators.FieldValue(asResponse, "BECAUSE:")
    Int byRead = StandingToPoints(standing)
    If byRead == 0
        Diag(LOG_WARN(), "Seed read for " + asked + " returned an unreadable standing: '" + \
            standing + "'. Falling back to rank and rapport alone.")
    EndIf
    Int byOld  = SeedTarget(who)
    Int target = byRead
    If byOld > target
        target = byOld
    EndIf
    Int cap = UNANSWERED_MAX()
    If IsMarriedToPlayer(who)
        cap = 2500
    EndIf
    If target > cap
        target = cap
    EndIf
    Int held = Romantasy.GetPoints(who)
    Diag(LOG_INFO(), "Seed read for " + asked + ": " + standing + " -> " + byRead + \
        " pts (rank/rapport floor " + byOld + ", cap " + cap + ", holds " + held + \
        "). Because: " + because)
    If target <= held
        Diag(LOG_INFO(), "Seed read for " + asked + " is at or below what they hold - nothing " + \
            "added. Seeding tops up and never claws back.")
        StorageUtil.SetIntValue(who, "SNRom_Seeded", 1)
        SeedRomanticFlag(who)
        Return
    EndIf
    MarkSelfAward(who)
    ; NOT ScaleAward: prior history predates this mod, and Bond Pace has no
    ; business retroactively shrinking someone's past. Same exemption SeedActor
    ; carries for the same reason.
    If Romantasy.ModifyPoints(who, target - held, "Prior history together", True)
        StorageUtil.SetIntValue(who, "SNRom_Seeded", 1)
        SeedRomanticFlag(who)
        Diag(LOG_INFO(), "Seeded " + asked + " from the record: " + held + " -> " + \
            Romantasy.GetPoints(who) + " pts." + MarasStateLine(who))
    Else
        Diag(LOG_DEBUG(), "Romantasy is not scoring " + asked + " yet - the seed read will be " + \
            "reapplied. Normal until one game load after enrollment.")
    EndIf
EndEvent

Function TestSetPoints(Actor akActor, Int aiTarget)
    { DIAGNOSTIC. Move someone to an exact point total, up or down.

      EXISTS BECAUSE SEEDING ONLY EVER TOPS UP, which is the right rule and is
      also why a bad read cannot be undone by a better one. Silana Petreia was
      read as DEVOTED on the strength of her own hedged longing - "perhaps in
      time, I will find a way bridge the gap" - and jumped 967 -> 1999. A
      corrected read returns FRIEND and changes nothing, because 1250 is below
      what she now holds.

      So the correction has to be explicit and by hand. Not wired to anything,
      not called by any tick, and it has no business surviving into a release. }
    If akActor == None || !_ready
        Return
    EndIf
    Int held = Romantasy.GetPoints(akActor)
    Int delta = aiTarget - held
    If delta == 0
        Diag(LOG_INFO(), "TestSetPoints: " + akActor.GetDisplayName() + " already holds " + held)
        Return
    EndIf
    MarkSelfAward(akActor)
    ; NOT ScaleAward. This is a correction to a number this mod got wrong, not an
    ; earning, and Bond Pace has no business scaling an apology.
    If Romantasy.ModifyPoints(akActor, delta, "Correcting an earlier misread", True)
        Diag(LOG_INFO(), "TestSetPoints: " + akActor.GetDisplayName() + " " + held + " -> " + \
            Romantasy.GetPoints(akActor) + " pts (asked for " + aiTarget + ")")
    Else
        Diag(LOG_ERROR(), "TestSetPoints: Romantasy refused the correction for " + \
            akActor.GetDisplayName() + " - are they actively following?")
    EndIf
EndFunction

Function TestSeedAssess(Actor akActor)
    { DIAGNOSTIC ENTRY POINT, for trying the new read on chosen followers before
      it goes anywhere near the whole roster. Clears the stamp and re-reads.

      DELIBERATELY NOT WIRED INTO THE HOUSEKEEPING TICK. 63 enrolled actors is 63
      LLM calls rewriting points on a live save, and the author asked to test select
      followers first. Wiring it in is a separate decision, taken after the reads
      have been seen. }
    If akActor == None || !_ready
        Return
    EndIf
    StorageUtil.UnsetIntValue(akActor, "SNRom_Seeded")
    Diag(LOG_INFO(), "TestSeedAssess: re-reading " + akActor.GetDisplayName() + \
        " from the record (currently " + Romantasy.GetPoints(akActor) + " pts)")
    AssessSeed(akActor)
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
      zero. Anyone seeded by that build deserves the same second look. }
    If akActor == None || !_ready
        Return
    EndIf
    Int had = Romantasy.GetPoints(akActor)
    StorageUtil.UnsetIntValue(akActor, "SNRom_Seeded")
    Diag(LOG_INFO(), "Re-seeding " + akActor.GetDisplayName() + " (currently " + had + " pts)")
    SeedActor(akActor)
EndFunction

Function SeedNextActor()
    { One SETTLED seed per tick, walking the roster in order.

      Two things here are load-bearing and both are the same bug this project
      already fixed once in AssessNextTalk:

      1. IsFollowing, not just roster membership. Romantasy only scores active
         followers, so a dismissed one is rejected EVERY time - not late, never.

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
        If a != None && !a.IsDead() && StorageUtil.GetIntValue(a, "SNRom_Seeded", 0) != 1 && IsFollowing(a)
            If SeedActor(a)
                Return                          ; settled - that is this tick's budget
            EndIf
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
    ; she is stamped. Ties break on roster order, which then rotates on the
    ; next tick because the winner has just been stamped.
    Float now = Utility.GetCurrentGameTime()
    Float cooldown = SkyrimNetApi.GetConfigFloat(CFG(), "talkCooldownHours", 3.0) / 24.0
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int i = 0
    Actor pick = None
    Float pickSince = 0.0
    Float bestWait = -1.0
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
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
    ; IsFollowing, NOT IsPlayerTeammate. These have to ask the SAME question the
    ; sweep asks, and for a long time they did not: SweepFollowers used the
    ; permissive two-test IsFollowing while this used the bare vanilla flag. An
    ; NPC in CurrentFollowerFaction who does not carry IsPlayerTeammate - which
    ; is normal for SeverActions-managed companions - was therefore ENROLLED and
    ; then never assessed, forever, with nothing logged.
    ;
    ; IsFollowing's own comment warns about exactly this ("never enrolled and
    ; never scored, silently, forever") and the warning did not reach the two
    ; functions that needed it. Observed 2026-08-01: Svana followed for 24 game
    ; hours as the most-overdue candidate and was never once picked, while
    ; Nicollette - waiting and sandboxing, but still flagged a teammate - was
    ; assessed repeatedly.
    If akActor.IsDead() || !IsFollowing(akActor) || !akActor.Is3DLoaded()
        Return False
    EndIf
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
        Int held = Romantasy.GetPoints(who)
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

    ; CHECK THE RETURN. Romantasy rejects points for an actor it does not yet
    ; consider enrolled - and it snapshots its roster at LOAD, so every NPC
    ; enrolled during this session is invisible to it until the next one
    ; (CommitConfig returns False; that is what "Romantasy scoring live: False"
    ; means at enrollment). Ignoring the return meant writing a ledger row for
    ; an award that never happened.
    ;
    ; Observed 2026-08-01: Svana lost 40 and Haelga lost 350 - the first LANDMARK
    ; this project ever produced - both recorded in the ledger as if they landed,
    ; both actually discarded. The tell is `ta:-1`, i.e. GetLevel() == 0.
    ; analyze_romance.py would have reported ~390 phantom points as earned.
    MarkSelfAward(akActor)
    Bool applied = Romantasy.ModifyPoints(akActor, awarded, asWhat, True)
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
        Diag(LOG_ERROR(), "Romantasy REJECTED " + awarded + " pts for " + \
            akActor.GetDisplayName() + " (tier=" + (Romantasy.GetLevel(akActor) - 1) + \
            ") - she is enrolled in our roster but not live in Romantasy yet, which " + \
            "needs one game load after enrollment. Award LOST, no ledger row written.")
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
    { Picks ONE eligible follower and asks whether the bond has crossed.

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
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int i = 0
    Actor pick = None
    Float bestWait = -1.0
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
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
    ; IsFollowing, not IsPlayerTeammate - same fix as TalkCandidate, see the note
    ; there. A SeverActions companion who never sets the vanilla flag would
    ; otherwise be permanently unable to cross into romance, and spark fires once
    ; per NPC ever, so "never assessed" and "never able to" are the same thing.
    If akActor.IsDead() || !IsFollowing(akActor)
        Return False                            ; not currently traveling together
    EndIf

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
        Diag(LOG_INFO(), "No spark for " + asked + " (answered '" + verdict + "')")
        Return
    EndIf
    If momentText == "" || SNRom_Decorators.Upper(momentText) == "NONE"
        Diag(LOG_WARN(), "Spark claimed for " + asked + " with no moment named - discarded")
        Return
    EndIf

    ApplySpark(who, momentText)
EndEvent

Function ApplySpark(Actor akActor, String asMoment)
    { The crossing itself. Everything AutoEnroll deliberately withheld happens
      here, because now something actually has happened. }
    StorageUtil.SetIntValue(akActor, "SNRom_Sparked", 1)
    StorageUtil.SetFloatValue(akActor, "SNRom_SparkedAt", Utility.GetCurrentGameTime())

    MarkSelfAward(akActor)
    Romantasy.ModifyPoints(akActor, ScaleAward(25), asMoment, False)

    SkyrimNetApi.RegisterPersistentEvent( \
        akActor.GetDisplayName() + " and " + Game.GetPlayer().GetDisplayName() + \
        " have reached an understanding neither has named. " + asMoment, akActor, Game.GetPlayer())

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
    Int n = StorageUtil.FormListCount(None, "SNRom_Roster")
    Int i = 0
    Actor pick = None
    Float bestWait = -1.0
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNRom_Roster", i) as Actor
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
    If akActor.IsDead() || !IsFollowing(akActor) || !akActor.Is3DLoaded()
        Return False
    EndIf

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

Function AssessDrift(Actor akActor)
    { Asks the one question, about the one field whose turn it is. }
    _driftActor = akActor
    _driftName  = akActor.GetDisplayName()
    _driftPendingAt = Utility.GetCurrentRealTime()

    ; Rotate rather than pick. Choosing the field "most likely to have moved"
    ; would need a judgment this code cannot make, and would quietly bias
    ; every review toward whichever axis the last award happened to touch.
    _driftField = StorageUtil.GetIntValue(akActor, "SNRom_DriftField", 0)
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

    ; Character BEFORE the likes check, deliberately. These are independent
    ; judgments and failing one says nothing about the other.
    ;
    ; Proven the hard way: given a real profile, the model answered the likes
    ; from the bio's "Interject Summary" (fishing, Dibella, Kleppr) and every
    ; one was rejected - but in the SAME response it judged Lynea CASUAL,
    ; ardor 3, exclusivity 60, which is the most characterful read we had ever
    ; got and the first CASUAL ever produced. All of it was discarded because
    ; the early return sat above this line. Never throw away a good answer
    ; because a different answer in the same response was bad.
    ApplyCharacter(who, asResponse)

    ; --- character-only path ----------------------------------------------
    ; Updates the four gate ints plus WHY/LIMIT/ADDRESS and touches PREFERENCES
    ; NOT AT ALL - no ApplyPreferenceList, no ApplyArchetype.
    ;
    ; This exists because preference removal CANNOT SURVIVE A RELOAD. Romantasy
    ; keeps its own persistent per-follower set and restores it, so every
    ; ApplyPreferenceList only ever ADDS, permanently. Jordis reached 50
    ; preferences that way and cannot be reduced - and an NPC who likes
    ; everything likes nothing.
    ;
    ; So re-authoring to pick up a prompt improvement used to cost irreversible
    ; preference growth. Fifteen NPCs still hold orientations authored under the
    ; old MEN/WOMEN/ANY vocabulary, which answered ANY 16 times out of 17
    ; because a bare gender word was the low-effort answer. Their character
    ; blocks are worth redoing; their preference lists are not worth inflating.
    ;
    ; Also the code path the living-disposition design will need: that asks a
    ; narrow question about ONE field and must never re-run preference authoring.
    If StorageUtil.GetIntValue(who, "SNRom_CharOnly", 0) == 1
        StorageUtil.UnsetIntValue(who, "SNRom_CharOnly")
        ApplyProse(who, asResponse, asked)
        Diag(LOG_INFO(), "Character block updated for " + asked + " - preferences untouched by design")
        LogDisposition(asked, aiSuccess, asResponse, "character-only")
        Return
    EndIf

    ; --- transcription guard ----------------------------------------------
    ; DISLIKES is now the final line, so its absence means the response was
    ; cut off DURING the lists - which only happens when the model is
    ; transcribing the catalogue rather than choosing from it. The surviving
    ; LIKES are then just the head of the list in catalogue order, a
    ; positional artefact and not a judgment about anyone.
    ;
    ; The character block above it is already safely written, which is the
    ; whole point of the reordering. Only the lists are abandoned.
    String likesCsv = SNRom_Decorators.FieldValue(asResponse, "LIKES:")
    If SNRom_Decorators.FieldValue(asResponse, "DISLIKES:") == ""
        Diag(LOG_WARN(), "Lists truncated for " + asked + \
            " - character fields kept, preferences discarded as catalogue transcription")
        LogDisposition(asked, aiSuccess, asResponse, "truncated-lists")
        ApplyArchetype(who)
        Return
    EndIf

    ; Caps are enforced HERE, not trusted to the prompt. Rule 1 asks for 4-7
    ; likes; a model handed a flat 58-name list answered with 34. Prose cannot
    ; enforce a count - Papyrus can.
    ; These are RECOGNIZED counts; newLikes/newDislikes are what actually
    ; changed. Falling back on "nothing NEW applied" wrongly discarded a good
    ; response for any already-established NPC.
    ; THE PLAYER MAY HAVE TAKEN THIS ONE OVER.
    ;
    ; Romantasy API 3 carries a per-actor ownership flag its own editor sets when
    ; a player edits someone's likes and dislikes by hand. The flag covers
    ; PREFERENCES ONLY, so this skips the preference write and lets the character
    ; block through - orientation, intimacy, ardor, exclusivity, WHY and LIMIT are
    ; ours, live in our own store, and his editor never touches them. That split
    ; already exists here as ReauthorCharacter versus ReauthorDisposition.
    ;
    ; We only ever READ this flag. SetPreferencesManual is for a genuine
    ; player-facing editor, and this mod is the automated authoring the flag
    ; exists to hold off - setting it would be claiming the player's edits as
    ; our own.
    If PreferencesAreForeign(who)
        Diag(LOG_INFO(), asked + " already holds preferences this mod did not write (" +             HeldPreferenceCount(who) + " of them) - another mod or a follower author " +             "owns them. Left untouched; character fields still authored.")
        LogDisposition(asked, aiSuccess, asResponse, "foreign-preferences")
        StorageUtil.SetIntValue(who, "SNRom_PrefsForeign", 1)
        StorageUtil.SetIntValue(who, "SNRom_DispositionAuthored", 1)
        Return
    EndIf
    If RomApi() >= 3 && Romantasy.IsPreferencesManual(who)
        Diag(LOG_INFO(), asked + " is player-managed in Romantasy - preferences left alone, " +             "character fields still authored")
        LogDisposition(asked, aiSuccess, asResponse, "player-managed")
        StorageUtil.SetIntValue(who, "SNRom_DispositionAuthored", 1)
        Return
    EndIf

    _prefsRefused = False
    Int liked    = ApplyPreferenceList(who, likesCsv, 1, 7)
    Int newLikes = _lastApplied
    Int disliked = ApplyPreferenceList(who, SNRom_Decorators.FieldValue(asResponse, "DISLIKES:"), 0, 4)
    Int newDislikes = _lastApplied

    If _prefsRefused
        ; DO NOT FALL THROUGH TO THE ARCHETYPE. Its fallback writes preferences
        ; with AddToFaction/SetFactionRank - the legacy path, which Romantasy does
        ; not guard - so a refused write followed by "no valid likes" put our
        ; archetype preferences on Endarie through the back door on 2026-08-21,
        ; overriding the exact ownership the refusal was protecting. Refused means
        ; refused, by every route we have.
        LogDisposition(asked, aiSuccess, asResponse, "romantasy-refused")
        StorageUtil.SetIntValue(who, "SNRom_DispositionAuthored", 1)
        Return
    EndIf

    If liked == 0
        Diag(LOG_WARN(), "No valid likes parsed for " + asked + " - archetype fallback (character fields kept)")
        ApplyArchetype(who)
        Return
    EndIf

    StorageUtil.SetIntValue(who, "SNRom_DispositionAuthored", 1)

    ; Same rule the character fields already follow in ApplyCharacter: an ABSENT
    ; field is not an answer of "blank", it means the response did not carry one.
    ; Writing "" here erases a good earlier line, and WHY is the ONLY field
    ; BuildCircle can read - so losing it silently takes circle differentiation
    ; down with it for every NPC authored afterwards, which is exactly the
    ; symptom that read as "it reverted with the save" for two sessions.
    ApplyProse(who, asResponse, asked)

    Diag(LOG_INFO(), "Disposition authored for " + asked + ": " + liked + " likes (" + newLikes + \
        " new), " + disliked + " dislikes (" + newDislikes + " new)")
    LogDisposition(asked, aiSuccess, asResponse, "applied:" + newLikes + "/" + newDislikes + \
        " recognized:" + liked + "/" + disliked)
EndEvent

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
EndFunction

Int Function CountHighFrequencyHeld(Actor akActor)
    { How many high-frequency preferences this actor ALREADY holds, counted from
      live faction membership rather than from anything we cached.

      Exists because the frequency budget was per-CALL and therefore only ever
      capped one response. Walks the same contiguous 0x801-0x83A preference
      range ClearDisposition uses, asking IsHighFrequency about each. }
    Int held = 0
    Int off = 0x801
    While off <= 0x83A
        If SNRom_Decorators.IsHighFrequency(off)
            Faction f = Game.GetFormFromFile(off, "CS_Romantasy.esp") as Faction
            If f != None && akActor.GetFactionRank(f) >= 0
                held += 1
            EndIf
        EndIf
        off += 1
    EndWhile
    Return held
EndFunction

; Set by ApplyPreferenceList when Romantasy REFUSED a write. A refusal is not a
; failure of ours and it is not a bad LLM response - it is Romantasy saying these
; preferences belong to somebody else. The caller has to know the difference,
; because its fallback for "no valid likes" is to write archetype preferences
; through AddToFaction, which bypasses the very protection that just refused us.
Bool _prefsRefused

Int Function ApplyPreferenceList(Actor akActor, String asCsv, Int aiRank, Int aiMax)
    { Returns how many names were RECOGNIZED - newly applied plus already
      held. _lastApplied carries the newly-applied count for logging.

      The distinction matters: returning only the newly-applied count made
      "she already believes everything you named" indistinguishable from
      "you named nothing real", and the caller threw away a perfectly good
      response as an archetype fallback. Re-authoring an established NPC hits
      that case constantly, because ApplyPreferenceList never overwrites.

      Unrecognized names are still dropped, not guessed at - LabelToOffset IS
      the whitelist.

      aiMax is a HARD cap. An NPC who likes everything likes nothing: the
      whole design rests on a few sharp preferences distinguishing one person
      from another, so a list of 34 is not a generous disposition, it is a
      destroyed one.

      The FREQUENCY BUDGET below is the subtler cap and matters more to how
      the game actually feels. See SNRom_Decorators.IsHighFrequency. }
    If asCsv == ""
        Return 0
    EndIf
    ; MIND THE ZERO.
    ;
    ; Our aiRank convention is 1 = LIKE and 0 = DISLIKE, and that is what both
    ; call sites pass. Romantasy's aiDirection uses 0 for REMOVE. Passing aiRank
    ; straight through to SetPreference would delete every dislike in the game,
    ; on every authored character, and the only symptom would be characters who
    ; mysteriously object to nothing. Derived here once so the two conventions
    ; never meet.
    Int dir = -1
    If aiRank == 1
        dir = 1
    EndIf
    ; Normalize separators first - a model that copies the catalogue's own
    ; display separator into its answer otherwise yields ONE giant unrecognized
    ; "name". See SNRom_Decorators.NormalizeSeparators.
    String[] parts = StringUtil.Split(SNRom_Decorators.NormalizeSeparators(asCsv), ",")
    Int i = 0
    Int applied = 0
    Int recognized = 0

    ; FREQUENCY BUDGET COUNTS WHAT SHE ALREADY HOLDS, not just this list.
    ; hiFreq used to start at 0 every call, so it only ever capped a single
    ; response - re-author an NPC three times and she accumulates six
    ; high-frequency preferences, two at a time, with the log cheerfully
    ; reporting the budget working on each pass. Since preferences can never be
    ; removed, that is a permanent distortion of her pacing. Seeding from the
    ; actor's CURRENT faction membership makes the cap mean what its comment
    ; always claimed.
    Int hiFreq = CountHighFrequencyHeld(akActor)
    While i < parts.Length && applied < aiMax && !_prefsRefused
        String label = SNRom_Decorators.Trim(parts[i])
        ; Papyrus has no Continue, so the whole body is guarded instead. Empty
        ; entries are normal here: separator normalization turns a multi-byte
        ; separator into two commas, leaving a gap between them. They are not
        ; worth a rejection warning.
        If label != ""
            ; Exact first, so the log can distinguish "the model wrote it
            ; correctly" from "we had to fold an inflection". Naming drift that
            ; goes unlogged is naming drift you cannot tune the prompt against.
            Int offset = SNRom_Decorators.LabelToOffset(SNRom_Decorators.Canon(label))
            If offset == 0
                offset = SNRom_Decorators.LabelToOffsetFuzzy(label)
                If offset != 0
                    Diag(LOG_INFO(), "Normalized '" + label + "' to a known activity for " + akActor.GetDisplayName())
                EndIf
            EndIf
            If offset == 0
                Diag(LOG_WARN(), "Rejected unrecognized activity '" + label + "' for " + akActor.GetDisplayName())
            Else
                ; Two DIFFERENT silent skips used to look identical from
                ; outside: a form that failed to resolve, and an opinion she
                ; already holds. The first is a bug, the second is the design
                ; working exactly as intended. "5 listed, 4 applied" is
                ; unattributable without this.
                Bool hf = SNRom_Decorators.IsHighFrequency(offset)
                Faction f = Game.GetFormFromFile(offset, "CS_Romantasy.esp") as Faction
                If hf && hiFreq >= 2
                    ; Rule 2 in the prompt asks for at most two of these.
                    ; Jordis came back with three of five - Chests Looted,
                    ; Critical Strikes, Backstabs - which would have paced her
                    ; entire romance on looting and combat mechanics instead of
                    ; on who she is. Prose did not hold the count limit either.
                    Diag(LOG_WARN(), "Frequency budget: dropped high-frequency '" + label + "' for " + \
                        akActor.GetDisplayName() + " (already has 2)")
                ElseIf f == None
                    Diag(LOG_ERROR(), "GetFormFromFile failed for '" + label + "' (offset " + offset + \
                        ") - CS_Romantasy.esp not loaded, or ESL indirection failed")
                ElseIf RomApi() < 3 && akActor.GetFactionRank(f) >= 0
                    ; LEGACY PATH ONLY, and the reason this branch existed at all:
                    ; before API 3 a preference could not be removed across a
                    ; reload, so an overwrite was a permanent addition rather than
                    ; a replacement, and not overwriting was the least bad option.
                    Diag(LOG_INFO(), "Kept " + akActor.GetDisplayName() + "'s existing opinion on '" + label + "'")
                    recognized += 1
                    If hf
                        hiFreq += 1                              ; still spends frequency budget
                    EndIf
                Else
                    Bool wrote = False
                    If RomApi() >= 3
                        ; NOT the label. Ten of the fifty-eight labels are
                        ; shorthands that are not the statistic name - see
                        ; OffsetToStatName, generated from the plugin's own records.
                        String statName = OffsetToStatName(offset)
                        If statName == ""
                            Diag(LOG_ERROR(), "No Romantasy stat name for offset " + offset +                                 " ('" + label + "') - preference NOT written")
                        Else
                            wrote = Romantasy.SetPreference(akActor, statName, dir)
                            If !wrote
                                ; ONE LINE, NOT TEN, AND STOP. Romantasy refuses every
                                ; write for a follower it considers author-defined, so
                                ; carrying on produced ten identical ERROR lines that
                                ; looked like our bug. The refusal is also the only
                                ; detection we have - there is no API to ask - so it
                                ; sets the same sticky flag PreferencesAreForeign uses
                                ; and we never try this actor again.
                                _prefsRefused = True
                                StorageUtil.SetIntValue(akActor, "SNRom_PrefsForeign", 1)
                                Diag(LOG_INFO(), "Romantasy refused '" + statName + "' for " +                                     akActor.GetDisplayName() + " - it owns their preferences. " +                                     "Leaving all of them alone; character fields still authored.")
                            EndIf
                        EndIf
                    Else
                        akActor.AddToFaction(f)
                        akActor.SetFactionRank(f, aiRank)
                        wrote = True
                    EndIf
                    If wrote
                        applied += 1
                        recognized += 1
                        If hf
                            hiFreq += 1
                        EndIf
                    EndIf
                EndIf
            EndIf
        EndIf
        i += 1
    EndWhile
    _lastApplied = applied
    Return recognized
EndFunction

Function ApplyArchetype(Actor akActor)
    { Deterministic fallback. Silent failure here is the worst outcome - an
      enrolled NPC with no opinions never moves, and looks like nothing is
      broken - so something is always applied. }
    Faction f = Game.GetFormFromFile(0x802, "CS_Romantasy.esp") as Faction   ; Dungeons Cleared
    If f != None && akActor.GetFactionRank(f) < 0
        akActor.AddToFaction(f)
        akActor.SetFactionRank(f, 1)
    EndIf
    f = Game.GetFormFromFile(0x838, "CS_Romantasy.esp") as Faction           ; Murders
    If f != None && akActor.GetFactionRank(f) < 0
        akActor.AddToFaction(f)
        akActor.SetFactionRank(f, 0)
    EndIf
    StorageUtil.SetIntValue(akActor, "SNRom_DispositionAuthored", 2)         ; 2 = archetype
    Diag(LOG_INFO(), "Archetype disposition applied to " + akActor.GetDisplayName())
EndFunction

Function LogDisposition(String asName, Int aiSuccess, String asRaw, String asOutcome)
    String row = "{\"npc\":\"" + Escape(asName) + "\"" + \
        ",\"gd\":" + Utility.GetCurrentGameTime() + \
        ",\"success\":" + aiSuccess + \
        ",\"outcome\":\"" + asOutcome + "\"" + \
        ",\"raw\":\"" + SNRom_Decorators.JsonEscape(asRaw) + "\"}"
    MiscUtil.WriteToFile("Data/SKSE/Plugins/SkyrimNet Relationships/logs/dispositions.jsonl", row + NL(), True, False)
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
    Diag(LOG_ERROR(), "CFG flt  barkPreferenceChance=" + SkyrimNetApi.GetConfigFloat(CFG(), "barkPreferenceChance", -1.0) + " (settings.yaml: 0.15)")
EndFunction

; The TestPrompt / TestPromptWithCtx / TestRender diagnostics that debugged
; the section-marker bug were removed once it was confirmed fixed (2026-07-27).
; If SendCustomPromptToLLM ever "returns empty" again: read SkyrimNet.log
; FIRST - "Messages array is empty" means a prompt is missing its
; [ system ]/[ user ] markers, and no variant or provider theory is worth an
; hour until that line has been ruled out. TestConfig above is kept
; deliberately: it is the only probe that can tell "config arrived" from
; "default taken", and it costs nothing.
