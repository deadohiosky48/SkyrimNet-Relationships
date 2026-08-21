Scriptname SNRom_Decorators Hidden
{ Decorator functions for SkyrimNet.

  DELIBERATELY A STANDALONE HIDDEN SCRIPT, NOT THE QUEST SCRIPT.

  SkyrimNet's documented example registers decorators against a plain script
  containing Global functions:

      SkyrimNetApi.RegisterDecorator("get_npc_mudcrab_status",
                                     "MudcrabMod_Decorators",
                                     "GetMudcrabStatus")
      String Function GetMudcrabStatus(Actor akActor) ...

  Hosting them as Global functions on a Quest-extending script (SNRom_Bridge)
  did not work: RegisterDecorator returned rc=0, but lookups failed with
  "EligibilityChecker: Decorator '<name>' not found". Removing Global instead
  produced "Papyrus: Failed to find function Dec_PhysicalOk in script
  SNRom_Bridge" - registry hit, dispatch miss.

  Rather than keep guessing which axis matters, this matches the documented
  shape exactly: standalone script, Global functions, no quest involvement.

  These read state only. Anything that MUTATES state stays on SNRom_Bridge,
  where the quest context and its cached fields live.

  EVERY FUNCTION RETURNS String - INCLUDING THE BOOLEAN ONES.
  Surveyed all 10 registered decorators across Player Needs, Baka, Playwright,
  iActions and OStimNet: every single one returns String, including Baka's
  IsInBakaAnimation which is semantically a boolean. Bool-returning decorators
  register with rc=0 and then fail at lookup/dispatch. This - not Global, and
  not quest-vs-standalone - was the actual cause. }

String Function IsEnrolled(Actor akActor) Global
    If akActor != None && Romantasy.GetLevel(akActor) > 0
        Return "true"
    EndIf
    Return "false"
EndFunction

String Function CanBegin(Actor akActor) Global
    { Hard gates live here, not in an action description, so the model cannot
      talk its way past receptivity or the attraction floor. }
    If akActor == None || Romantasy.GetLevel(akActor) > 0
        Return "false"
    EndIf
    If StorageUtil.GetIntValue(akActor, "SNRom_Enrolled", 0) == 1
        Return "false"
    EndIf
    ; enrollmentRequireFollower was advertised in the manifest and read by
    ; nothing - the only follower gate lived in RomanceBeginSpark.yaml's
    ; eligibility, where no config value can reach it. Honored here so the
    ; setting is real rather than decorative.
    ;
    ; NOTE: the YAML rule still applies as a cheap pre-filter, so setting this
    ; False is necessary but NOT sufficient - the `is_follower` eligibility
    ; rule must also be removed for non-followers to be offered the action at
    ; all. Deliberately left in place: without it the Romance category is
    ; offered to every NPC in Skyrim, and action slots compete for attention.
    ; SNRom_Bridge.IsFollowing, NOT the bare vanilla flag. SeverActions
    ; companions set CurrentFollowerFaction without IsPlayerTeammate, and asking
    ; the narrow question here excluded them from ever beginning a romance -
    ; the same bug that stopped TalkCandidate/SparkCandidate ever picking them.
    ; Found by tools\check.ps1, which asserts this shape everywhere.
    If SkyrimNetApi.GetConfigBool(SNRom_Bridge.CFG(), "enrollmentRequireFollower", True)
        If !SNRom_Bridge.IsFollowing(akActor)
            Return "false"
        EndIf
    EndIf
    ; Orientation lives in RomanceOk, shared with the bond prompt's Lover gate.
    ; It was duplicated here and there is no version of this where the two
    ; copies disagreeing is anything but a bug.
    If !SNRom_Decorators.RomanceOk(akActor)
        Return "false"
    EndIf
    Return "true"
EndFunction

String Function PhysicalOk(Actor akActor) Global
    { s = [minTier, attractionCanBypass, emotionalWeight]. Governs SEXUAL
      intimacy only - affection tracks the emotional bond, or a devout
      character would refuse to be kissed until married. }
    If akActor == None
        Return "false"
    EndIf
    ; Same bar as RomanceOk, and needed separately: intimacy has its own gate,
    ; and a CASUAL disposition with the attraction bypass set would otherwise
    ; open it regardless of what the romantic ladder says.
    If KinGuardOn() && SNRom_Decorators.IsPlayerKin(akActor)
        Return "false"
    EndIf
    Int minTier = StorageUtil.GetIntValue(akActor, "SNRom_PhysMinTier", 4)
    If minTier < 0
        Return "false"
    EndIf
    Int tier = Romantasy.GetLevel(akActor) - 1   ; GetLevel is 1-6; tiers 0-5
    If tier >= minTier
        Return "true"
    EndIf
    If StorageUtil.GetIntValue(akActor, "SNRom_PhysAttrBypass", 0) == 1
        ; The bar was hardcoded 1.5 for as long as nothing wrote the ratio, so
        ; it was never once compared against a real number. Now that SNRom_Bridge
        ; feeds it from OCR, make it tunable - the sane setting depends on how
        ; far through the game the player is, because OCR's numerator grows with
        ; skills, fame and main-quest progress while its denominator is a fixed
        ; per-class constant. An early character sits near 0.7; an established
        ; one clears 2.0 against most NPCs.
        ;
        ; 0.0 is a meaningful setting and is why this reads > rather than >=:
        ; the ratio is 0.0 both when OCR is absent and when the actor has never
        ; been refreshed, and neither of those is evidence of attraction.
        Float ratio = StorageUtil.GetFloatValue(akActor, "SNRom_AttractionRatio", 0.0)
        If ratio > 0.0 && ratio >= SkyrimNetApi.GetConfigFloat(SNRom_Bridge.CFG(), "attractionBypassRatio", 1.5)
            Return "true"
        EndIf
    EndIf
    Return "false"
EndFunction

String Function JsonBool(Bool abValue) Global
    { Emits an unquoted JSON literal so Inja sees a real boolean - "false" as
      a STRING is truthy, which would put every NPC on the romantic ladder. }
    If abValue
        Return "true"
    EndIf
    Return "false"
EndFunction

