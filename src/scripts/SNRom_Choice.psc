ScriptName SNRom_Choice Hidden
{ The player's explicit yes/no, asked as a real message box.

  WHY THIS IS ITS OWN SCRIPT AND NOT PART OF SNRom_Bridge
  -------------------------------------------------------
  Every function here reaches SkyMessage, which is `global native` and backed
  by SkyrimScripting.MessageBox.dll. If that DLL or SkyMessage.pex is missing,
  the script that references it fails to link. Papyrus link failure is
  PER-SCRIPT, so keeping these calls out of SNRom_Bridge means a missing
  dependency costs the player this one feature instead of enrollment,
  assessment, awards and seeding all at once.

  That is not a hypothetical worry in this project. The pattern that keeps
  costing us is a silent failure in one place taking out something unrelated -
  dead StorageUtil keys reading 0.0 forever, a decorator returning a default
  nobody ever wrote. Isolating the one call with an external native dependency
  is the cheapest insurance available.

  WHERE IT COMES FROM
  -------------------
  SkyMessage ships with "Papyrus MessageBox" (Nexus 83578,
  github.com/SkyrimScripting/MessageBox). MARAS bundles the identical DLL and
  scripts, and this mod already integrates with MARAS for marriage detection,
  so on any setup this mod targets the dependency is already satisfied. There
  is no ESP or ESL - no plugin slot, no load order position.

  NO PRESENCE CHECK IS NEEDED. Show_NonBlocking returns 0 when the plugin is
  absent (SkyMessage.psc does exactly this test before falling back to a
  Debug.MessageBox nag). Open() returns that 0 straight through, so callers
  test the id rather than probing for the mod.
}

Import StringUtil

Int Function ANSWER_NONE() Global
    { No answer yet, or the box could not be opened. }
    Return -1
EndFunction

Int Function ANSWER_ACCEPT() Global
    Return 0
EndFunction

Int Function ANSWER_DECLINE() Global
    Return 1
EndFunction

Int Function ANSWER_DEFER() Global
    { "Not now." Deliberately NOT the same as declining: it leaves the question
      open so the retry timer asks again later, rather than friend-zoning
      someone because the player was mid-fight and wanted the box gone. }
    Return 2
EndFunction

String Function NL() Global
    { Papyrus has no \n escape. It supports \" and \\ and nothing else, which is
      why SNRom_Decorators.JsonEscape has to build tab/LF/CR from character
      codes too. Build the newline the same way rather than discovering at
      runtime that the body text is one long run-on line.

      AsChar(10) only. Never loop AsChar over a range that includes 0 - AsChar(0)
      yields an EMPTY string, and ReplaceAll(s, "", x) froze the game solid on
      2026-08-06. }
    Return StringUtil.AsChar(10)
EndFunction

Int Function Open(String asBody, String asAccept, String asDecline, String asDefer) Global
    { Puts the box on screen and returns IMMEDIATELY with a box id.

      Non-blocking on purpose. The caller is the follower sweep, which runs on a
      game-time update and must not sit in a wait loop holding a script thread
      while the player wanders off with a menu open. Poll IsAnswered() on a
      later tick and read it with Take().

      Returns 0 if the box could not be opened, which is the same signal
      SkyMessage itself uses for "plugin not installed". Callers MUST test for
      it - a 0 id passed to IsAnswered() would poll forever on a box that does
      not exist, and the question would silently never be asked. }
    Return SkyMessage.Show_NonBlocking(asBody, asAccept, asDecline, asDefer)
EndFunction

Bool Function IsAnswered(Int aiBoxId) Global
    { False for a 0/invalid id as well as for an unanswered box, so a failed
      Open() can never look like a pending question. }
    If aiBoxId == 0
        Return False
    EndIf
    Return SkyMessage.IsMessageResultAvailable(aiBoxId)
EndFunction

Int Function Take(Int aiBoxId) Global
    { Reads the chosen button index and RELEASES the box.

      Reading is destructive: GetResultIndex deletes the stored result and
      invalidates the id unless deleteResultOnAccess is False. We want exactly
      one read, so the default is correct - but it means the answer is gone
      after this call and the caller must act on the value it gets back rather
      than re-reading later.

      Returns ANSWER_NONE for an invalid id or an unanswered box. }
    If !IsAnswered(aiBoxId)
        Return ANSWER_NONE()
    EndIf
    Return SkyMessage.GetResultIndex(aiBoxId)
EndFunction

Function Discard(Int aiBoxId) Global
    { Throw a pending box away without reading it - for when the subject dies,
      unenrolls, or the romance ends while the question is still on screen.
      Leaking ids is not catastrophic but they accumulate for the session. }
    If aiBoxId != 0
        SkyMessage.Delete(aiBoxId)
    EndIf
EndFunction

Int Function AskNow(String asBody, String asAccept, String asDecline, String asDefer, Float afTimeoutSeconds = 60.0) Global
    { Blocking convenience: shows the box and waits for an answer.

      For MANUAL dispatch and testing only - the sweep uses Open()/IsAnswered()/
      Take() instead. Kept because it makes the whole round trip testable from
      one execute-quest-script-function call, with no timer involved, which is
      how the natives get proven before anything is built on them.

      Timeout is real seconds and returns ANSWER_NONE, so a dispatched thread
      cannot be parked indefinitely if the player ignores the box. }
    Int boxId = Open(asBody, asAccept, asDecline, asDefer)
    If boxId == 0
        Return ANSWER_NONE()
    EndIf
    Float started = Utility.GetCurrentRealTime()
    While !SkyMessage.IsMessageResultAvailable(boxId) && (Utility.GetCurrentRealTime() - started) < afTimeoutSeconds
        Utility.WaitMenuMode(0.1)
    EndWhile
    If !SkyMessage.IsMessageResultAvailable(boxId)
        Discard(boxId)
        Return ANSWER_NONE()
    EndIf
    Return SkyMessage.GetResultIndex(boxId)
EndFunction
