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
    { Every block the person carries, the player's own included, as titles.
      NOT part of SeverActions' frozen public API (it serves their VR menu), so
      a future SeverActions may change it. Present since 3.9.14, so wherever
      Version() is 1 or more it is there too; that is the only condition under
      which callers use an empty answer as "carries nothing". }
    Return SeverActionsNativeExt2.Native_BioBlock_AssignedTitles(akActor)
EndFunction