Bool Function IsSparked(Actor akActor) Global
    { Selects which ladder 0330_romantasy_bond renders: platonic or romantic.

      ONE explicit flag, no inference. SNRom_Sparked is set by BeginSpark and
      deliberately NOT by AutoEnroll, so the romantic ladder requires that
      something actually happened.

      There WAS a migration here that treated faction membership as evidence
      of a past spark, on the reasoning that before this flag existed the only
      way into ROM_RomanceLevel was a deliberate BeginSpark. Removed
      2026-07-29. Two reasons:

      1. It was false in practice. Every enrolled NPC on the current save got
         there through development testing, not through a spark, and Jordis
         was rendering "something has shifted... sideways glances" over a bond
         with 0 points and no history.
      2. It was a permanent trap. ANY route into that faction - another mod, a
         console command, a future feature - would have read as romance
         forever, with nothing to distinguish it.

      An inference that quietly asserts a romance is worse than a flag that
      occasionally has to be set by hand. }
    If akActor == None
        Return False
    EndIf
    Return StorageUtil.GetIntValue(akActor, "SNRom_Sparked", 0) == 1
EndFunction

Int Function OrientationBasisToInt(String asWord) Global
    { Confidence in the orientation value. 0 unknown, 1 inferred, 2 known.

      This exists because of Lynea. She was handed ORIENTATION: WOMEN from a
      twelve-word bio containing no evidence either way, and that invented
      answer immediately hard-blocked a romance the player had spent hours
      building. The bug was not a wrong guess - it was FORCING a guess where
      the honest answer was "nobody has established this yet".

      Unrecognized input means unknown, which is the permissive branch. }
    String w = SNRom_Decorators.Upper(SNRom_Decorators.Trim(asWord))
    If w == "STATED"
        Return 2
    ElseIf w == "IMPLIED"
        Return 1
    EndIf
    Return 0
EndFunction

Bool Function IsPlayerKin(Actor akActor) Global
    { True if SkyrimNet-Kinship records this actor as the player's child.

      SOFT DEPENDENCY BY CONSTRUCTION. Kinship sets `SNKin_Bound` to 1 on the
      CHILD actor when it binds them to its roster
      (`StorageUtil.SetIntValue(akChild, "SNKin_Bound", 1)`), and StorageUtil is
      a shared namespace, so reading it needs no compile-time reference to
      Kinship at all. Without Kinship installed the key is absent, the read
      returns the 0 default, and every gate below behaves exactly as it did
      before this function existed.

      An Int, not a string, so it survives a save reload.

      DELIBERATELY NOT reading Kinship's JSON store or its `ref.<formid>.child`
      mapping. Those are its internals and it is free to change them; the
      per-actor flag is the part another mod can reasonably lean on.

      TWO KEYS, ON PURPOSE, FOR ONE RELEASE.

      `SNKin_IsPlayerChild` (Kinship 1.1.0+) is the correct answer. It is
      written on every path that establishes child identity - INCLUDING the
      paths where `BindChildRef` deliberately refuses to bind, which is the case
      that matters: Fertility Mode reuses one spawned actor across children
      sharing an appearance archetype, and Kinship would rather leave the second
      child unbound than give one NPC two identities. That actor is
      unambiguously the player's child.

      `SNKin_Bound` (Kinship 1.0.0) is the fallback and is WEAKER THAN IT LOOKS.
      It means "bound to Kinship's roster", not "is the player's child", and in
      the refused-binding case above it is never written at all - so a read of
      it alone returns 0 and this guard FAILS OPEN on a real child. Kinship
      found that; the first version of this function shipped with it.

      Kinship's own `kinship_is_child` decorator already compensates by falling
      through to a dynamic-ref plus name lookup, so the prompt-side answer has
      been strictly more correct than this Papyrus-side one. 1.1.0 closes that.

      Drop the `SNKin_Bound` half once Kinship 1.1.0 is a stated requirement.
      Absent Kinship entirely BOTH read 0 and the guard is inert, which is the
      intended soft-dependency behavior and unchanged by any of this. }
    If akActor == None
        Return False
    EndIf
    Return StorageUtil.GetIntValue(akActor, "SNKin_IsPlayerChild", 0) == 1 || \
           StorageUtil.GetIntValue(akActor, "SNKin_Bound", 0) == 1
EndFunction

Bool Function KinGuardOn() Global
    { Whether the player's own children are barred from the romantic and sexual
      ladders. Named so it cannot case-fold into its own config path - see the
      note on VoiceLeadSeconds in SNRom_Bridge for what that collision costs.

      Default ON. It costs nothing when Kinship is absent, because IsPlayerKin
      reads 0 for everyone. }
    Return SkyrimNetApi.GetConfigBool(SNRom_Bridge.CFG(), "kinshipBlockRomance", True)
EndFunction

Bool Function RomanceOk(Actor akActor) Global
    { Does this person's orientation permit crossing into Lover with THIS
      player? Gates the top two rungs of the romantic ladder.

      ONLY a KNOWN orientation can refuse. Unknown and merely inferred both
      pass: an inference colors how she behaves, it does not get to delete
      content the player is working toward. A gate that silently removes a
      storyline had better be standing on a fact. }
    If akActor == None
        Return False
    EndIf
    ; THE PLAYER'S OWN CHILD IS NEVER A ROMANTIC PROSPECT. This sits ABOVE the
    ; marriage override deliberately: that override exists to stop an inferred
    ; trait deleting a real relationship, and nothing should be able to argue
    ; its way past this one.
    If KinGuardOn() && SNRom_Decorators.IsPlayerKin(akActor)
        Return False
    EndIf
    ; A RECORDED MARRIAGE OUTRANKS AN AUTHORED TRAIT. Always.
    ;
    ; Jarl Elisif the Fair, married to the player through MARAS, was authored
    ; ORIENTATION: WOMEN with BASIS: STATED - and STATED is the only level that
    ; is allowed to refuse. Nothing in her profile states any such thing; the
    ; model inferred it and marked it as fact, the same restrictive-answer-
    ; without-evidence failure that once returned NEVER for an NPC whose diary
    ; described going to bed with the player.
    ;
    ; The result was that RomanceOk returned FALSE for the player's own wife,
    ; closing the top two rungs of the ladder and rendering "there is a door in
    ; it that does not open" at her.
    ;
    ; The prompt fix for the hallucination is worth making separately, but this
    ; must not depend on it: an inference should never be able to overrule a
    ; ceremony the game recorded. Same principle the spark prompt already
    ; states - when the established facts of their life answer the question,
    ; believe them and stop reasoning.
    If SNRom_Bridge.IsMarriedToPlayer(akActor)
        Return True
    EndIf
    If StorageUtil.GetIntValue(akActor, "SNRom_OrientationKnown", 0) < 2
        Return True
    EndIf
    ; 0 none, 1 men, 2 women, 3 any.
    Int orient = StorageUtil.GetIntValue(akActor, "SNRom_Orientation", 3)
    If orient == 0
        Return False
    EndIf
    Int playerSex = Game.GetPlayer().GetActorBase().GetSex()
    If orient == 1 && playerSex != 0
        Return False
    ElseIf orient == 2 && playerSex != 1
        Return False
    EndIf
    Return True
