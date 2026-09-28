Scriptname SeverActionsNativeExt2 Hidden
{ VENDORED HEADER - compile-time only, and deliberately minimal.

  The real script is SeverActions' own (3.9.14 and later, including the Beta 25
  build), and it declares hundreds of natives. This declares the ONE we call,
  so our build does not depend on what happens to be deployed in Data.

  Never shipped and never compiled to .pex: build.ps1 and package.ps1 both take
  SNRom_*.psc only, the same rule that keeps Romantasy.psc, MARAS.psc and
  SkyrimNetApi.psc as imports. At runtime SeverActions' own .pex supplies it.

  Titles come back exactly as the player sees them in the library, which is
  why the caller strips an import-collision suffix such as " (2)". }

String[] Function Native_BioBlock_AssignedTitles(Actor akActor) Global Native
