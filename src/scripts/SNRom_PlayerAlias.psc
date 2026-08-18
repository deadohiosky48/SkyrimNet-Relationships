Scriptname SNRom_PlayerAlias extends ReferenceAlias
{ Re-establishes the bridge on every game load.

  Decorator registrations and ModEvent registrations do NOT survive a
  save/load. Without this the integration silently stops working after the
  first reload - a nasty failure mode, because everything looks fine until
  you notice nothing is scoring.

  Resolves the bridge via GetOwningQuest() rather than a filled property, so
  there is nothing to wire by hand in the Creation Kit and nothing to leave
  unset. }

Event OnInit()
    Rebind(True)
EndEvent

Event OnPlayerLoadGame()
    { FORCED. This event fires exactly once per game load and is the only
      unambiguous "new session" signal available, so it must never be
      debounced away.

      Bootstrap's debounce compares Utility.GetCurrentRealTime() against a
      value that PERSISTS in the save. Load a save at a similar point in the
      launch as last time and the delta lands inside the debounce window, so
      the whole bootstrap is skipped on a brand new session. Observed
      2026-07-29: the spark timer was never armed for an entire play session
      and nothing logged, because RegisterForSingleUpdateGameTime lives inside
      the part that got skipped. Real time cannot distinguish sessions; this
      event can. }
    Rebind(True)
EndEvent

Function Rebind(Bool abForce = False)
    SNRom_Bridge bridge = GetOwningQuest() as SNRom_Bridge
    If bridge == None
        Debug.Trace("[SNRom] Player alias could not resolve SNRom_Bridge on its owning quest.")
        Return
    EndIf
    bridge.Bootstrap(abForce)
EndFunction