EndFunction

String Function OrientationWord(Actor akActor) Global
    { Human-readable form for the bio block. Deliberately returns "" unless
      the orientation is KNOWN - the block states facts, and an inference is
      not a fact. Silence is what invites the story to discover it. }
    If akActor == None
        Return ""
    EndIf
    If StorageUtil.GetIntValue(akActor, "SNRom_OrientationKnown", 0) < 2
        Return ""
    EndIf
    Int o = StorageUtil.GetIntValue(akActor, "SNRom_Orientation", 3)
    If o == 1
        Return "men"
    ElseIf o == 2
        Return "women"
    ElseIf o == 0
        Return "no one"
    EndIf
    Return "both men and women"
EndFunction

String Function GetRomance(Actor akActor) Global
    { Rich state for prompts. Never call inside a get_nearby_npc_list loop -
      mod-added decorators only resolve for the current speaker or target. }
    If akActor == None
        Return "{\"enrolled\":false}"
    EndIf
    Int level = Romantasy.GetLevel(akActor)
    If level <= 0
        Return "{\"enrolled\":false}"
    EndIf
    Int pts = Romantasy.GetPoints(akActor)
    Int tier = level - 1
    Int toNext = ((tier + 1) * 500) - pts
    ; Explicit booleans, never inlined JsonBool. An inlined call produced the
    ; Papyrus literal "False" in the authoring context on 2026-08-06, which is
    ; not valid JSON - and here the consequence would be worse and quieter:
    ; this whole object is parsed by Inja, so ONE bad token makes every rom.*
    ; field undefined. The bond prompt reads them through default(), so it would
    ; not error - every NPC would simply drop to the platonic ladder at tier 0
    ; and nothing would say why.
    ; INTS, NOT JSON BOOLEANS. The comment above was right about the danger and
    ; wrong about the remedy: a hand-written lowercase "true" DOES NOT SURVIVE
    ; COMPILATION. Papyrus interns strings case-insensitively, so the literal
    ; folds into whatever casing already holds the slot in the script - source
    ; says "true", the .pex can say True, and the object ships invalid.
    ;
    ; It has been surviving here by luck: SNRom_Decorators.pex happened to hold
    ; lowercase (true x2 / false x4) while the identical literal folded to
    ; capitals in SNRom_Bridge.pex on 2026-08-07 and made every authoring
    ; variable undefined. One capitalised True entering this file would have
    ; dropped every NPC to the platonic ladder at tier 0 with nothing saying why
    ; - exactly the failure the old comment predicted, via the mechanism it did
    ; not know about.
    ;
    ; An Int cannot be case-folded. The prompts test == 1.
    Int sparkedFlag = 0
    If SNRom_Decorators.IsSparked(akActor)
        sparkedFlag = 1
    EndIf
    Int romanceOkFlag = 0
    If SNRom_Decorators.RomanceOk(akActor)
        romanceOkFlag = 1
    EndIf
    If toNext < 0
        toNext = 0
    EndIf
    Return "{\"enrolled\":true,\"points\":" + pts + ",\"level\":" + tier + \
        ",\"levelName\":\"" + Romantasy.GetLevelName(akActor) + "\",\"toNext\":" + toNext + \
        ",\"ardor\":" + StorageUtil.GetIntValue(akActor, "SNRom_Ardor", 2) + \
        ",\"exclusivity\":" + StorageUtil.GetIntValue(akActor, "SNRom_Exclusivity", 50) + \
        ",\"sparked\":" + sparkedFlag + \
        ",\"romanceOk\":" + romanceOkFlag + \
        ",\"orientation\":\"" + SNRom_Decorators.OrientationWord(akActor) + "\"" + \
        ",\"orientationKnown\":" + StorageUtil.GetIntValue(akActor, "SNRom_OrientationKnown", 0) + \
        ",\"why\":\"" + SNRom_Decorators.JsonEscape(SNRom_Bridge.StoreGetText(akActor, "Why")) + "\"" + \
        ",\"limit\":\"" + SNRom_Decorators.JsonEscape(SNRom_Bridge.StoreGetText(akActor, "Limit")) + "\"" + \
        ",\"address\":\"" + SNRom_Decorators.JsonEscape(SNRom_Bridge.StoreGetText(akActor, "Address")) + "\"" + \
        ",\"physMinTier\":" + StorageUtil.GetIntValue(akActor, "SNRom_PhysMinTier", 4) + \
        ",\"stance\":" + StorageUtil.GetIntValue(akActor, "SNRom_PlayerStance", 0) + "}"
EndFunction

; ===========================================================================
; Disposition support - whitelist + case folding
; ===========================================================================

String Function Upper(String asText) Global
    { PapyrusUtil's StringUtil has NO ToUpper - only GetLength, GetNthChar,
      Find, Substring, AsOrd, AsChar and Split. Fold manually so label matching
      survives whatever casing the model returns. }
    String out = ""
    Int i = 0
    Int n = StringUtil.GetLength(asText)
    While i < n
        String c = StringUtil.GetNthChar(asText, i)
        Int o = StringUtil.AsOrd(c)
        If o >= 97 && o <= 122
            c = StringUtil.AsChar(o - 32)
        EndIf
        out += c
        i += 1
    EndWhile
    Return out
EndFunction

String Function NameCore(String asName) Global
    { Upper-folds a name and strips every NON-LETTER from BOTH ENDS, for
      comparing a model's echoed NAME: against the NPC we actually asked about.

      Written 2026-08-07. Bryling's assessments were being answered correctly
      and thrown away anyway: the model replied with

          NAME: "Bryling",

      - JSON habit bleeding into a labeled-line format - so the guard compared
      '"BRYLING",' against 'BRYLING', called it a mismatch, and discarded every
      single assessment she generated. The response was RIGHT. The comparison
      was too literal.

      Only the ENDS are trimmed, so internal spaces, hyphens and apostrophes
      survive: "Svana Far-Shield" and "Jarl Elisif the Fair" still compare
      intact, and two genuinely different NPCs still cannot collide. That
      matters - this guard is the only thing stopping a response about a nearby
      NPC from rewriting someone else's disposition permanently, so it must be
      loosened exactly this far and no further.

      Empty in, empty out. Callers treat an empty core as "no echo present"
      rather than as a mismatch. }
    String up = Upper(asName)
    Int n = StringUtil.GetLength(up)
    Int first = 0
    While first < n && !IsLetterOrd(StringUtil.AsOrd(StringUtil.GetNthChar(up, first)))
        first += 1
    EndWhile
    Int last = n - 1
    While last > first && !IsLetterOrd(StringUtil.AsOrd(StringUtil.GetNthChar(up, last)))
        last -= 1
    EndWhile
    If first > last
        Return ""
    EndIf
    Return StringUtil.Substring(up, first, (last - first) + 1)
