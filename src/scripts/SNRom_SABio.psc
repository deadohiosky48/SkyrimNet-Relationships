Scriptname SNRom_SABio Hidden
{ EVERY SEVERACTIONS BIO BLOCKS CALL THIS MOD MAKES, and nothing else.

  SeverActions' API guide: where SeverActions is not installed, a script that
  names SeverActionsNativeExt2 cannot be used. So the calls live here (and in
  the generated SNRom_SABioLib), and SNRom_Bridge reaches them only by static
  calls - never through a variable, property, parameter or return of this
  script's type - after checking SNRom_Bridge.SeverActionsPresent().

  Keys passed in are LOCAL ("expression.warm-but-not-effusive"); the prefix
  that makes them ours is added here. }

Int Function Version() Global
    { 1 on SeverActions 4.0.1 and later. 0 on an older SeverActions, where the
      call fails, logs one Papyrus error, and returns the default. }
    Return SeverActionsNativeExt2.BioApi_Version()
EndFunction

Int Function LibrarySize() Global
    { How many blocks DefineAll offers (generated with the library). }
    Return SNRom_SABioLib.LibrarySize()
EndFunction

Int Function DefineAll() Global
    { Offers both libraries. Called on every game load: a Define that changes
      nothing writes nothing, and this is how new block text reaches players. }
    Return SNRom_SABioLib.DefineRelationships() + SNRom_SABioLib.DefineArousal()
EndFunction

Bool Function Apply(Actor akActor, String asLocalKey) Global
    Return SeverActionsNativeExt2.BioApi_Apply(akActor, SNRom_SABioLib.PREFIX() + asLocalKey)
EndFunction

Bool Function Unapply(Actor akActor, String asLocalKey) Global
    Return SeverActionsNativeExt2.BioApi_Unapply(akActor, SNRom_SABioLib.PREFIX() + asLocalKey)
EndFunction

Bool Function IsApplied(Actor akActor, String asLocalKey) Global
    Return SeverActionsNativeExt2.BioApi_IsApplied(akActor, SNRom_SABioLib.PREFIX() + asLocalKey)
EndFunction

String[] Function AssignedTitles(Actor akActor) Global
    { Every block the person's bio shows, the player's own included, as titles.

      FROM API v2 (SeverActions 4.3.0) THE PUBLIC, FROZEN READ, BioApi_ListApplied,
      which is what we asked for (2026-10-05): its titles are field 3 of each
      record. Before that, Native_BioBlock_AssignedTitles - written for
      SeverActions' VR menu, not part of its public API - which every v1
      install still has. Either way an empty answer means "carries nothing". }
    If SeverActionsNativeExt2.BioApi_Version() < 2
        Return SeverActionsNativeExt2.Native_BioBlock_AssignedTitles(akActor)
    EndIf
    String[] recs = SeverActionsNativeExt2.BioApi_ListApplied(akActor)
    Int n = 0
    If recs
        n = recs.Length
    EndIf
    String[] titles = Utility.CreateStringArray(n)
    Int i = 0
    While i < n
        String[] f = StringUtil.Split(recs[i], "\t")
        If f.Length >= 3
            titles[i] = f[2]
        EndIf
        i += 1
    EndWhile
    Return titles
EndFunction

String[] Function ListApplied(Actor akActor) Global
    { API v2: the raw records (see the stub). Callers check Version() >= 2. }
    Return SeverActionsNativeExt2.BioApi_ListApplied(akActor)
EndFunction

String[] Function ListBlocks() Global
    { API v4: every keyed block, intimate ones included (the author wants
      Sexual Behavior and Kinks among the choices). Callers check Version() >= 4. }
    Return SeverActionsNativeExt2.BioApi_ListBlocks(True)
EndFunction

Bool Function ApplyKey(Actor akActor, String asFullKey) Global
    { A block by its FULL key - someone else's (SeverActions' own shipped
      blocks), not ours: Apply adds our prefix. }
    Return SeverActionsNativeExt2.BioApi_Apply(akActor, asFullKey)
EndFunction

Bool Function UnapplyKey(Actor akActor, String asFullKey) Global
    Return SeverActionsNativeExt2.BioApi_Unapply(akActor, asFullKey)
EndFunction

Bool Function IsAppliedKey(Actor akActor, String asFullKey) Global
    Return SeverActionsNativeExt2.BioApi_IsApplied(akActor, asFullKey)
EndFunction

Function MarkOneBlockTabs() Global
    { API v3: Drawn To, Expression and Attachment each answer one question, so
      a second block in one only ever contradicts the first (Untroubled beside
      Needs to Be the Only One). Appetite too. NOT Limits: someone holds
      several. Every load; a tab the player set by hand keeps their choice
      (SetTabExclusive then answers False and changes nothing). }
    If SeverActionsNativeExt2.BioApi_Version() < 3
        Return
    EndIf
    SeverActionsNativeExt2.BioApi_SetTabExclusive("Relationships: Drawn To", True)
    SeverActionsNativeExt2.BioApi_SetTabExclusive("Relationships: Expression", True)
    SeverActionsNativeExt2.BioApi_SetTabExclusive("Relationships: Attachment", True)
    SeverActionsNativeExt2.BioApi_SetTabExclusive("Arousal: Appetite", True)
EndFunction
