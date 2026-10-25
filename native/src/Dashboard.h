#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "Display.h"

// The dashboard: the page in ui/relationships/, hosted by a UI framework
// (ViewHost), and the protocol bridge.js defines for talking to it.
//
// THE DLL IS OPTIONAL, AND SO IS THE DASHBOARD. Without Meridian UI the rest of
// the plugin still loads, and without this DLL the mod still works: Papyrus
// calls nothing here unless SKSE.GetPluginVersion says the DLL is present.
namespace SNRom::Dashboard {

    // kInputLoaded: ask for the UI framework. Logs once if there is none.
    void OnInputLoaded();

    // kDataLoaded: create the (hidden) view and register the page's two
    // window functions, snromRequest and snromClose.
    void OnDataLoaded();

    // The hotkey. Opens the dashboard, or closes it if it has focus. Main
    // thread only: Hotkey.cpp's sink queues it.
    void Toggle();

    // kPreLoadGame and kNewGame: the read model forgets the timeline being
    // left, so it can never show one save's values in another.
    void OnGameLoading();

    // ---- From the Papyrus natives (Natives.cpp), on a VM thread. Each writes
    // the read model under its lock and QUEUES anything that touches the view.
    //
    // a_generation > 0: part of that refresh. 0: unsolicited, from a text
    // writer or a finished LLM callback; shown at once if the view is open.
    // < 0: part of a page action, whose ActionDone sends the snapshot.
    void PushNumbers(std::int32_t a_generation, std::int32_t a_formId, const std::vector<std::int32_t>& a_values);
    void PushText(std::int32_t a_generation, std::int32_t a_formId, const std::vector<std::string>& a_values);
    void PushPlaythrough(std::int32_t a_generation, std::string a_id, std::string a_store, std::int32_t a_decision);
    // Once per refresh, before its RefreshDone: what Papyrus fetched with the
    // batch APIs (MARAS, SeverActions) and the kin guard.
    void PushFacts(std::int32_t a_generation, Display::BatchFacts a_facts);
    void DropBond(std::int32_t a_formId);

    // What the engine says about one actor, and the player's sex, as the
    // snapshot reads them. Main thread. Shared with the read API (Api.cpp).
    Display::EngineFacts EngineFactsOf(std::int32_t a_formId);
    std::int32_t         PlayerSexNow();
    // a_status is "ok", or "not ready: <why>".
    void RefreshDone(std::int32_t a_generation, std::int32_t a_count, std::string a_status);

    // The developer tool "Check the display against the rules": Papyrus's
    // real answers for one bond, compared with the display copy worked out
    // from fresh facts. Logs each disagreement; returns how many. MAIN THREAD
    // (the native waits for it), because it reads the engine.
    std::int32_t CheckBond(std::int32_t a_formId, bool a_following, std::int32_t a_commitment,
                           std::int32_t a_applicability);

    // A page action's Int arguments, for SNRom_Bridge.OnDashboardAction.
    std::vector<std::int32_t> ActionArgs(std::int32_t a_requestId);
    std::string               ActionText(std::int32_t a_requestId);
    // Papyrus's answer to a page action. A long-running one says "started",
    // and its LLM callback's push is its end.
    void ActionDone(std::int32_t a_requestId, bool a_ok, std::string a_message);

    // From the SkyrimNet setting dashboardDeveloperView, via Papyrus
    // (SNRom_Native.SetDeveloperView) and the settings watcher. Sent to the
    // page as settings.developer, at once if the dashboard is open.
    void SetDeveloperView(bool a_on);

    // From the SkyrimNet settings dashboardScale and dashboardTextSize, the
    // same two ways: SNRom_Native.SetDisplaySettings at bootstrap, and the
    // settings watcher. Values as Settings::ScaleFromName and TextSizeFromName
    // read them; an empty one stays as it is. Sent to the page as
    // settings.scale and settings.textSize, at once if the dashboard is open.
    void SetDisplay(std::optional<std::int32_t> a_scale, std::optional<std::int32_t> a_textSize);

    // ---- QUESTIONS FOR THE PLAYER IN OUR OWN UI (2.5), in place of a Papyrus
    // message box. One at a time, in the order asked: over the dashboard if it
    // is open, otherwise the view opens showing the question alone, and closes
    // when it is answered. From a VM thread.
    //
    // Ask returns the question's id, or 0 when there is no dashboard view (no
    // UI framework): the caller then asks some other way.
    // a_default: the button a running-out timer of a_seconds chooses (-1:
    // none, so it is dismissed; 0 seconds: no timer). M8c.
    std::int32_t Ask(std::string a_title, std::string a_body, std::vector<std::string> a_buttons,
                     std::int32_t a_default = -1, float a_seconds = 0.0f);

    // kAskPending until answered; then, ONCE (the answer is forgotten when
    // read), the button's index, kAskDismissed (closed without a choice), or
    // kAskUnshown (another menu kept the screen for a minute).
    inline constexpr std::int32_t kAskPending = -2;
    inline constexpr std::int32_t kAskDismissed = -1;
    inline constexpr std::int32_t kAskUnshown = -3;
    std::int32_t AskAnswer(std::int32_t a_id);

    // As AskAnswer, but the answer stays to be read (SNRom_Choice's
    // non-blocking questions, which look before they take).
    std::int32_t AskPeek(std::int32_t a_id);

    // Withdraws a question: off the queue, or off the screen.
    void AskCancel(std::int32_t a_id);
}