EndFunction

Bool Function IsLetterOrd(Int aiOrd) Global
    { A-Z only. NameCore upper-folds before calling this, so lowercase never
      reaches here. }
    Return aiOrd >= 65 && aiOrd <= 90
EndFunction

String Function IntimacyWordFromTier(Int aiMinTier) Global
    { Reverse of IntimacyToMinTier, for showing a companion's authored intimacy
      back to the model in BuildCircle. Kept next to the forward mapper so the
      two are read together; if one gains a value the other must too. }
    If aiMinTier < 0
        Return "NEVER"
    ElseIf aiMinTier >= 5
        Return "GUARDED"
    ElseIf aiMinTier == 4
        Return "ROMANTIC"
    EndIf
    Return "CASUAL"
EndFunction

Int Function IntimacyRank(Int aiMinTier) Global
    { Intimacy as a LADDER, most open to most closed: 0 casual, 1 romantic,
      2 guarded, 3 never.

      Needed because the stored form is a minimum tier and NEVER is -1, so the
      stored numbers do not sort. Drift has to move exactly one rung at a time
      and cannot do that arithmetic on a value where the most closed answer is
      also the smallest. }
    If aiMinTier < 0
        Return 3
    ElseIf aiMinTier >= 5
        Return 2
    ElseIf aiMinTier == 4
        Return 1
    EndIf
    Return 0
EndFunction

Int Function MinTierFromRank(Int aiRank) Global
    { Inverse of IntimacyRank. Values must match IntimacyToMinTier exactly - if
      one gains a rung the other two must too. }
    If aiRank >= 3
        Return -1
    ElseIf aiRank == 2
        Return 5
    ElseIf aiRank == 1
        Return 4
    EndIf
    Return 2
EndFunction

String Function ReplaceAll(String asText, String asFind, String asWith) Global
    { StringUtil has no Replace either. }
    String out = ""
    String rest = asText
    Int at = StringUtil.Find(rest, asFind)
    While at >= 0
        out += StringUtil.Substring(rest, 0, at) + asWith
        rest = StringUtil.Substring(rest, at + StringUtil.GetLength(asFind))
        at = StringUtil.Find(rest, asFind)
    EndWhile
    Return out + rest
EndFunction

String Function Trim(String asText) Global
    String t = asText
    While StringUtil.GetLength(t) > 0 && StringUtil.GetNthChar(t, 0) == " "
        t = StringUtil.Substring(t, 1)
    EndWhile
    While StringUtil.GetLength(t) > 0 && StringUtil.GetNthChar(t, StringUtil.GetLength(t) - 1) == " "
        t = StringUtil.Substring(t, 0, StringUtil.GetLength(t) - 1)
    EndWhile
    Return t
EndFunction

String Function Canon(String asLabel) Global
    { Folds only what CANNOT change meaning: case, separator punctuation and
      repeated spaces. Anything that could alter which activity is named is
      left to FlipPlural, which probes the table rather than trusting itself. }
    String s = SNRom_Decorators.Upper(asLabel)
    s = ReplaceAll(s, "-", " ")
    s = ReplaceAll(s, "_", " ")
    s = ReplaceAll(s, ".", "")
    s = ReplaceAll(s, ",", "")
    s = ReplaceAll(s, "'", "")
    ; One pass is not enough - collapsing "   " leaves "  ".
    While StringUtil.Find(s, "  ") >= 0
        s = ReplaceAll(s, "  ", " ")
    EndWhile
    Return Trim(s)
EndFunction

String Function FlipPlural(String asLabel, Bool abFirstWord, Bool abAdd) Global
    { Adds or removes a trailing S on either the first or the last word.
      Used ONLY to probe the exact-match table - never to construct a name we
      then trust. Returns the input unchanged when there is nothing to strip,
      which makes that probe a harmless repeat of the exact lookup. }
    String[] w = StringUtil.Split(asLabel, " ")
    If w.Length == 0
        Return asLabel
    EndIf
    Int idx = w.Length - 1
    If abFirstWord
        idx = 0
    EndIf
    String word = w[idx]
    Int n = StringUtil.GetLength(word)
    If n == 0
        Return asLabel
    EndIf
    If abAdd
        word = word + "S"
    ElseIf StringUtil.GetNthChar(word, n - 1) != "S"
        Return asLabel
    Else
        word = StringUtil.Substring(word, 0, n - 1)
    EndIf
    w[idx] = word
    String out = ""
    Int i = 0
    While i < w.Length
        If i > 0
            out += " "
        EndIf
        out += w[i]
        i += 1
    EndWhile
    Return out
EndFunction

Int Function LabelToOffsetFuzzy(String asLabel) Global
    { Tolerant front door to the whitelist. LabelToOffset itself stays a strict
      exact-match table so it can still be eyeballed against CS_Romantasy.esp.

      This does NOT relax the never-guess rule. It only folds INFLECTIONS of
      names already in the table - a model writing "Soul Trapped" for
      "Souls Trapped" loses a pick to one character. An invented or genuinely
      wrong activity still returns 0 and is rejected exactly as before.

      The asymmetry that governs this: a dropped pick is invisible noise, but a
      MISmapped pick is a wrong personality that persists forever. So every
      probe below was checked to be collision-free - stripping a trailing S
      from every word of all 58 entries yields 58 distinct strings, so no fold
      can ever land on a different activity than the one written. }
    String l = Canon(asLabel)
    Int hit = LabelToOffset(l)
    If hit != 0
        Return hit
    EndIf
    hit = LabelToOffset(FlipPlural(l, True, True))     ; singular first word: "Soul Trapped"
    If hit != 0
        Return hit
    EndIf
    hit = LabelToOffset(FlipPlural(l, False, True))    ; singular last word:  "Critical Strike"
    If hit != 0
        Return hit
    EndIf
    hit = LabelToOffset(FlipPlural(l, True, False))    ; over-pluralised first: "Armors Made"
    If hit != 0
        Return hit
    EndIf
    Return LabelToOffset(FlipPlural(l, False, False))  ; over-pluralised last
