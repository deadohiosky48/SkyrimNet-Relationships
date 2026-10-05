Scriptname SeverActionsNativeExt2 Hidden
{ VENDORED HEADER - compile-time only, and deliberately minimal.

  The real script is SeverActions' own, and it declares hundreds of natives.
  This declares only the ones we call, so our build does not depend on what
  happens to be deployed in Data.

  Never shipped and never compiled to .pex: build.ps1 and package.ps1 both take
  SNRom_*.psc only, the same rule that keeps Romantasy.psc, MARAS.psc and
  SkyrimNetApi.psc as imports. At runtime SeverActions' own .pex supplies it.

  ONLY SNRom_SABio AND SNRom_SABioLib MAY NAME THIS SCRIPT. SeverActions' API
  guide: where SeverActions is absent, a script that names it cannot be used,
  so every call lives in those two small scripts and everything else reaches
  them by static calls after checking that SeverActions is installed. }

; Titles come back exactly as the player sees them in the library, which is
; why the caller strips an import-collision suffix such as " (2)". Written for
; SeverActions' own VR menu and NOT part of its frozen public API: it can
; change in a SeverActions release. The public API sees only our own keys.
String[] Function Native_BioBlock_AssignedTitles(Actor akActor) Global Native

; Bio Blocks public API v1 (SeverActions 4.0.1 and later). Frozen: the
; signatures never change and the functions are never removed. The guide is
; Data/SKSE/Plugins/SeverActions/API/BIO_BLOCKS_API.md.
Int Function BioApi_Version() Global Native
Bool Function BioApi_Define(String asKey, String asTitle, String asContent, String asTab) Global Native
Bool Function BioApi_Exists(String asKey) Global Native
Bool Function BioApi_Apply(Actor akActor, String asKey) Global Native
Bool Function BioApi_Unapply(Actor akActor, String asKey) Global Native
Bool Function BioApi_IsApplied(Actor akActor, String asKey) Global Native
