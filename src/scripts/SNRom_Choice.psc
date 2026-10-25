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

Int Function Open(String asBody, String asAccept, String asDecline, String asDefer, Int aiDefault = 2, \
    Float afSeconds = 30.0) Global
    { Puts the box on screen and returns IMMEDIATELY with a box id.

      IN OUR OWN VIEW FIRST (Build B, M8c): a negative id is our question
      (SNRom_Native.AskOpenEx, waiting for a calm moment, then floating with a
      timer that chooses aiDefault after afSeconds); a positive one is
      SkyMessage's, when there is no view.

      Non-blocking on purpose. The caller is the follower sweep, which runs on a
      game-time update and must not sit in a wait loop holding a script thread
      while the player wanders off with a menu open. Poll IsAnswered() on a
      later tick and read it with Take().

      Returns 0 if the box could not be opened, which is the same signal
      SkyMessage itself uses for "plugin not installed". Callers MUST test for
      it - a 0 id passed to IsAnswered() would poll forever on a box that does
      not exist, and the question would silently never be asked. }
    If InView()
        Int id = SNRom_Native.AskOpenEx("", asBody, Buttons(asAccept, asDecline, asDefer), aiDefault, afSeconds)
        If id > 0
            Return -id
        EndIf
    EndIf
    Return SkyMessage.Show_NonBlocking(asBody, asAccept, asDecline, asDefer)
EndFunction

Bool Function IsAnswered(Int aiBoxId) Global
    { False for a 0/invalid id as well as for an unanswered box, so a failed
      Open() can never look like a pending question. }
    If aiBoxId == 0
        Return False
    ElseIf aiBoxId < 0
        Return SNRom_Native.AskPeek(-aiBoxId) != -2
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
    ElseIf aiBoxId < 0
        Int answer = SNRom_Native.AskAnswer(-aiBoxId)
        If answer < 0
            Return ANSWER_NONE()
        EndIf
        Return answer
    EndIf
    Return SkyMessage.GetResultIndex(aiBoxId)
EndFunction

Function Discard(Int aiBoxId) Global
    { Throw a pending box away without reading it - for when the subject dies,
      unenrolls, or the romance ends while the question is still on screen.
      Leaking ids is not catastrophic but they accumulate for the session. }
    If aiBoxId < 0
        SNRom_Native.AskCancel(-aiBoxId)
    ElseIf aiBoxId != 0
        SkyMessage.Delete(aiBoxId)
    EndIf
EndFunction

Int Function AskNow(String asBody, String asAccept, String asDecline, String asDefer, Float afTimeoutSeconds = 60.0, \
    Int aiDefault = -1, Float afSeconds = 30.0) Global
    { Blocking convenience: shows the box and waits for an answer.

      IN OUR OWN VIEW FIRST (Build B, M8c): floating, at a calm moment, its
      timer choosing aiDefault after afSeconds (AskInViewEx). A message box
      only when there is no view.

      For MANUAL dispatch and testing only - the sweep uses Open()/IsAnswered()/
      Take() instead. Kept because it makes the whole round trip testable from
      one execute-quest-script-function call, with no timer involved, which is
      how the natives get proven before anything is built on them.

      Timeout is real seconds and returns ANSWER_NONE, so a dispatched thread
      cannot be parked indefinitely if the player ignores the box. }
    If InView()
        Return AskInViewEx("", asBody, Buttons(asAccept, asDecline, asDefer), aiDefault, afSeconds)
    EndIf
    Int boxId = SkyMessage.Show_NonBlocking(asBody, asAccept, asDecline, asDefer)
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

Int Function AskList(String asBody, String[] asButtons, Float afTimeoutSeconds = 60.0) Global
    { AskNow with any number of buttons (2.5: which ring, which betrothed).
      Returns the index of the button chosen, or ANSWER_NONE on a timeout or a
      box that could not open. }
    If asButtons.Length == 0
        Return ANSWER_NONE()
    EndIf
    Int boxId = SkyMessage.ShowArray_NonBlocking(asBody, asButtons)
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

Int Function AskInView(String asTitle, String asBody, String[] asButtons) Global
    { AskInViewEx with no default and no timer. }
    Return AskInViewEx(asTitle, asBody, asButtons, -1, 0.0)
EndFunction

Int Function AskInViewEx(String asTitle, String asBody, String[] asButtons, Int aiDefault, Float afSeconds) Global
    { THE QUESTION IN OUR OWN UI (2.5; the author, 2026-10-19: "Use our UI for
      the confirmation box"), shown by the DLL in the dashboard's view
      (SNRom_Native.AskOpen). Returns the index of the button chosen, or
      ANSWER_NONE when it was dismissed or never answered. The caller has
      checked that the natives are version 17 or later.

      Lines of asBody are split on a newline (NL()). With no dashboard view (no
      UI framework installed), or when another menu held the screen for a
      minute, the same question is asked in a message box instead.

      FLOATING, AT A CALM MOMENT (Build B, M8c; the author, 2026-10-20): asked
      on its own, the question waits until the player is out of combat, in no
      menu or conversation and at no wedding, then floats low on the screen
      while the game plays on, with a timer bar that chooses aiDefault after
      afSeconds (-1: none). Over an open dashboard it is asked there, paused,
      as before.

      Waits in menu time, which counts whether or not a menu is open. Ten
      minutes at most; a question still unasked then is withdrawn. }
    If asButtons.Length == 0
        Return ANSWER_NONE()
    EndIf
    Int id = 0
    If SNRom_Native.Version() >= 28
        id = SNRom_Native.AskOpenEx(asTitle, asBody, asButtons, aiDefault, afSeconds)
    Else
        id = SNRom_Native.AskOpen(asTitle, asBody, asButtons)
    EndIf
    Int answer = -3
    If id > 0
        answer = SNRom_Native.AskAnswer(id)
        Float started = Utility.GetCurrentRealTime()
        While answer == -2 && (Utility.GetCurrentRealTime() - started) < 600.0
            Utility.WaitMenuMode(0.2)
            answer = SNRom_Native.AskAnswer(id)
        EndWhile
        If answer == -2
            SNRom_Native.AskCancel(id)
            Return ANSWER_NONE()
        EndIf
    EndIf
    If answer == -3 || id <= 0
        Return AskList(asTitle + NL() + NL() + asBody, asButtons)
    EndIf
    If answer < 0
        Return ANSWER_NONE()
    EndIf
    Return answer
EndFunction

Bool Function InView() Global
    { Our own view can ask (natives v28, M8c). Without the DLL, or one older,
      SkyMessage asks. }
    Return SNRom_Native.Version() >= 28
EndFunction

String[] Function Buttons(String asAccept, String asDecline, String asDefer) Global
    { Two or three buttons, in SkyMessage's order: an empty asDefer leaves the
      third out. }
    Int count = 2
    If asDefer != ""
        count = 3
    EndIf
    String[] out = Utility.CreateStringArray(count)
    out[0] = asAccept
    out[1] = asDecline
    If count == 3
        out[2] = asDefer
    EndIf
    Return out
EndFunction