EndFunction

Bool Function IsHighFrequency(Int aiOffset) Global
    { The eleven statistics that fire constantly in ordinary play.

      Romantasy's point weights are FIXED and cannot be changed, so frequency
      - not weight - decides the economy. Critical Strikes fires hundreds of
      times an hour; Questlines Completed fires about five times in a
      playthrough. An NPC who likes three of these is paced by grind rate
      rather than by character, and reaches Spouse while a thoughtfully
      authored one is still at Confidant.

      The prompt asks for at most two. It asked for 4-7 likes and got 34, so
      the count is enforced in Papyrus and so is this. Applies to DISLIKES
      too: a disliked high-frequency stat drains a bond just as fast as a
      liked one builds it. }
    Return aiOffset == 0x826 \
        || aiOffset == 0x820 \
        || aiOffset == 0x822 \
        || aiOffset == 0x805 \
        || aiOffset == 0x808 \
        || aiOffset == 0x806 \
        || aiOffset == 0x827 \
        || aiOffset == 0x828 \
        || aiOffset == 0x834 \
        || aiOffset == 0x836 \
        || aiOffset == 0x821
EndFunction

Int Function LabelToOffset(String asLabel) Global
    { Maps a human activity name (as written in snrom_author_disposition.prompt)
      to its ROM_ faction's plugin-local FormID. Generated from CS_Romantasy.esp
      so it cannot drift from the actual records.
      Returns 0 for anything unrecognized - that IS the whitelist: a model that
      invents or misspells an activity gets rejected rather than interpreted. }
    String l = SNRom_Decorators.Upper(asLabel)
    If l == "ANIMALS KILLED"
        Return 0x821
    ElseIf l == "ARMOR MADE"
        Return 0x831
    ElseIf l == "ASSAULTS"
        Return 0x837
    ElseIf l == "AUTOMATONS KILLED"
        Return 0x825
    ElseIf l == "BACKSTABS"
        Return 0x828
    ElseIf l == "BARTERS"
        Return 0x808
    ElseIf l == "BRIBES"
        Return 0x80A
    ElseIf l == "BUNNIES SLAUGHTERED"
        Return 0x82A
    ElseIf l == "CHESTS LOOTED"
        Return 0x805
    ElseIf l == "CIVIL WAR COMPLETED"
        Return 0x81B
    ElseIf l == "COLLEGE COMPLETED"
        Return 0x818
    ElseIf l == "COMPANIONS COMPLETED"
        Return 0x817
    ElseIf l == "CREATURES KILLED"
        Return 0x822
    ElseIf l == "CRITICAL STRIKES"
        Return 0x826
    ElseIf l == "DAEDRA KILLED"
        Return 0x824
    ElseIf l == "DAEDRIC COMPLETED"
        Return 0x81C
    ElseIf l == "DARK BROTHERHOOD COMPLETED"
        Return 0x81A
    ElseIf l == "DAWNGUARD COMPLETED"
        Return 0x81D
    ElseIf l == "DAYS PASSED"
        Return 0x803
    ElseIf l == "DAYS VAMPIRE"
        Return 0x80D
    ElseIf l == "DAYS WEREWOLF"
        Return 0x80E
    ElseIf l == "DISEASES CONTRACTED"
        Return 0x80C
    ElseIf l == "DRAGON SOULS COLLECTED"
        Return 0x82C
    ElseIf l == "DRAGONBORN COMPLETED"
        Return 0x81E
    ElseIf l == "DUNGEONS CLEARED"
        Return 0x802
    ElseIf l == "HORSES STOLEN"
        Return 0x839
    ElseIf l == "INTIMIDATIONS"
        Return 0x80B
    ElseIf l == "ITEMS STOLEN"
        Return 0x836
    ElseIf l == "LOCATIONS DISCOVERED"
        Return 0x801
    ElseIf l == "LOCKS PICKED"
        Return 0x834
    ElseIf l == "MAGIC ITEMS MADE"
        Return 0x82F
    ElseIf l == "MAIN QUESTS COMPLETED"
        Return 0x815
    ElseIf l == "MAULS"
        Return 0x812
    ElseIf l == "MISC OBJECTIVES COMPLETED"
        Return 0x814
    ElseIf l == "MURDERS"
        Return 0x838
    ElseIf l == "NECKS BITTEN"
        Return 0x80F
    ElseIf l == "PEOPLE KILLED"
        Return 0x820
    ElseIf l == "PERSUASIONS"
        Return 0x809
    ElseIf l == "POCKETS PICKED"
        Return 0x835
    ElseIf l == "POISONS MIXED"
        Return 0x833
    ElseIf l == "POTIONS MIXED"
        Return 0x832
    ElseIf l == "QUESTLINES COMPLETED"
        Return 0x81F
    ElseIf l == "QUESTS COMPLETED"
        Return 0x813
    ElseIf l == "SHOUTS LEARNED"
        Return 0x82D
    ElseIf l == "SIDE QUESTS COMPLETED"
        Return 0x816
    ElseIf l == "SKILL BOOKS READ"
        Return 0x807
    ElseIf l == "SKILL INCREASES"
        Return 0x806
    ElseIf l == "SNEAK ATTACKS"
        Return 0x827
    ElseIf l == "SOULS TRAPPED"
        Return 0x82E
    ElseIf l == "SPELLS LEARNED"
        Return 0x82B
    ElseIf l == "STANDING STONES FOUND"
        Return 0x804
    ElseIf l == "THIEVES COMPLETED"
        Return 0x819
    ElseIf l == "TRESPASSES"
        Return 0x83A
    ElseIf l == "UNDEAD KILLED"
        Return 0x823
    ElseIf l == "VAMPIRISM CURES"
        Return 0x810
    ElseIf l == "WEAPONS DISARMED"
        Return 0x829
    ElseIf l == "WEAPONS MADE"
        Return 0x830
    ElseIf l == "WEREWOLF TRANSFORMATIONS"
        Return 0x811
    EndIf
    Return 0
EndFunction
; ===========================================================================
; Authored-disposition mappers
;
; These translate the LLM's labeled words into the StorageUtil values the
; gates read. Every one of these keys was READ-ONLY until 2026-07-28 - read
; with a default and never written by anything - so every NPC silently shared
; one hardcoded personality: pansexual, sex only at Lover tier, no attraction
; bypass, ardor 2, exclusivity 50. The gates existed; the data did not.
;
; Unrecognized input returns the SAFE value, never the permissive one. A model
; that answers unexpectedly must not accidentally unlock intimacy.
; ===========================================================================

