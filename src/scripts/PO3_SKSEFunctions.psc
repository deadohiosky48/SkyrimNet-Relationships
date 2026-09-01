Scriptname PO3_SKSEFunctions Hidden

{ HEADER ONLY - declarations so our code compiles, exactly like MARAS.psc and
  Romantasy.psc. po3's PapyrusExtender ships the real .pex and NO source, so
  this file exists solely to satisfy the compiler and is never itself compiled
  (build.ps1 selects SNRom_*.psc only) and never shipped (package.ps1 does the
  same).

  ONLY the four keyword functions are declared, and only because we call them.
  Declaring a native does not create it: at runtime these bind by name to
  po3_PapyrusExtender.dll, so a missing DLL means the CALL fails, not the load.
  Guard every use.

  AddKeywordToForm's signature is CONFIRMED from a real call site -
  DbMiscFunctions.psc:862, `PO3_SKSEFunctions.AddKeywordToForm(B, keywords[i])`
  where B is a Form. The other three are inferred by symmetry from the names
  exported by PO3_SKSEFunctions.pex and are NOT verified. If a call errors at
  runtime with a mismatched-signature complaint, that is why. }

; Base form. po3's documentation describes these as runtime-only rather than
; persisted, which matters for anything we add: a reload is expected to clear
; it. NOT VERIFIED - treat a reload as likely to reset, never as guaranteed.
Function AddKeywordToForm(Form akForm, Keyword akKeyword) global native
Function RemoveKeywordOnForm(Form akForm, Keyword akKeyword) global native

; Single reference, leaving other instances of the same base untouched.
Function AddKeywordToRef(ObjectReference akRef, Keyword akKeyword) global native
Function RemoveKeywordFromRef(ObjectReference akRef, Keyword akKeyword) global native
