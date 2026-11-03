ScriptName SNRom_Choice Hidden
{ The player's explicit answer, asked as a card in our own UI.

  OUR OWN UI ONLY (the author, 2026-11-03: "convert the Papyrus MessageBox
  popups to our own UI cards ... Then we can completely eliminate dependency
  on that mod"). Every question is a card the DLL shows in whichever UI
  framework is installed - Meridian UI, Magelight UI or Prisma UI - the same
  view the dashboard uses (SNRom_Native.AskOpenEx, Dashboard::Ask). Papyrus
  MessageBox (SkyMessage) is no longer used: MARAS bundled it, players drop
  MARAS after the import, and a script that names SkyMessage fails to link
  without it, taking every question with it.

  WITH NO UI FRAMEWORK nothing can be asked: AskOpenEx returns 0, the DLL says
  so once a session, and the callers treat the question as unanswered (still
  owed, asked again later). One of the three is required for this reason.

  WHY THIS IS STILL ITS OWN SCRIPT: the polling pairs (Open/IsAnswered/Take)
  and the blocking ones (AskNow) are shared by the consent question and every
  marriage confirmation, and keep the box-id conventions in one place.
}

Import StringUtil

Int Function ANSWER_NONE() Global
    { No answer yet, or the question could not be asked. }
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
    { Puts the question on screen and returns IMMEDIATELY with a box id.

      A card in our own view (SNRom_Native.AskOpenEx): it waits for a calm
      moment, then floats with a timer that chooses aiDefault after afSeconds.
      The id is the question's, negated.

      Non-blocking on purpose. The caller is the follower sweep, which runs on a
      game-time update and must not sit in a wait loop holding a script thread
      while the player wanders off with a menu open. Poll IsAnswered() on a
      later tick and read it with Take().

      Returns 0 when it could not be asked (no UI framework). Callers MUST
      test for it - a 0 id passed to IsAnswered() would poll forever on a box
      that does not exist, and the question would silently never be asked. }
    If !InView()
        Return 0
    EndIf
    Int id = SNRom_Native.AskOpenEx("", asBody, Buttons(asAccept, asDecline, asDefer), aiDefault, afSeconds)
    If id > 0
        Return -id
    EndIf
    Return 0
EndFunction

Bool Function IsAnswered(Int aiBoxId) Global
    { False for a 0 id as well as for an unanswered question, so a failed Open()
      can never look like a pending one.

      A POSITIVE id was a Papyrus MessageBox box, from a save made before
      2026-11-03. Nothing can answer it now, so it reads as answered and Take()
      gives ANSWER_NONE: the question stays owed and is asked again, as a card. }
    If aiBoxId == 0
        Return False
    ElseIf aiBoxId > 0
        Return True
    EndIf
    Return SNRom_Native.AskPeek(-aiBoxId) != -2
EndFunction

Int Function Take(Int aiBoxId) Global
    { Reads the chosen button index and RELEASES the question. The answer is
      forgotten once read (Dashboard::AskAnswer), so the caller must act on the
      value it gets back rather than re-reading later.

      Returns ANSWER_NONE for an invalid id, an unanswered question, or one
      closed without a choice. }
    If aiBoxId >= 0 || !IsAnswered(aiBoxId)
        Return ANSWER_NONE()
    EndIf
    Int answer = SNRom_Native.AskAnswer(-aiBoxId)
    If answer < 0
        Return ANSWER_NONE()
    EndIf
    Return answer
EndFunction

Function Discard(Int aiBoxId) Global
    { Throw a pending question away without reading it - for when the subject
      dies, unenrolls, or the romance ends while it is still on screen. }
    If aiBoxId < 0
        SNRom_Native.AskCancel(-aiBoxId)
    EndIf
EndFunction

Int Function AskNow(String asBody, String asAccept, String asDecline, String asDefer, Float afTimeoutSeconds = 60.0, \
    Int aiDefault = -1, Float afSeconds = 30.0) Global
    { Blocking convenience: asks and waits for an answer (AskInViewEx):
      floating, at a calm moment, its timer choosing aiDefault after afSeconds.

      afTimeoutSeconds is no longer used: it bounded the wait on a message box.
      A card is waited on for ten minutes at most (AskInViewEx). Kept so no
      caller changes.

      Returns ANSWER_NONE when it could not be asked or was never answered. }
    Return AskInViewEx("", asBody, Buttons(asAccept, asDecline, asDefer), aiDefault, afSeconds)
EndFunction

Int Function AskList(String asBody, String[] asButtons, Float afTimeoutSeconds = 60.0) Global
    { AskNow with any number of buttons (2.5: which ring, which betrothed), as a
      card with no default and no timer. afTimeoutSeconds as in AskNow. }
    Return AskInViewEx("", asBody, asButtons, -1, 0.0)
EndFunction

Int Function AskInView(String asTitle, String asBody, String[] asButtons) Global
    { AskInViewEx with no default and no timer. }
    Return AskInViewEx(asTitle, asBody, asButtons, -1, 0.0)
EndFunction

Int Function AskInViewEx(String asTitle, String asBody, String[] asButtons, Int aiDefault, Float afSeconds) Global
    { THE QUESTION IN OUR OWN UI (2.5; the author, 2026-10-19: "Use our UI for
      the confirmation box"), shown by the DLL in the dashboard's view
      (SNRom_Native.AskOpenEx). Returns the index of the button chosen, or
      ANSWER_NONE when it was dismissed, never answered, or could not be asked.

      Lines of asBody are split on a newline (NL()).

      FLOATING, AT A CALM MOMENT (Build B, M8c; the author, 2026-10-20): asked
      on its own, the question waits until the player is out of combat, in no
      menu or conversation and at no wedding, then floats low on the screen
      while the game plays on, with a timer bar that chooses aiDefault after
      afSeconds (-1: none). Over an open dashboard it is asked there, paused,
      as before.

      KEPT OFF THE SCREEN (-3, another menu held it for a minute): asked again,
      as a card, rather than in a message box as before (2026-11-03).

      Waits in menu time, which counts whether or not a menu is open. Ten
      minutes at most, asking again included; a question still unasked then
      is withdrawn. }
    If asButtons.Length == 0 || !InView()
        Return ANSWER_NONE()
    EndIf
    Float started = Utility.GetCurrentRealTime()
    Int id = 0
    Int answer = -3
    While answer == -3 && (Utility.GetCurrentRealTime() - started) < 600.0
        id = SNRom_Native.AskOpenEx(asTitle, asBody, asButtons, aiDefault, afSeconds)
        If id <= 0
            ; No UI framework: the DLL has told the player (Dashboard::Ask).
            Return ANSWER_NONE()
        EndIf
        answer = SNRom_Native.AskAnswer(id)
        While answer == -2 && (Utility.GetCurrentRealTime() - started) < 600.0
            Utility.WaitMenuMode(0.2)
            answer = SNRom_Native.AskAnswer(id)
        EndWhile
        If answer == -2
            SNRom_Native.AskCancel(id)
            Return ANSWER_NONE()
        EndIf
    EndWhile
    If answer < 0
        Return ANSWER_NONE()
    EndIf
    Return answer
EndFunction

Bool Function InView() Global
    { Our own view can ask: natives v28 or later (M8c). With an older DLL
      nothing is asked. }
    Return SNRom_Native.Version() >= 28
EndFunction

String[] Function Buttons(String asAccept, String asDecline, String asDefer) Global
    { Two or three buttons, accept first: an empty asDefer leaves the third
      out. }
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