Int Function OrientationToInt(String asWord) Global
    { 0 none, 1 men, 2 women, 3 any. Matches SNRom_Decorators.CanBegin.

      TWO VOCABULARIES ACCEPTED, on purpose.

      The prompt now asks for ATTRACTED_TO_MEN / ATTRACTED_TO_WOMEN /
      ATTRACTED_TO_BOTH / ATTRACTED_TO_NEITHER, because the old bare MEN/WOMEN
      answers are the SAME TOKENS as the subject's own gender. Elisif came back
      WOMEN/STATED six times out of six - while married to a male player, with
      a diary full of loving him, and eventually with the prompt explicitly
      saying "this is NOT their own gender". Every other NPC answered ANY. The
      working theory is slot-filling from her unusually long first-person,
      heavily gendered diary, and directional tokens remove the collision.

      The old words stay accepted because a model that ignores the new
      vocabulary and answers WOMEN must still parse as WOMEN. Falling through
      to the default would turn a visible wrong answer into a silent one, and
      the authored word is logged either way, so keeping them costs no signal. }
    String w = SNRom_Decorators.Upper(SNRom_Decorators.Trim(asWord))
    If w == "ATTRACTED_TO_MEN" || w == "MEN"
        Return 1
    ElseIf w == "ATTRACTED_TO_WOMEN" || w == "WOMEN"
        Return 2
    ElseIf w == "ATTRACTED_TO_BOTH" || w == "ANY" || w == "BOTH"
        Return 3
    ElseIf w == "ATTRACTED_TO_NEITHER" || w == "NONE" || w == "NEITHER"
        Return 0
    EndIf
    Return 3   ; unreadable answer: leave romance possible, the pre-existing default
EndFunction

Int Function IntimacyToMinTier(String asWord) Global
    { Feeds SNRom_PhysMinTier. -1 means never, otherwise the tier at which
      sexual intimacy becomes possible at all. }
    String w = SNRom_Decorators.Upper(SNRom_Decorators.Trim(asWord))
    If w == "NEVER"
        Return -1
    ElseIf w == "GUARDED"
        Return 5   ; settled bond only
    ElseIf w == "ROMANTIC"
        Return 4   ; in love first
    ElseIf w == "CASUAL"
        Return 2   ; close enough to trust, love not required
    EndIf
    Return 4       ; unreadable answer: the conservative middle
EndFunction

Int Function IntimacyToBypass(String asWord) Global
    { Feeds SNRom_PhysAttrBypass - THE Sapphire switch. Only CASUAL lets raw
      attraction stand in for tier: someone who keeps everyone at arm's length
      and may never reach Lover can still want someone in their bed. }
    If SNRom_Decorators.Upper(SNRom_Decorators.Trim(asWord)) == "CASUAL"
        Return 1
    EndIf
    Return 0
EndFunction

Int Function WeightToPoints(String asWord) Global
    { Conversational weight -> points. A tier is 500, which is the scale every
      number here is set against.

      The MODEL NEVER SEES THESE NUMBERS. It answers with a word describing
      what happened; Papyrus decides what that is worth. That separation is
      deliberate - asked for a number the model inflates (ten NPCs answered
      "3" on a 0-4 scale), and it has no way to know what 40 means against an
      economy it cannot see.

      LANDMARK is 350 - most of a tier - because two people explicitly and
      mutually deciding to be partners is not a small event and scoring it
      like one is the thing that makes these systems feel fake. It is gated
      hard in Papyrus instead: see the landmark cooldown in ApplyTalkAward.

      Unknown words return 0. A garbled answer must move nothing. }
    String w = SNRom_Decorators.Upper(SNRom_Decorators.Trim(asWord))
    If w == "SMALL"
        Return 10
    ElseIf w == "REAL"
        Return 40
    ElseIf w == "MAJOR"
        Return 120
    ElseIf w == "LANDMARK"
        Return 350
    ; ── The downward half, added 2026-08-04 ──────────────────────────────────
    ; Until now every weight was non-negative, so a bond could only ever
    ; improve. A breakup conversation would most likely have read as "two people
    ; explicitly redefining their relationship" and scored LANDMARK: +350.
    ;
    ; DELIBERATELY ASYMMETRIC MAGNITUDES. SETBACK is the mirror of REAL, not of
    ; MAJOR, because the common case is an argument and an argument is not a
    ; wound. 40 against a 500-point tier is recoverable in one good conversation,
    ; which is the point - one disagreement about which road to take must not
    ; put a relationship in danger.
    ;
    ; RUPTURE mirrors LANDMARK exactly, because it IS a landmark: the day two
    ; people stop being what they were is as defining as the day they started.
    ElseIf w == "SETBACK"
        Return -40
    ElseIf w == "RUPTURE"
        Return -350
    EndIf
    Return 0
EndFunction

Int Function ArdorToInt(String asWord) Global
    { How demonstrative she is, 0-4. Authored as a WORD, not a number.

      It was a 0-4 scale and came back 3 for TEN CONSECUTIVE NPCs. An
      unanchored numeric range has no meaning to answer against, so everything
      lands middle-high and the axis measures nothing. Intimacy and
      exclusivity varied over the same ten, so this was the scale's fault
      rather than the model's.

      Words carry their own definition. "Reserved" and "intense" are things a
      person can be recognized as; 1 and 4 are not. The stored value stays an
      int because PhysicalOk and the spark calibration want to compare it. }
    String w = SNRom_Decorators.Upper(SNRom_Decorators.Trim(asWord))
    If w == "RESERVED"
        Return 0
    ElseIf w == "MEASURED"
        Return 1
    ElseIf w == "WARM"
        Return 2
    ElseIf w == "OPEN"
        Return 3
    ElseIf w == "INTENSE"
        Return 4
    EndIf
    ; Older saves and any model that answers with a digit anyway.
    Return SNRom_Decorators.ClampInt(asWord, 0, 4, 2)
EndFunction

String Function ArdorWord(Int aiArdor) Global
    { Inverse, for the spark assessment - it calibrates far better against
      "reserved" than against "1". }
    If aiArdor <= 0
        Return "reserved and undemonstrative"
    ElseIf aiArdor == 1
        Return "measured, showing little"
    ElseIf aiArdor == 2
        Return "warm but not effusive"
    ElseIf aiArdor == 3
        Return "open about what she feels"
    EndIf
    Return "intense and unmistakable"
EndFunction

Int Function ClampInt(String asText, Int aiLow, Int aiHigh, Int aiFallback) Global
    { Papyrus has no TryParse: a non-numeric string casts to 0, which is a
      LEGAL value for both ardor and exclusivity and so cannot be distinguished
      from a real answer. Verify the text is digits before trusting it. }
    String t = SNRom_Decorators.Trim(asText)
    Int n = StringUtil.GetLength(t)
    If n == 0
        Return aiFallback
    EndIf
    Int i = 0
    While i < n
        Int o = StringUtil.AsOrd(StringUtil.GetNthChar(t, i))
        If o < 48 || o > 57
            Return aiFallback
        EndIf
        i += 1
    EndWhile
    Int v = t as Int
    If v < aiLow
        Return aiLow
    ElseIf v > aiHigh
        Return aiHigh
    EndIf
    Return v
EndFunction

String Function SexWord(Int aiSex) Global
    If aiSex == 1
        Return "female"
    EndIf
    Return "male"
EndFunction

String Function FieldValue(String asResponse, String asKey) Global
    { Pulls "KEY: value" out of a labeled-line response. Labeled lines are
      used instead of JSON because Papyrus parses them trivially and small
      models produce them far more reliably than nested structures. }
    Int at = StringUtil.Find(asResponse, asKey)
    Int skip = StringUtil.GetLength(asKey)
    If at < 0
        ; Tolerate QUOTED keys. A model that drifts into JSON writes 'WHY': or
        ; "WHY": and the plain lookup misses every field, so a COMPLETE and
        ; correct response is discarded as truncated. Happened twice in a row
        ; for Svana Far-Shield, who fell back to a generic archetype both times.
        ;
        ; The root cause was use_structured_outputs on the LLM variant and that
        ; is fixed, so this is belt-and-braces - but it costs two Finds on a
        ; path that has already failed, and the failure it prevents is silent.
        String bare = StringUtil.Substring(asKey, 0, StringUtil.GetLength(asKey) - 1)
        String alt = bare + "':"
        at = StringUtil.Find(asResponse, alt)
        skip = StringUtil.GetLength(alt)
        If at < 0
            alt = bare + "\":"
            at = StringUtil.Find(asResponse, alt)
            skip = StringUtil.GetLength(alt)
        EndIf
    EndIf
    If at < 0
        Return ""
    EndIf
    Int start = at + skip
    String rest = StringUtil.Substring(asResponse, start)
    Int nl = StringUtil.Find(rest, "\n")
    If nl < 0
        nl = StringUtil.Find(rest, StringUtil.AsChar(10))
    EndIf
    If nl >= 0
        rest = StringUtil.Substring(rest, 0, nl)
    EndIf
    Return Unquote(rest)
EndFunction

String Function DayOfStamp(String asEntry) Global
    { The DAY part of a bracketed timestamp, or "" if there is no stamp.

      Timestamps render as "[11:27 PM, Middas, 14th of Morning Star, 4E 202]".
      The clock time is deliberately DISCARDED and only the day kept, because
      the whole point is to tell separate days apart: two citations from the
      same evening carry different clock times and must not count as two
      occasions.

      Everything from the first comma to the closing bracket is the day. That
      keeps the weekday, the date and the year together, so "14th of Morning
      Star" and "15th of Morning Star" differ while "11:27 PM" and "11:53 PM"
      on the same date collapse to one. }
    Int open = StringUtil.Find(asEntry, "[")
    If open < 0
        Return ""
    EndIf
    Int close = StringUtil.Find(asEntry, "]")
    If close <= open
        Return ""
    EndIf
    String stamp = StringUtil.Substring(asEntry, open + 1, close - open - 1)
    Int comma = StringUtil.Find(stamp, ",")
    If comma < 0
        Return SNRom_Decorators.Upper(SNRom_Decorators.Trim(stamp))
    EndIf
    Return SNRom_Decorators.Upper(SNRom_Decorators.Trim( \
        StringUtil.Substring(stamp, comma + 1)))
EndFunction

Int Function CountOccasions(String asText) Global
    { How many DISTINCT DAYS a drift verdict actually cited.

      A COUNT OF ENTRIES WAS NOT ENOUGH. The first version counted
      bar-separated fragments, and the very first verdict under it returned
      three - all describing one evening, none carrying a date, none naming a
      separate moment. Counting separators only ever measures whether the model
      can type a bar.

      What makes an occasion distinct is WHEN it happened, so that is what gets
      counted: entries without a copied timestamp are ignored entirely, and
      entries sharing a day count once. A single night subdivided into three
      vivid phrasings now scores 1 and is discarded, which is the whole point.

      THE STRUCTURAL FIX, and it exists because two rounds of prose tightening
      did nothing. Across three subjects the assessor answered from SALIENCE
      rather than from pattern: vivid material nearby produced YES, thin
      material produced NO, and neither had anything to do with whether a
      behavior had recurred. Sybille's verdict was a paraphrase of a talk award
      that had fired seconds earlier, on a different axis entirely.

      Returns a COUNT rather than a Bool so the caller can log how many were
      cited; "cited 1" and "cited none" are different failures and the log
      should be able to say which.

      Capped at eight days tracked. Nothing needs more than two to pass, the
      array is a fixed size because Papyrus has no set, and a model listing
      nine dated citations has already answered the question. }
    String t = SNRom_Decorators.Trim(asText)
    If t == "" || SNRom_Decorators.Upper(t) == "NONE"
        Return 0
    EndIf
    String[] days = Utility.CreateStringArray(8, "")
    Int found = 0
    String rest = t + "|"
    Int at = StringUtil.Find(rest, "|")
    While at >= 0 && found < 8
        String entry = SNRom_Decorators.Trim(StringUtil.Substring(rest, 0, at))
        String day = SNRom_Decorators.DayOfStamp(entry)
        If day != ""
            Bool seen = False
            Int i = 0
            While i < found
                If days[i] == day
                    seen = True
                EndIf
                i += 1
            EndWhile
            If !seen
                days[found] = day
                found += 1
            EndIf
        EndIf
        rest = StringUtil.Substring(rest, at + 1)
        at = StringUtil.Find(rest, "|")
    EndWhile
    Return found
EndFunction

Bool Function PatternIsWatching(String asPattern) Global
    { True if a drift PATTERN rests on what the NPC merely WATCHED.

      PAPYRUS, NOT PROSE - and this one was earned. The drift prompt excluded
      witnessed events from the start. After the first live review cited them
      anyway, the exclusion was restated with emphasis, given its own section
      saying a characterisation is not a pattern, and armed with two explicit
      pre-write tests. The very next run on the same NPC produced the same
      answer and used the word "witness" in it.

      That is the fourth time this project has tightened a threshold in wording
      and had the model reason straight past it. The tenure gate went into
      Papyrus for exactly this reason; so does this.

      FAILS SAFE. A match discards the verdict, and a discarded verdict means no
      change - which is already the expected answer, so a false positive costs
      nothing but a review that will come round again. That asymmetry is why a
      blunt word list is acceptable here and would not be if it gated an award.

      Deliberately NOT matching "others" on its own. "He has repeatedly chosen
      her over others" is a pattern ABOUT the two of them and must survive.
      Every needle below describes the NPC in the role of onlooker. }
    String p = SNRom_Decorators.Upper(asPattern)
    If StringUtil.Find(p, "WITNESS") >= 0
        Return True
    ElseIf StringUtil.Find(p, "OBSERV") >= 0
        Return True
    ElseIf StringUtil.Find(p, "WATCH") >= 0
        Return True
    ElseIf StringUtil.Find(p, "BYSTANDER") >= 0
        Return True
    ElseIf StringUtil.Find(p, "ONLOOKER") >= 0
        Return True
    ElseIf StringUtil.Find(p, "OVERHEARD") >= 0
        Return True
    ElseIf StringUtil.Find(p, "SPECTAT") >= 0
        Return True
    ElseIf StringUtil.Find(p, "INTIMACY OF OTHERS") >= 0
        Return True
    EndIf
    Return False
EndFunction

String Function Unquote(String asValue) Global
    { Strips JSON punctuation a drifting model wraps around a VALUE.

      The quoted-KEY tolerance above was only half the problem. A model that
      slips into JSON writes both sides of the pair, and a weight arriving as
      LANDMARK wrapped in quotes with a trailing comma matches no weight, no
      orientation and no intimacy word - so a correct answer scores nothing and
      the log line reads as though the model simply declined.

      Abelone lost a genuine 350-point defining moment to exactly this on
      2026-08-09, and it looked like the landmark cooldown had fired. It had
      not - the downgrade line was absent. 3 of 126 verdicts in that save came
      back this way: rare, silent, and worth a few Finds to catch.

      SAFE ON PROSE. WHY and LIMIT are sentences; removing a MATCHED pair of
      wrapping quotes, or one trailing comma, cannot change their meaning.
      Internal quotation is untouched because only the first and last
      characters are ever considered. }
    String v = Trim(asValue)
    Int n = StringUtil.GetLength(v)
    If n == 0
        Return v
    EndIf
    If StringUtil.GetNthChar(v, n - 1) == ","
        v = Trim(StringUtil.Substring(v, 0, n - 1))
        n = StringUtil.GetLength(v)
    EndIf
    If n >= 2
        String f = StringUtil.GetNthChar(v, 0)
        String l = StringUtil.GetNthChar(v, n - 1)
        If (f == "\"" && l == "\"") || (f == "'" && l == "'")
            v = Trim(StringUtil.Substring(v, 1, n - 2))
        EndIf
    EndIf
    Return v
EndFunction

String Function NormalizeSeparators(String asCsv) Global
    { The catalogue in snrom_author_disposition.prompt is DISPLAYED with middle-dot
      separators, and a model copied that separator into its ANSWER - so
      "Dungeons Cleared - Standing Stones Found - Barters ..." arrived as ONE
      name and all seven likes were rejected as a single unrecognized activity.
      Svana Far-Shield lost a whole authoring run to it and fell back to a
      generic archetype.

      Same failure family as the group headings that became answers: whatever
      sits next to the answer gets copied. Rather than guess which separator a
      model will pick, fold ANY character that cannot appear in an activity name
      into a comma. The 58 catalogue entries are letters, digits and spaces only
      - verified against LabelToOffset - so this cannot corrupt a valid name.

      Deliberately character-code based rather than a literal-character replace:
      a middle dot may arrive as one char or two depending on how the response
      was decoded, and this does not care either way. }
    Int n = StringUtil.GetLength(asCsv)
    String out = ""
    Int i = 0
    While i < n
        String ch = StringUtil.GetNthChar(asCsv, i)
        Int o = StringUtil.AsOrd(ch)
        If (o >= 48 && o <= 57) || (o >= 65 && o <= 90) || (o >= 97 && o <= 122) || o == 32 || o == 44
            out += ch
        Else
            out += ","                          ; anything else IS a separator
        EndIf
        i += 1
    EndWhile
    Return out
EndFunction

String Function JsonEscape(String asText) Global
    { Raw LLM output goes into a JSON log line verbatim, and into the authoring
      CONTEXT object - quotes, newlines, backslashes or control characters in
      it would corrupt either. }
    ; Hardened 2026-08-06. It handled quotes and newlines and nothing else,
    ; which is enough for a log line and NOT enough for the authoring context:
    ; that is a single JSON object, so one bad character anywhere makes the
    ; WHOLE thing unparseable and every variable silently undefined.
    ;
    ; Backslash was missing entirely and is the dangerous one - a trailing
    ; backslash escapes the closing quote and swallows the rest of the object.
    ; TAB and the other C0 control characters are invalid unescaped inside a
    ; JSON string, and LLM prose reaches here by way of the disposition store,
    ; so none of it is under our control.
    ;
    ; Removing rather than escaping, deliberately: this is prose destined for a
    ; prompt, so a lost backslash costs nothing, while emitting an escaped pair
    ; and relying on both ends to agree is one more thing to get wrong.
    ; NEVER loop AsChar(0..31) here. That was the first attempt and it broke
    ; authoring completely: AsChar(0) is the null character, which Papyrus
    ; yields as an EMPTY string, so the first iteration became
    ; ReplaceAll(s, "", " ") - replacing the empty string. That faults, and
    ; because it faults inside AuthorDisposition's context construction the
    ; whole function dies AFTER _pendingActor is set and BEFORE the send, which
    ; leaves the authoring slot held forever and every later request queued
    ; behind a request that will never complete.
    ;
    ; Tab, LF and CR are the only control characters that realistically appear
    ; in LLM prose, and they are named explicitly so nothing has to be derived
    ; from a character code again.
    String s = asText
    s = ReplaceAll(s, "\\", "")
    s = ReplaceAll(s, "\"", "'")
    s = ReplaceAll(s, StringUtil.AsChar(9), " ")
    s = ReplaceAll(s, StringUtil.AsChar(10), " ")
    s = ReplaceAll(s, StringUtil.AsChar(13), " ")
    Return s
EndFunction
